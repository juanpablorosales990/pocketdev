import Foundation
#if canImport(Shared)
import Shared
#endif

#if canImport(Hypervisor)
import Hypervisor
#endif

/// Native Hypervisor.framework backend for M-series iPads.
/// Provides bare-metal ARM64 virtualization — the fastest possible path.
/// Requires TrollStore or equivalent entitlement injection on iPadOS.
public final class HypervisorBackend: VMBackend, @unchecked Sendable {
    public let name = "Hypervisor.framework (Native)"
    public let performanceTier = PerformanceTier.native
    public let requiresVMSetup = true

    public var isAvailable: Bool {
        Self.checkAvailability().available
    }

    public init() {}

    public static func checkAvailability() -> BackendAvailability {
        #if canImport(Hypervisor) && arch(arm64)
        let result = hv_vm_create(nil)
        if result == HV_SUCCESS {
            hv_vm_destroy()
            return BackendAvailability(
                available: true,
                requiresEntitlement: true,
                requiresSideloading: true
            )
        } else {
            let reason: String
            switch Int(result) {
            case HV_ERROR:
                reason = "Hypervisor error — may need entitlement (TrollStore)"
            case HV_BUSY:
                reason = "Hypervisor is busy"
            case HV_NO_RESOURCES:
                reason = "Insufficient resources"
            case HV_UNSUPPORTED:
                reason = "Hypervisor not supported on this device"
            default:
                reason = "Unknown error: \(result)"
            }
            return BackendAvailability(
                available: false,
                reason: reason,
                requiresEntitlement: true,
                requiresSideloading: true
            )
        }
        #else
        return BackendAvailability(
            available: false,
            reason: "Hypervisor.framework not available on this platform/architecture",
            requiresEntitlement: true,
            requiresSideloading: true
        )
        #endif
    }

    public func createVM(config: VMConfig) async throws -> VirtualMachine {
        guard isAvailable else {
            throw PocketDevError.hypervisorUnavailable
        }
        return try HypervisorVM(config: config)
    }
}

// MARK: - Hypervisor VM Implementation

final class HypervisorVM: VirtualMachine, @unchecked Sendable {
    let id: String
    private let config: VMConfig
    private var _state: ContainerState = .creating
    private let lock = NSLock()

    #if canImport(Hypervisor) && arch(arm64)
    private var vcpu: hv_vcpu_t = 0
    private var vcpuExit: UnsafeMutablePointer<hv_vcpu_exit_t>?
    private var vcpuThread: pthread_t?

    // Memory
    private var ramHost: UnsafeMutableRawPointer?
    private var ramSize: Int = 0

    // Devices
    private var uart: PL011?
    private var gic: GICv3?
    private var exitHandler: VCPUExitHandler?
    private var virtioBlk: VirtioBlk?
    private var virtioConsole: VirtioConsole?
    #endif

    // I/O
    private var outputContinuation: AsyncStream<ProcessOutput>.Continuation?
    private var outputStream: AsyncStream<ProcessOutput>?
    private var processCounter: Int = 0
    private var processes: [Int: HypervisorVMProcess] = [:]

    func getState() async -> ContainerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    init(config: VMConfig) throws {
        self.id = config.id
        self.config = config

        #if canImport(Hypervisor) && arch(arm64)
        // Create the VM
        let result = hv_vm_create(nil)
        guard result == HV_SUCCESS else {
            throw PocketDevError.vmCreationFailed("hv_vm_create failed: \(result)")
        }

        // Allocate and map guest RAM at GPA 0x4000_0000
        let memorySize = config.memoryMB * 1024 * 1024
        let memory = UnsafeMutableRawPointer.allocate(byteCount: memorySize, alignment: 4096)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: memorySize)
        self.ramHost = memory
        self.ramSize = memorySize

        let mapResult = hv_vm_map(
            memory,
            FDTBuilder.RAM_BASE,
            Int(memorySize),
            UInt64(HV_MEMORY_READ) | UInt64(HV_MEMORY_WRITE) | UInt64(HV_MEMORY_EXEC)
        )
        guard mapResult == HV_SUCCESS else {
            memory.deallocate()
            hv_vm_destroy()
            throw PocketDevError.vmCreationFailed("Memory mapping failed: \(mapResult)")
        }

