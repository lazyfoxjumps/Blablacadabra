import AVFoundation
import Foundation
import Speech

/// Why an Apple `SpeechAnalyzer` session couldn't start. Every case is a signal
/// to the caller (`AppState`) to fall back to the WhisperKit pipeline silently:
/// the user keeps captions, they just run on the universal engine instead.
public enum AppleSpeechUnavailable: LocalizedError, Equatable {
    /// Speech Recognition permission was denied or restricted.
    case notAuthorized
    /// Apple has no transcriber for this locale on this Mac.
    case localeUnsupported
    /// The on-demand locale model wouldn't download/install.
    case assetInstallFailed
    /// The analyzer offered no audio format we could convert to.
    case noCompatibleFormat
    /// Apple's `Translation` couldn't translate this language pair (Round 2): the
    /// pack isn't usable on this Mac. The session falls back to WhisperKit, which
    /// translates it instead.
    case translationUnavailable

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech Recognition isn't allowed, so Apple's fast captions are off. Falling back to the built-in model."
        case .localeUnsupported:
            return "Apple doesn't caption this language on this Mac. Falling back to the built-in model."
        case .assetInstallFailed:
            return "Apple's speech model for this language couldn't be set up. Falling back to the built-in model."
        case .noCompatibleFormat:
            return "Apple's captions couldn't match the audio format. Falling back to the built-in model."
        case .translationUnavailable:
            return "Apple can't translate this language on this Mac yet. Falling back to the built-in model."
        }
    }
}

/// Locale mapping for the Apple path. Pure (no Speech symbols, no OS-26 gate) so
/// it is unit-testable and usable from `AppState`'s engine-selection code on any
/// macOS. The Apple analyzer needs a KNOWN locale (it does not auto-detect from
/// audio the way Whisper does), so a locked `spokenLanguage` wins and an unlocked
/// session assumes English, mirroring the existing "unlocked transcribe = English"
/// rule in `TranscriptionPipeline.resolvedLanguage`.
public enum AppleSpeechLocale {
    /// The locale to caption in: the locked spoken language (ISO 639-1) when set,
    /// otherwise the user's chosen English variant.
    public static func resolved(spokenLanguage code: String?, englishLocale: EnglishLocale) -> Locale {
        if let code, !code.isEmpty {
            return Locale(identifier: code)
        }
        return Locale(identifier: englishLocale.localeIdentifier)
    }

    /// The ISO 639-1 language code for a locale (e.g. "en" for en-GB), used to tag
    /// caption events so the status line can name the heard language. nil when the
    /// locale carries no language code.
    public static func isoCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }
}

