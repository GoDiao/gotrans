// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gotrans",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "GoTransKit", targets: ["GoTransKit"]),
        .library(name: "GoTransServer", targets: ["GoTransServer"]),
        .executable(name: "gotrans-cli", targets: ["gotrans-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .binaryTarget(
            name: "LlamaRuntime",
            url: "https://github.com/GoDiao/gotrans/releases/download/runtime-llama-1.0.0-r1/LlamaRuntime-1.0.0-r1.zip",
            checksum: "18532f7648d07a28e7a5b7f620fa6585d26b3c6ae1915d456560c76337ca0ce4"
        ),
        .target(
            name: "GoTransKit",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .target(name: "LlamaRuntime", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GoTransServer",
            dependencies: [
                "GoTransKit",
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ]
        ),
        .executableTarget(
            name: "gotrans-cli",
            dependencies: ["GoTransKit", "GoTransServer"]
        ),
        .testTarget(
            name: "GoTransKitTests",
            dependencies: ["GoTransKit"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "GoTransServerTests", dependencies: ["GoTransServer"]),
    ]
)
