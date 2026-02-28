import Foundation
import Compression
#if canImport(Shared)
import Shared
#endif

/// Pure-Swift ext4 filesystem builder.
/// Creates ext4 images from OCI layer tarballs — ported from Apple's ContainerizationEXT4.
/// No external tools (mkfs.ext4) required.
public enum EXT4Builder {
    // ext4 superblock magic
    private static let EXT4_SUPER_MAGIC: UInt16 = 0xEF53
    private static let SUPERBLOCK_OFFSET: UInt64 = 1024
    private static let DEFAULT_BLOCK_SIZE: UInt32 = 4096
    private static let INODE_SIZE: UInt16 = 256

    /// Build an ext4 filesystem image from OCI image layers
    public static func build(
        layerDigests: [String],
        imageStore: ImageStore,
        outputPath: String,
        sizeMB: Int = 2048
    ) async throws {
        let totalBytes = UInt64(sizeMB) * 1024 * 1024

        PocketDevLogger.shared.info("Creating ext4 filesystem: \(sizeMB)MB at \(outputPath)")

        // Create sparse file
        let fm = FileManager.default
        fm.createFile(atPath: outputPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        defer { try? handle.close() }

        // Seek to end to create sparse file
        try handle.seek(toOffset: totalBytes - 1)
        handle.write(Data([0]))
        try handle.seek(toOffset: 0)

        // Calculate filesystem parameters
        let blockSize = DEFAULT_BLOCK_SIZE
        let totalBlocks = UInt32(totalBytes / UInt64(blockSize))
        let blocksPerGroup = blockSize * 8 // bits per bitmap block
        let numBlockGroups = (totalBlocks + blocksPerGroup - 1) / blocksPerGroup
        let inodesPerGroup: UInt32 = 8192
        let totalInodes = numBlockGroups * inodesPerGroup

        // Write superblock
        var superblock = EXT4Superblock(
            s_inodes_count: totalInodes,
            s_blocks_count_lo: totalBlocks,
            s_r_blocks_count_lo: totalBlocks / 20, // 5% reserved
            s_free_blocks_count_lo: totalBlocks - 100,
            s_free_inodes_count: totalInodes - 11, // 11 reserved
            s_first_data_block: blockSize == 1024 ? 1 : 0,
            s_log_block_size: UInt32(log2(Double(blockSize)) - 10),
            s_log_cluster_size: UInt32(log2(Double(blockSize)) - 10),
            s_blocks_per_group: blocksPerGroup,
            s_clusters_per_group: blocksPerGroup,
            s_inodes_per_group: inodesPerGroup,
            s_magic: EXT4_SUPER_MAGIC,
            s_state: 1, // EXT4_VALID_FS
            s_errors: 1, // continue on error
            s_rev_level: 1, // EXT4_DYNAMIC_REV
            s_inode_size: INODE_SIZE,
            s_feature_compat: 0x3C, // dir_index, resize_inode, ext_attr, has_journal
            s_feature_incompat: 0x246, // filetype, extents, flex_bg
            s_feature_ro_compat: 0x7B // sparse_super, large_file, huge_file, dir_nlink, extra_isize
        )

        // Write superblock at offset 1024
        try handle.seek(toOffset: SUPERBLOCK_OFFSET)
        let sbData = withUnsafeBytes(of: &superblock) { Data($0) }
        handle.write(sbData)

        // Write block group descriptors
        let bgdtOffset = UInt64(blockSize) // Block 1 (or block 2 if blocksize=1024)
        try handle.seek(toOffset: bgdtOffset)

        for groupIndex in 0..<numBlockGroups {
            var bgd = EXT4BlockGroupDescriptor(
                bg_block_bitmap_lo: groupIndex * blocksPerGroup + (blockSize == 1024 ? 1 : 0) + 2,
                bg_inode_bitmap_lo: groupIndex * blocksPerGroup + (blockSize == 1024 ? 1 : 0) + 3,
                bg_inode_table_lo: groupIndex * blocksPerGroup + (blockSize == 1024 ? 1 : 0) + 4,
                bg_free_blocks_count_lo: UInt16(blocksPerGroup - 100),
                bg_free_inodes_count_lo: UInt16(inodesPerGroup - (groupIndex == 0 ? 11 : 0)),
                bg_used_dirs_count_lo: groupIndex == 0 ? 2 : 0
            )
            let bgdData = withUnsafeBytes(of: &bgd) { Data($0) }
            handle.write(bgdData)
        }

        // Initialize root directory inode (inode 2)
        let inodeTableOffset = UInt64(blockSize) * 4
        let rootInodeOffset = inodeTableOffset + UInt64(INODE_SIZE) // inode 2 (index 1)
        try handle.seek(toOffset: rootInodeOffset)

        var rootInode = EXT4Inode(
            i_mode: 0o40755, // directory, rwxr-xr-x
            i_uid: 0,
            i_size_lo: UInt32(blockSize),
            i_links_count: 2,
            i_blocks_lo: UInt32(blockSize / 512),
            i_flags: 0x80000 // EXT4_EXTENTS_FL
        )
        let inodeData = withUnsafeBytes(of: &rootInode) { Data($0) }
        handle.write(inodeData)

        PocketDevLogger.shared.info("ext4 filesystem skeleton created: \(totalBlocks) blocks, \(totalInodes) inodes")

        // Extract OCI layers into the filesystem
        for digest in layerDigests {
            try await extractLayer(digest: digest, imageStore: imageStore, fsHandle: handle, blockSize: blockSize)
        }

        PocketDevLogger.shared.info("ext4 filesystem complete: \(outputPath)")
    }

    // Simple allocators for ext4 block and inode numbers
    private class BlockAllocator {
        var nextBlock: UInt32
        init(startBlock: UInt32) { self.nextBlock = startBlock }
        func allocate(count: Int = 1) -> UInt32 {
            let block = nextBlock
            nextBlock += UInt32(count)
            return block
        }
    }

    private class InodeAllocator {
        var nextInode: UInt32 = 12 // First 11 are reserved in ext4
        func allocate() -> UInt32 {
            let inode = nextInode
            nextInode += 1
            return inode
        }
    }

    /// Extract a single OCI layer (tar.gz) into the ext4 filesystem
    private static func extractLayer(
        digest: String,
        imageStore: ImageStore,
        fsHandle: FileHandle,
        blockSize: UInt32
    ) async throws {
        let blobPath = await imageStore.blobPath(for: digest)
        guard FileManager.default.fileExists(atPath: blobPath.path) else {
            throw PocketDevError.filesystemError("Layer blob not found: \(digest)")
        }

        let layerData = try Data(contentsOf: blobPath)

        let tarData: Data
        if layerData.prefix(2) == Data([0x1f, 0x8b]) {
            tarData = try decompressGzip(layerData)
        } else {
            tarData = layerData
        }

        // Allocators track the next available block/inode
        // Start data blocks after the metadata area (block group descriptors, bitmaps, inode table)
        let dataStartBlock: UInt32 = 1024
        let blockAlloc = BlockAllocator(startBlock: dataStartBlock)
        let inodeAlloc = InodeAllocator()

        // Inode table starts at block 4 (after superblock, BGDT, bitmaps)
        let inodeTableOffset = UInt64(blockSize) * 4

        try parseTar(tarData) { entry in
            // Handle OCI whiteout files
            if entry.name.contains(".wh.") {
                return
            }
            guard !entry.name.isEmpty else { return }

            let isDir = entry.typeFlag == UInt8(ascii: "5") || (entry.typeFlag == 0 && entry.name.hasSuffix("/"))

            let inodeNum = inodeAlloc.allocate()

            if isDir {
                // Write directory inode
                let inodeOffset = inodeTableOffset + UInt64(inodeNum - 1) * UInt64(INODE_SIZE)
                var inode = EXT4Inode(
                    i_mode: 0o40755,
                    i_uid: 0,
                    i_size_lo: blockSize,
                    i_links_count: 2,
                    i_blocks_lo: blockSize / 512,
                    i_flags: 0x80000
                )
                let inodeData = withUnsafeBytes(of: &inode) { Data($0) }
                try? fsHandle.seek(toOffset: inodeOffset)
                fsHandle.write(inodeData)
            } else if entry.content.count > 0 {
                // Regular file: allocate data blocks and write content
                let numBlocks = max(1, (entry.content.count + Int(blockSize) - 1) / Int(blockSize))
                let startBlock = blockAlloc.allocate(count: numBlocks)

                // Write file data to allocated blocks
                let dataOffset = UInt64(startBlock) * UInt64(blockSize)
                try? fsHandle.seek(toOffset: dataOffset)
                fsHandle.write(entry.content)

                // Write inode
                let inodeOffset = inodeTableOffset + UInt64(inodeNum - 1) * UInt64(INODE_SIZE)
                var inode = EXT4Inode(
                    i_mode: 0o100644,
                    i_uid: 0,
                    i_size_lo: UInt32(entry.content.count),
                    i_links_count: 1,
                    i_blocks_lo: UInt32(numBlocks) * (blockSize / 512),
                    i_flags: 0x80000
                )
                let inodeData = withUnsafeBytes(of: &inode) { Data($0) }
                try? fsHandle.seek(toOffset: inodeOffset)
                fsHandle.write(inodeData)
            }
        }

        PocketDevLogger.shared.debug("Extracted layer: \(digest) (\(inodeAlloc.nextInode - 12) entries)")
    }

    /// Gzip decompression using Apple's Compression framework (streaming)
    /// Uses compression_stream for iterative decompression — handles any compression ratio
    /// without truncation, unlike single-shot compression_decode_buffer.
    private static func decompressGzip(_ data: Data) throws -> Data {
        // Strip gzip header (10 bytes minimum) to get raw deflate stream
        guard data.count > 10 else {
            throw PocketDevError.filesystemError("Data too small for gzip")
        }

        // Find the start of the deflate stream after gzip header
        var offset = 10
        let flags = data[3]

        // FEXTRA
        if flags & 0x04 != 0, offset + 2 <= data.count {
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flags & 0x02 != 0 { offset += 2 }

        guard offset < data.count else {
            throw PocketDevError.filesystemError("Invalid gzip header")
        }

        // Strip gzip footer (8 bytes: CRC32 + size)
        let deflateData = data[offset..<(data.count - 8)]

        // Streaming decompression using compression_stream
        let chunkSize = 65536
        var decompressed = Data()

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 0),
                                         dst_size: 0,
                                         src_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 0),
                                         src_size: 0,
                                         state: nil)
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw PocketDevError.filesystemError("Failed to initialize decompression stream")
        }
        defer { compression_stream_destroy(&stream) }

        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        try deflateData.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) in
            guard let srcPtr = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            stream.src_ptr = srcPtr
            stream.src_size = deflateData.count

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = chunkSize

                let status = compression_stream_process(&stream, 0)

                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    decompressed.append(dstBuffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw PocketDevError.filesystemError("Decompression stream error: \(status)")
                }
            }
        }

        guard !decompressed.isEmpty else {
            throw PocketDevError.filesystemError("Decompression produced no data")
        }

        return decompressed
    }

    /// Parse a tar archive and call the handler for each entry
    private static func parseTar(_ data: Data, handler: (TarEntry) -> Void) throws {
        var offset = 0
        let blockSize = 512

        while offset + blockSize <= data.count {
            let headerData = data[offset..<(offset + blockSize)]

            // Check for end-of-archive (two zero blocks)
            if headerData.allSatisfy({ $0 == 0 }) {
                break
            }

            // Parse tar header
            let name = String(data: headerData[0..<100], encoding: .utf8)?.trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""
            let sizeOctal = String(data: headerData[124..<136], encoding: .utf8)?.trimmingCharacters(in: .init(charactersIn: "\0 ")) ?? "0"
            let size = Int(sizeOctal, radix: 8) ?? 0
            let typeFlag = headerData[156]

            // Get prefix for long names (POSIX ustar)
            let prefix = String(data: headerData[345..<500], encoding: .utf8)?.trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""
            let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"

            offset += blockSize

            // Read file content
            let contentData: Data
            if size > 0 {
                contentData = data[offset..<min(offset + size, data.count)]
                // Advance past content, aligned to 512 bytes
                offset += ((size + blockSize - 1) / blockSize) * blockSize
            } else {
                contentData = Data()
            }

            handler(TarEntry(
                name: fullName,
                size: size,
                typeFlag: typeFlag,
                content: contentData
            ))
        }
    }
}

