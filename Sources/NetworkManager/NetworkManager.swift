import Foundation
import Network
#if canImport(Shared)
import Shared
#endif

/// Manages networking for container VMs.
/// Handles TCP port forwarding using Network framework (NWListener/NWConnection).
public actor NetworkManager {
    private var activeForwardings: [UInt16: ActiveForwarding] = [:]

    public init() {}

    // MARK: - Port Forwarding

    /// Register and start a TCP port forwarding rule.
    /// Listens on hostPort and forwards to containerAddress:containerPort.
    public func addPortForwarding(
        hostPort: UInt16,
        containerPort: UInt16,
        vmID: String,
        containerAddress: String = "127.0.0.1"
    ) async throws {
        // Stop existing forwarding on this port if any
        if let existing = activeForwardings[hostPort] {
            existing.listener.cancel()
        }

        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: hostPort)!)

        let forwarding = ActiveForwarding(
            hostPort: hostPort,
            containerPort: containerPort,
            vmID: vmID,
            containerAddress: containerAddress,
            listener: listener
        )

        listener.newConnectionHandler = { [containerPort, containerAddress] incomingConnection in
            Self.handleIncomingConnection(
                incomingConnection,
                containerAddress: containerAddress,
                containerPort: containerPort
            )
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                PocketDevLogger.shared.info("Port forwarding active: localhost:\(hostPort) -> \(containerAddress):\(containerPort)")
            case .failed(let error):
                PocketDevLogger.shared.error("Port forwarding failed on :\(hostPort): \(error)")
            case .cancelled:
                PocketDevLogger.shared.info("Port forwarding cancelled on :\(hostPort)")
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        activeForwardings[hostPort] = forwarding

        PocketDevLogger.shared.info("Port forwarding: localhost:\(hostPort) -> \(containerAddress):\(containerPort) (VM: \(vmID))")
    }

    /// Remove and stop a port forwarding
    public func removePortForwarding(hostPort: UInt16) async throws {
        guard let forwarding = activeForwardings.removeValue(forKey: hostPort) else {
            return
        }
        forwarding.listener.cancel()
        for connection in forwarding.connections {
            connection.cancel()
        }
        PocketDevLogger.shared.info("Removed port forwarding on :\(hostPort)")
    }

    /// List active port forwardings
    public func listForwardings() -> [PortForwardingInfo] {
        activeForwardings.values.map {
            PortForwardingInfo(hostPort: $0.hostPort, containerPort: $0.containerPort, vmID: $0.vmID)
        }
    }

    /// Shut down all networking
    public func shutdown() async throws {
        for (_, forwarding) in activeForwardings {
            forwarding.listener.cancel()
            for connection in forwarding.connections {
                connection.cancel()
            }
        }
        activeForwardings.removeAll()
    }

    // MARK: - Bidirectional TCP Pipe

    /// Handle an incoming connection by opening an outbound connection to the container
    /// and piping data bidirectionally.
    private static func handleIncomingConnection(
        _ incoming: NWConnection,
        containerAddress: String,
        containerPort: UInt16
    ) {
        let host = NWEndpoint.Host(containerAddress)
        let port = NWEndpoint.Port(rawValue: containerPort)!
        let outgoing = NWConnection(host: host, port: port, using: .tcp)

        incoming.start(queue: .global(qos: .userInitiated))
        outgoing.start(queue: .global(qos: .userInitiated))

        outgoing.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                PocketDevLogger.shared.error("Container connection failed: \(error)")
                incoming.cancel()
            }
        }

        // Pipe: incoming -> outgoing
        Self.pipe(from: incoming, to: outgoing)
        // Pipe: outgoing -> incoming
        Self.pipe(from: outgoing, to: incoming)
    }

    /// Read from `source` and write to `destination` until EOF or error.
    private static func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed({ sendError in
                    if let sendError = sendError {
                        PocketDevLogger.shared.error("Pipe send error: \(sendError)")
                        source.cancel()
                        destination.cancel()
                        return
                    }
                    // Continue reading
                    Self.pipe(from: source, to: destination)
                }))
            }

            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ _ in }))
                return
            }
        }
    }
}

// MARK: - Types

public struct PortForwardingInfo: Sendable {
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let vmID: String
}

/// Tracks an active port forwarding with its listener and active connections.
final class ActiveForwarding: @unchecked Sendable {
    let hostPort: UInt16
    let containerPort: UInt16
    let vmID: String
    let containerAddress: String
    let listener: NWListener
    var connections: [NWConnection] = []

    init(hostPort: UInt16, containerPort: UInt16, vmID: String, containerAddress: String, listener: NWListener) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.vmID = vmID
        self.containerAddress = containerAddress
        self.listener = listener
    }
}
