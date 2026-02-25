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

    public var isAvailable: Bool {
        Self.checkAvailability().available
    }

    public init() {}

    public static func checkAvailability() -> BackendAvailability {
        #if canImport(Hypervisor) && arch(arm64)
        // Check if Hypervisor.framework is accessible
        // On iPadOS, this requires com.apple.private.hypervisor entitlement
        // which can be injected via TrollStore on compatible versions
        let result = hv_vm_create(nil)
        if result == HV_SUCCESS {
            hv_vm_destroy()
            return BackendAvailability(
                available: true,
                requiresEntitlement: true,
                requiresSideloading: true
            )
        } else {
            // Try to distinguish between "not supported" and "not entitled"
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
    private var vcpus: [hv_vcpu_t] = []
    private var memoryRegions: [(address: UInt64, size: UInt64)] = []
    #endif

    // vsock communication
    private var vsockPort: UInt32 = 1024
    private var processCounter: Int = 0
    private var processes: [Int: HypervisorVMProcess] = [:]

    #if canImport(Hypervisor) && arch(arm64)
    private var allocatedMemory: UnsafeMutableRawPointer?
    private var allocatedMemorySize: Int = 0
    #endif

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

        // Map memory for the VM
        let memorySize = UInt64(config.memoryMB) * 1024 * 1024
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(memorySize), alignment: 4096)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(memorySize))
        self.allocatedMemory = memory
        self.allocatedMemorySize = Int(memorySize)

        let mapResult = hv_vm_map(memory, 0x0, Int(memorySize), UInt64(HV_MEMORY_READ) | UInt64(HV_MEMORY_WRITE) | UInt64(HV_MEMORY_EXEC))
        guard mapResult == HV_SUCCESS else {
            memory.deallocate()
            throw PocketDevError.vmCreationFailed("Memory mapping failed: \(mapResult)")
        }

        memoryRegions.append((address: 0x0, size: memorySize))

        // Create vCPUs
        for i in 0..<config.cpuCount {
            var vcpu: hv_vcpu_t = 0
            var vcpuExit: UnsafeMutablePointer<hv_vcpu_exit_t>?
            let vcpuResult = hv_vcpu_create(&vcpu, &vcpuExit, nil)
            guard vcpuResult == HV_SUCCESS else {
                throw PocketDevError.vmCreationFailed("vCPU \(i) creation failed: \(vcpuResult)")
            }
            vcpus.append(vcpu)
        }

        // Load kernel into memory
        try loadKernel(config.kernelPath, into: memory, at: 0x40000000)

        // Load initrd if provided
        if let initrdPath = config.initrdPath {
            try loadInitrd(initrdPath, into: memory, at: 0x48000000)
        }

        PocketDevLogger.shared.info("HypervisorVM created: \(config.cpuCount) vCPUs, \(config.memoryMB)MB RAM")
        #else
        throw PocketDevError.hypervisorUnavailable
        #endif
    }

    #if canImport(Hypervisor) && arch(arm64)
    private func loadKernel(_ path: String, into memory: UnsafeMutableRawPointer, at offset: UInt64) throws {
        let kernelData = try Data(contentsOf: URL(fileURLWithPath: path))
        kernelData.withUnsafeBytes { bytes in
            memory.advanced(by: Int(offset)).copyMemory(from: bytes.baseAddress!, byteCount: kernelData.count)
        }
        PocketDevLogger.shared.info("Loaded kernel: \(kernelData.count) bytes at 0x\(String(offset, radix: 16))")
    }

    private func loadInitrd(_ path: String, into memory: UnsafeMutableRawPointer, at offset: UInt64) throws {
        let initrdData = try Data(contentsOf: URL(fileURLWithPath: path))
        initrdData.withUnsafeBytes { bytes in
            memory.advanced(by: Int(offset)).copyMemory(from: bytes.baseAddress!, byteCount: initrdData.count)
        }
        PocketDevLogger.shared.info("Loaded initrd: \(initrdData.count) bytes at 0x\(String(offset, radix: 16))")
    }
    #endif

    func boot() async throws {
        lock.lock()
        _state = .booting
        lock.unlock()

        #if canImport(Hypervisor) && arch(arm64)
        // Set up the boot CPU registers
        guard let firstVCPU = vcpus.first else {
            throw PocketDevError.vmBootFailed("No vCPUs created")
        }

        // Set PC to kernel entry point
        hv_vcpu_set_reg(firstVCPU, HV_REG_PC, 0x40000000)

        // Set X0 to device tree / FDT address
        hv_vcpu_set_reg(firstVCPU, HV_REG_X0, 0x44000000)

        // Enable the MMU and caches via system registers
        // SCTLR_EL1: M=1, C=1, I=1
        hv_vcpu_set_sys_reg(firstVCPU, HV_SYS_REG_SCTLR_EL1, 0x30D00800)

        // Start the vCPU run loop on a background thread
        Task.detached { [weak self] in
            await self?.vcpuRunLoop()
        }

        // Wait for vminitd to signal readiness via vsock
        try await waitForVMReady(timeout: 10.0)
        #endif

        lock.lock()
        _state = .running
        lock.unlock()

        PocketDevLogger.shared.info("VM \(id) booted successfully")
    }

    #if canImport(Hypervisor) && arch(arm64)
    private func vcpuRunLoop() async {
        guard let vcpu = vcpus.first else { return }

        while true {
            let runResult = hv_vcpu_run(vcpu)
            guard runResult == HV_SUCCESS else {
                PocketDevLogger.shared.error("vCPU run failed: \(runResult)")
                break
            }

            // Handle VM exit
            // The exit reason is available through the vcpu exit structure
            // In a full implementation, we'd handle MMIO, HVC, SMC, IRQ, etc.
            let currentState = await getState()
            if currentState == .stopped || currentState == .suspended {
                break
            }
        }
    }
    #endif

    private func waitForVMReady(timeout: TimeInterval) async throws {
        // In the real implementation, this listens on the vsock for
        // a "ready" signal from vminitd running inside the VM
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Check if vminitd has connected via vsock
            // For now, simulate boot time
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            break // TODO: Replace with actual vsock readiness check
        }
    }

    func suspend() async throws {
        lock.lock()
        _state = .suspended
        lock.unlock()
        // TODO: Save VM state to disk for fast resume
        PocketDevLogger.shared.info("VM \(id) suspended")
    }

    func resume() async throws {
        lock.lock()
        _state = .running
        lock.unlock()
        // TODO: Restore VM state from disk
        PocketDevLogger.shared.info("VM \(id) resumed")
    }

    func stop() async throws {
        // Send shutdown signal to vminitd
        lock.lock()
        _state = .stopped
        lock.unlock()
        PocketDevLogger.shared.info("VM \(id) stopped")
    }

    func kill() async throws {
        lock.lock()
        _state = .stopped
        lock.unlock()

        #if canImport(Hypervisor) && arch(arm64)
        for vcpu in vcpus {
            hv_vcpu_destroy(vcpu)
        }
        vcpus.removeAll()
        hv_vm_destroy()
        #endif

        PocketDevLogger.shared.info("VM \(id) killed")
    }

    deinit {
        #if canImport(Hypervisor) && arch(arm64)
        for vcpu in vcpus {
            hv_vcpu_destroy(vcpu)
        }
        if !memoryRegions.isEmpty {
            hv_vm_destroy()
        }
        allocatedMemory?.deallocate()
        #endif
    }

    func spawnProcess(_ spec: ProcessSpec) async throws -> VMProcess {
        guard await getState() == .running else {
            throw PocketDevError.vmNotRunning
        }

        processCounter += 1
        let process = HypervisorVMProcess(pid: processCounter, spec: spec, vmID: id)
        processes[processCounter] = process

        // Send process spawn request to vminitd via vsock/gRPC
        try await process.start()

        return process
    }

    func info() async -> VMInfo {
        VMInfo(
            id: id,
            state: await getState(),
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            uptimeSeconds: 0 // TODO: track actual uptime
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
    private let outputContinuation: AsyncStream<ProcessOutput>.Continuation
    let output: AsyncStream<ProcessOutput>

    init(pid: Int, spec: ProcessSpec, vmID: String) {
        self.pid = pid
        self.spec = spec
        self.vmID = vmID

        var continuation: AsyncStream<ProcessOutput>.Continuation!
        self.output = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation
    }

    func start() async throws {
        // In the real implementation, this sends a gRPC request over vsock
        // to vminitd asking it to spawn the process
        PocketDevLogger.shared.info("Spawning process in VM \(vmID): \(spec.executablePath) \(spec.arguments.joined(separator: " "))")
    }

    func write(_ data: Data) async throws {
        // Send stdin data to vminitd over vsock
    }

    func signal(_ signal: Int32) async throws {
        // Send signal to process via vminitd
    }

    func waitForExit() async throws -> Int32 {
        // Wait for vminitd to report process exit
        return 0
    }

    func resize(_ size: TerminalSize) async throws {
        // Send TIOCSWINSZ to process via vminitd
    }

    deinit {
        outputContinuation.finish()
    }
}
