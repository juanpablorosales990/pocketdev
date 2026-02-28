import SwiftUI
#if canImport(Shared)
import Shared
#endif
#if canImport(PlatformAbstraction)
import PlatformAbstraction
#endif
#if canImport(ContainerRuntime)
import ContainerRuntime
#endif
#if canImport(TerminalUI)
import TerminalUI
#endif

/// Global application state manager
@MainActor
public final class AppState: ObservableObject {
    // Navigation
    @Published var currentScreen: AppScreen = .onboarding
    @Published var showingNewContainer = false
    @Published var showingSettings = false

    // Container state
    @Published var containers: [ContainerStatus] = []
    @Published var activeContainerID: String?

    // Terminal sessions
    @Published var terminalSessions: [String: TerminalSession] = [:]

    // Device capabilities
    @Published var capabilities: DeviceCapabilities?

    // Subscription
    @Published var currentTier: SubscriptionTier = .free

    // Backend
    private var backend: (any VMBackend)?
    private var lifecycleManager: VMLifecycleManager?
    private var imageStore: ImageStore?
    private var kernelManager: KernelManager?
    private var isInitialized = false

    public init() {
        detectCapabilities()
    }

    // MARK: - Initialization

    func detectCapabilities() {
        capabilities = BackendSelector.deviceCapabilities()
    }

    func initializeRuntime() async throws {
        if isInitialized { return }

        let detection = BackendSelector.detect()
        backend = detection.selectedBackend

        if detection.selectedBackend.requiresVMSetup {
            imageStore = try ImageStore()
            kernelManager = KernelManager()
        }

        lifecycleManager = VMLifecycleManager(
            backend: detection.selectedBackend,
            imageStore: imageStore,
            kernelManager: kernelManager
        )

        isInitialized = true
        currentScreen = .home
    }

    /// Spawn a process in the active container (used by file browser)
    func spawnProcess(for containerID: String, spec: ProcessSpec) async throws -> any VMProcess {
        guard let manager = lifecycleManager else {
            throw PocketDevError.unsupportedPlatform
        }
        let vm = try await manager.getVM(containerID: containerID)
        return try await vm.spawnProcess(spec)
    }

    // MARK: - Container Operations

    func createContainer(config: ContainerConfig) async throws {
        guard let manager = lifecycleManager else {
            throw PocketDevError.unsupportedPlatform
        }

        // Check subscription limits
        if currentTier == .free && containers.count >= 1 {
            throw PocketDevError.subscriptionRequired("Multiple containers require Pro subscription")
        }

        let id = try await manager.createContainer(config: config) { [weak self] progress in
            Task { @MainActor in
                self?.handleContainerProgress(progress, containerID: config.id)
            }
        }

        // Create terminal session
        let session = TerminalSession(id: id)
        let vm = try await manager.getVM(containerID: id)

        // Spawn default shell
        let shellProcess = try await vm.spawnProcess(ProcessSpec(
            executablePath: "/bin/sh",
            arguments: ["-l"],
            environment: [
                "TERM": "xterm-256color",
                "HOME": "/root",
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            ],
            workingDirectory: "/workspace",
            terminalSize: TerminalSize(columns: 80, rows: 24)
        ))

        session.attach(to: shellProcess)
        terminalSessions[id] = session

        activeContainerID = id
        await refreshContainerList()
        currentScreen = .workspace
    }

    func stopContainer(_ id: String) async throws {
        terminalSessions[id]?.detach()
        terminalSessions.removeValue(forKey: id)
        try await lifecycleManager?.stopContainer(id)
        if activeContainerID == id {
            activeContainerID = containers.first(where: { $0.id != id })?.id
        }
        await refreshContainerList()
    }

    func switchToContainer(_ id: String) {
        activeContainerID = id
        currentScreen = .workspace
    }

    // MARK: - App Lifecycle

    func handleBackground() async {
        await lifecycleManager?.suspendAll()
    }

    func handleForeground() async {
        await lifecycleManager?.resumeAll()
    }

    // MARK: - Private

    private func refreshContainerList() async {
        containers = await lifecycleManager?.listContainers() ?? []
    }

    private func handleContainerProgress(_ progress: ContainerProgress, containerID: String) {
        // Update UI based on progress
        // This would drive a progress indicator in the creation flow
    }
}

// MARK: - Navigation

enum AppScreen {
    case onboarding
    case home
    case workspace
    case settings
}
