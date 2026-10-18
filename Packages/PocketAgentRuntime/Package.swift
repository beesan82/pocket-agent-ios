// swift-tools-version: 6.1

import PackageDescription

// The only place (besides app Adapters) allowed to import AgentRunKit.
let package = Package(
    name: "PocketAgentRuntime",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PocketAgentRuntime", targets: ["PocketAgentRuntime"])
    ],
    dependencies: [
        .package(url: "https://github.com/Tom-Ryder/AgentRunKit.git", exact: "6.1.0"),
        .package(path: "../PocketAgentCore")
    ],
    targets: [
        .target(
            name: "PocketAgentRuntime",
            dependencies: [
                .product(name: "AgentRunKit", package: "AgentRunKit"),
                .product(name: "PocketAgentCore", package: "PocketAgentCore")
            ]
        ),
        .testTarget(
            name: "PocketAgentRuntimeTests",
            dependencies: [
                "PocketAgentRuntime",
                .product(name: "AgentRunKit", package: "AgentRunKit"),
                .product(name: "PocketAgentCore", package: "PocketAgentCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
