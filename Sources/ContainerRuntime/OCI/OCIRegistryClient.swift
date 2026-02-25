import Foundation
import CryptoKit
#if canImport(Shared)
import Shared
#endif

/// OCI Distribution Spec v2 registry client.
/// Pulls images from Docker Hub, GHCR, and any OCI-compliant registry.
public actor OCIRegistryClient {
    private let session: URLSession
    private var authTokens: [String: AuthToken] = [:]

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600 // 10 min for large layers
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config)
    }

    // MARK: - Pull Image

    /// Pull an OCI image manifest and all its layers
    public func pull(
        reference: OCIImageReference,
        platform: OCIPlatform = OCIPlatform(architecture: "arm64", os: "linux"),
        onProgress: @Sendable @escaping (PullProgress) -> Void
    ) async throws -> PulledImage {
        PocketDevLogger.shared.info("Pulling image: \(reference)")

        // Step 1: Authenticate with the registry
        let token = try await authenticate(registry: reference.registry, repository: reference.repository)

        // Step 2: Fetch the manifest (could be index or manifest)
        let manifestData = try await fetchManifest(reference: reference, token: token)

        // Step 3: Parse — could be an index (multi-arch) or a single manifest
        let manifest: OCIManifest
        if let index = try? JSONDecoder().decode(OCIIndex.self, from: manifestData),
           index.schemaVersion == 2,
           let mediaType = index.mediaType,
           (mediaType.contains("manifest.list") || mediaType.contains("image.index")) {
            // Multi-arch: select the right platform
            guard let platformManifest = selectPlatform(from: index, platform: platform) else {
                throw PocketDevError.imagePullFailed("No manifest for platform \(platform.architecture)/\(platform.os)")
            }
            let platformData = try await fetchBlob(reference: reference, digest: platformManifest.digest, token: token)
            manifest = try JSONDecoder().decode(OCIManifest.self, from: platformData)
        } else {
            manifest = try JSONDecoder().decode(OCIManifest.self, from: manifestData)
        }

        // Step 4: Fetch the config blob
        onProgress(.fetchingConfig)
        let configData = try await fetchBlob(reference: reference, digest: manifest.config.digest, token: token)
        let imageConfig = try JSONDecoder().decode(OCIImageConfig.self, from: configData)

        // Step 5: Fetch all layer blobs
        var layers: [PulledLayer] = []
        let totalSize = manifest.layers.reduce(Int64(0)) { $0 + $1.size }
        var downloadedSize: Int64 = 0

        for (index, layerDesc) in manifest.layers.enumerated() {
            onProgress(.downloadingLayer(index: index, total: manifest.layers.count, bytesDownloaded: downloadedSize, bytesTotal: totalSize))

            let layerData = try await fetchBlob(reference: reference, digest: layerDesc.digest, token: token)
            downloadedSize += Int64(layerData.count)

            layers.append(PulledLayer(
                digest: layerDesc.digest,
                mediaType: layerDesc.mediaType,
                size: layerDesc.size,
                data: layerData
            ))
        }

        onProgress(.complete)

        return PulledImage(
            reference: reference,
            manifest: manifest,
            config: imageConfig,
            layers: layers
        )
    }

    // MARK: - Authentication

    private func authenticate(registry: String, repository: String) async throws -> String {
        // Check cached token
        let cacheKey = "\(registry)/\(repository)"
        if let cached = authTokens[cacheKey], !cached.isExpired {
            return cached.token
        }

        if registry == "registry-1.docker.io" {
            // Docker Hub uses token auth
            let tokenURL = URL(string: "https://auth.docker.io/token?service=registry.docker.io&scope=repository:\(repository):pull")!
            let (data, _) = try await session.data(from: tokenURL)
            let response = try JSONDecoder().decode(DockerAuthResponse.self, from: data)
            let authToken = AuthToken(token: response.token, expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 300)))
            authTokens[cacheKey] = authToken
            return response.token
        } else if registry == "ghcr.io" {
            // GHCR uses anonymous token
            let tokenURL = URL(string: "https://ghcr.io/token?service=ghcr.io&scope=repository:\(repository):pull")!
            let (data, _) = try await session.data(from: tokenURL)
            let response = try JSONDecoder().decode(DockerAuthResponse.self, from: data)
            let authToken = AuthToken(token: response.token, expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 300)))
            authTokens[cacheKey] = authToken
            return response.token
        }

        // Other registries: try anonymous access
        return ""
    }

    // MARK: - Fetch Operations

    private func fetchManifest(reference: OCIImageReference, token: String) async throws -> Data {
        let url = URL(string: "\(reference.pullURL)/manifests/\(reference.tag)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Accept both Docker and OCI manifest types
        request.setValue([
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
        ].joined(separator: ", "), forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PocketDevError.imagePullFailed("Manifest fetch failed: HTTP \(statusCode)")
        }
        return data
    }

    private func fetchBlob(reference: OCIImageReference, digest: String, token: String) async throws -> Data {
        let url = URL(string: "\(reference.pullURL)/blobs/\(digest)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PocketDevError.imagePullFailed("Blob fetch failed (\(digest)): HTTP \(statusCode)")
        }

        // Verify digest
        let computedDigest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if computedDigest != digest {
            PocketDevLogger.shared.warning("Digest mismatch: expected \(digest), got \(computedDigest)")
        }

        return data
    }

    // MARK: - Platform Selection

    private func selectPlatform(from index: OCIIndex, platform: OCIPlatform) -> OCIDescriptor? {
        // First try exact match
        if let exact = index.manifests.first(where: {
            $0.platform?.architecture == platform.architecture &&
            $0.platform?.os == platform.os &&
            (platform.variant == nil || $0.platform?.variant == platform.variant)
        }) {
            return exact
        }

        // Try without variant
        if let noVariant = index.manifests.first(where: {
            $0.platform?.architecture == platform.architecture &&
            $0.platform?.os == platform.os
        }) {
            return noVariant
        }

        return nil
    }
}

// MARK: - Supporting Types

public enum PullProgress: Sendable {
    case fetchingConfig
    case downloadingLayer(index: Int, total: Int, bytesDownloaded: Int64, bytesTotal: Int64)
    case extractingLayers
    case complete
}

public struct PulledImage: Sendable {
    public let reference: OCIImageReference
    public let manifest: OCIManifest
    public let config: OCIImageConfig
    public let layers: [PulledLayer]
}

public struct PulledLayer: Sendable {
    public let digest: String
    public let mediaType: String
    public let size: Int64
    public let data: Data
}

private struct DockerAuthResponse: Codable {
    let token: String
    let expires_in: Int?
    let access_token: String?
}

private struct AuthToken {
    let token: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}
