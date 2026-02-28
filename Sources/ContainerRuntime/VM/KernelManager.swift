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
        throw PocketDevError.vmBootFailed("""
            Linux kernel not found. To build a compatible kernel:

            1. Clone linux-stable: git clone --depth 1 --branch v\(kernelVersion) \
               https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
            2. Apply the PocketDev defconfig (or start from Apple's virt config):
               make ARCH=arm64 defconfig
               scripts/config --enable VIRTIO_MMIO --enable VIRTIO_CONSOLE \
                   --enable VIRTIO_BLK --enable VIRTIO_VSOCK --enable EXT4_FS \
                   --enable OVERLAY_FS --enable CGROUPS --enable NAMESPACES
            3. Cross-compile: make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image
            4. Copy arch/arm64/boot/Image to the Xcode project as 'vmlinux'
               (Add to the app target's "Copy Bundle Resources" build phase)

            Alternatively, download a prebuilt kernel from PocketDev releases.
            """)
    }

    private func downloadInitrd(to destination: URL) async throws {
        throw PocketDevError.vmBootFailed("""
            Initrd (initial ramdisk) not found. The initrd contains vminitd — \
            PocketDev's guest-side agent that manages process spawning, I/O, and networking.

            To build: cd tools/vminitd && make ARCH=arm64
            Then add the output 'initrd.img' to the Xcode project's bundle resources.
            """)
    }
}
