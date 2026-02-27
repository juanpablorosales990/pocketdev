#if canImport(Hypervisor) && arch(arm64)
import Foundation
import Hypervisor

// MARK: - vCPU Exit Handler

/// Decodes and dispatches vCPU exits from `hv_vcpu_run()`.
/// Routes MMIO traps to the correct virtual device, handles PSCI hypercalls,
/// manages timer interrupts, and processes system register traps.
final class VCPUExitHandler {

    let vcpu: hv_vcpu_t
    let vcpuExit: UnsafeMutablePointer<hv_vcpu_exit_t>

    // Devices
    let uart: PL011
    let gic: GICv3
    var virtioDevices: [UInt64: VirtioMMIODevice] = [:]  // base address → device

    // RAM access
    let ramHost: UnsafeMutableRawPointer  // host pointer to guest RAM
    let ramGuestBase: UInt64              // guest physical address of RAM start

    // Callbacks
    var onShutdown: (() -> Void)?

    // State
    private(set) var shouldStop = false

    init(
        vcpu: hv_vcpu_t,
        vcpuExit: UnsafeMutablePointer<hv_vcpu_exit_t>,
        uart: PL011,
        gic: GICv3,
        ramHost: UnsafeMutableRawPointer,
        ramGuestBase: UInt64
    ) {
        self.vcpu = vcpu
        self.vcpuExit = vcpuExit
        self.uart = uart
        self.gic = gic
        self.ramHost = ramHost
        self.ramGuestBase = ramGuestBase
    }

    /// Register a virtio-mmio device at the given base address.
    func registerVirtioDevice(_ device: VirtioMMIODevice, at base: UInt64) {
        virtioDevices[base] = device
    }

    /// Handle one vCPU exit. Returns true if the vCPU should continue running.
    func handleExit() -> Bool {
        if shouldStop { return false }

        let reason = vcpuExit.pointee.reason
        switch reason {
        case HV_EXIT_REASON_EXCEPTION:
            return handleException()
        case HV_EXIT_REASON_VTIMER_ACTIVATED:
            return handleVTimer()
        case HV_EXIT_REASON_CANCELED:
            return !shouldStop
        default:
            return false
        }
    }

    /// Request the vCPU to stop.
    func requestStop() {
        shouldStop = true
    }

    // MARK: - Exception Handling

    private func handleException() -> Bool {
        let syndrome = vcpuExit.pointee.exception.syndrome
        let ec = (syndrome >> 26) & 0x3F

        switch ec {
        case 0x24: // Data Abort from lower EL (MMIO trap)
            return handleDataAbort(syndrome: syndrome)

        case 0x16: // HVC (AArch64) — PSCI
            return handleHVC()

        case 0x01: // WFI/WFE
            return handleWFI()

        case 0x18: // MSR/MRS trap (system register access)
            return handleSysRegTrap(syndrome: syndrome)

        default:
            // Unknown EC — advance PC and continue
            advancePC()
            return true
        }
    }

    // MARK: - Data Abort (MMIO)

    private func handleDataAbort(syndrome: UInt64) -> Bool {
        // Extract IPA from FAR_EL2 via HPFAR_EL2
        let ipa = vcpuExit.pointee.exception.physical_address

        // Decode ISS
        let isWrite = (syndrome & (1 << 6)) != 0
        let srt = Int((syndrome >> 16) & 0x1F)    // target register
        let sas = Int((syndrome >> 22) & 0x3)      // access size: 0=byte, 1=hw, 2=word, 3=dw
        let accessSize = 1 << sas

        if isWrite {
            let value = readVCPUReg(srt)
            handleMMIOWrite(address: ipa, value: UInt32(truncatingIfNeeded: value), size: accessSize)
        } else {
            let value = handleMMIORead(address: ipa, size: accessSize)
            writeVCPUReg(srt, value: UInt64(value))
        }

        advancePC()
        return true
    }

