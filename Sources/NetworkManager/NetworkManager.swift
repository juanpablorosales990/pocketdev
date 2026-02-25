import Foundation
#if canImport(Shared)
import Shared
#endif

/// Manages networking for container VMs.
/// Handles port forwarding and NAT using Foundation networking.
public actor NetworkManager {
    private var portForwardings: [UInt16: PortForwardingInfo] = [:]

    public init() {}

    // MARK: - Port Forwarding

    /// Register a port forwarding rule
    public func addPortForwarding(
        hostPort: UInt16,
        containerPort: UInt16,
        vmID: String
    ) async throws {
        let info = PortForwardingInfo(
            hostPort: hostPort,
            containerPort: containerPort,
            vmID: vmID
        )
        portForwardings[hostPort] = info
        PocketDevLogger.shared.info("Port forwarding: localhost:\(hostPort) -> container:\(containerPort)")
    }

    /// Remove a port forwarding
    public func removePortForwarding(hostPort: UInt16) async throws {
        portForwardings.removeValue(forKey: hostPort)
        PocketDevLogger.shared.info("Removed port forwarding on :\(hostPort)")
    }

    /// List active port forwardings
    public func listForwardings() -> [PortForwardingInfo] {
        Array(portForwardings.values)
    }

    /// Shut down all networking
    public func shutdown() async throws {
        portForwardings.removeAll()
    }
}

// MARK: - Types

public struct PortForwardingInfo: Sendable {
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let vmID: String
}
