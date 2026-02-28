import Foundation
#if canImport(Shared)
import Shared
#endif

/// QEMU Tiny Code Generator backend — works on ALL iOS devices.
/// Uses threaded interpretation (no JIT) to emulate ARM64 Linux.
/// Slower than native Hypervisor (~3-5x) but requires no jailbreak or special entitlements.
/// Based on the approach proven by UTM SE.
///
/// On iOS, QEMU is embedded as a C library (not spawned as a process).
/// The QEMU engine runs in-process using the threaded interpreter.
public final class QEMUTCGBackend: VMBackend, @unchecked Sendable {
    public let name = "QEMU TCG (Emulated)"
    public let performanceTier = PerformanceTier.emulated
    public let requiresVMSetup = true

    public var isAvailable: Bool {
        Self.checkAvailability().available
    }

    public init(qemuBinaryPath: String? = nil) {}

    public static func checkAvailability() -> BackendAvailability {
        #if arch(arm64)
        return BackendAvailability(
            available: true,
            reason: nil,
            requiresEntitlement: false,
            requiresSideloading: false
        )
        #else
        return BackendAvailability(
            available: false,
            reason: "QEMU TCG backend requires ARM64",
            requiresEntitlement: false,
            requiresSideloading: false
        )
        #endif
    }

    public func createVM(config: VMConfig) async throws -> VirtualMachine {
        return QEMUEmbeddedVM(config: config)
    }
}

// MARK: - QEMU Embedded VM Implementation (iOS)
// On iOS, QEMU runs as an embedded C library (libqemu) within the app process.
// This is the approach used by UTM SE and iSH.

final class QEMUEmbeddedVM: VirtualMachine, @unchecked Sendable {
    let id: String
    private let config: VMConfig
    private var _state: ContainerState = .creating
    private let lock = NSLock()
    private var processCounter: Int = 0
    private var processes: [Int: QEMUEmbeddedProcess] = [:]

    // I/O buffers for the embedded QEMU engine
    private var inputBuffer = Data()
    private var outputBuffer = Data()
    private let bufferLock = NSLock()

    func getState() async -> ContainerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    init(config: VMConfig) {
        self.id = config.id
        self.config = config
    }

    func boot() async throws {
        lock.lock()
        _state = .booting
        lock.unlock()

        // STUB: Full implementation requires embedding libqemu as a C library.
        // Integration steps needed:
        // 1. Build QEMU for iOS (aarch64-softmmu) as a static library (libqemu-system-aarch64.a)
        //    - Configure with: --disable-jit --enable-tcg-interpreter --target-list=aarch64-softmmu
        //    - Cross-compile with iOS SDK: xcrun -sdk iphoneos clang ...
        // 2. Link libqemu into the app target via Package.swift or Xcode build settings
        // 3. Call qemu_init() with argv[] for machine config (virt, cpu, memory, devices)
        // 4. Attach virtio-console and virtio-vsock backends to in-process I/O buffers
        // 5. Run qemu_main_loop() on a dedicated background thread (not async)
        // 6. Wait for vminitd (inside the VM) to signal readiness via virtio-console

        PocketDevLogger.shared.info("[STUB] QEMU Embedded VM booting: \(config.cpuCount) vCPUs, \(config.memoryMB)MB RAM")
        PocketDevLogger.shared.info("[STUB] libqemu not yet integrated — running in demo mode")

        try await Task.sleep(nanoseconds: 500_000_000) // 500ms simulated boot

        lock.lock()
        _state = .running
        lock.unlock()

        PocketDevLogger.shared.info("[STUB] QEMU Embedded VM \(id) booted (demo mode)")
    }

    func suspend() async throws {
        lock.lock()
        _state = .suspended
        lock.unlock()
        PocketDevLogger.shared.info("VM \(id) suspended")
    }

    func resume() async throws {
        lock.lock()
        _state = .running
        lock.unlock()
        PocketDevLogger.shared.info("VM \(id) resumed")
    }

    func stop() async throws {
        lock.lock()
        _state = .stopped
        lock.unlock()
        PocketDevLogger.shared.info("VM \(id) stopped")
    }

    func kill() async throws {
        lock.lock()
        _state = .stopped
        lock.unlock()
        PocketDevLogger.shared.info("VM \(id) killed")
    }

    func spawnProcess(_ spec: ProcessSpec) async throws -> VMProcess {
        guard await getState() == .running else {
            throw PocketDevError.vmNotRunning
        }

        lock.lock()
        processCounter += 1
        let pid = processCounter
        lock.unlock()

        let process = QEMUEmbeddedProcess(pid: pid, spec: spec)
        try await process.start()

        lock.lock()
        processes[pid] = process
        lock.unlock()

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
        for (_, process) in processes {
            try await process.resize(size)
        }
    }
}

// MARK: - QEMU Embedded Process

final class QEMUEmbeddedProcess: VMProcess, @unchecked Sendable {
    let pid: Int
    private let spec: ProcessSpec
    private let outputContinuation: AsyncStream<ProcessOutput>.Continuation
    let output: AsyncStream<ProcessOutput>

    init(pid: Int, spec: ProcessSpec) {
        self.pid = pid
        self.spec = spec

        var continuation: AsyncStream<ProcessOutput>.Continuation!
        self.output = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation
    }

    func start() async throws {
        PocketDevLogger.shared.info("[STUB] Spawning process: \(spec.executablePath) \(spec.arguments.joined(separator: " "))")

        // Show a colored warning explaining this is a stub, then a prompt
        let warning = "\u{1B}[1;33m" +
            "╔══════════════════════════════════════════════════╗\r\n" +
            "║  PocketDev — QEMU TCG Backend (Demo Mode)        ║\r\n" +
            "╠══════════════════════════════════════════════════╣\r\n" +
            "║  libqemu is not yet integrated.                  ║\r\n" +
            "║  Input is echoed back — no real VM is running.   ║\r\n" +
            "║                                                  ║\r\n" +
            "║  To enable real execution, embed libqemu:        ║\r\n" +
            "║  1. Build QEMU aarch64-softmmu as static lib     ║\r\n" +
            "║  2. Link into PocketDev app target               ║\r\n" +
            "║  3. Provide vmlinux + initrd in app bundle       ║\r\n" +
            "╚══════════════════════════════════════════════════╝\u{1B}[0m\r\n" +
            "\r\n\(spec.executablePath) (stub)\r\n$ "
        outputContinuation.yield(.stdout(Data(warning.utf8)))
    }

    func write(_ data: Data) async throws {
        // Forward stdin to the VM process via virtio-console/vsock
        // For now, echo back the input as a demo
        if let text = String(data: data, encoding: .utf8) {
            if text == "\r" || text == "\n" {
                outputContinuation.yield(.stdout(Data("\r\n$ ".utf8)))
            } else {
                outputContinuation.yield(.stdout(data))
            }
        }
    }

    func signal(_ signal: Int32) async throws {
        if signal == 2 { // SIGINT
            outputContinuation.yield(.stdout(Data("^C\r\n$ ".utf8)))
        }
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
        // Send TIOCSWINSZ to process via vminitd
    }

    deinit {
        outputContinuation.finish()
    }
}
