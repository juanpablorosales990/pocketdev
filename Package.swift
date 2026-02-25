// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PocketDev",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PlatformAbstraction", targets: ["PlatformAbstraction"]),
        .library(name: "ContainerRuntime", targets: ["ContainerRuntime"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        .library(name: "PocketDevFileManager", targets: ["PocketDevFileManager"]),
        .library(name: "NetworkManager", targets: ["NetworkManager"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // MARK: - Shared
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Shared"
        ),

        // MARK: - C PTY Support (pseudo-terminal for local shell)
        .target(
            name: "CPTYSupport",
            path: "Sources/CPTYSupport",
            publicHeadersPath: "include"
        ),

        // MARK: - Platform Abstraction Layer
        .target(
            name: "PlatformAbstraction",
            dependencies: [
                "Shared",
                "CPTYSupport",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PlatformAbstraction"
        ),

        // MARK: - Container Runtime
        .target(
            name: "ContainerRuntime",
            dependencies: [
                "PlatformAbstraction",
                "NetworkManager",
                "Shared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ContainerRuntime"
        ),

        // MARK: - Terminal UI
        .target(
            name: "TerminalUI",
            dependencies: [
                "Shared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/TerminalUI"
        ),

        // MARK: - File Manager
        .target(
            name: "PocketDevFileManager",
            dependencies: [
                "Shared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/FileManager"
        ),

        // MARK: - Network Manager
        .target(
            name: "NetworkManager",
            dependencies: [
                "Shared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/NetworkManager"
        ),

        // MARK: - App
        .executableTarget(
            name: "PocketDevApp",
            dependencies: [
                "Shared",
                "PlatformAbstraction",
                "ContainerRuntime",
                "TerminalUI",
                "PocketDevFileManager",
            ],
            path: "Sources/PocketDevApp"
        ),

        // MARK: - Tests
        .testTarget(
            name: "PlatformAbstractionTests",
            dependencies: ["PlatformAbstraction"],
            path: "Tests/PlatformAbstractionTests"
        ),
        .testTarget(
            name: "ContainerRuntimeTests",
            dependencies: ["ContainerRuntime"],
            path: "Tests/ContainerRuntimeTests"
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI"],
            path: "Tests/TerminalUITests"
        ),
    ]
)
