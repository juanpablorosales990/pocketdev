import XCTest
@testable import PlatformAbstraction
@testable import Shared

final class BackendSelectorTests: XCTestCase {
    func testDetectReturnsBackend() {
        let result = BackendSelector.detect()
        XCTAssertFalse(result.reason.isEmpty)
        XCTAssertFalse(result.allBackends.isEmpty)
    }

    func testDeviceCapabilities() {
        let caps = BackendSelector.deviceCapabilities()
        XCTAssertGreaterThan(caps.totalMemoryMB, 0)
        XCTAssertGreaterThan(caps.processorCount, 0)
        XCTAssertGreaterThan(caps.recommendedCPUs, 0)
        XCTAssertGreaterThan(caps.recommendedMemoryMB, 0)
        XCTAssertTrue(caps.isAppleSilicon)
    }

    func testQEMUAlwaysAvailableOnARM64() {
        let availability = QEMUTCGBackend.checkAvailability()
        #if arch(arm64)
        XCTAssertTrue(availability.available)
        XCTAssertFalse(availability.requiresEntitlement)
        XCTAssertFalse(availability.requiresSideloading)
        #endif
    }

    func testHypervisorRequiresEntitlement() {
        let availability = HypervisorBackend.checkAvailability()
        XCTAssertTrue(availability.requiresEntitlement)
        XCTAssertTrue(availability.requiresSideloading)
    }

    func testRemoteAlwaysAvailable() {
        let availability = RemoteVMBackend.checkAvailability()
        XCTAssertTrue(availability.available)
    }

    func testPerformanceTierOrdering() {
        XCTAssertGreaterThan(PerformanceTier.native, .nearNative)
        XCTAssertGreaterThan(PerformanceTier.nearNative, .emulated)
        XCTAssertGreaterThan(PerformanceTier.emulated, .remote)
    }
}
