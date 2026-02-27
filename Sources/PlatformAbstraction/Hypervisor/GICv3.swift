import Foundation

#if canImport(Hypervisor) && arch(arm64)
import Hypervisor
#endif

// MARK: - GICv3 Emulation

/// Minimal GICv3 (Generic Interrupt Controller v3) emulation.
/// Handles GICD (Distributor) and GICR (Redistributor) MMIO registers,
/// plus ICC system register trapping for interrupt acknowledge/EOI.
///
/// Supports up to 96 SPIs (IRQ 32–127) which covers UART + 2 virtio devices.
/// PPI 27 (virtual timer) is handled directly by Hypervisor.framework.
final class GICv3: @unchecked Sendable {

    // GICD registers (Distributor)
    private static let GICD_CTLR:       UInt64 = 0x0000
    private static let GICD_TYPER:      UInt64 = 0x0004
    private static let GICD_IIDR:       UInt64 = 0x0008
    private static let GICD_ISENABLER:  UInt64 = 0x0100  // 0x100–0x17C (array)
    private static let GICD_ICENABLER:  UInt64 = 0x0180  // 0x180–0x1FC
    private static let GICD_ISPENDR:    UInt64 = 0x0200  // 0x200–0x27C
    private static let GICD_ICPENDR:    UInt64 = 0x0280  // 0x280–0x2FC
    private static let GICD_ISACTIVER:  UInt64 = 0x0300
    private static let GICD_ICACTIVER:  UInt64 = 0x0380
    private static let GICD_IPRIORITYR: UInt64 = 0x0400  // 0x400–0x7FC
    private static let GICD_ITARGETSR:  UInt64 = 0x0800  // 0x800–0xBFC
    private static let GICD_ICFGR:      UInt64 = 0x0C00  // 0xC00–0xCFC
    private static let GICD_IROUTER:    UInt64 = 0x6000  // 0x6000+ (64-bit per SPI)
    private static let GICD_PIDR2:      UInt64 = 0xFFE8

    // GICR registers (Redistributor — per-CPU)
    private static let GICR_CTLR:       UInt64 = 0x0000
    private static let GICR_IIDR:       UInt64 = 0x0004
    private static let GICR_TYPER:      UInt64 = 0x0008
    private static let GICR_WAKER:      UInt64 = 0x0014
    private static let GICR_IGROUPR0:   UInt64 = 0x10080
    private static let GICR_ISENABLER0: UInt64 = 0x10100
    private static let GICR_ICENABLER0: UInt64 = 0x10180
    private static let GICR_ISPENDR0:   UInt64 = 0x10200
    private static let GICR_ICPENDR0:   UInt64 = 0x10280
    private static let GICR_IPRIORITYR: UInt64 = 0x10400

    // Constants
    private static let MAX_IRQS = 128  // IRQ 0–127
    private static let SPI_BASE = 32

    // State
    private var ctlr: UInt32 = 0
    private var enabled = [UInt32](repeating: 0, count: 4)   // 128 bits = 4 words
    private var pending = [UInt32](repeating: 0, count: 4)
    private var active  = [UInt32](repeating: 0, count: 4)
    private var priority = [UInt8](repeating: 0, count: 128)
    private var config   = [UInt32](repeating: 0, count: 8)  // 2 bits per IRQ

    // GICR state
    private var gicr_waker: UInt32 = 0x0000_0002 // ChildrenAsleep initially set
    private var gicr_enabled0: UInt32 = 0   // PPI/SGI enables (IRQ 0–31)
    private var gicr_pending0: UInt32 = 0
    private var gicr_group0: UInt32 = 0xFFFF_FFFF  // all group 1

    // ICC system register state
    private var icc_pmr: UInt32 = 0
    private var icc_ctlr: UInt32 = 0
    private var icc_igrpen1: UInt32 = 0
    private var icc_bpr1: UInt32 = 0

    private let lock = NSLock()

    /// Set an SPI interrupt as pending.
    func setSPIPending(_ irqNum: UInt32) {
        guard irqNum >= 32, irqNum < 128 else { return }
        lock.lock()
        let word = Int(irqNum / 32)
        let bit = UInt32(1) << (irqNum % 32)
        pending[word] |= bit
        lock.unlock()
    }

