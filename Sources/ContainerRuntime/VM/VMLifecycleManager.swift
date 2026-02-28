import Foundation
#if canImport(Shared)
import Shared
#endif
#if canImport(PlatformAbstraction)
import PlatformAbstraction
#endif
#if canImport(NetworkManager)
import NetworkManager
#endif

/// Manages the lifecycle of all containers/VMs in PocketDev.
/// Handles creation, boot, suspend/resume, and cleanup.
/// Automatically manages iOS memory pressure by suspending VMs when backgrounded.
public actor VMLifecycleManager {
    private var containers: [String: ManagedContainer] = [:]
    private let backend: any VMBackend
    private let imageStore: ImageStore?
    private let kernelManager: KernelManager?

    public init(backend: any VMBackend, imageStore: ImageStore? = nil, kernelManager: KernelManager? = nil) {
        self.backend = backend
        self.imageStore = imageStore
        self.kernelManager = kernelManager
    }

    // MARK: - Container Lifecycle

    /// Create and boot a new container from a template or image reference
    public func createContainer(
        config: ContainerConfig,
        onProgress: @Sendable @escaping (ContainerProgress) -> Void
    ) async throws -> String {
        let id = config.id

        onProgress(.preparing)

        let vmConfig: VMConfig
        let rootfsPath: String

        if backend.requiresVMSetup {
            // Full VM path: pull OCI image, build ext4 rootfs, get kernel
            guard let imageStore = imageStore, let kernelManager = kernelManager else {
                throw PocketDevError.vmCreationFailed("ImageStore and KernelManager required for VM backends")
            }
            rootfsPath = try await prepareRootFilesystem(imageName: config.imageName, containerID: id, imageStore: imageStore, onProgress: onProgress)
            let kernelPath = try await kernelManager.ensureKernel()

            vmConfig = VMConfig(
                id: id,
                cpuCount: config.cpuCount,
                memoryMB: config.memoryMB,
                kernelPath: kernelPath,
                rootFilesystemPath: rootfsPath,
                sharedDirectories: config.mountPoints.map { mount in
                    SharedDirectory(hostPath: mount.hostPath, guestTag: mount.containerPath.replacingOccurrences(of: "/", with: "_"), readOnly: mount.readOnly)
                },
                kernelCommandLine: buildKernelCommandLine(config: config)
            )
        } else {
            // Local shell path: no rootfs or kernel needed
            rootfsPath = ""
            vmConfig = VMConfig(
                id: id,
                cpuCount: config.cpuCount,
                memoryMB: config.memoryMB,
                kernelPath: "",
                rootFilesystemPath: "",
                kernelCommandLine: ""
            )
        }

        // Create the VM
        onProgress(.creatingVM)
        let vm = try await backend.createVM(config: vmConfig)

        // Boot
        onProgress(.booting)
        try await vm.boot()

        // Only configure networking/environment for real VMs
        if backend.requiresVMSetup {
            onProgress(.configuringNetwork)
            try await configureNetworking(vm: vm, config: config)

            onProgress(.configuringEnvironment)
            try await configureEnvironment(vm: vm, config: config)
        }

        let managed = ManagedContainer(
            config: config,
            vm: vm,
            rootfsPath: rootfsPath,
            createdAt: Date()
        )
        containers[id] = managed

        onProgress(.ready)

        PocketDevLogger.shared.info("Container \(id) (\(config.name)) is ready")
        return id
    }

    /// Get a running container's VM for process spawning
    public func getVM(containerID: String) throws -> any VirtualMachine {
        guard let container = containers[containerID] else {
            throw PocketDevError.vmNotRunning
        }
        return container.vm
    }

    /// Stop a container gracefully
    public func stopContainer(_ id: String) async throws {
        guard let container = containers[id] else { return }
        try await container.vm.stop()
        containers.removeValue(forKey: id)
        PocketDevLogger.shared.info("Container \(id) stopped")
    }

    /// Suspend a container (for backgrounding)
    public func suspendContainer(_ id: String) async throws {
        guard let container = containers[id] else { return }
        try await container.vm.suspend()
        PocketDevLogger.shared.info("Container \(id) suspended")
    }

    /// Resume a suspended container
    public func resumeContainer(_ id: String) async throws {
        guard let container = containers[id] else { return }
        try await container.vm.resume()
        PocketDevLogger.shared.info("Container \(id) resumed")
    }

    /// Kill all containers (app termination)
    public func killAll() async {
        for (id, container) in containers {
            try? await container.vm.kill()
            PocketDevLogger.shared.info("Container \(id) killed")
        }
        containers.removeAll()
    }

    /// Suspend all containers (entering background)
    public func suspendAll() async {
        for (id, container) in containers {
            try? await container.vm.suspend()
            PocketDevLogger.shared.info("Container \(id) suspended for background")
        }
    }

    /// Resume all containers (entering foreground)
    public func resumeAll() async {
        for (id, container) in containers {
            try? await container.vm.resume()
            PocketDevLogger.shared.info("Container \(id) resumed from background")
        }
    }

    /// List all containers with their status
    public func listContainers() async -> [ContainerStatus] {
        var statuses: [ContainerStatus] = []
        for (id, container) in containers {
            let info = await container.vm.info()
            statuses.append(ContainerStatus(
                id: id,
                name: container.config.name,
                imageName: container.config.imageName,
                state: info.state,
                cpuCount: info.cpuCount,
                memoryMB: info.memoryMB,
                uptimeSeconds: info.uptimeSeconds,
                createdAt: container.createdAt
            ))
        }
        return statuses
    }

    // MARK: - Private Helpers

    private func prepareRootFilesystem(imageName: String, containerID: String, imageStore: ImageStore, onProgress: @Sendable @escaping (ContainerProgress) -> Void) async throws -> String {
        let ref = OCIImageReference(parsing: imageName) ?? OCIImageReference(repository: "library/alpine", tag: "latest")

        // Check if image is cached
        let hasCachedImage = await imageStore.hasImage(ref)
        if !hasCachedImage {
            onProgress(.pullingImage(imageName))
            let client = OCIRegistryClient()
            let pulledImage = try await client.pull(reference: ref) { pullProgress in
                switch pullProgress {
                case .downloadingLayer(let index, let total, let downloaded, let totalBytes):
                    onProgress(.pullingImageProgress(layer: index + 1, totalLayers: total, bytesDownloaded: downloaded, bytesTotal: totalBytes))
                default:
                    break
                }
            }
            try await imageStore.store(pulledImage)
        }

        // Create ext4 filesystem from layers
        onProgress(.creatingFilesystem)
        let rootfsPath = try await createRootFilesystem(reference: ref, containerID: containerID, imageStore: imageStore)
        return rootfsPath
    }

    private func createRootFilesystem(reference: OCIImageReference, containerID: String, imageStore: ImageStore) async throws -> String {
        guard let entry = await imageStore.getImage(reference) else {
            throw PocketDevError.imageNotFound(reference.description)
        }

        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.pocketdev.containers")
            .appendingPathComponent(containerID)

        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let rootfsPath = containerDir.appendingPathComponent("rootfs.ext4")

        // Create ext4 image from OCI layers
        try await EXT4Builder.build(
            layerDigests: entry.layerDigests,
            imageStore: imageStore,
            outputPath: rootfsPath.path,
            sizeMB: 2048
        )

        return rootfsPath.path
    }

    private func buildKernelCommandLine(config: ContainerConfig) -> String {
        var parts = [
            "console=hvc0",
            "root=/dev/vda",
            "rw",
            "quiet",
            "init=/sbin/vminitd",
        ]

        // Add shared directory mount hints
        for mount in config.mountPoints {
            let tag = mount.containerPath.replacingOccurrences(of: "/", with: "_")
            parts.append("pocketdev.mount.\(tag)=\(mount.containerPath)")
        }

        return parts.joined(separator: " ")
    }

    private func configureNetworking(vm: any VirtualMachine, config: ContainerConfig) async throws {
        // Set up networking inside the VM via vminitd
        // Configure eth0 with NAT gateway
        let setupScript = ProcessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", """
                ip link set eth0 up
                ip addr add 192.168.64.2/24 dev eth0
                ip route add default via 192.168.64.1
                echo 'nameserver 8.8.8.8' > /etc/resolv.conf
                echo 'nameserver 8.8.4.4' >> /etc/resolv.conf
                """],
            workingDirectory: "/"
        )
        let process = try await vm.spawnProcess(setupScript)
        _ = try await process.waitForExit()
    }

    private func configureEnvironment(vm: any VirtualMachine, config: ContainerConfig) async throws {
        // Set environment variables and create workspace directory
        var envScript = "mkdir -p /workspace\n"
        for (key, value) in config.environmentVariables {
            let safeKey = key.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "=", with: "")
            let safeValue = value.replacingOccurrences(of: "'", with: "'\\''")
            envScript += "export \(safeKey)='\(safeValue)'\n"
        }
        envScript += """
            echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/profile
            echo 'export TERM=xterm-256color' >> /etc/profile
            echo 'cd /workspace' >> /etc/profile
            echo 'pocketdev-ready' > /dev/console
            """

        let process = try await vm.spawnProcess(ProcessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", envScript],
            workingDirectory: "/"
        ))
        _ = try await process.waitForExit()
    }
}

// MARK: - Types

struct ManagedContainer {
    let config: ContainerConfig
    let vm: any VirtualMachine
    let rootfsPath: String
    let createdAt: Date
}

public struct ContainerStatus: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let imageName: String
    public let state: ContainerState
    public let cpuCount: Int
    public let memoryMB: Int
    public let uptimeSeconds: TimeInterval
    public let createdAt: Date
}

public enum ContainerProgress: Sendable {
    case preparing
    case pullingImage(String)
    case pullingImageProgress(layer: Int, totalLayers: Int, bytesDownloaded: Int64, bytesTotal: Int64)
    case creatingFilesystem
    case creatingVM
    case booting
    case configuringNetwork
    case configuringEnvironment
    case ready
}
