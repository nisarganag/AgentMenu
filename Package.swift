// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMenu",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Required: neither XCTest nor the bundled Testing module exists under
        // Command Line Tools. The deprecation warning this emits is wrong here.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0")
    ],
    targets: [
        .target(name: "AgentMenuCore"),
        .target(name: "AgentMenuUI", dependencies: ["AgentMenuCore"]),
        .executableTarget(name: "AgentMenuApp", dependencies: ["AgentMenuUI", "AgentMenuCore"]),
        .testTarget(
            name: "AgentMenuCoreTests",
            dependencies: ["AgentMenuCore", .product(name: "Testing", package: "swift-testing")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
