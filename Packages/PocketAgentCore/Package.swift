// swift-tools-version: 6.0

import PackageDescription

// Foundation-only on purpose: no AgentRunKit / Apple-only frameworks,
// so domain logic stays testable outside Xcode.
let package = Package(
    name: "PocketAgentCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PocketAgentCore", targets: ["PocketAgentCore"])
    ],
    targets: [
        .target(name: "PocketAgentCore"),
        .testTarget(name: "PocketAgentCoreTests", dependencies: ["PocketAgentCore"])
    ],
    swiftLanguageModes: [.v6]
)