    private func handleMMIORead(address: UInt64, size: Int) -> UInt32 {
        // UART: 0x0900_0000 – 0x0900_0FFF
        if address >= FDTBuilder.UART_BASE && address < FDTBuilder.UART_BASE + FDTBuilder.UART_SIZE {
            return uart.read(offset: address - FDTBuilder.UART_BASE, size: size)
        }

        // GIC Distributor: 0x0800_0000 – 0x0800_FFFF
        if address >= FDTBuilder.GICD_BASE && address < FDTBuilder.GICD_BASE + FDTBuilder.GICD_SIZE {
            return gic.readDistributor(offset: address - FDTBuilder.GICD_BASE, size: size)
        }

        // GIC Redistributor: 0x080A_0000 – 0x080B_FFFF
        if address >= FDTBuilder.GICR_BASE && address < FDTBuilder.GICR_BASE + FDTBuilder.GICR_SIZE {
            return gic.readRedistributor(offset: address - FDTBuilder.GICR_BASE, size: size)
        }

        // Virtio devices
        for (base, device) in virtioDevices {
            if address >= base && address < base + FDTBuilder.VIRTIO_SLOT_SIZE {
                return device.readRegister(offset: address - base)
            }
        }

        return 0
    }

    private func handleMMIOWrite(address: UInt64, value: UInt32, size: Int) {
        // UART
        if address >= FDTBuilder.UART_BASE && address < FDTBuilder.UART_BASE + FDTBuilder.UART_SIZE {
            uart.write(offset: address - FDTBuilder.UART_BASE, value: value, size: size)
            return
        }

        // GIC Distributor
        if address >= FDTBuilder.GICD_BASE && address < FDTBuilder.GICD_BASE + FDTBuilder.GICD_SIZE {
            gic.writeDistributor(offset: address - FDTBuilder.GICD_BASE, value: value, size: size)
            return
        }

        // GIC Redistributor
        if address >= FDTBuilder.GICR_BASE && address < FDTBuilder.GICR_BASE + FDTBuilder.GICR_SIZE {
            gic.writeRedistributor(offset: address - FDTBuilder.GICR_BASE, value: value, size: size)
            return
        }

        // Virtio devices
        for (base, device) in virtioDevices {
            if address >= base && address < base + FDTBuilder.VIRTIO_SLOT_SIZE {
                device.writeRegister(offset: address - base, value: value)
                return
            }
        }
    }

    // MARK: - HVC (PSCI)

    private func handleHVC() -> Bool {
        var functionID: UInt64 = 0
        hv_vcpu_get_reg(vcpu, HV_REG_X0, &functionID)

        switch UInt32(truncatingIfNeeded: functionID) {
        case 0x8400_0000: // PSCI_VERSION
            hv_vcpu_set_reg(vcpu, HV_REG_X0, 0x0001_0001) // v1.1

        case 0xC400_0003: // CPU_ON (64-bit)
            // Single vCPU — return ALREADY_ON
            hv_vcpu_set_reg(vcpu, HV_REG_X0, UInt64(bitPattern: -4)) // PSCI_RET_ALREADY_ON

        case 0x8400_0008: // SYSTEM_OFF
            shouldStop = true
            onShutdown?()
            return false

        case 0x8400_0009: // SYSTEM_RESET
            shouldStop = true
            onShutdown?()
            return false

        case 0x8400_000A: // PSCI_FEATURES
            var featureID: UInt64 = 0
            hv_vcpu_get_reg(vcpu, HV_REG_X1, &featureID)
            // Support all basic PSCI calls
            hv_vcpu_set_reg(vcpu, HV_REG_X0, 0) // SUCCESS

        default:
            // Unknown PSCI function — return NOT_SUPPORTED
            hv_vcpu_set_reg(vcpu, HV_REG_X0, UInt64(bitPattern: -1))
        }

        advancePC()
        return true
    }

    // MARK: - WFI (Wait For Interrupt)

    private func handleWFI() -> Bool {
        // Check if there's a pending interrupt
        if gic.hasPendingInterrupt() {
            advancePC()
            return true
        }

        // Sleep briefly, then check again. The vtimer or another device
        // will wake us via hv_vcpus_exit if needed.
        usleep(500) // 0.5ms — balance between latency and CPU usage
        advancePC()
        return true
    }

    // MARK: - Virtual Timer

