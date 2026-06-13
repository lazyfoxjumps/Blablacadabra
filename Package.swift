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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .target(
            name: "BlablacadabraCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
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
