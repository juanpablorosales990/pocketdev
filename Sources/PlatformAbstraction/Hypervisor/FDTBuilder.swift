import Foundation

// MARK: - Flattened Device Tree Builder

/// Generates a binary Flattened Device Tree (FDT) blob that describes the virtual
/// hardware layout to the Linux kernel. The FDT format is defined by the devicetree
/// specification (https://www.devicetree.org/specifications/).
///
/// Memory layout:
///   0x0800_0000 — GICv3 Distributor
///   0x080A_0000 — GICv3 Redistributor
///   0x0900_0000 — PL011 UART
///   0x0A00_0000 — virtio-mmio slot 0 (blk)
///   0x0A00_0200 — virtio-mmio slot 1 (console)
///   0x4000_0000 — RAM start (kernel Image)
///   0x4400_0000 — FDT
///   0x4800_0000 — initrd (optional)
struct FDTBuilder {

    // FDT constants
    private static let FDT_MAGIC: UInt32         = 0xD00DFEED
    private static let FDT_BEGIN_NODE: UInt32    = 0x00000001
    private static let FDT_END_NODE: UInt32      = 0x00000002
    private static let FDT_PROP: UInt32          = 0x00000003
    private static let FDT_END: UInt32           = 0x00000009

    // GIC interrupt type constants
    private static let GIC_SPI: UInt32  = 0  // Shared Peripheral Interrupt
    private static let GIC_PPI: UInt32  = 1  // Private Peripheral Interrupt
    private static let IRQ_TYPE_LEVEL_HIGH: UInt32 = 4

    // Device addresses
    static let RAM_BASE:  UInt64 = 0x4000_0000
    static let FDT_BASE:  UInt64 = 0x4400_0000
    static let INITRD_BASE: UInt64 = 0x4800_0000

    static let GICD_BASE: UInt64 = 0x0800_0000
    static let GICD_SIZE: UInt64 = 0x0001_0000  // 64KB
    static let GICR_BASE: UInt64 = 0x080A_0000
    static let GICR_SIZE: UInt64 = 0x0002_0000  // 128KB

    static let UART_BASE: UInt64 = 0x0900_0000
    static let UART_SIZE: UInt64 = 0x0000_1000  // 4KB
    static let UART_IRQ:  UInt32 = 1  // SPI 1

    static let VIRTIO_BASE: UInt64 = 0x0A00_0000
    static let VIRTIO_SLOT_SIZE: UInt64 = 0x200
    static let VIRTIO_BLK_IRQ: UInt32 = 16     // SPI 16
    static let VIRTIO_CONSOLE_IRQ: UInt32 = 17 // SPI 17

    // Build state
    private var structBlock = Data()
    private var stringsBlock = Data()
    private var stringOffsets: [String: UInt32] = [:]

