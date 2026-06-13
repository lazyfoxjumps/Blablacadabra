// swift-tools-version: 6.2
import PackageDescription

// Step 0 SDK spike for the 0.7.0 Apple SpeechAnalyzer fast-path.
// Pins the real SpeechAnalyzer / SpeechTranscriber API names against the
// installed macOS 26 SDK before we build AppleSpeechPipeline.swift.
// macOS 26 floor: SpeechAnalyzer and friends are @available(macOS 26, *).
let package = Package(
    name: "SpeechAnalyzerSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "SpeechAnalyzerSpike")
    ]
)
