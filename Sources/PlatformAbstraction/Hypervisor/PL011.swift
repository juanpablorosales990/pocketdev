import Foundation

// MARK: - PL011 UART Emulation

/// Minimal ARM PL011 UART emulation for serial console I/O.
/// The guest kernel writes characters to the Data Register (DR) which are
/// forwarded to the host via `onOutput`. The host can inject characters
/// into the RX FIFO via `enqueueInput(_:)`.
///
/// Register map (offset from base 0x0900_0000):
///   0x000 DR     — Data Register (read: rx byte, write: tx byte)
///   0x018 FR     — Flag Register (read-only status bits)
///   0x024 IBRD   — Integer Baud Rate Divisor (ignored)
///   0x028 FBRD   — Fractional Baud Rate Divisor (ignored)
///   0x02C LCR_H  — Line Control Register (ignored)
///   0x030 CR     — Control Register (ignored)
///   0x038 IMSC   — Interrupt Mask Set/Clear
///   0x03C RIS    — Raw Interrupt Status
///   0x040 MIS    — Masked Interrupt Status
///   0x044 ICR    — Interrupt Clear Register
final class PL011: @unchecked Sendable {

    /// Called when the guest writes a byte to the UART TX.
    var onOutput: ((Data) -> Void)?

    /// Called when interrupt state changes. Bool = interrupt asserted.
    var onIRQChange: ((Bool) -> Void)?

    // RX FIFO
    private var rxFIFO: [UInt8] = []
    private let rxLock = NSLock()

    // Registers (stored values; most are no-ops)
    private var imsc: UInt32 = 0   // Interrupt Mask
    private var ris: UInt32 = 0    // Raw Interrupt Status
    private var cr: UInt32 = 0x0300 // Control Register (TX/RX enabled)
    private var lcr_h: UInt32 = 0
    private var ibrd: UInt32 = 0
    private var fbrd: UInt32 = 0

    // Interrupt bits
    private static let RXIM: UInt32 = 1 << 4  // RX interrupt
    private static let TXIM: UInt32 = 1 << 5  // TX interrupt

    // Flag register bits
    private static let FR_RXFE: UInt32 = 1 << 4  // RX FIFO empty
    private static let FR_TXFF: UInt32 = 1 << 5  // TX FIFO full (never full)
    private static let FR_RXFF: UInt32 = 1 << 6  // RX FIFO full
    private static let FR_TXFE: UInt32 = 1 << 7  // TX FIFO empty (always empty)

    /// Enqueue input bytes (from the host/user) into the RX FIFO.
    func enqueueInput(_ data: Data) {
        rxLock.lock()
        rxFIFO.append(contentsOf: data)
        ris |= Self.RXIM
        rxLock.unlock()
        updateIRQ()
    }

    /// Handle an MMIO read at the given offset from UART base.
    func read(offset: UInt64, size: Int) -> UInt32 {
        switch offset {
        case 0x000: // DR
            rxLock.lock()
            let byte: UInt32
            if rxFIFO.isEmpty {
                byte = 0
            } else {
                byte = UInt32(rxFIFO.removeFirst())
                if rxFIFO.isEmpty {
                    ris &= ~Self.RXIM
                }
            }
            rxLock.unlock()
            updateIRQ()
            return byte

        case 0x018: // FR (Flag Register)
            rxLock.lock()
            var flags: UInt32 = Self.FR_TXFE // TX always empty (instant write)
            if rxFIFO.isEmpty {
                flags |= Self.FR_RXFE
            }
            rxLock.unlock()
            return flags

        case 0x024: return ibrd
        case 0x028: return fbrd
        case 0x02C: return lcr_h
        case 0x030: return cr
        case 0x038: return imsc
        case 0x03C: return ris
        case 0x040: return ris & imsc  // MIS = RIS & IMSC

        // PL011 identification registers (PrimeCell ID)
        case 0xFE0: return 0x11  // PeriphID0
        case 0xFE4: return 0x10  // PeriphID1
        case 0xFE8: return 0x14  // PeriphID2 (rev 1, designer 0x41 = ARM)
        case 0xFEC: return 0x00  // PeriphID3
        case 0xFF0: return 0x0D  // CellID0
        case 0xFF4: return 0xF0  // CellID1
        case 0xFF8: return 0x05  // CellID2
        case 0xFFC: return 0xB1  // CellID3

        default:
            return 0
        }
    }

    /// Handle an MMIO write at the given offset from UART base.
    func write(offset: UInt64, value: UInt32, size: Int) {
        switch offset {
        case 0x000: // DR — transmit byte
            let byte = UInt8(value & 0xFF)
            onOutput?(Data([byte]))
            // TX complete — set TX raw interrupt
            ris |= Self.TXIM
            updateIRQ()

        case 0x024: ibrd = value
        case 0x028: fbrd = value
        case 0x02C: lcr_h = value
        case 0x030: cr = value
        case 0x038: // IMSC
            imsc = value
            updateIRQ()

        case 0x044: // ICR — clear interrupts
            ris &= ~value
            updateIRQ()

        default:
            break
        }
    }

    private func updateIRQ() {
        let pending = (ris & imsc) != 0
        onIRQChange?(pending)
    }
}