    /// Build a complete FDT for the given VM configuration.
    static func build(
        cpuCount: Int,
        memoryMB: Int,
        bootargs: String,
        initrdStart: UInt64? = nil,
        initrdEnd: UInt64? = nil
    ) -> Data {
        var builder = FDTBuilder()
        let memorySize = UInt64(memoryMB) * 1024 * 1024

        // Root node
        builder.beginNode("")
        builder.addProperty("compatible", stringValue: "linux,dummy-virt")
        builder.addProperty("#address-cells", u32Value: 2)
        builder.addProperty("#size-cells", u32Value: 2)
        builder.addProperty("interrupt-parent", u32Value: 0x8001) // phandle of GIC

        // /chosen
        builder.beginNode("chosen")
        builder.addProperty("bootargs", stringValue: bootargs)
        builder.addProperty("stdout-path", stringValue: "/pl011@9000000")
        if let start = initrdStart, let end = initrdEnd {
            builder.addProperty("linux,initrd-start", u64Value: start)
            builder.addProperty("linux,initrd-end", u64Value: end)
        }
        builder.endNode()

        // /memory@40000000
        builder.beginNode("memory@40000000")
        builder.addProperty("device_type", stringValue: "memory")
        builder.addProperty("reg", u64PairValue: (RAM_BASE, memorySize))
        builder.endNode()

        // /cpus
        builder.beginNode("cpus")
        builder.addProperty("#address-cells", u32Value: 1)
        builder.addProperty("#size-cells", u32Value: 0)
        for i in 0..<cpuCount {
            builder.beginNode("cpu@\(i)")
            builder.addProperty("device_type", stringValue: "cpu")
            builder.addProperty("compatible", stringValue: "arm,arm-v8")
            builder.addProperty("reg", u32Value: UInt32(i))
            builder.addProperty("enable-method", stringValue: "psci")
            builder.endNode()
        }
        builder.endNode()

        // /psci
        builder.beginNode("psci")
        builder.addProperty("compatible", stringValue: "arm,psci-1.0")
        builder.addProperty("method", stringValue: "hvc")
        builder.endNode()

        // /timer
        builder.beginNode("timer")
        builder.addProperty("compatible", stringValue: "arm,armv8-timer")
        builder.addProperty("always-on", emptyValue: true)
        // interrupts: secure phys, non-secure phys, virt, hyp
        // Each is: <type irq flags>
        var timerInts = Data()
        let timerEntries: [(UInt32, UInt32, UInt32)] = [
            (GIC_PPI, 13, IRQ_TYPE_LEVEL_HIGH), // secure phys
            (GIC_PPI, 14, IRQ_TYPE_LEVEL_HIGH), // non-secure phys
            (GIC_PPI, 11, IRQ_TYPE_LEVEL_HIGH), // virtual
            (GIC_PPI, 10, IRQ_TYPE_LEVEL_HIGH), // hypervisor
        ]
        for (type, irq, flags) in timerEntries {
            timerInts.appendBigEndian(type)
            timerInts.appendBigEndian(irq)
            timerInts.appendBigEndian(flags)
        }
        builder.addProperty("interrupts", rawValue: timerInts)
        builder.endNode()

        // /intc@8000000 — GICv3
        builder.beginNode("intc@8000000")
        builder.addProperty("compatible", stringValue: "arm,gic-v3")
        builder.addProperty("#interrupt-cells", u32Value: 3)
        builder.addProperty("interrupt-controller", emptyValue: true)
        builder.addProperty("phandle", u32Value: 0x8001)
        // reg = <GICD_BASE GICD_SIZE GICR_BASE GICR_SIZE>
        var gicReg = Data()
        gicReg.appendBigEndian(UInt64(0)) // high 32 of GICD addr
        gicReg.appendBigEndian(GICD_BASE)
        gicReg.appendBigEndian(UInt64(0))
        gicReg.appendBigEndian(GICD_SIZE)
        gicReg.appendBigEndian(UInt64(0))
        gicReg.appendBigEndian(GICR_BASE)
        gicReg.appendBigEndian(UInt64(0))
        gicReg.appendBigEndian(GICR_SIZE)
        builder.addProperty("reg", rawValue: gicReg)
        builder.endNode()

        // /pl011@9000000 — UART
        builder.beginNode("pl011@9000000")
        builder.addProperty("compatible", stringValue: "arm,pl011\0arm,primecell")
        builder.addProperty("reg", u64PairValue: (UART_BASE, UART_SIZE))
        var uartInts = Data()
        uartInts.appendBigEndian(GIC_SPI)
        uartInts.appendBigEndian(UART_IRQ)
        uartInts.appendBigEndian(IRQ_TYPE_LEVEL_HIGH)
        builder.addProperty("interrupts", rawValue: uartInts)
        // PL011 needs clock references; use a fixed clock
        builder.addProperty("clock-names", stringValue: "uartclk\0apb_pclk")
        builder.addProperty("clocks", u32PairValue: (0x8002, 0x8002)) // phandle of fixed clock
        builder.endNode()

        // /apb-pclk — fixed clock for PL011
        builder.beginNode("apb-pclk")
        builder.addProperty("compatible", stringValue: "fixed-clock")
        builder.addProperty("#clock-cells", u32Value: 0)
        builder.addProperty("clock-frequency", u32Value: 24_000_000) // 24MHz
        builder.addProperty("phandle", u32Value: 0x8002)
        builder.endNode()

        // /virtio_mmio@a000000 — virtio-blk
        builder.beginNode("virtio_mmio@a000000")
        builder.addProperty("compatible", stringValue: "virtio,mmio")
        builder.addProperty("reg", u64PairValue: (VIRTIO_BASE, VIRTIO_SLOT_SIZE))
        var blkInts = Data()
        blkInts.appendBigEndian(GIC_SPI)
        blkInts.appendBigEndian(VIRTIO_BLK_IRQ)
        blkInts.appendBigEndian(IRQ_TYPE_LEVEL_HIGH)
        builder.addProperty("interrupts", rawValue: blkInts)
        builder.endNode()

        // /virtio_mmio@a000200 — virtio-console
        builder.beginNode("virtio_mmio@a000200")
        builder.addProperty("compatible", stringValue: "virtio,mmio")
        let consoleBase = VIRTIO_BASE + VIRTIO_SLOT_SIZE
        builder.addProperty("reg", u64PairValue: (consoleBase, VIRTIO_SLOT_SIZE))
        var conInts = Data()
        conInts.appendBigEndian(GIC_SPI)
        conInts.appendBigEndian(VIRTIO_CONSOLE_IRQ)
        conInts.appendBigEndian(IRQ_TYPE_LEVEL_HIGH)
        builder.addProperty("interrupts", rawValue: conInts)
        builder.endNode()

        // End root node
        builder.endNode()

        return builder.finalize()
    }

