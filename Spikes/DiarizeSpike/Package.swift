// swift-tools-version: 6.0
import PackageDescription

// Phase 6 Part A — Step 1 dependency spike for speaker diarization.
// Pins FluidAudio (Apache-2.0) against this M4 BEFORE any Core integration.
// Goal: prove the per-utterance embedding + online-clustering path that the
// Phase6-SpeakerColors.md plan calls for, against real multi-speaker audio
// ("Talk with Kevin.mov"). Nothing here links BlablacadabraCore; if FluidAudio
// fails the exit criteria we throw this folder away and re-research.
//
// Swift 5 language mode mirrors the real Core target (swift-tools 5.9) so the
// API we exercise here is the same API we'd get in Core, not a Swift-6-isolated
// subset.
let package = Package(
    name: "DiarizeSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "DiarizeSpike",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
