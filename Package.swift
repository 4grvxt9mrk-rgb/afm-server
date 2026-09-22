// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "afm-server",
    platforms: [
        // FoundationModels (Apple on-device Intelligence) requires macOS 26+.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "afm-server", targets: ["afm-server"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
    ],
    targets: [
        // Pure domain layer: no server, no Apple framework — easy to test.
        .target(name: "ShimCore"),

        // Wraps Apple's FoundationModels framework behind the LLMProvider protocol.
        .target(
            name: "FoundationProvider",
            dependencies: ["ShimCore"]
        ),

        // OpenAI-compatible wire format + Hummingbird route handlers.
        .target(
            name: "OpenAICompat",
            dependencies: [
                "ShimCore",
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),

        // Executable: composition root that wires everything together.
        .executableTarget(
            name: "afm-server",
            dependencies: [
                "ShimCore",
                "FoundationProvider",
                "OpenAICompat",
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),

        .testTarget(
            name: "ShimCoreTests",
            dependencies: ["ShimCore"]
        ),

        .testTarget(
            name: "OpenAICompatTests",
            dependencies: ["OpenAICompat", "ShimCore"]
        )
    ]
)