    // MARK: - Node construction

    private mutating func beginNode(_ name: String) {
        structBlock.appendBigEndian(Self.FDT_BEGIN_NODE)
        appendNullTerminatedString(name, to: &structBlock)
        alignTo4(&structBlock)
    }

    private mutating func endNode() {
        structBlock.appendBigEndian(Self.FDT_END_NODE)
    }

    private mutating func addProperty(_ name: String, stringValue: String) {
        let strData = Data(stringValue.utf8) + Data([0])
        addPropertyRaw(name, value: strData)
    }

    private mutating func addProperty(_ name: String, u32Value: UInt32) {
        var data = Data()
        data.appendBigEndian(u32Value)
        addPropertyRaw(name, value: data)
    }

    private mutating func addProperty(_ name: String, u64Value: UInt64) {
        var data = Data()
        data.appendBigEndian(u64Value)
        addPropertyRaw(name, value: data)
    }

    private mutating func addProperty(_ name: String, u64PairValue: (UInt64, UInt64)) {
        var data = Data()
        // For #address-cells=2, #size-cells=2: each value is two u32s
        data.appendBigEndian(UInt32(u64PairValue.0 >> 32))
        data.appendBigEndian(UInt32(u64PairValue.0 & 0xFFFFFFFF))
        data.appendBigEndian(UInt32(u64PairValue.1 >> 32))
        data.appendBigEndian(UInt32(u64PairValue.1 & 0xFFFFFFFF))
        addPropertyRaw(name, value: data)
    }

    private mutating func addProperty(_ name: String, u32PairValue: (UInt32, UInt32)) {
        var data = Data()
        data.appendBigEndian(u32PairValue.0)
        data.appendBigEndian(u32PairValue.1)
        addPropertyRaw(name, value: data)
    }

    private mutating func addProperty(_ name: String, rawValue: Data) {
        addPropertyRaw(name, value: rawValue)
    }

    private mutating func addProperty(_ name: String, emptyValue: Bool) {
        addPropertyRaw(name, value: Data())
    }

    private mutating func addPropertyRaw(_ name: String, value: Data) {
        let nameOffset = internString(name)
        structBlock.appendBigEndian(Self.FDT_PROP)
        structBlock.appendBigEndian(UInt32(value.count))
        structBlock.appendBigEndian(nameOffset)
        structBlock.append(value)
        alignTo4(&structBlock)
    }

    // MARK: - String interning

    private mutating func internString(_ s: String) -> UInt32 {
        if let offset = stringOffsets[s] {
            return offset
        }
        let offset = UInt32(stringsBlock.count)
        stringOffsets[s] = offset
        appendNullTerminatedString(s, to: &stringsBlock)
        return offset
    }

    // MARK: - Finalization

    private mutating func finalize() -> Data {
        // Append FDT_END token
        structBlock.appendBigEndian(Self.FDT_END)

        // Build the header
        let headerSize: UInt32 = 40 // 10 x UInt32 fields
        // Memory reservation block is empty (8 bytes of zeros to terminate)
        let memRsvSize: UInt32 = 16 // one entry of all-zeros to terminate
        let structOffset = headerSize + memRsvSize
        let stringsOffset = structOffset + UInt32(structBlock.count)
        let totalSize = stringsOffset + UInt32(stringsBlock.count)

        var header = Data()
        header.appendBigEndian(Self.FDT_MAGIC)
        header.appendBigEndian(totalSize)
        header.appendBigEndian(structOffset)
        header.appendBigEndian(stringsOffset)
        header.appendBigEndian(headerSize)  // off_mem_rsvmap
        header.appendBigEndian(UInt32(17))  // version 17
        header.appendBigEndian(UInt32(16))  // last_comp_version
        header.appendBigEndian(UInt32(0))   // boot_cpuid_phys
        header.appendBigEndian(UInt32(stringsBlock.count)) // size_dt_strings
        header.appendBigEndian(UInt32(structBlock.count))  // size_dt_struct

        // Memory reservation block: one empty entry (16 bytes of 0)
        let memRsv = Data(count: 16)

        var result = Data()
        result.append(header)
        result.append(memRsv)
        result.append(structBlock)
        result.append(stringsBlock)
        return result
    }

    // MARK: - Helpers

    private func appendNullTerminatedString(_ s: String, to data: inout Data) {
        data.append(contentsOf: s.utf8)
        data.append(0)
    }

    private func alignTo4(_ data: inout Data) {
        let remainder = data.count % 4
        if remainder != 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
    }
}

// MARK: - Data extension for big-endian writes

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var be = value.bigEndian
        append(Data(bytes: &be, count: 4))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var be = value.bigEndian
        append(Data(bytes: &be, count: 8))
    }
}
