import Foundation

// MARK: - Virtio MMIO Transport

/// Protocol for virtio devices that plug into the MMIO transport.
protocol VirtioMMIODevice: AnyObject {
    /// Read a register at the given offset from the device's MMIO base.
    func readRegister(offset: UInt64) -> UInt32
    /// Write a register at the given offset.
    func writeRegister(offset: UInt64, value: UInt32)
}

/// Virtio-MMIO transport layer (virtio spec v1.2, §4.2).
/// Each virtio device has a 512-byte MMIO register region.
/// This class handles the common register set and virtqueue setup.
/// Subclasses (VirtioBlk, VirtioConsole) implement device-specific logic.
class VirtioMMIOTransport: VirtioMMIODevice {

    // Virtio MMIO register offsets (spec §4.2.2)
    static let MAGIC_VALUE:        UInt64 = 0x000
    static let VERSION:            UInt64 = 0x004
    static let DEVICE_ID:          UInt64 = 0x008
    static let VENDOR_ID:          UInt64 = 0x00C
    static let DEVICE_FEATURES:    UInt64 = 0x010
    static let DEVICE_FEATURES_SEL: UInt64 = 0x014
    static let DRIVER_FEATURES:    UInt64 = 0x020
    static let DRIVER_FEATURES_SEL: UInt64 = 0x024
    static let QUEUE_SEL:          UInt64 = 0x030
    static let QUEUE_NUM_MAX:      UInt64 = 0x034
    static let QUEUE_NUM:          UInt64 = 0x038
    static let QUEUE_READY:        UInt64 = 0x044
    static let QUEUE_NOTIFY:       UInt64 = 0x050
    static let INTERRUPT_STATUS:   UInt64 = 0x060
    static let INTERRUPT_ACK:      UInt64 = 0x064
    static let STATUS:             UInt64 = 0x070
    static let QUEUE_DESC_LOW:     UInt64 = 0x080
    static let QUEUE_DESC_HIGH:    UInt64 = 0x084
    static let QUEUE_DRIVER_LOW:   UInt64 = 0x090
    static let QUEUE_DRIVER_HIGH:  UInt64 = 0x094
    static let QUEUE_DEVICE_LOW:   UInt64 = 0x0A0
    static let QUEUE_DEVICE_HIGH:  UInt64 = 0x0A4
    static let CONFIG_GENERATION:  UInt64 = 0x0FC
    static let CONFIG_BASE:        UInt64 = 0x100

    // Device properties (set by subclass)
    let deviceID: UInt32
    let numQueues: Int

    // RAM access for reading/writing virtqueue memory
    let ramHost: UnsafeMutableRawPointer
    let ramGuestBase: UInt64

    // Callback to fire an interrupt
    var onInterrupt: (() -> Void)?

    // Transport state
    private var status: UInt32 = 0
    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeatures: [UInt32] = [0, 0]
    private var queueSel: UInt32 = 0
    private var interruptStatus: UInt32 = 0

    // Per-queue state
    struct VirtqueueState {
        var num: UInt32 = 0
        var ready: UInt32 = 0
        var descAddr: UInt64 = 0
        var driverAddr: UInt64 = 0  // available ring
        var deviceAddr: UInt64 = 0  // used ring
        var lastAvailIdx: UInt16 = 0
    }
    var queues: [VirtqueueState]

    init(deviceID: UInt32, numQueues: Int, ramHost: UnsafeMutableRawPointer, ramGuestBase: UInt64) {
        self.deviceID = deviceID
        self.numQueues = numQueues
        self.ramHost = ramHost
        self.ramGuestBase = ramGuestBase
        self.queues = [VirtqueueState](repeating: VirtqueueState(), count: numQueues)
    }

    /// Override in subclass to provide device-specific feature bits.
    func deviceFeatures(page: UInt32) -> UInt32 {
        if page == 1 {
            return 1 // VIRTIO_F_VERSION_1 (bit 32 → page 1, bit 0)
        }
        return 0
    }

    /// Override in subclass to handle queue notifications.
    func queueNotify(queueIndex: UInt32) {
        // Subclass handles
    }

    /// Override in subclass to provide device config space reads.
    func readConfig(offset: UInt64) -> UInt32 {
        return 0
    }

    /// Override in subclass to handle device config space writes.
    func writeConfig(offset: UInt64, value: UInt32) {
    }

    // MARK: - VirtioMMIODevice

    func readRegister(offset: UInt64) -> UInt32 {
        switch offset {
        case Self.MAGIC_VALUE:
            return 0x74726976 // "virt"
        case Self.VERSION:
            return 2 // virtio v1.0 (modern)
        case Self.DEVICE_ID:
            return deviceID
        case Self.VENDOR_ID:
            return 0x554D4551 // "QEMU" — standard vendor ID
        case Self.DEVICE_FEATURES:
            return deviceFeatures(page: deviceFeaturesSel)
        case Self.QUEUE_NUM_MAX:
            return 256 // max queue size
        case Self.QUEUE_READY:
            let idx = Int(queueSel)
            return idx < numQueues ? queues[idx].ready : 0
        case Self.INTERRUPT_STATUS:
            return interruptStatus
        case Self.STATUS:
            return status
        case Self.CONFIG_GENERATION:
            return 0
        default:
            if offset >= Self.CONFIG_BASE {
                return readConfig(offset: offset - Self.CONFIG_BASE)
            }
            return 0
        }
    }

