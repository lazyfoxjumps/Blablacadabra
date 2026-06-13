// Step 0 SDK spike — Apple SpeechAnalyzer fast-path (0.7.0, Round 1)
//
// Purpose: PIN the exact Speech-framework API names/signatures against the
// installed SDK so AppleSpeechPipeline.swift can be written without guessing.
// These names drifted across the macOS 26 seeds; this file is the ground-truth
// proof that the surface the plan assumed actually compiles here.
//
// Every symbol below was cross-checked against the SDK swiftinterface:
//   <SDK>/System/Library/Frameworks/Speech.framework/.../arm64e-apple-macos.swiftinterface
//
// Build:  swift build           (compiling == every name is real on this SDK)
// Run:    swift run             (prints live SDK facts: locales + auth status)
//
// FINDINGS (read these before writing AppleSpeechPipeline.swift):
//   1. SpeechTranscriber.Result has NO direct `isFinal`. `isFinal` comes from a
//      default extension on the `SpeechModuleResult` protocol, so `result.isFinal`
//      still works — just know where it lives.
//   2. AnalyzerInputConverter (the Apple-provided format converter) is
//      @available(macOS 27, *) — NOT usable on 26. So we build our OWN
//      AVAudioConverter to `bestAvailableAudioFormat`, exactly as the plan says.
//   3. There is no dedicated "input builder" type. The analyzer consumes any
//      AsyncSequence<AnalyzerInput>; use AsyncStream<AnalyzerInput> + its
//      continuation. `continuation.yield(...)` / `.finish()` are the real
//      equivalents of the plan's `inputBuilder.yield/finish`.
//   4. assetInstallationRequest(supporting:) returns AssetInstallationRequest?
//      — nil means nothing to install (asset already present). Only call
//      downloadAndInstall() when it is non-nil.
//   5. SpeechAnalyzer init is `(modules:options:)`; streaming is started with
//      `start(inputSequence:)` and ended with `finalizeAndFinishThroughEndOfInput()`.
//   6. LIVE on this Mac (macOS 26.6, M4): 30 supportedLocales. All 8 of our
//      EnglishLocale values (en-US/GB/AU/SG/CA/IN/NZ/IE) are ALREADY installed,
//      so the default English path costs ZERO download. es-* installed too.
//      de/fr/it/ja/ko/pt/yue/zh are supported but on-demand (need the asset
//      install path). authorizationStatus() == notDetermined → prompt on first use.

import Foundation
import AVFoundation
import Speech

// MARK: - Compile-only surface proof
//
// This function is never called at runtime (no audio device / no permission
// needed). It exists purely so the compiler validates every signature the real
// pipeline will use. If this compiles, the names are pinned.
@available(macOS 26, *)
func _pinnedSurface() async throws {
    // --- Locale resolution (spokenLanguage lock wins, else English) ---
    let locale = Locale(identifier: "en-US")

    // --- Transcriber: full options init + volatile (partial) streaming ---
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: []
    )

    // --- Analyzer over the transcriber module ---
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // --- Mandatory format: analyzer rejects arbitrary formats ---
    let analyzerFormat: AVAudioFormat? = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber]
    )
    _ = analyzerFormat

    // --- Input is an AsyncSequence<AnalyzerInput>; AsyncStream is the vehicle ---
    let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

    // One reused AVAudioConverter (16k mono Float32 -> analyzerFormat) lives in
    // the real pipeline; here we just prove AnalyzerInput(buffer:) is the wrapper.
    func feed(_ pcm: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: pcm))      // plan's inputBuilder.yield
    }
    _ = feed

    // --- Start streaming ---
    try await analyzer.start(inputSequence: inputStream)

    // --- Results: volatile -> .partial, final -> .final ---
    let resultsTask = Task {
        do {
            for try await result in transcriber.results {
                let text: String = String(result.text.characters)  // result.text is AttributedString
                let isFinal: Bool = result.isFinal                  // from SpeechModuleResult ext (finding #1)
                _ = (text, isFinal)
            }
        } catch {
            // real pipeline surfaces this as a friendly "lost the audio" state
        }
    }
    _ = resultsTask

    // --- Teardown ---
    continuation.finish()                                    // plan's inputBuilder.finish
    try await analyzer.finalizeAndFinishThroughEndOfInput()

    // --- Asset install (download the OS locale model on first use) ---
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        // request.progress is a Foundation.Progress (reuse for the download UI)
        _ = request.progress
        try await request.downloadAndInstall()
    } // nil == already installed, nothing to do (finding #4)

    // --- Availability probes used by the engine-selection decision ---
    let supported: [Locale] = await SpeechTranscriber.supportedLocales
    let installed: [Locale] = await SpeechTranscriber.installedLocales
    _ = (supported, installed)
}

// MARK: - Live SDK facts (safe to actually run)

@available(macOS 26, *)
func reportLiveFacts() async {
    print("== Blablacadabra · SpeechAnalyzer Step 0 spike ==")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n")

    let supported = await SpeechTranscriber.supportedLocales
    let installed = await SpeechTranscriber.installedLocales
    let installedIDs = Set(installed.map { $0.identifier(.bcp47) })

    print("SpeechTranscriber.supportedLocales: \(supported.count)")
    for loc in supported.sorted(by: { $0.identifier < $1.identifier }) {
        let id = loc.identifier(.bcp47)
        let mark = installedIDs.contains(id) ? "● installed" : "○ on-demand"
        print("  \(mark)  \(id)")
    }

    // English support check used by the auto-engine decision.
    let enUS = Locale(identifier: "en-US")
    let enSupported = supported.contains { $0.identifier(.bcp47).lowercased().hasPrefix("en") }
    print("\nen-US supported by Apple on this Mac: \(enSupported)")
    _ = enUS

    // Authorization status (does NOT prompt; just reads current state).
    let status = SFSpeechRecognizer.authorizationStatus()
    print("SFSpeechRecognizer.authorizationStatus(): \(describe(status))")
    print("\n(requestAuthorization is wired lazily on first Apple use, not here.)")
}

@available(macOS 26, *)
func describe(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .denied:        return "denied"
    case .restricted:    return "restricted"
    case .authorized:    return "authorized"
    @unknown default:    return "unknown(\(s.rawValue))"
    }
}

// MARK: - Entry

if #available(macOS 26, *) {
    await reportLiveFacts()
} else {
    print("This Mac is below macOS 26; SpeechAnalyzer is unavailable (Whisper-only path).")
}
