import Foundation
import Darwin
#if canImport(Shared)
import Shared
#endif
#if canImport(CPTYSupport)
import CPTYSupport
#endif

// MARK: - Local Shell Backend

/// A backend that spawns a real local shell via PTY.
/// Works in the iOS Simulator and on macOS — no VM, kernel, or rootfs needed.
/// Provides a genuine terminal experience for development and testing.
public final class LocalShellBackend: VMBackend, @unchecked Sendable {
    public let name = "Local Shell (PTY)"
    public let performanceTier = PerformanceTier.native
    public let requiresVMSetup = false

    public var isAvailable: Bool {
        Self.checkAvailability().available
    }

    public init() {}

    public static func checkAvailability() -> BackendAvailability {
        #if targetEnvironment(simulator) || os(macOS)
        return BackendAvailability(available: true, reason: nil)
        #else
        return BackendAvailability(available: false, reason: "Local shell only available in simulator/macOS")
        #endif
    }

    public func createVM(config: VMConfig) async throws -> VirtualMachine {
        return LocalShellVM(config: config)
    }
}

// MARK: - Local Shell VM

/// A lightweight "VM" that's really just a process manager for local PTY shells.
final class LocalShellVM: VirtualMachine, @unchecked Sendable {
    let id: String
    private let config: VMConfig
    private var _state: ContainerState = .creating
    private let lock = NSLock()
    private var processCounter: Int = 0
    private var processes: [Int: LocalPTYProcess] = [:]

    init(config: VMConfig) {
        self.id = config.id
        self.config = config
    }

    func getState() async -> ContainerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    func boot() async throws {
        lock.lock()
        _state = .running
        lock.unlock()
        PocketDevLogger.shared.info("Local shell VM \(id) ready")
    }

    func suspend() async throws {
        lock.lock()
        _state = .suspended
        lock.unlock()
    }

    func resume() async throws {
        lock.lock()
        _state = .running
        lock.unlock()
    }

    func stop() async throws {
        lock.lock()
        let procs = processes.values
        _state = .stopped
        lock.unlock()

        for proc in procs {
            proc.terminate()
        }
    }

    func kill() async throws {
        try await stop()
    }

    func spawnProcess(_ spec: ProcessSpec) async throws -> VMProcess {
        guard await getState() == .running else {
            throw PocketDevError.vmNotRunning
        }

        processCounter += 1
        let process = LocalPTYProcess(pid: processCounter, spec: spec)
        try process.start()
        processes[processCounter] = process
        return process
    }

    func info() async -> VMInfo {
        VMInfo(
            id: id,
            state: await getState(),
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            uptimeSeconds: 0
        )
    }

    func resizeTerminal(_ size: TerminalSize) async throws {
        lock.lock()
        let procs = Array(processes.values)
        lock.unlock()
        for proc in procs {
            try await proc.resize(size)
        }
    }

    deinit {
        for proc in processes.values {
            proc.terminate()
        }
    }
}

// MARK: - Local PTY Process

/// A real process running in a pseudo-terminal.
/// Uses POSIX PTY APIs to create a genuine terminal with full line editing,
/// signal handling, and escape sequence support.
final class LocalPTYProcess: VMProcess, @unchecked Sendable {
    let pid: Int
    let output: AsyncStream<ProcessOutput>
    private let outputContinuation: AsyncStream<ProcessOutput>.Continuation
    private let spec: ProcessSpec
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readThread: Thread?
    private var isRunning = false
    private let lock = NSLock()

    init(pid: Int, spec: ProcessSpec) {
        self.pid = pid
        self.spec = spec

        var continuation: AsyncStream<ProcessOutput>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation = $0 }
        self.outputContinuation = continuation
    }

    func start() throws {
        var childPid: pid_t = 0
        let rows = spec.terminalSize?.rows ?? 24
        let cols = spec.terminalSize?.columns ?? 80

        // Determine shell path
        let shellPath: String
        if spec.executablePath == "/bin/sh" || spec.executablePath.hasSuffix("sh") {
            if FileManager.default.fileExists(atPath: "/bin/zsh") {
                shellPath = "/bin/zsh"
            } else {
                shellPath = spec.executablePath
            }
        } else {
            shellPath = spec.executablePath
        }

        // pty_spawn_shell is available via CPTYSupport module (SPM) or bridging header (Xcode)
        masterFD = Int32(pty_spawn_shell(&childPid, UInt16(rows), UInt16(cols), shellPath))

        guard masterFD >= 0 else {
            throw PocketDevError.processSpawnFailed("Failed to create PTY (errno: \(errno))")
        }

        self.childPID = childPid
        isRunning = true

        PocketDevLogger.shared.info("Spawned local shell: \(shellPath) (PID: \(childPid), master FD: \(masterFD))")

        // Start background thread to read PTY output
        startReadLoop()
    }

    func write(_ data: Data) async throws {
        guard isRunning, masterFD >= 0 else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            _ = pty_write_data(masterFD, ptr, UInt(rawBuffer.count))
        }
    }

    func signal(_ signal: Int32) async throws {
        guard childPID > 0 else { return }
        Darwin.kill(childPID, signal)
    }

    func waitForExit() async throws -> Int32 {
        for await event in output {
            if case .exit(let code) = event {
                return code
            }
        }
        return 0
    }

    func resize(_ size: TerminalSize) async throws {
        guard masterFD >= 0 else { return }
        _ = pty_resize(masterFD, UInt16(size.rows), UInt16(size.columns))
    }

    func terminate() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        let fd = masterFD
        let cpid = childPID
        masterFD = -1
        childPID = 0
        lock.unlock()

        if wasRunning {
            pty_close(fd, cpid)
            outputContinuation.finish()
        }
    }

    deinit {
        terminate()
    }

    // MARK: - Private

    private func startReadLoop() {
        let fd = masterFD
        let continuation = outputContinuation

        let thread = Thread {
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while true {
                let bytesRead = pty_read_data(fd, buffer, UInt(bufferSize))

                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: Int(bytesRead))
                    continuation.yield(.stdout(data))
                } else if bytesRead == 0 {
                    break
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        Thread.sleep(forTimeInterval: 0.01)
                        continue
                    }
                    break
                }
            }

            var status: Int32 = 0
            waitpid(-1, &status, 0)
            let exited = (status & 0x7f) == 0
            let exitCode: Int32 = exited ? ((status >> 8) & 0xff) : 1
            continuation.yield(.exit(exitCode))
            continuation.finish()
        }
        thread.name = "PTY-Read-\(pid)"
        thread.start()
        self.readThread = thread
    }
}