        // Create vCPU
        var vcpuLocal: hv_vcpu_t = 0
        var vcpuExitLocal: UnsafeMutablePointer<hv_vcpu_exit_t>?
        let vcpuResult = hv_vcpu_create(&vcpuLocal, &vcpuExitLocal, nil)
        guard vcpuResult == HV_SUCCESS else {
            memory.deallocate()
            hv_vm_destroy()
            throw PocketDevError.vmCreationFailed("vCPU creation failed: \(vcpuResult)")
        }
        self.vcpu = vcpuLocal
        self.vcpuExit = vcpuExitLocal

        // Load kernel Image into RAM at offset 0 (GPA 0x4000_0000)
        try loadImage(config.kernelPath, into: memory, at: 0)

        // Load initrd if provided, at offset 0x800_0000 (GPA 0x4800_0000)
        if let initrdPath = config.initrdPath {
            try loadImage(initrdPath, into: memory, at: Int(FDTBuilder.INITRD_BASE - FDTBuilder.RAM_BASE))
        }

        PocketDevLogger.shared.info("HypervisorVM created: 1 vCPU, \(config.memoryMB)MB RAM at 0x\(String(FDTBuilder.RAM_BASE, radix: 16))")
        #else
        throw PocketDevError.hypervisorUnavailable
        #endif
    }

    #if canImport(Hypervisor) && arch(arm64)
    private func loadImage(_ path: String, into memory: UnsafeMutableRawPointer, at offset: Int) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        data.withUnsafeBytes { bytes in
            memory.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: data.count)
        }
        PocketDevLogger.shared.info("Loaded image: \(data.count) bytes at RAM offset 0x\(String(offset, radix: 16))")
    }
    #endif

    func boot() async throws {
        lock.lock()
        _state = .booting
        lock.unlock()

        #if canImport(Hypervisor) && arch(arm64)
        guard let memory = ramHost else {
            throw PocketDevError.vmBootFailed("No RAM allocated")
        }

        // Set up output stream
        var continuation: AsyncStream<ProcessOutput>.Continuation!
        let stream = AsyncStream<ProcessOutput>(bufferingPolicy: .bufferingNewest(100)) { continuation = $0 }
        self.outputContinuation = continuation
        self.outputStream = stream

        // Create devices
        let uartDevice = PL011()
        let gicDevice = GICv3()
        self.uart = uartDevice
        self.gic = gicDevice

        // Wire UART output → output stream (terminal display)
        uartDevice.onOutput = { [weak self] data in
            self?.outputContinuation?.yield(.stdout(data))
        }

        // Wire UART interrupt → GIC
        uartDevice.onIRQChange = { [weak self] asserted in
            if asserted {
                self?.gic?.setSPIPending(FDTBuilder.UART_IRQ + 32) // SPI offset
            } else {
                self?.gic?.clearSPIPending(FDTBuilder.UART_IRQ + 32)
            }
        }

        // Generate FDT
        var initrdStart: UInt64? = nil
        var initrdEnd: UInt64? = nil
        if config.initrdPath != nil {
            initrdStart = FDTBuilder.INITRD_BASE
            // Calculate actual initrd size
            if let path = config.initrdPath,
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                initrdEnd = FDTBuilder.INITRD_BASE + size
            }
        }

        let bootargs = config.kernelCommandLine.isEmpty
            ? "console=ttyAMA0 root=/dev/vda rw"
            : config.kernelCommandLine

        let fdt = FDTBuilder.build(
            cpuCount: 1,
            memoryMB: config.memoryMB,
            bootargs: bootargs,
            initrdStart: initrdStart,
            initrdEnd: initrdEnd
        )

        // Write FDT into RAM at offset for 0x4400_0000
        let fdtOffset = Int(FDTBuilder.FDT_BASE - FDTBuilder.RAM_BASE)
        fdt.withUnsafeBytes { bytes in
            memory.advanced(by: fdtOffset).copyMemory(from: bytes.baseAddress!, byteCount: fdt.count)
        }
        PocketDevLogger.shared.info("FDT: \(fdt.count) bytes at GPA 0x\(String(FDTBuilder.FDT_BASE, radix: 16))")

        // Create virtio-blk if rootfs exists
        if FileManager.default.fileExists(atPath: config.rootFilesystemPath) {
            do {
                let blk = try VirtioBlk(
                    imagePath: config.rootFilesystemPath,
                    ramHost: memory,
                    ramGuestBase: FDTBuilder.RAM_BASE
                )
                blk.onInterrupt = { [weak self] in
                    self?.gic?.setSPIPending(FDTBuilder.VIRTIO_BLK_IRQ + 32)
                }
                self.virtioBlk = blk
            } catch {
                PocketDevLogger.shared.warning("virtio-blk not available: \(error)")
            }
        }

        // Create virtio-console
        let console = VirtioConsole(ramHost: memory, ramGuestBase: FDTBuilder.RAM_BASE)
        console.onOutput = { [weak self] data in
            self?.outputContinuation?.yield(.stdout(data))
        }
        console.onInterrupt = { [weak self] in
            self?.gic?.setSPIPending(FDTBuilder.VIRTIO_CONSOLE_IRQ + 32)
        }
        self.virtioConsole = console

        // Create exit handler
        guard let vcpuExitPtr = vcpuExit else {
            throw PocketDevError.vmBootFailed("vCPU exit pointer is nil")
        }

        let handler = VCPUExitHandler(
            vcpu: vcpu,
            vcpuExit: vcpuExitPtr,
            uart: uartDevice,
            gic: gicDevice,
            ramHost: memory,
            ramGuestBase: FDTBuilder.RAM_BASE
        )

        // Register virtio devices
        if let blk = virtioBlk {
            handler.registerVirtioDevice(blk, at: FDTBuilder.VIRTIO_BASE)
        }
        handler.registerVirtioDevice(console, at: FDTBuilder.VIRTIO_BASE + FDTBuilder.VIRTIO_SLOT_SIZE)

        handler.onShutdown = { [weak self] in
            Task { @MainActor in
                self?.lock.lock()
                self?._state = .stopped
                self?.lock.unlock()
                self?.outputContinuation?.yield(.exit(0))
                self?.outputContinuation?.finish()
            }
        }

        self.exitHandler = handler

        // Set boot registers
        // PC = kernel entry point (GPA 0x4000_0000)
        hv_vcpu_set_reg(vcpu, HV_REG_PC, FDTBuilder.RAM_BASE)

        // X0 = FDT address
        hv_vcpu_set_reg(vcpu, HV_REG_X0, FDTBuilder.FDT_BASE)

        // CPSR = EL1h, all interrupts masked, AArch64
        hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3C5)

        // Do NOT set SCTLR_EL1 — kernel starts with MMU off and configures it itself

        PocketDevLogger.shared.info("Starting vCPU: PC=0x\(String(FDTBuilder.RAM_BASE, radix: 16)) X0=0x\(String(FDTBuilder.FDT_BASE, radix: 16)) CPSR=0x3C5")

        // Start vCPU on a dedicated pthread (Hypervisor requires same OS thread)
        let handlerRef = Unmanaged.passRetained(handler)
        var thread: pthread_t?
        let pthreadResult = pthread_create(&thread, nil, { context in
            let handler = Unmanaged<VCPUExitHandler>.fromOpaque(context).takeRetainedValue()
            let vcpu = handler.vcpu

            while true {
                let runResult = hv_vcpu_run(vcpu)
                guard runResult == HV_SUCCESS else {
                    break
                }
                if !handler.handleExit() {
                    break
                }
            }

            return nil
        }, handlerRef.toOpaque())

        guard pthreadResult == 0 else {
            handlerRef.release()
            throw PocketDevError.vmBootFailed("pthread_create failed: \(pthreadResult)")
        }
        self.vcpuThread = thread

        #endif

        lock.lock()
        _state = .running
        lock.unlock()

        PocketDevLogger.shared.info("VM \(id) booted — vCPU running on dedicated thread")
    }

    func suspend() async throws {
        lock.lock()
        _state = .suspended
        lock.unlock()
        #if canImport(Hypervisor) && arch(arm64)
        exitHandler?.requestStop()
        #endif
        PocketDevLogger.shared.info("VM \(id) suspended")
    }

    func resume() async throws {
        lock.lock()
        _state = .running
        lock.unlock()
        PocketDevLogger.shared.info("VM \(id) resumed")
    }

    func stop() async throws {
        #if canImport(Hypervisor) && arch(arm64)
        exitHandler?.requestStop()
        // Kick the vCPU out of its run loop
        hv_vcpus_exit(&vcpu, 1)
        #endif

        lock.lock()
        _state = .stopped
        lock.unlock()

        outputContinuation?.yield(.exit(0))
        outputContinuation?.finish()

        PocketDevLogger.shared.info("VM \(id) stopped")
    }

    func kill() async throws {
        #if canImport(Hypervisor) && arch(arm64)
        exitHandler?.requestStop()
        hv_vcpus_exit(&vcpu, 1)

        // Wait for vCPU thread to finish
        if let thread = vcpuThread {
            pthread_join(thread, nil)
            vcpuThread = nil
        }

        hv_vcpu_destroy(vcpu)
        hv_vm_destroy()
        #endif

        lock.lock()
        _state = .stopped
        lock.unlock()

        outputContinuation?.yield(.exit(0))
        outputContinuation?.finish()

        PocketDevLogger.shared.info("VM \(id) killed")
    }

    deinit {
        #if canImport(Hypervisor) && arch(arm64)
        exitHandler?.requestStop()
        if let thread = vcpuThread {
            pthread_join(thread, nil)
        }
        hv_vcpu_destroy(vcpu)
        hv_vm_destroy()
        ramHost?.deallocate()
        #endif
        outputContinuation?.finish()
    }

    func spawnProcess(_ spec: ProcessSpec) async throws -> VMProcess {
        guard await getState() == .running else {
            throw PocketDevError.vmNotRunning
        }

        lock.lock()
        processCounter += 1
        let pid = processCounter
        lock.unlock()

        // Create a process that communicates via virtio-console
        #if canImport(Hypervisor) && arch(arm64)
        let console = virtioConsole
        let uartDev = uart
        #else
        let console: VirtioConsole? = nil
        let uartDev: PL011? = nil
        #endif

        let process = HypervisorVMProcess(
            pid: pid,
            spec: spec,
            vmID: id,
            console: console,
            uart: uartDev,
            outputStream: outputStream
        )

        lock.lock()
        processes[pid] = process
        lock.unlock()

        return process
    }

    func info() async -> VMInfo {
        VMInfo(
            id: id,
            state: await getState(),
            cpuCount: 1,
            memoryMB: config.memoryMB,
            uptimeSeconds: 0
        )
    }

    func resizeTerminal(_ size: TerminalSize) async throws {
        for (_, process) in processes {
            try await process.resize(size)
        }
    }
}

