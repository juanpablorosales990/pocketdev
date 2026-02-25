import Foundation
#if canImport(Shared)
import Shared
#endif

/// Content-addressable image store.
/// Manages pulled OCI images, layer deduplication, and caching.
public actor ImageStore {
    private let storageDir: URL
    private let blobsDir: URL
    private let manifestsDir: URL
    private let indexPath: URL
    private var imageIndex: ImageIndex

    public init(storageDir: URL? = nil) throws {
        let base = storageDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.pocketdev.images")

        self.storageDir = base
        self.blobsDir = base.appendingPathComponent("blobs")
        self.manifestsDir = base.appendingPathComponent("manifests")
        self.indexPath = base.appendingPathComponent("index.json")

        // Create directories
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)

        // Load or create index
        if let data = try? Data(contentsOf: indexPath),
           let index = try? JSONDecoder().decode(ImageIndex.self, from: data) {
            self.imageIndex = index
        } else {
            self.imageIndex = ImageIndex(images: [])
        }

        PocketDevLogger.shared.info("ImageStore initialized at \(base.path)")
    }

    // MARK: - Store Operations

    /// Store a pulled image and its layers
    public func store(_ image: PulledImage) async throws {
        // Store each layer blob (with deduplication)
        for layer in image.layers {
            let blobPath = blobPath(for: layer.digest)
            if !FileManager.default.fileExists(atPath: blobPath.path) {
                try layer.data.write(to: blobPath)
                PocketDevLogger.shared.debug("Stored blob: \(layer.digest) (\(layer.data.count) bytes)")
            } else {
                PocketDevLogger.shared.debug("Blob already exists: \(layer.digest)")
            }
        }

        // Store manifest
        let manifestData = try JSONEncoder().encode(image.manifest)
        let manifestPath = self.manifestsDir.appendingPathComponent(image.reference.description.replacingOccurrences(of: "/", with: "_"))
        try manifestData.write(to: manifestPath)

        // Store config
        let configData = try JSONEncoder().encode(image.config)
        let configPath = blobPath(for: image.manifest.config.digest)
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try configData.write(to: configPath)
        }

        // Update index
        let entry = ImageEntry(
            reference: image.reference.description,
            manifestDigest: "", // TODO: compute
            configDigest: image.manifest.config.digest,
            layerDigests: image.layers.map(\.digest),
            pulledAt: Date(),
            totalSize: image.layers.reduce(0) { $0 + $1.size }
        )

        imageIndex.images.removeAll { $0.reference == entry.reference }
        imageIndex.images.append(entry)
        try saveIndex()

        PocketDevLogger.shared.info("Image stored: \(image.reference)")
    }

    /// Check if an image is already cached
    public func hasImage(_ reference: OCIImageReference) -> Bool {
        imageIndex.images.contains { $0.reference == reference.description }
    }

    /// Get cached image entry
    public func getImage(_ reference: OCIImageReference) -> ImageEntry? {
        imageIndex.images.first { $0.reference == reference.description }
    }

    /// List all cached images
    public func listImages() -> [ImageEntry] {
        imageIndex.images
    }

    /// Remove an image and its unique layers
    public func removeImage(_ reference: OCIImageReference) throws {
        guard let entry = getImage(reference) else { return }

        // Find layers that are only used by this image
        let otherImages = imageIndex.images.filter { $0.reference != reference.description }
        let otherLayerDigests = Set(otherImages.flatMap(\.layerDigests))

        for digest in entry.layerDigests {
            if !otherLayerDigests.contains(digest) {
                let path = blobPath(for: digest)
                try? FileManager.default.removeItem(at: path)
                PocketDevLogger.shared.debug("Removed orphaned blob: \(digest)")
            }
        }

        // Remove config if unique
        if !otherImages.contains(where: { $0.configDigest == entry.configDigest }) {
            try? FileManager.default.removeItem(at: blobPath(for: entry.configDigest))
        }

        imageIndex.images.removeAll { $0.reference == reference.description }
        try saveIndex()

        PocketDevLogger.shared.info("Image removed: \(reference)")
    }

    /// Get the path to a stored blob
    public func blobPath(for digest: String) -> URL {
        let cleanDigest = digest.replacingOccurrences(of: "sha256:", with: "")
        return blobsDir.appendingPathComponent(cleanDigest)
    }

    /// Total storage used by all images
    public func totalStorageUsed() -> Int64 {
        imageIndex.images.reduce(0) { $0 + $1.totalSize }
    }

    /// Garbage collect unreferenced blobs
    public func gc() throws {
        let referencedDigests = Set(imageIndex.images.flatMap(\.layerDigests) + imageIndex.images.map(\.configDigest))

        let allBlobs = try FileManager.default.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil)
        var reclaimedBytes: Int64 = 0

        for blobURL in allBlobs {
            let digest = "sha256:" + blobURL.lastPathComponent
            if !referencedDigests.contains(digest) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: blobURL.path),
                   let size = attrs[.size] as? Int64 {
                    reclaimedBytes += size
                }
                try FileManager.default.removeItem(at: blobURL)
            }
        }

        PocketDevLogger.shared.info("GC complete: reclaimed \(reclaimedBytes / 1024 / 1024)MB")
    }

    // MARK: - Private

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(imageIndex)
        try data.write(to: indexPath)
    }
}

// MARK: - Storage Types

public struct ImageIndex: Codable {
    public var images: [ImageEntry]
}

public struct ImageEntry: Codable, Identifiable {
    public let reference: String
    public let manifestDigest: String
    public let configDigest: String
    public let layerDigests: [String]
    public let pulledAt: Date
    public let totalSize: Int64

    public var id: String { reference }

    public var totalSizeMB: Int {
        Int(totalSize / 1024 / 1024)
    }
}
