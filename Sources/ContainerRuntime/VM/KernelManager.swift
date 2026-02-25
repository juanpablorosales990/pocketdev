import Foundation
#if canImport(Shared)
import Shared
#endif

/// Manages the Linux kernel binary used for container VMs.
/// Handles downloading, caching, and version management.
public actor KernelManager {
    private let storageDir: URL
    private let kernelVersion = "6.18.5"

    public init(storageDir: URL? = nil) {
        self.storageDir = storageDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.pocketdev.kernel")
    }

    /// Ensure a kernel binary is available, downloading if necessary
    public func ensureKernel() async throws -> String {
        let kernelPath = storageDir.appendingPathComponent("vmlinux-\(kernelVersion)")

        if FileManager.default.fileExists(atPath: kernelPath.path) {
            PocketDevLogger.shared.info("Kernel found at \(kernelPath.path)")
            return kernelPath.path
        }

        // Check bundle first (shipped with app)
        if let bundledPath = Bundle.main.path(forResource: "vmlinux", ofType: nil) {
            PocketDevLogger.shared.info("Using bundled kernel at \(bundledPath)")
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: bundledPath, toPath: kernelPath.path)
            return kernelPath.path
        }

        // Download kernel
        PocketDevLogger.shared.info("Downloading kernel v\(kernelVersion)...")
        try await downloadKernel(to: kernelPath)
        return kernelPath.path
    }

    /// Get the path to the initrd (initial ramdisk with vminitd)
    public func ensureInitrd() async throws -> String {
        let initrdPath = storageDir.appendingPathComponent("initrd-\(kernelVersion)")

        if FileManager.default.fileExists(atPath: initrdPath.path) {
            return initrdPath.path
        }

        if let bundledPath = Bundle.main.path(forResource: "initrd", ofType: "img") {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: bundledPath, toPath: initrdPath.path)
            return initrdPath.path
        }

        try await downloadInitrd(to: initrdPath)
        return initrdPath.path
    }

    private func downloadKernel(to destination: URL) async throws {
        // In production, this would download from PocketDev's CDN
        // For now, we'll build the kernel from Apple's config and bundle it
        throw PocketDevError.vmBootFailed("Kernel not found. Please build and include vmlinux in the app bundle.")
    }

    private func downloadInitrd(to destination: URL) async throws {
        throw PocketDevError.vmBootFailed("Initrd not found. Please build and include initrd.img in the app bundle.")
    }
}
