import Foundation

// MARK: - Container Types

public enum ContainerState: String, Codable, Sendable {
    case creating
    case pulling
    case booting
    case running
    case suspended
    case stopped
    case failed
}

public struct ContainerConfig: Codable, Sendable {
    public let id: String
    public let name: String
    public let imageName: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let storageMB: Int
    public let portMappings: [PortMapping]
    public let environmentVariables: [String: String]
    public let mountPoints: [MountPoint]

    public init(
        id: String = UUID().uuidString,
        name: String,
        imageName: String,
        cpuCount: Int = 2,
        memoryMB: Int = 512,
        storageMB: Int = 2048,
        portMappings: [PortMapping] = [],
        environmentVariables: [String: String] = [:],
        mountPoints: [MountPoint] = []
    ) {
        self.id = id
        self.name = name
        self.imageName = imageName
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.storageMB = storageMB
        self.portMappings = portMappings
        self.environmentVariables = environmentVariables
        self.mountPoints = mountPoints
    }
}

public struct PortMapping: Codable, Sendable, Hashable {
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let protocol_: TransportProtocol

    public init(hostPort: UInt16, containerPort: UInt16, protocol_: TransportProtocol = .tcp) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocol_ = protocol_
    }

    enum CodingKeys: String, CodingKey {
        case hostPort
        case containerPort
        case protocol_ = "protocol"
    }
}

public enum TransportProtocol: String, Codable, Sendable, Hashable {
    case tcp
    case udp
}

public struct MountPoint: Codable, Sendable, Hashable {
    public let hostPath: String
    public let containerPath: String
    public let readOnly: Bool

    public init(hostPath: String, containerPath: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
    }
}

// MARK: - VM Types

public struct VMInfo: Sendable {
    public let id: String
    public let state: ContainerState
    public let cpuCount: Int
    public let memoryMB: Int
    public let uptimeSeconds: TimeInterval
    public let pid: Int?

    public init(id: String, state: ContainerState, cpuCount: Int, memoryMB: Int, uptimeSeconds: TimeInterval, pid: Int? = nil) {
        self.id = id
        self.state = state
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.uptimeSeconds = uptimeSeconds
        self.pid = pid
    }
}

// MARK: - Process Types

public struct ProcessSpec: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let terminalSize: TerminalSize?

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String = "/root",
        terminalSize: TerminalSize? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminalSize = terminalSize
    }
}

public struct TerminalSize: Sendable, Codable, Equatable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }
}

// MARK: - OCI Types

public struct OCIImageReference: Sendable, Hashable, CustomStringConvertible {
    public let registry: String
    public let repository: String
    public let tag: String

    public var description: String {
        "\(registry)/\(repository):\(tag)"
    }

    public var pullURL: String {
        "https://\(registry)/v2/\(repository)"
    }

    public init(registry: String = "registry-1.docker.io", repository: String, tag: String = "latest") {
        self.registry = registry
        self.repository = repository
        self.tag = tag
    }

    public init?(parsing reference: String) {
        let parts = reference.split(separator: ":", maxSplits: 1)
        let tag = parts.count > 1 ? String(parts[1]) : "latest"

        let pathParts = parts[0].split(separator: "/")

        if pathParts.count == 1 {
            // e.g. "alpine" -> docker.io/library/alpine
            self.registry = "registry-1.docker.io"
            self.repository = "library/\(pathParts[0])"
            self.tag = tag
        } else if pathParts.count == 2 && !pathParts[0].contains(".") {
            // e.g. "pocketdev/ai-coder" -> docker.io/pocketdev/ai-coder
            self.registry = "registry-1.docker.io"
            self.repository = String(parts[0])
            self.tag = tag
        } else if pathParts.count >= 2 {
            // e.g. "ghcr.io/user/repo"
            self.registry = String(pathParts[0])
            self.repository = pathParts.dropFirst().joined(separator: "/")
            self.tag = tag
        } else {
            return nil
        }
    }
}

public struct OCIManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String?
    public let config: OCIDescriptor
    public let layers: [OCIDescriptor]

    public init(schemaVersion: Int, mediaType: String?, config: OCIDescriptor, layers: [OCIDescriptor]) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.layers = layers
    }
}

public struct OCIDescriptor: Codable, Sendable {
    public let mediaType: String
    public let digest: String
    public let size: Int64
    public let urls: [String]?
    public let annotations: [String: String]?
    public let platform: OCIPlatform?

    public init(mediaType: String, digest: String, size: Int64, urls: [String]? = nil, annotations: [String: String]? = nil, platform: OCIPlatform? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.urls = urls
        self.annotations = annotations
        self.platform = platform
    }
}

public struct OCIPlatform: Codable, Sendable {
    public let architecture: String
    public let os: String
    public let variant: String?

    public init(architecture: String, os: String, variant: String? = nil) {
        self.architecture = architecture
        self.os = os
        self.variant = variant
    }
}

public struct OCIIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String?
    public let manifests: [OCIDescriptor]

    public init(schemaVersion: Int, mediaType: String?, manifests: [OCIDescriptor]) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.manifests = manifests
    }
}

public struct OCIImageConfig: Codable, Sendable {
    public let architecture: String?
    public let os: String?
    public let config: OCIContainerConfig?
    public let rootfs: OCIRootFS?

    public init(architecture: String?, os: String?, config: OCIContainerConfig?, rootfs: OCIRootFS?) {
        self.architecture = architecture
        self.os = os
        self.config = config
        self.rootfs = rootfs
    }
}

public struct OCIContainerConfig: Codable, Sendable {
    public let Env: [String]?
    public let Cmd: [String]?
    public let Entrypoint: [String]?
    public let WorkingDir: String?
    public let ExposedPorts: [String: EmptyObject]?

