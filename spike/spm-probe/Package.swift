// swift-tools-version: 6.1
// THROWAWAY probe: can AgentRunKit 6.1.0 (declares mlx-swift-lm .upToNextMinor 2.30.0) resolve next to
// mlx-swift-lm 3.32.3 when only AgentRunKit's non-MLX products are used?
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/Tom-Ryder/AgentRunKit.git", exact: "6.1.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
    ],
    targets: [
        .target(
            name: "Probe",
            dependencies: [
                .product(name: "AgentRunKit", package: "AgentRunKit"),
                .product(name: "AgentRunKitFoundationModels", package: "AgentRunKit"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        )
    ]
)