/// The Apple `SpeechAnalyzer` caption pipeline: a streaming-native sibling to the
/// WhisperKit-backed `TranscriptionPipeline`. Where Whisper re-decodes a growing
/// VAD chunk for every partial, `SpeechAnalyzer` consumes a continuous audio
/// stream and emits its own volatile (partial) and final results on the Neural
/// Engine, so it bypasses `VoiceChunker` entirely. Both pipelines emit the same
/// `CaptionEvent`s, so the overlay, level meter, and Both-mode lanes don't care
/// which one is running.
///
/// Round 1 is TRANSCRIPTION only: this pipeline is built for a fixed locale, no
/// translate, no bilingual. `AppState` chooses it only when the Translate toggle
/// is off and the locale is Apple-supported + authorized; otherwise it builds a
/// `TranscriptionPipeline`. Because the locale is fixed at `SpeechTranscriber`
/// init, a language change is handled by an `AppState` restart, not mid-stream.
@available(macOS 26, *)
public actor AppleSpeechPipeline: CaptionPipeline {
    private let source: AudioSource
    private let locale: Locale
    private let isoCode: String?
    /// Reports asset-install progress (0...1) when Apple has to download an
    /// on-demand locale model. English is pre-installed on this Mac (zero
    /// download), so this fires only for on-demand languages. `AppState` wires it
    /// to the existing "Setting up the speech model" status copy.
    private let installProgress: (@Sendable (Double) -> Void)?

    /// Linear input gain applied to every sample before the analyzer and the tap.
    /// 1.0 = unchanged; clamped to [-1, 1] after scaling. Settable mid-stream.
    private var inputGain: Float

    /// Optional tap on incoming pipeline-format samples; feeds the level meter
    /// without touching the caption stream.
    private var audioTap: (@Sendable ([Float]) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var convertRatio: Double = 1

    private var captionContinuation: AsyncStream<CaptionEvent>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var installObservation: NSKeyValueObservation?

    public init(
        source: AudioSource,
        locale: Locale,
        inputGain: Float = 1,
        installProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.source = source
        self.locale = locale
        self.isoCode = AppleSpeechLocale.isoCode(for: locale)
        self.inputGain = max(0.1, inputGain)
        self.installProgress = installProgress
    }

    // MARK: - CaptionPipeline

    /// Authorizes, installs the locale asset if needed, wires the analyzer, and
    /// starts streaming. Throws `AppleSpeechUnavailable` on any blocker so the
    /// caller falls back to WhisperKit; throws `AudioCaptureError.alreadyRunning`
    /// if called twice.
    public func start() async throws -> AsyncStream<CaptionEvent> {
        guard pumpTask == nil else { throw AudioCaptureError.alreadyRunning }

        guard await Self.requestAuthorization() else { throw AppleSpeechUnavailable.notAuthorized }
        guard await Self.isSupported(locale) else { throw AppleSpeechUnavailable.localeUnsupported }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        try await installAssetIfNeeded(for: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // The analyzer rejects arbitrary formats; convert our 16 kHz mono Float32
        // into the format it asks for, with ONE reused converter.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: AudioPipelineFormat.format, to: analyzerFormat)
        else {
            throw AppleSpeechUnavailable.noCompatibleFormat
        }
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        self.convertRatio = analyzerFormat.sampleRate / AudioPipelineFormat.sampleRate

        let audio = try await source.start()

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputCont

        let captionStream = AsyncStream<CaptionEvent> { continuation in
            self.captionContinuation = continuation
        }

        try await analyzer.start(inputSequence: inputStream)

        // Results task: volatile -> .partial, final -> .final. Ends when the
        // analyzer is finalized (which finishes `results`), then finishes the
        // caption stream. An iteration error finishes captions too, so AppState
        // surfaces its "lost the audio" state instead of hanging.
        resultsTask = Task { [transcriber, isoCode] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self.yieldCaption(.final(text, original: nil, language: isoCode))
                    } else {
                        self.yieldCaption(.partial(text, language: isoCode))
                    }
                }
            } catch {
                // analyzer stream errored; fall through to finish the captions.
            }
            self.finishCaptions()
        }

        // Pump task: gain-clamp, tap, convert, feed the analyzer.
        pumpTask = Task {
            for await buffer in audio {
                if Task.isCancelled { break }
                self.feed(buffer)
            }
            self.inputContinuation?.finish()
        }

        return captionStream
    }

    public func stop() async {
        await source.stop() // finishes the audio stream; the pump loop then exits
        await pumpTask?.value
        pumpTask = nil

        inputContinuation?.finish()
        inputContinuation = nil

        // Finalize flushes any pending finals and ends `transcriber.results`, so
        // the results task completes on its own; await it so those last finals
        // reach the screen before the stream closes.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil

        finishCaptions()
    }

    /// No-op: the Apple path is transcribe-only in Round 1. Translate flips the
    /// engine back to WhisperKit via an `AppState` restart, not a live task swap.
    public func setTask(_ newTask: TranscriptionTask) {}

    /// No-op: the locale is fixed at `SpeechTranscriber` init. A language change
    /// is applied by `AppState` restarting the session, not mid-stream.
    public func setSpokenLanguage(_ code: String?) {}

    /// No-op: bilingual is a translate feature, out of scope for the transcribe-
    /// only Apple path.
    public func setShowOriginal(_ show: Bool) {}

    public func setInputGain(_ gain: Float) {
        inputGain = max(0.1, gain)
    }

    public func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?) {
        audioTap = tap
    }

    // MARK: - Pumping

    /// One incoming pipeline-format buffer (16 kHz mono Float32): apply gain in
    /// place, feed the level-meter tap, convert to the analyzer's format, and
    /// hand it to the analyzer.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData else { return }

        let gain = inputGain
        if gain != 1 {
            for i in 0..<frames {
                channel[0][i] = max(-1, min(1, channel[0][i] * gain))
            }
        }
        audioTap?(Array(UnsafeBufferPointer(start: channel[0], count: frames)))

        guard let converted = convertToAnalyzerFormat(buffer) else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: converted))
    }

    /// Resamples a pipeline-format buffer to the analyzer's format with the one
    /// reused converter. Returns nil for empty/failed conversions (a resampler
    /// can legitimately emit zero frames while filling its filter window).
    private func convertToAnalyzerFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let analyzerFormat, buffer.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * convertRatio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private func yieldCaption(_ event: CaptionEvent) {
        captionContinuation?.yield(event)
    }

    private func finishCaptions() {
        captionContinuation?.finish()
        captionContinuation = nil
    }

    // MARK: - Asset install

    /// Installs the locale's on-demand model if Apple says one is needed. English
    /// is pre-installed (the request comes back nil), so this is a no-op on the
    /// common path. Any failure becomes `AppleSpeechUnavailable.assetInstallFailed`.
    private func installAssetIfNeeded(for transcriber: SpeechTranscriber) async throws {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return // nil = nothing to install (asset already present)
            }
            installProgress?(0)
            installObservation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { await self?.reportInstallProgress(fraction) }
            }
            try await request.downloadAndInstall()
            installObservation = nil
            installProgress?(1)
        } catch {
            installObservation = nil
            throw AppleSpeechUnavailable.assetInstallFailed
        }
    }

    private func reportInstallProgress(_ fraction: Double) {
        installProgress?(fraction)
    }

    // MARK: - Availability (live OS calls; not unit-testable, see gotcha 21)

    /// Whether Apple can transcribe this locale on this Mac. Matches the full
    /// BCP 47 id first, then falls back to a language-code prefix (so a "ja" lock
    /// resolves against Apple's "ja-JP").
    public static func isSupported(_ locale: Locale) async -> Bool {
        let target = locale.identifier(.bcp47).lowercased()
        let supported = await SpeechTranscriber.supportedLocales
        if supported.contains(where: { $0.identifier(.bcp47).lowercased() == target }) {
            return true
        }
        guard let language = locale.language.languageCode?.identifier.lowercased() else { return false }
        return supported.contains { $0.identifier(.bcp47).lowercased().hasPrefix(language) }
    }

    /// Requests Speech Recognition permission lazily (NOT in onboarding, to honor
    /// the max-two-asks rule). Returns whether captioning is allowed. A denial
    /// just routes the session to WhisperKit.
    public static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }
}