    private func handleVTimer() -> Bool {
        // The guest's virtual timer has fired.
        // Mask it so we don't get repeated exits, then let the interrupt be delivered.
        hv_vcpu_set_vtimer_mask(vcpu, true)

        // The timer PPI (IRQ 27) is auto-injected by Hypervisor.framework
        // when we unmask. We mask it here to prevent re-entry, then unmask
        // after a short delay to let the guest handle it.

        // Actually: Hypervisor.framework delivers the vtimer interrupt automatically.
        // We just need to unmask it so the guest can process it.
        // The mask prevents repeated VTIMER_ACTIVATED exits.
        // The guest will clear the timer condition, then we unmask for the next one.

        // Unmask after the guest handles the interrupt (on next WFI or soon)
        hv_vcpu_set_vtimer_mask(vcpu, false)

        return true
    }

    // MARK: - System Register Traps

    private func handleSysRegTrap(syndrome: UInt64) -> Bool {
        let isRead = (syndrome & 1) != 0
        let rt = Int((syndrome >> 5) & 0x1F)
        let crm = Int((syndrome >> 1) & 0xF)
        let crn = Int((syndrome >> 10) & 0xF)
        let op1 = Int((syndrome >> 14) & 0x7)
        let op2 = Int((syndrome >> 17) & 0x7)
        let op0 = Int((syndrome >> 20) & 0x3)

        // Identify ICC registers by their encoding:
        // ICC_SRE_EL1:    op0=3, op1=0, crn=12, crm=12, op2=5
        // ICC_PMR_EL1:    op0=3, op1=0, crn=4,  crm=6,  op2=0
        // ICC_IAR1_EL1:   op0=3, op1=0, crn=12, crm=12, op2=0
        // ICC_EOIR1_EL1:  op0=3, op1=0, crn=12, crm=12, op2=1
        // ICC_CTLR_EL1:   op0=3, op1=0, crn=12, crm=12, op2=4
        // ICC_IGRPEN1_EL1:op0=3, op1=0, crn=12, crm=12, op2=7
        // ICC_BPR1_EL1:   op0=3, op1=0, crn=12, crm=12, op2=3
        // ICC_RPR_EL1:    op0=3, op1=0, crn=12, crm=11, op2=3
        // ICC_HPPIR1_EL1: op0=3, op1=0, crn=12, crm=12, op2=2

        if let iccReg = decodeICCRegister(op0: op0, op1: op1, crn: crn, crm: crm, op2: op2) {
            if isRead {
                let value = gic.readICCRegister(iccReg)
                writeVCPUReg(rt, value: value)
            } else {
                let value = readVCPUReg(rt)
                gic.writeICCRegister(iccReg, value: value)
            }
        } else if op0 == 3 && op1 == 0 && crn == 12 && crm == 12 && op2 == 1 && !isRead {
            // ICC_EOIR1_EL1 — End of Interrupt (write-only)
            let irqNum = UInt32(readVCPUReg(rt))
            gic.endOfInterrupt(irqNum)
        } else {
            // Unknown system register — return 0 for reads
            if isRead {
                writeVCPUReg(rt, value: 0)
            }
        }

        advancePC()
        return true
    }

    private func decodeICCRegister(op0: Int, op1: Int, crn: Int, crm: Int, op2: Int) -> GICv3.ICCRegister? {
        guard op0 == 3, op1 == 0 else { return nil }

        if crn == 12 && crm == 12 {
            switch op2 {
            case 0: return .IAR1_EL1
            case 2: return .HPPIR1_EL1
            case 3: return .BPR1_EL1
            case 4: return .CTLR_EL1
            case 5: return .SRE_EL1
            case 7: return .IGRPEN1_EL1
            default: return nil
            }
        }

        if crn == 4 && crm == 6 && op2 == 0 {
            return .PMR_EL1
        }

        if crn == 12 && crm == 11 && op2 == 3 {
            return .RPR_EL1
        }

        return nil
    }

    // MARK: - Register Helpers

    private func readVCPUReg(_ index: Int) -> UInt64 {
        var value: UInt64 = 0
        if index == 31 {
            return 0 // XZR
        }
        let reg = hv_reg_t(rawValue: UInt32(HV_REG_X0.rawValue) + UInt32(index))
        hv_vcpu_get_reg(vcpu, reg, &value)
        return value
    }

    private func writeVCPUReg(_ index: Int, value: UInt64) {
        if index == 31 { return } // XZR
        let reg = hv_reg_t(rawValue: UInt32(HV_REG_X0.rawValue) + UInt32(index))
        hv_vcpu_set_reg(vcpu, reg, value)
    }

    private func advancePC() {
        var pc: UInt64 = 0
        hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
        hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4)
    }
}

#endif
