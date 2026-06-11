// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Blablacadabra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlablacadabraCore", targets: ["BlablacadabraCore"]),
        .executable(name: "capture-check", targets: ["CaptureCheck"]),
    ],
    targets: [
        .target(name: "BlablacadabraCore"),
        .executableTarget(
            name: "CaptureCheck",
            dependencies: ["BlablacadabraCore"]
        ),
        .testTarget(
            name: "BlablacadabraCoreTests",
            dependencies: ["BlablacadabraCore"]
        ),
    ]
)
