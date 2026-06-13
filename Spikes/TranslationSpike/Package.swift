// swift-tools-version: 6.2
import PackageDescription

// Step 0 SDK spike for the 0.8.0 Apple Translation fast-path (Round 2).
// Pins the real Translation framework API against the installed macOS 26 SDK
// before we build the Apple translate path. The macOS-26-only direct
// `TranslationSession(installedSource:target:)` initializer means NO hidden
// SwiftUI host is needed (the macOS-15 API required `.translationTask`); this
// spike proves that out and reports which language pairs are installed here.
let package = Package(
    name: "TranslationSpike",
    platforms: [.macOS(.v26)],
    targets: [
        // Swift 5 language mode to mirror the real package (swift-tools 5.9):
        // Translation's LanguageAvailability/TranslationSession are non-Sendable
        // with nonisolated async members, which Swift 6 mode rejects across an
        // actor boundary but Swift 5 mode allows. The real Core target is 5.9.
        .executableTarget(
            name: "TranslationSpike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
