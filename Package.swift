// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Blablacadabra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlablacadabraCore", targets: ["BlablacadabraCore"]),
        .executable(name: "capture-check", targets: ["CaptureCheck"]),
        .executable(name: "transcribe-check", targets: ["TranscribeCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "BlablacadabraCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(
            name: "CaptureCheck",
            dependencies: ["BlablacadabraCore"]
        ),
        .executableTarget(
            name: "TranscribeCheck",
            dependencies: ["BlablacadabraCore"]
        ),
        .testTarget(
            name: "BlablacadabraCoreTests",
            dependencies: ["BlablacadabraCore"]
        ),
    ]
)