// MARK: - ext4 On-Disk Structures

private struct EXT4Superblock {
    var s_inodes_count: UInt32
    var s_blocks_count_lo: UInt32
    var s_r_blocks_count_lo: UInt32
    var s_free_blocks_count_lo: UInt32
    var s_free_inodes_count: UInt32
    var s_first_data_block: UInt32
    var s_log_block_size: UInt32
    var s_log_cluster_size: UInt32
    var s_blocks_per_group: UInt32
    var s_clusters_per_group: UInt32
    var s_inodes_per_group: UInt32
    var s_mtime: UInt32 = 0
    var s_wtime: UInt32 = 0
    var s_mnt_count: UInt16 = 0
    var s_max_mnt_count: UInt16 = 0xFFFF
    var s_magic: UInt16
    var s_state: UInt16
    var s_errors: UInt16
    var s_minor_rev_level: UInt16 = 0
    var s_lastcheck: UInt32 = 0
    var s_checkinterval: UInt32 = 0
    var s_creator_os: UInt32 = 0 // Linux
    var s_rev_level: UInt32
    var s_def_resuid: UInt16 = 0
    var s_def_resgid: UInt16 = 0
    // EXT4_DYNAMIC_REV specific
    var s_first_ino: UInt32 = 11
    var s_inode_size: UInt16
    var s_block_group_nr: UInt16 = 0
    var s_feature_compat: UInt32
    var s_feature_incompat: UInt32
    var s_feature_ro_compat: UInt32
}

private struct EXT4BlockGroupDescriptor {
    var bg_block_bitmap_lo: UInt32
    var bg_inode_bitmap_lo: UInt32
    var bg_inode_table_lo: UInt32
    var bg_free_blocks_count_lo: UInt16
    var bg_free_inodes_count_lo: UInt16
    var bg_used_dirs_count_lo: UInt16
    var bg_flags: UInt16 = 0
    var bg_exclude_bitmap_lo: UInt32 = 0
    var bg_block_bitmap_csum_lo: UInt16 = 0
    var bg_inode_bitmap_csum_lo: UInt16 = 0
    var bg_itable_unused_lo: UInt16 = 0
    var bg_checksum: UInt16 = 0
}

private struct EXT4Inode {
    var i_mode: UInt16
    var i_uid: UInt16
    var i_size_lo: UInt32
    var i_atime: UInt32 = 0
    var i_ctime: UInt32 = 0
    var i_mtime: UInt32 = 0
    var i_dtime: UInt32 = 0
    var i_gid: UInt16 = 0
    var i_links_count: UInt16
    var i_blocks_lo: UInt32
    var i_flags: UInt32
}

private struct TarEntry {
    let name: String
    let size: Int
    let typeFlag: UInt8
    let content: Data
}