    public init(Env: [String]?, Cmd: [String]?, Entrypoint: [String]?, WorkingDir: String?, ExposedPorts: [String: EmptyObject]?) {
        self.Env = Env
        self.Cmd = Cmd
        self.Entrypoint = Entrypoint
        self.WorkingDir = WorkingDir
        self.ExposedPorts = ExposedPorts
    }
}

public struct EmptyObject: Codable, Sendable {}

public struct OCIRootFS: Codable, Sendable {
    public let type: String
    public let diff_ids: [String]

    public init(type: String, diff_ids: [String]) {
        self.type = type
        self.diff_ids = diff_ids
    }
}

// MARK: - Error Types

public enum PocketDevError: Error, LocalizedError, Sendable {
    case vmCreationFailed(String)
    case vmBootFailed(String)
    case vmNotRunning
    case hypervisorUnavailable
    case imageNotFound(String)
    case imagePullFailed(String)
    case networkError(String)
    case filesystemError(String)
    case processSpawnFailed(String)
    case vsockConnectionFailed(String)
    case unsupportedPlatform
    case memoryLimitExceeded
    case storageLimitExceeded
    case subscriptionRequired(String)

    public var errorDescription: String? {
        switch self {
        case .vmCreationFailed(let msg): return "VM creation failed: \(msg)"
        case .vmBootFailed(let msg): return "VM boot failed: \(msg)"
        case .vmNotRunning: return "VM is not running"
        case .hypervisorUnavailable: return "Hypervisor is not available on this device"
        case .imageNotFound(let name): return "Image not found: \(name)"
        case .imagePullFailed(let msg): return "Image pull failed: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .filesystemError(let msg): return "Filesystem error: \(msg)"
        case .processSpawnFailed(let msg): return "Process spawn failed: \(msg)"
        case .vsockConnectionFailed(let msg): return "Vsock connection failed: \(msg)"
        case .unsupportedPlatform: return "This platform is not supported"
        case .memoryLimitExceeded: return "Memory limit exceeded"
        case .storageLimitExceeded: return "Storage limit exceeded"
        case .subscriptionRequired(let feature): return "Subscription required for: \(feature)"
        }
    }
}

// MARK: - Process I/O Types

public enum ProcessOutput: Sendable {
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)
}

/// Represents a process running inside a VM
public protocol VMProcess: AnyObject, Sendable {
    var pid: Int { get }

    /// Stream of stdout/stderr data from the process
    var output: AsyncStream<ProcessOutput> { get }

    /// Write data to the process's stdin
    func write(_ data: Data) async throws

    /// Send a signal to the process
    func signal(_ signal: Int32) async throws

    /// Wait for the process to exit, returns exit code
    func waitForExit() async throws -> Int32

    /// Resize the process's terminal
    func resize(_ size: TerminalSize) async throws
}

// MARK: - Template Types

public enum ContainerTemplate: String, CaseIterable, Identifiable, Sendable {
    case aiCoder = "pocketdev/ai-coder"
    case webdev = "pocketdev/webdev"
    case python = "pocketdev/python"
    case fullstack = "pocketdev/fullstack"
    case devops = "pocketdev/devops"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aiCoder: return "AI Coder"
        case .webdev: return "Web Development"
        case .python: return "Python"
        case .fullstack: return "Full Stack"
        case .devops: return "DevOps"
        case .custom: return "Custom Image"
        }
    }

    public var description: String {
        switch self {
        case .aiCoder: return "Alpine + Node.js 22 + Claude Code + git + ripgrep"
        case .webdev: return "Alpine + Node.js 22 + npm + Vite + Tailwind CSS"
        case .python: return "Alpine + Python 3.12 + pip + Jupyter + git"
        case .fullstack: return "Debian + Node.js + Python + PostgreSQL + Redis"
        case .devops: return "Alpine + Docker CLI + kubectl + terraform + AWS CLI"
        case .custom: return "Pull any OCI image from Docker Hub or GHCR"
        }
    }

    public var iconName: String {
        switch self {
        case .aiCoder: return "brain.head.profile"
        case .webdev: return "globe"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .fullstack: return "server.rack"
        case .devops: return "gearshape.2"
        case .custom: return "shippingbox"
        }
    }

    public var estimatedSizeMB: Int {
        switch self {
        case .aiCoder: return 150
        case .webdev: return 200
        case .python: return 180
        case .fullstack: return 500
        case .devops: return 250
        case .custom: return 0
        }
    }

    public var defaultMemoryMB: Int {
        switch self {
        case .aiCoder: return 512
        case .webdev: return 512
        case .python: return 512
        case .fullstack: return 1024
        case .devops: return 512
        case .custom: return 512
        }
    }
}

// MARK: - Subscription Types

public enum SubscriptionTier: String, CaseIterable, Identifiable, Sendable {
    case free
    case pro
    case team
    case enterprise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        }
    }

    public var monthlyPrice: Decimal? {
        switch self {
        case .free: return nil
        case .pro: return 12.99
        case .team: return 24.99
        case .enterprise: return nil
        }
    }

    public var maxContainers: Int {
        switch self {
        case .free: return 1
        case .pro: return .max
        case .team: return .max
        case .enterprise: return .max
        }
    }

    public var maxStorageMB: Int {
        switch self {
        case .free: return 2048
        case .pro: return 10240
        case .team: return 51200
        case .enterprise: return .max
        }
    }

    public var storeProductID: String? {
        switch self {
        case .free: return nil
        case .pro: return "com.pocketdev.pro.monthly"
        case .team: return "com.pocketdev.team.monthly"
        case .enterprise: return nil
        }
    }
}