    /// Clear an SPI interrupt pending bit.
    func clearSPIPending(_ irqNum: UInt32) {
        guard irqNum >= 32, irqNum < 128 else { return }
        lock.lock()
        let word = Int(irqNum / 32)
        let bit = UInt32(1) << (irqNum % 32)
        pending[word] &= ~bit
        lock.unlock()
    }

    /// Check if any interrupt is pending and enabled. Returns true if IRQ should be asserted.
    func hasPendingInterrupt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<4 {
            if (pending[i] & enabled[i]) != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - GICD MMIO

    func readDistributor(offset: UInt64, size: Int) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case Self.GICD_CTLR:
            return ctlr
        case Self.GICD_TYPER:
            // ITLinesNumber = 2 (supports IRQ 0–95), SecurityExtn=0, CPUNumber=0
            return 2
        case Self.GICD_IIDR:
            return 0x0100_143B // ARM GICv3
        case Self.GICD_PIDR2:
            return 0x3B // GICv3 architecture revision

        case 0x0100...0x017C: // ISENABLER
            let idx = Int((offset - 0x0100) / 4)
            return idx < enabled.count ? enabled[idx] : 0

        case 0x0200...0x027C: // ISPENDR
            let idx = Int((offset - 0x0200) / 4)
            return idx < pending.count ? pending[idx] : 0

        case 0x0300...0x037C: // ISACTIVER
            let idx = Int((offset - 0x0300) / 4)
            return idx < active.count ? active[idx] : 0

        case 0x0400...0x07FC: // IPRIORITYR (byte accessible)
            let byteOff = Int(offset - 0x0400)
            if byteOff < priority.count {
                return UInt32(priority[byteOff])
            }
            return 0

        case 0x0C00...0x0CFC: // ICFGR
            let idx = Int((offset - 0x0C00) / 4)
            return idx < config.count ? config[idx] : 0

        case 0x6000...0x7FFC: // IROUTER
            return 0 // all routed to CPU 0

        default:
            return 0
        }
    }

    func writeDistributor(offset: UInt64, value: UInt32, size: Int) {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case Self.GICD_CTLR:
            ctlr = value

        case 0x0100...0x017C: // ISENABLER — set enable
            let idx = Int((offset - 0x0100) / 4)
            if idx < enabled.count {
                enabled[idx] |= value
            }

        case 0x0180...0x01FC: // ICENABLER — clear enable
            let idx = Int((offset - 0x0180) / 4)
            if idx < enabled.count {
                enabled[idx] &= ~value
            }

        case 0x0200...0x027C: // ISPENDR — set pending
            let idx = Int((offset - 0x0200) / 4)
            if idx < pending.count {
                pending[idx] |= value
            }

        case 0x0280...0x02FC: // ICPENDR — clear pending
            let idx = Int((offset - 0x0280) / 4)
            if idx < pending.count {
                pending[idx] &= ~value
            }

        case 0x0300...0x037C: // ISACTIVER — set active
            let idx = Int((offset - 0x0300) / 4)
            if idx < active.count {
                active[idx] |= value
            }

        case 0x0380...0x03FC: // ICACTIVER — clear active
            let idx = Int((offset - 0x0380) / 4)
            if idx < active.count {
                active[idx] &= ~value
            }

        case 0x0400...0x07FC: // IPRIORITYR
            let byteOff = Int(offset - 0x0400)
            if byteOff < priority.count {
                priority[byteOff] = UInt8(value & 0xFF)
            }

        case 0x0C00...0x0CFC: // ICFGR
            let idx = Int((offset - 0x0C00) / 4)
            if idx < config.count {
                config[idx] = value
            }

        case 0x6000...0x7FFC: // IROUTER
            break // single CPU, ignore

        default:
            break
        }
    }

    // MARK: - GICR MMIO

    func readRedistributor(offset: UInt64, size: Int) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case Self.GICR_CTLR:
            return 0
        case Self.GICR_IIDR:
            return 0x0100_143B
        case Self.GICR_TYPER:
            // Last=1 (single CPU), Processor_Number=0, VLPIS=0
            return 0x10  // bit 4 = Last
        case Self.GICR_TYPER + 4: // High 32 bits of TYPER
            return 0
        case Self.GICR_WAKER:
            return gicr_waker

        // SGI/PPI frame (offset 0x10000+)
        case Self.GICR_IGROUPR0:
            return gicr_group0
        case Self.GICR_ISENABLER0:
            return gicr_enabled0
        case Self.GICR_ISPENDR0:
            return gicr_pending0
        case Self.GICR_ICPENDR0:
            return gicr_pending0

        case 0x10400...0x1041C: // GICR_IPRIORITYR for SGI/PPI
            return 0

        default:
            return 0
        }
    }

    func writeRedistributor(offset: UInt64, value: UInt32, size: Int) {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case Self.GICR_WAKER:
            // Guest clears ChildrenAsleep (bit 1) to wake the redistributor
            gicr_waker = value & ~UInt32(0x4) // clear ProcessorSleep ack
            if (value & 0x2) == 0 {
                // Waking up: clear ChildrenAsleep
                gicr_waker &= ~UInt32(0x4)
            }

        case Self.GICR_IGROUPR0:
            gicr_group0 = value
        case Self.GICR_ISENABLER0:
            gicr_enabled0 |= value
        case Self.GICR_ICENABLER0:
            gicr_enabled0 &= ~value
        case Self.GICR_ISPENDR0:
            gicr_pending0 |= value
        case Self.GICR_ICPENDR0:
            gicr_pending0 &= ~value

        default:
            break
        }
    }

    // MARK: - ICC System Register Emulation

    /// Handle a trapped read of an ICC system register.
    /// Returns the value the guest should see.
    func readICCRegister(_ reg: ICCRegister) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        switch reg {
        case .SRE_EL1:
            return 0x7 // SRE=1, DFB=1, DIB=1 (system register access enabled)
        case .PMR_EL1:
            return UInt64(icc_pmr)
        case .CTLR_EL1:
            return UInt64(icc_ctlr)
        case .IGRPEN1_EL1:
            return UInt64(icc_igrpen1)
        case .BPR1_EL1:
            return UInt64(icc_bpr1)
        case .IAR1_EL1:
            // Return highest-priority pending & enabled interrupt
            return UInt64(acknowledgeInterrupt())
        case .RPR_EL1:
            return 0xFF // idle priority
        case .HPPIR1_EL1:
            return UInt64(highestPendingInterrupt())
        }
    }

    /// Handle a trapped write to an ICC system register.
    func writeICCRegister(_ reg: ICCRegister, value: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        switch reg {
        case .SRE_EL1:
            break // read-only
        case .PMR_EL1:
            icc_pmr = UInt32(value & 0xFF)
        case .CTLR_EL1:
            icc_ctlr = UInt32(value)
        case .IGRPEN1_EL1:
            icc_igrpen1 = UInt32(value & 1)
        case .BPR1_EL1:
            icc_bpr1 = UInt32(value & 0x7)
        case .IAR1_EL1:
            break // read-only
        case .RPR_EL1:
            break // read-only
        case .HPPIR1_EL1:
            break // read-only
        }
    }

    /// Handle a write to ICC_EOIR1_EL1 (End of Interrupt).
    func endOfInterrupt(_ irqNum: UInt32) {
        guard irqNum < 128 else { return }
        lock.lock()
        let word = Int(irqNum / 32)
        let bit = UInt32(1) << (irqNum % 32)
        active[word] &= ~bit
        lock.unlock()
    }

    // MARK: - Private

    /// Acknowledge the highest-priority pending interrupt.
    /// Returns the IRQ number, or 1023 if none pending.
    private func acknowledgeInterrupt() -> UInt32 {
        // Check SPIs (32+)
        for i in 1..<4 {
            let pendingEnabled = pending[i] & enabled[i]
            if pendingEnabled != 0 {
                let bit = UInt32(pendingEnabled.trailingZeroBitCount)
                let irq = UInt32(i * 32) + bit
                pending[i] &= ~(1 << bit)
                active[i] |= (1 << bit)
                return irq
            }
        }
        return 1023 // spurious
    }

    private func highestPendingInterrupt() -> UInt32 {
        for i in 1..<4 {
            let pendingEnabled = pending[i] & enabled[i]
            if pendingEnabled != 0 {
                let bit = UInt32(pendingEnabled.trailingZeroBitCount)
                return UInt32(i * 32) + bit
            }
        }
        return 1023
    }

    /// Known ICC system registers we trap.
    enum ICCRegister {
        case SRE_EL1
        case PMR_EL1
        case CTLR_EL1
        case IGRPEN1_EL1
        case BPR1_EL1
        case IAR1_EL1
        case RPR_EL1
        case HPPIR1_EL1
    }
}
