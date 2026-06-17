// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Blablacadabra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlablacadabraCore", targets: ["BlablacadabraCore"]),
        .executable(name: "capture-check", targets: ["CaptureCheck"]),
        .executable(name: "transcribe-check", targets: ["TranscribeCheck"]),
        .executable(name: "Blablacadabra", targets: ["BlablacadabraApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Phase 6 Part A: on-device speaker diarization (Apache-2.0). Pinned to
        // match the Step 1 spike that proved it on this M4.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // Phase 7B (B.1): on-device LLM RUNTIME for the translation bake-off.
        // CORE mlx-swift only (tensors + NN), NOT the mlx-swift-examples model zoo:
        // the zoo pins swift-transformers to a version that conflicts with
        // WhisperKit's (zoo wants 1.0.x/1.3.x, WhisperKit wants 1.1.x — no overlap),
        // and the two MUST share one binary. Core mlx-swift pulls only swift-numerics,
        // so it coexists cleanly. We build the Gemma/MADLAD model layer on top in B.2
        // (the soniqo/speech-swift MADLAD port proves T5-on-core-MLX works) and reuse
        // the swift-transformers tokenizer already in the graph via WhisperKit.
        // Apple-Silicon only; off the live caption path until Phase 7C. Pinned EXACT:
        // the runtime moves fast and a silent bump could swing bake-off numbers.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.4")
    ],
    targets: [
        .target(
            name: "BlablacadabraCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                // Phase 7B (B.1): linked, not yet used. B.2 adds
                // GemmaTranslationService: TextTranslating built on these.
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLinalg", package: "mlx-swift")
            ]
        ),
        .executableTarget(
            name: "CaptureCheck",
            dependencies: ["BlablacadabraCore"]
        ),
        .executableTarget(
            name: "TranscribeCheck",
            dependencies: ["BlablacadabraCore"]
        ),
        .executableTarget(
            name: "BlablacadabraApp",
            dependencies: ["BlablacadabraCore"]
        ),
        .testTarget(
            name: "BlablacadabraCoreTests",
            dependencies: ["BlablacadabraCore"]
        ),
    ]
)
