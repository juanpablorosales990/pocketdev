import Foundation
#if canImport(Shared)
import Shared
#endif

/// Automatically detects and selects the best available VM backend for the current device.
/// Priority: Hypervisor (native) > QEMU TCG (emulated) > Remote (cloud)
public final class BackendSelector: Sendable {
    public struct DetectionResult: Sendable {
        public let selectedBackend: any VMBackend
        public let allBackends: [(backend: any VMBackend, availability: BackendAvailability)]
        public let reason: String
    }

    public static func detect(remoteServerURL: URL? = nil, remoteAPIKey: String? = nil) -> DetectionResult {
        var results: [(backend: any VMBackend, availability: BackendAvailability)] = []

        // Check Hypervisor.framework (best performance)
        let hypervisor = HypervisorBackend()
        let hypervisorAvail = HypervisorBackend.checkAvailability()
        results.append((hypervisor, hypervisorAvail))

        // Check QEMU TCG (works everywhere on ARM64)
        let qemu = QEMUTCGBackend()
        let qemuAvail = QEMUTCGBackend.checkAvailability()
        results.append((qemu, qemuAvail))

        // Remote is always available if configured
        if let serverURL = remoteServerURL {
            let remote = RemoteVMBackend(serverURL: serverURL, apiKey: remoteAPIKey)
            let remoteAvail = RemoteVMBackend.checkAvailability()
            results.append((remote, remoteAvail))
        }

        // Select the best available backend
        let available = results.filter { $0.availability.available }
            .sorted { $0.backend.performanceTier > $1.backend.performanceTier }

        if let best = available.first {
            let reason = "Selected \(best.backend.name) (performance tier: \(best.backend.performanceTier))"
            PocketDevLogger.shared.info("\(reason)")
            return DetectionResult(selectedBackend: best.backend, allBackends: results, reason: reason)
        }

        // Fallback: return QEMU even if "unavailable" (it should always work on ARM64)
        let fallback = qemu
        let reason = "No optimal backend found, falling back to QEMU TCG"
        PocketDevLogger.shared.warning("\(reason)")
        return DetectionResult(selectedBackend: fallback, allBackends: results, reason: reason)
    }

    /// Quick check: is any on-device virtualization available?
    public static var hasOnDeviceVirtualization: Bool {
        HypervisorBackend.checkAvailability().available || QEMUTCGBackend.checkAvailability().available
    }

    /// Get device capability summary for UI display
    public static func deviceCapabilities() -> DeviceCapabilities {
        let hypervisor = HypervisorBackend.checkAvailability()
        let qemu = QEMUTCGBackend.checkAvailability()

        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let availableMemory = totalMemory / 2 // Conservative: use at most half for VM
        let processorCount = ProcessInfo.processInfo.processorCount

        return DeviceCapabilities(
            hypervisorAvailable: hypervisor.available,
            qemuAvailable: qemu.available,
            totalMemoryMB: Int(totalMemory / 1024 / 1024),
            availableForVMMB: Int(availableMemory / 1024 / 1024),
            processorCount: processorCount,
            recommendedCPUs: max(1, min(processorCount - 1, 4)),
            recommendedMemoryMB: min(Int(availableMemory / 1024 / 1024), 1024),
            isAppleSilicon: true // We only target ARM64
        )
    }
}

public struct DeviceCapabilities: Sendable {
    public let hypervisorAvailable: Bool
    public let qemuAvailable: Bool
    public let totalMemoryMB: Int
    public let availableForVMMB: Int
    public let processorCount: Int
    public let recommendedCPUs: Int
    public let recommendedMemoryMB: Int
    public let isAppleSilicon: Bool

    public var bestPerformanceTier: PerformanceTier {
        if hypervisorAvailable { return .native }
        if qemuAvailable { return .emulated }
        return .remote
    }

    public var summary: String {
        let tier = bestPerformanceTier
        switch tier {
        case .native:
            return "Native speed via Hypervisor.framework (\(processorCount) cores, \(totalMemoryMB)MB RAM)"
        case .nearNative:
            return "Near-native via Virtualization.framework (\(processorCount) cores, \(totalMemoryMB)MB RAM)"
        case .emulated:
            return "Emulated via QEMU TCG (\(processorCount) cores, \(totalMemoryMB)MB RAM)"
        case .remote:
            return "Cloud-based (remote VM)"
        }
    }
}
