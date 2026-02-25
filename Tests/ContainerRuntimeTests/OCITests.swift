import XCTest
@testable import ContainerRuntime
@testable import Shared

final class OCIImageReferenceTests: XCTestCase {
    func testParseSimpleName() {
        let ref = OCIImageReference(parsing: "alpine")!
        XCTAssertEqual(ref.registry, "registry-1.docker.io")
        XCTAssertEqual(ref.repository, "library/alpine")
        XCTAssertEqual(ref.tag, "latest")
    }

    func testParseNameWithTag() {
        let ref = OCIImageReference(parsing: "alpine:3.19")!
        XCTAssertEqual(ref.registry, "registry-1.docker.io")
        XCTAssertEqual(ref.repository, "library/alpine")
        XCTAssertEqual(ref.tag, "3.19")
    }

    func testParseNamespacedImage() {
        let ref = OCIImageReference(parsing: "pocketdev/ai-coder:latest")!
        XCTAssertEqual(ref.registry, "registry-1.docker.io")
        XCTAssertEqual(ref.repository, "pocketdev/ai-coder")
        XCTAssertEqual(ref.tag, "latest")
    }

    func testParseCustomRegistry() {
        let ref = OCIImageReference(parsing: "ghcr.io/apple/containerization/vminit:1.0.0")!
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "apple/containerization/vminit")
        XCTAssertEqual(ref.tag, "1.0.0")
    }

    func testParseDefault() {
        let ref = OCIImageReference(parsing: "ubuntu")!
        XCTAssertEqual(ref.description, "registry-1.docker.io/library/ubuntu:latest")
    }

    func testPullURL() {
        let ref = OCIImageReference(parsing: "alpine:3.19")!
        XCTAssertEqual(ref.pullURL, "https://registry-1.docker.io/v2/library/alpine")
    }
}

final class ContainerTemplateTests: XCTestCase {
    func testAllTemplatesHaveDefaults() {
        for template in ContainerTemplate.allCases {
            XCTAssertFalse(template.displayName.isEmpty)
            XCTAssertFalse(template.description.isEmpty)
            XCTAssertFalse(template.iconName.isEmpty)
            XCTAssertGreaterThanOrEqual(template.defaultMemoryMB, 256)
        }
    }

    func testAICoderTemplate() {
        let t = ContainerTemplate.aiCoder
        XCTAssertEqual(t.rawValue, "pocketdev/ai-coder")
        XCTAssertEqual(t.estimatedSizeMB, 150)
    }
}

final class ContainerConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = ContainerConfig(name: "test", imageName: "alpine")
        XCTAssertEqual(config.name, "test")
        XCTAssertEqual(config.imageName, "alpine")
        XCTAssertEqual(config.cpuCount, 2)
        XCTAssertEqual(config.memoryMB, 512)
        XCTAssertTrue(config.portMappings.isEmpty)
        XCTAssertTrue(config.environmentVariables.isEmpty)
    }
}

final class SubscriptionTierTests: XCTestCase {
    func testFreeTierLimits() {
        XCTAssertEqual(SubscriptionTier.free.maxContainers, 1)
        XCTAssertEqual(SubscriptionTier.free.maxStorageMB, 2048)
        XCTAssertNil(SubscriptionTier.free.monthlyPrice)
        XCTAssertNil(SubscriptionTier.free.storeProductID)
    }

    func testProTier() {
        XCTAssertEqual(SubscriptionTier.pro.maxContainers, .max)
        XCTAssertEqual(SubscriptionTier.pro.monthlyPrice, 12.99)
        XCTAssertNotNil(SubscriptionTier.pro.storeProductID)
    }
}