// MARK: - Hypervisor VM Process

final class HypervisorVMProcess: VMProcess, @unchecked Sendable {
    let pid: Int
    private let spec: ProcessSpec
    private let vmID: String
    private weak var console: VirtioConsole?
    private weak var uart: PL011?
    let output: AsyncStream<ProcessOutput>

    init(
        pid: Int,
        spec: ProcessSpec,
        vmID: String,
        console: VirtioConsole?,
        uart: PL011?,
        outputStream: AsyncStream<ProcessOutput>?
    ) {
        self.pid = pid
        self.spec = spec
        self.vmID = vmID
        self.console = console
        self.uart = uart
        // Share the VM's output stream so terminal output flows through
        self.output = outputStream ?? AsyncStream { $0.finish() }
    }

    func write(_ data: Data) async throws {
        // Send input to the guest via virtio-console (preferred) or UART
        if let console = console {
            console.enqueueInput(data)
        } else {
            uart?.enqueueInput(data)
        }
    }

    func signal(_ signal: Int32) async throws {
        // Would send signal to process via init protocol
    }

    func waitForExit() async throws -> Int32 {
        for await event in output {
            if case .exit(let code) = event {
                return code
            }
        }
        return 0
    }

    func resize(_ size: TerminalSize) async throws {
        // Would send TIOCSWINSZ to process via init protocol
    }
}
