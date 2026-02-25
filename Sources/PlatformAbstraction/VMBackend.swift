import Foundation
#if canImport(Shared)
import Shared
#endif

// MARK: - VM Backend Protocol

/// The core abstraction that allows PocketDev to run on different virtualization backends.
/// Each backend implements this protocol to provide VM lifecycle management.
public protocol VMBackend: AnyObject, Sendable {
    /// Human-readable name for this backend
    var name: String { get }

    /// Whether this backend is available on the current device
    var isAvailable: Bool { get }

    /// Performance tier of this backend
    var performanceTier: PerformanceTier { get }

    /// Create a new VM with the given configuration
    func createVM(config: VMConfig) async throws -> VirtualMachine

    /// Check if the hardware/OS supports this backend
    static func checkAvailability() -> BackendAvailability
}

// MARK: - Virtual Machine Protocol

/// Represents a running or stopped virtual machine
public protocol VirtualMachine: AnyObject, Sendable {
    var id: String { get }
    func getState() async -> ContainerState

    /// Boot the VM. Returns when the VM is ready to accept commands.
    func boot() async throws

    /// Suspend the VM, preserving state to disk
    func suspend() async throws

    /// Resume a suspended VM
    func resume() async throws

    /// Stop the VM gracefully
    func stop() async throws

    /// Force kill the VM
    func kill() async throws

    /// Spawn a process inside the VM
    func spawnProcess(_ spec: ProcessSpec) async throws -> VMProcess

    /// Get information about the VM
    func info() async -> VMInfo

    /// Resize the terminal for all active processes
    func resizeTerminal(_ size: TerminalSize) async throws
}

// MARK: - Supporting Types

public struct VMConfig: Sendable {
    public let id: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let kernelPath: String
    public let initrdPath: String?
    public let rootFilesystemPath: String
    public let sharedDirectories: [SharedDirectory]
    public let networkMode: NetworkMode
    public let kernelCommandLine: String

    public init(
        id: String = UUID().uuidString,
        cpuCount: Int = 2,
        memoryMB: Int = 512,
        kernelPath: String,
        initrdPath: String? = nil,
        rootFilesystemPath: String,
        sharedDirectories: [SharedDirectory] = [],
        networkMode: NetworkMode = .nat,
        kernelCommandLine: String = "console=hvc0 root=/dev/vda rw quiet"
    ) {
        self.id = id
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.rootFilesystemPath = rootFilesystemPath
        self.sharedDirectories = sharedDirectories
        self.networkMode = networkMode
        self.kernelCommandLine = kernelCommandLine
    }
}

public struct SharedDirectory: Sendable {
    public let hostPath: String
    public let guestTag: String
    public let readOnly: Bool

    public init(hostPath: String, guestTag: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.guestTag = guestTag
        self.readOnly = readOnly
    }
}

public enum NetworkMode: Sendable {
    case nat
    case bridged
    case none
}

public enum PerformanceTier: Int, Comparable, Sendable {
    case native = 3      // Hypervisor.framework — bare metal speed
    case nearNative = 2  // Virtualization.framework — near native
    case emulated = 1    // QEMU TCG — 3-5x slower
    case remote = 0      // Cloud VM — network dependent

    public static func < (lhs: PerformanceTier, rhs: PerformanceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct BackendAvailability: Sendable {
    public let available: Bool
    public let reason: String?
    public let requiresEntitlement: Bool
    public let requiresSideloading: Bool

    public init(available: Bool, reason: String? = nil, requiresEntitlement: Bool = false, requiresSideloading: Bool = false) {
        self.available = available
        self.reason = reason
        self.requiresEntitlement = requiresEntitlement
        self.requiresSideloading = requiresSideloading
    }
}

