import Foundation

// MARK: - Virtio Block Device

/// Virtio block device (device ID = 2) for serving the ext4 root filesystem.
/// Handles read/write requests from the guest kernel's block layer.
///
/// Request format (virtio-blk spec §5.2.6):
///   Descriptor 0: virtio_blk_req header (type, reserved, sector)  — 16 bytes, read-only
///   Descriptor 1: data buffer — variable length, read or write
///   Descriptor 2: status byte — 1 byte, device-writable
final class VirtioBlk: VirtioMMIOTransport {

    // virtio-blk request types
    private static let VIRTIO_BLK_T_IN:  UInt32 = 0   // read
    private static let VIRTIO_BLK_T_OUT: UInt32 = 1   // write
    private static let VIRTIO_BLK_T_FLUSH: UInt32 = 4
    private static let VIRTIO_BLK_T_GET_ID: UInt32 = 8

    // virtio-blk status codes
    private static let VIRTIO_BLK_S_OK:     UInt8 = 0
    private static let VIRTIO_BLK_S_IOERR:  UInt8 = 1
    private static let VIRTIO_BLK_S_UNSUPP: UInt8 = 2

    // Block device state
    private let fileHandle: FileHandle
    private let diskSizeBytes: UInt64
    private let sectorSize: UInt32 = 512

