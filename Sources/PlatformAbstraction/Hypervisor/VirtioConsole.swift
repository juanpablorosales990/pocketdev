import Foundation

// MARK: - Virtio Console Device

/// Virtio console device (device ID = 3) for terminal I/O between the guest
/// and the host terminal emulator (SwiftTerm).
///
/// Two virtqueues:
///   Queue 0 (receiveq): host → guest (keyboard input)
///   Queue 1 (transmitq): guest → host (terminal output)
final class VirtioConsole: VirtioMMIOTransport {

    /// Called when the guest writes output to the console (terminal display).
    var onOutput: ((Data) -> Void)?

    /// Pending input bytes from the host waiting to be consumed by the guest.
    private var inputBuffer: [UInt8] = []
    private let inputLock = NSLock()

    init(ramHost: UnsafeMutableRawPointer, ramGuestBase: UInt64) {
        super.init(
            deviceID: 3,  // VIRTIO_ID_CONSOLE
            numQueues: 2, // receiveq + transmitq
            ramHost: ramHost,
            ramGuestBase: ramGuestBase
        )
    }

    // MARK: - Device Features

    override func deviceFeatures(page: UInt32) -> UInt32 {
        switch page {
        case 0:
            return 0 // No special console features for MVP
        case 1:
            return 1 // VIRTIO_F_VERSION_1
        default:
            return 0
        }
    }

    // MARK: - Config Space

    override func readConfig(offset: UInt64) -> UInt32 {
        switch offset {
        case 0: return 80  // cols
        case 2: return 24  // rows
        case 4: return 1   // max_nr_ports
        default: return 0
        }
    }

    // MARK: - Host → Guest Input

    /// Enqueue input from the host (user typing in the terminal).
    /// This data will be delivered to the guest via the receiveq.
    func enqueueInput(_ data: Data) {
        inputLock.lock()
        inputBuffer.append(contentsOf: data)
        inputLock.unlock()

        // Try to deliver immediately if guest has posted receive buffers
        deliverPendingInput()
    }

    /// Deliver pending input bytes to the guest via receiveq (queue 0).
    private func deliverPendingInput() {
        inputLock.lock()
        guard !inputBuffer.isEmpty else {
            inputLock.unlock()
            return
        }

        while !inputBuffer.isEmpty {
            guard let head = nextAvailable(queue: 0) else {
                break // No receive buffers available from guest
            }

            guard let desc = readDescriptor(queue: 0, index: head) else {
                break
            }

            guard let ptr = guestToHost(desc.addr) else {
                break
            }

            let copyLen = min(inputBuffer.count, Int(desc.len))
            inputBuffer.withUnsafeBufferPointer { buf in
                ptr.copyMemory(from: buf.baseAddress!, byteCount: copyLen)
            }
            inputBuffer.removeFirst(copyLen)

            pushUsed(queue: 0, head: head, len: UInt32(copyLen))
        }
        inputLock.unlock()

        raiseInterrupt()
    }

    // MARK: - Queue Notification

    override func queueNotify(queueIndex: UInt32) {
        switch queueIndex {
        case 0: // receiveq — guest posted new receive buffers
            deliverPendingInput()
        case 1: // transmitq — guest sent output
            processTransmitQueue()
        default:
            break
        }
    }

    /// Process the transmit queue: read data guest wants to output.
    private func processTransmitQueue() {
        while let head = nextAvailable(queue: 1) {
            var output = Data()

            // Walk the descriptor chain
            var currentIdx = head
            while true {
                guard let desc = readDescriptor(queue: 1, index: currentIdx) else { break }
                if let ptr = guestToHost(desc.addr) {
                    output.append(Data(bytes: ptr, count: Int(desc.len)))
                }
                if (desc.flags & VirtqDesc.VIRTQ_DESC_F_NEXT) != 0 {
                    currentIdx = desc.next
                } else {
                    break
                }
            }

            pushUsed(queue: 1, head: head, len: 0)

            if !output.isEmpty {
                onOutput?(output)
            }
        }

        raiseInterrupt()
    }
}
