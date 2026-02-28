import Foundation
#if canImport(Shared)
import Shared
#endif

/// Cloud/Remote VM backend — thin client that connects to a server-side container.
/// Works on ANY device, ANY iOS version. Network-dependent but always available.
/// Uses WebSocket for real-time terminal I/O with a cloud ARM64 VPS.
public final class RemoteVMBackend: VMBackend, @unchecked Sendable {
    public let name = "Remote VM (Cloud)"
    public let performanceTier = PerformanceTier.remote
    public let requiresVMSetup = true

    private let serverURL: URL
    private let apiKey: String?

    public var isAvailable: Bool { true }

    public init(serverURL: URL, apiKey: String? = nil) {
        self.serverURL = serverURL
        self.apiKey = apiKey
    }

    public static func checkAvailability() -> BackendAvailability {
        BackendAvailability(available: true)
    }

    public func createVM(config: VMConfig) async throws -> VirtualMachine {
        return try await RemoteVM(serverURL: serverURL, apiKey: apiKey, config: config)
    }
}

// MARK: - Remote VM Implementation

final class RemoteVM: VirtualMachine, @unchecked Sendable {
    let id: String
    private let serverURL: URL
    private let apiKey: String?
    private let config: VMConfig
    private var _state: ContainerState = .creating
    private let lock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession
    private var remoteContainerID: String?
    private var processCounter: Int = 0
    private var processes: [Int: RemoteVMProcess] = [:]

    func getState() async -> ContainerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    init(serverURL: URL, apiKey: String?, config: VMConfig) async throws {
        self.id = config.id
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.config = config
        self.session = URLSession(configuration: .default)

        // Create container on remote server
        try await createRemoteContainer()
    }

    private func createRemoteContainer() async throws {
        let url = serverURL.appendingPathComponent("/api/v1/containers")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "cpu_count": config.cpuCount,
            "memory_mb": config.memoryMB,
            "image": "alpine:latest", // Default, will be overridden by OCI image
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            throw PocketDevError.vmCreationFailed("Remote container creation failed")
        }

        let result = try JSONDecoder().decode(RemoteContainerResponse.self, from: data)
        self.remoteContainerID = result.id

        PocketDevLogger.shared.info("Remote container created: \(result.id)")
    }

    func boot() async throws {
        lock.lock()
        _state = .booting
        lock.unlock()

        guard let containerID = remoteContainerID else {
            throw PocketDevError.vmBootFailed("No remote container ID")
        }

        // Start container on remote
        let url = serverURL.appendingPathComponent("/api/v1/containers/\(containerID)/start")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw PocketDevError.vmBootFailed("Remote container start failed")
        }

        // Connect WebSocket for real-time I/O
        try await connectWebSocket()

        lock.lock()
        _state = .running
        lock.unlock()
    }

    private func connectWebSocket() async throws {
        guard let containerID = remoteContainerID else { return }

        var wsURL = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        wsURL.scheme = serverURL.scheme == "https" ? "wss" : "ws"
        wsURL.path = "/api/v1/containers/\(containerID)/attach"

        var request = URLRequest(url: wsURL.url!)
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        task.resume()
        self.webSocketTask = task

        PocketDevLogger.shared.info("WebSocket connected to remote container")
    }

    func suspend() async throws {
        // Remote containers can be paused
        guard let containerID = remoteContainerID else { return }
        let url = serverURL.appendingPathComponent("/api/v1/containers/\(containerID)/pause")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try await session.data(for: request)

        lock.lock()
        _state = .suspended
        lock.unlock()
    }

    func resume() async throws {
        guard let containerID = remoteContainerID else { return }
        let url = serverURL.appendingPathComponent("/api/v1/containers/\(containerID)/unpause")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try await session.data(for: request)

        lock.lock()
        _state = .running
        lock.unlock()
    }

    func stop() async throws {
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        guard let containerID = remoteContainerID else { return }
        let url = serverURL.appendingPathComponent("/api/v1/containers/\(containerID)/stop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try await session.data(for: request)

        lock.lock()
        _state = .stopped
        lock.unlock()
    }

    func kill() async throws {
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        guard let containerID = remoteContainerID else { return }
        let url = serverURL.appendingPathComponent("/api/v1/containers/\(containerID)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try await session.data(for: request)

        lock.lock()
        _state = .stopped
        lock.unlock()
    }

    func spawnProcess(_ spec: ProcessSpec) async throws -> VMProcess {
        guard await getState() == .running else {
            throw PocketDevError.vmNotRunning
        }
        guard let ws = webSocketTask else {
            throw PocketDevError.vsockConnectionFailed("WebSocket not connected")
        }

        lock.lock()
        processCounter += 1
        let pid = processCounter
        lock.unlock()

        let process = RemoteVMProcess(pid: pid, spec: spec, webSocket: ws)
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
        // Send resize command over WebSocket
        let msg = try JSONEncoder().encode(["type": "resize", "cols": "\(size.columns)", "rows": "\(size.rows)"])
        try await webSocketTask?.send(.data(msg))
    }
}

// MARK: - Remote VM Process

final class RemoteVMProcess: VMProcess, @unchecked Sendable {
    let pid: Int
    private let spec: ProcessSpec
    private let webSocket: URLSessionWebSocketTask
    private let outputContinuation: AsyncStream<ProcessOutput>.Continuation
    let output: AsyncStream<ProcessOutput>

    init(pid: Int, spec: ProcessSpec, webSocket: URLSessionWebSocketTask) {
        self.pid = pid
        self.spec = spec
        self.webSocket = webSocket

        var continuation: AsyncStream<ProcessOutput>.Continuation!
        self.output = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation
    }

    func start() async throws {
        let command = ([spec.executablePath] + spec.arguments).joined(separator: " ")
        let msg = try JSONEncoder().encode(["type": "exec", "command": command, "cwd": spec.workingDirectory])
        try await webSocket.send(.data(msg))

        // Start reading WebSocket messages
        Task { await readMessages() }
    }

    private func readMessages() async {
        while true {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .data(let data):
                    outputContinuation.yield(.stdout(data))
                case .string(let text):
                    outputContinuation.yield(.stdout(Data(text.utf8)))
                @unknown default:
                    break
                }
            } catch {
                outputContinuation.yield(.exit(1))
                outputContinuation.finish()
                break
            }
        }
    }

    func write(_ data: Data) async throws {
        try await webSocket.send(.data(data))
    }

    func signal(_ signal: Int32) async throws {
        let msg = try JSONEncoder().encode(["type": "signal", "signal": "\(signal)", "pid": "\(pid)"])
        try await webSocket.send(.data(msg))
    }

    func waitForExit() async throws -> Int32 {
        for await event in output {
            if case .exit(let code) = event {
                return code
            }
        }
        return -1
    }

    func resize(_ size: TerminalSize) async throws {
        let msg = try JSONEncoder().encode(["type": "resize", "cols": "\(size.columns)", "rows": "\(size.rows)"])
        try await webSocket.send(.data(msg))
    }

    deinit {
        outputContinuation.finish()
    }
}

// MARK: - API Response Types

private struct RemoteContainerResponse: Codable {
    let id: String
    let status: String
}