    func writeRegister(offset: UInt64, value: UInt32) {
        switch offset {
        case Self.DEVICE_FEATURES_SEL:
            deviceFeaturesSel = value
        case Self.DRIVER_FEATURES:
            let sel = Int(driverFeaturesSel)
            if sel < driverFeatures.count {
                driverFeatures[sel] = value
            }
        case Self.DRIVER_FEATURES_SEL:
            driverFeaturesSel = value
        case Self.QUEUE_SEL:
            queueSel = value
        case Self.QUEUE_NUM:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].num = value
            }
        case Self.QUEUE_READY:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].ready = value
            }
        case Self.QUEUE_NOTIFY:
            queueNotify(queueIndex: value)
        case Self.INTERRUPT_ACK:
            interruptStatus &= ~value
        case Self.STATUS:
            status = value
            if value == 0 {
                resetDevice()
            }
        case Self.QUEUE_DESC_LOW:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].descAddr = (queues[idx].descAddr & 0xFFFFFFFF_00000000) | UInt64(value)
            }
        case Self.QUEUE_DESC_HIGH:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].descAddr = (queues[idx].descAddr & 0x00000000_FFFFFFFF) | (UInt64(value) << 32)
            }
        case Self.QUEUE_DRIVER_LOW:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].driverAddr = (queues[idx].driverAddr & 0xFFFFFFFF_00000000) | UInt64(value)
            }
        case Self.QUEUE_DRIVER_HIGH:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].driverAddr = (queues[idx].driverAddr & 0x00000000_FFFFFFFF) | (UInt64(value) << 32)
            }
        case Self.QUEUE_DEVICE_LOW:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].deviceAddr = (queues[idx].deviceAddr & 0xFFFFFFFF_00000000) | UInt64(value)
            }
        case Self.QUEUE_DEVICE_HIGH:
            let idx = Int(queueSel)
            if idx < numQueues {
                queues[idx].deviceAddr = (queues[idx].deviceAddr & 0x00000000_FFFFFFFF) | (UInt64(value) << 32)
            }
        default:
            if offset >= Self.CONFIG_BASE {
                writeConfig(offset: offset - Self.CONFIG_BASE, value: value)
            }
        }
    }

    private func resetDevice() {
        status = 0
        interruptStatus = 0
        for i in 0..<numQueues {
            queues[i] = VirtqueueState()
        }
    }

    // MARK: - Virtqueue Access

    /// Signal an interrupt to the guest (used ring updated).
    func raiseInterrupt() {
        interruptStatus |= 1 // bit 0 = used ring update
        onInterrupt?()
    }

    /// Translate a guest physical address to a host pointer.
    func guestToHost(_ gpa: UInt64) -> UnsafeMutableRawPointer? {
        guard gpa >= ramGuestBase else { return nil }
        let offset = gpa - ramGuestBase
        return ramHost.advanced(by: Int(offset))
    }

    // Virtqueue descriptor (16 bytes each)
    struct VirtqDesc {
        let addr: UInt64    // guest physical address of buffer
        let len: UInt32     // buffer length
        let flags: UInt16   // NEXT=1, WRITE=2, INDIRECT=4
        let next: UInt16    // next descriptor index (if NEXT flag set)

        static let VIRTQ_DESC_F_NEXT: UInt16 = 1
        static let VIRTQ_DESC_F_WRITE: UInt16 = 2
    }

    /// Read a descriptor from the descriptor table.
    func readDescriptor(queue: Int, index: UInt16) -> VirtqDesc? {
        guard queue < numQueues else { return nil }
        let q = queues[queue]
        guard let base = guestToHost(q.descAddr) else { return nil }
        let ptr = base.advanced(by: Int(index) * 16)

        let addr = ptr.load(fromByteOffset: 0, as: UInt64.self)
        let len = ptr.load(fromByteOffset: 8, as: UInt32.self)
        let flags = ptr.load(fromByteOffset: 12, as: UInt16.self)
        let next = ptr.load(fromByteOffset: 14, as: UInt16.self)

        return VirtqDesc(addr: addr, len: len, flags: flags, next: next)
    }

    /// Read the next available descriptor chain head index.
    /// Returns nil if no new descriptors are available.
    func nextAvailable(queue: Int) -> UInt16? {
        guard queue < numQueues else { return nil }
        let q = queues[queue]
        guard let base = guestToHost(q.driverAddr) else { return nil }

        // Available ring layout:
        //   u16 flags
        //   u16 idx  (next index driver will write to)
        //   u16 ring[queue_size]
        let availIdx = base.load(fromByteOffset: 2, as: UInt16.self)
        if availIdx == q.lastAvailIdx {
            return nil // no new descriptors
        }
        let ringIdx = Int(q.lastAvailIdx % UInt16(q.num))
        let head = base.load(fromByteOffset: 4 + ringIdx * 2, as: UInt16.self)
        queues[queue].lastAvailIdx &+= 1
        return head
    }

    /// Write a used descriptor entry.
    func pushUsed(queue: Int, head: UInt16, len: UInt32) {
        guard queue < numQueues else { return }
        let q = queues[queue]
        guard let base = guestToHost(q.deviceAddr) else { return }

        // Used ring layout:
        //   u16 flags
        //   u16 idx
        //   struct { u32 id; u32 len; } ring[queue_size]
        let usedIdx = base.load(fromByteOffset: 2, as: UInt16.self)
        let ringIdx = Int(usedIdx % UInt16(q.num))
        let entryOffset = 4 + ringIdx * 8

        base.storeBytes(of: UInt32(head), toByteOffset: entryOffset, as: UInt32.self)
        base.storeBytes(of: len, toByteOffset: entryOffset + 4, as: UInt32.self)

        // Increment used index
        base.storeBytes(of: usedIdx &+ 1, toByteOffset: 2, as: UInt16.self)
    }
}