    /// Initialize with the path to the ext4 rootfs image.
    init(imagePath: String, ramHost: UnsafeMutableRawPointer, ramGuestBase: UInt64) throws {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw NSError(domain: "VirtioBlk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk image not found: \(imagePath)"])
        }
        self.fileHandle = try FileHandle(forUpdating: URL(fileURLWithPath: imagePath))

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: imagePath)
        self.diskSizeBytes = (attrs[.size] as? UInt64) ?? 0

        super.init(
            deviceID: 2,  // VIRTIO_ID_BLOCK
            numQueues: 1, // single request queue
            ramHost: ramHost,
            ramGuestBase: ramGuestBase
        )
    }

    deinit {
        try? fileHandle.close()
    }

    // MARK: - Device Features

    override func deviceFeatures(page: UInt32) -> UInt32 {
        switch page {
        case 0:
            // VIRTIO_BLK_F_SIZE_MAX (bit 1) | VIRTIO_BLK_F_SEG_MAX (bit 2)
            // | VIRTIO_BLK_F_FLUSH (bit 9)
            return (1 << 1) | (1 << 2) | (1 << 9)
        case 1:
            return 1 // VIRTIO_F_VERSION_1
        default:
            return 0
        }
    }

    // MARK: - Device Config Space

    /// Config space (spec §5.2.4):
    ///   u64 capacity   — size in 512-byte sectors
    ///   u32 size_max   — max segment size
    ///   u32 seg_max    — max segments per request
    override func readConfig(offset: UInt64) -> UInt32 {
        let capacity = diskSizeBytes / UInt64(sectorSize)
        switch offset {
        case 0: return UInt32(capacity & 0xFFFFFFFF)        // capacity low
        case 4: return UInt32(capacity >> 32)                // capacity high
        case 8: return 4096                                   // size_max
        case 12: return 128                                   // seg_max
        default: return 0
        }
    }

    // MARK: - Queue Notification

    override func queueNotify(queueIndex: UInt32) {
        guard queueIndex == 0 else { return }
        processRequestQueue()
    }

    private func processRequestQueue() {
        while let head = nextAvailable(queue: 0) {
            processRequest(head: head)
        }
    }

    private func processRequest(head: UInt16) {
        // Walk the descriptor chain
        guard let headerDesc = readDescriptor(queue: 0, index: head) else {
            pushUsed(queue: 0, head: head, len: 0)
            raiseInterrupt()
            return
        }

        // Read the request header (16 bytes)
        guard let headerPtr = guestToHost(headerDesc.addr) else {
            pushUsed(queue: 0, head: head, len: 0)
            raiseInterrupt()
            return
        }

        let type = headerPtr.load(fromByteOffset: 0, as: UInt32.self)
        // reserved: headerPtr.load(fromByteOffset: 4, as: UInt32.self)
        let sector = headerPtr.load(fromByteOffset: 8, as: UInt64.self)

        // Follow chain: header → data → status
        var dataDescs: [(VirtqDesc)] = []
        var statusDesc: VirtqDesc?

        var currentIdx = head
        var current = headerDesc
        var totalLen: UInt32 = 0

        // Skip header, collect data descriptors, last is status
        while (current.flags & VirtqDesc.VIRTQ_DESC_F_NEXT) != 0 {
            currentIdx = current.next
            guard let next = readDescriptor(queue: 0, index: currentIdx) else { break }
            current = next
            if (current.flags & VirtqDesc.VIRTQ_DESC_F_NEXT) != 0 {
                // This is a data descriptor
                dataDescs.append(current)
            } else {
                // Last descriptor in chain is status
                statusDesc = current
            }
        }

        // If only one descriptor after header, it might be status only (no data)
        // Actually: for reads, desc after header has WRITE flag (device writes data)
        // The very last descriptor in the chain is always the status byte
        // Re-parse: collect all descriptors after header
        var allAfterHeader: [VirtqDesc] = []
        currentIdx = head
        current = headerDesc
        while (current.flags & VirtqDesc.VIRTQ_DESC_F_NEXT) != 0 {
            currentIdx = current.next
            guard let next = readDescriptor(queue: 0, index: currentIdx) else { break }
            current = next
            allAfterHeader.append(current)
        }

        guard !allAfterHeader.isEmpty else {
            pushUsed(queue: 0, head: head, len: 0)
            raiseInterrupt()
            return
        }

        // Last descriptor is status, rest are data
        statusDesc = allAfterHeader.last
        dataDescs = Array(allAfterHeader.dropLast())

        let statusByte: UInt8

        switch type {
        case Self.VIRTIO_BLK_T_IN: // Read
            statusByte = handleRead(sector: sector, dataDescs: dataDescs, totalLen: &totalLen)

        case Self.VIRTIO_BLK_T_OUT: // Write
            statusByte = handleWrite(sector: sector, dataDescs: dataDescs, totalLen: &totalLen)

        case Self.VIRTIO_BLK_T_FLUSH:
            fileHandle.synchronizeFile()
            statusByte = Self.VIRTIO_BLK_S_OK

        case Self.VIRTIO_BLK_T_GET_ID:
            // Write a device ID string to the data buffer
            if let firstData = dataDescs.first, let ptr = guestToHost(firstData.addr) {
                let id = "pocketdev-vda"
                id.withCString { cstr in
                    ptr.copyMemory(from: cstr, byteCount: min(id.count + 1, Int(firstData.len)))
                }
            }
            statusByte = Self.VIRTIO_BLK_S_OK

        default:
            statusByte = Self.VIRTIO_BLK_S_UNSUPP
        }

        // Write status byte
        if let sd = statusDesc, let statusPtr = guestToHost(sd.addr) {
            statusPtr.storeBytes(of: statusByte, as: UInt8.self)
        }

        pushUsed(queue: 0, head: head, len: totalLen + 1) // +1 for status byte
        raiseInterrupt()
    }

    // MARK: - I/O Operations

    private func handleRead(sector: UInt64, dataDescs: [VirtqDesc], totalLen: inout UInt32) -> UInt8 {
        var offset = sector * UInt64(sectorSize)

        for desc in dataDescs {
            guard let ptr = guestToHost(desc.addr) else {
                return Self.VIRTIO_BLK_S_IOERR
            }

            let len = Int(desc.len)
            do {
                try fileHandle.seek(toOffset: offset)
                guard let data = try fileHandle.read(upToCount: len) else {
                    return Self.VIRTIO_BLK_S_IOERR
                }
                data.withUnsafeBytes { bytes in
                    ptr.copyMemory(from: bytes.baseAddress!, byteCount: min(data.count, len))
                }
                // Zero-fill if we got less data than requested
                if data.count < len {
                    ptr.advanced(by: data.count).initializeMemory(as: UInt8.self, repeating: 0, count: len - data.count)
                }
                offset += UInt64(len)
                totalLen += UInt32(len)
            } catch {
                return Self.VIRTIO_BLK_S_IOERR
            }
        }

        return Self.VIRTIO_BLK_S_OK
    }

    private func handleWrite(sector: UInt64, dataDescs: [VirtqDesc], totalLen: inout UInt32) -> UInt8 {
        var offset = sector * UInt64(sectorSize)

        for desc in dataDescs {
            guard let ptr = guestToHost(desc.addr) else {
                return Self.VIRTIO_BLK_S_IOERR
            }

            let len = Int(desc.len)
            let data = Data(bytes: ptr, count: len)
            do {
                try fileHandle.seek(toOffset: offset)
                fileHandle.write(data)
                offset += UInt64(len)
                totalLen += UInt32(len)
            } catch {
                return Self.VIRTIO_BLK_S_IOERR
            }
        }

        return Self.VIRTIO_BLK_S_OK
    }
}
