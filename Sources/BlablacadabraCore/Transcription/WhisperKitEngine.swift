import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit. Default engine: private, free,
/// offline, and handles the translate-to-English task natively.
///
/// An actor so concurrent callers serialize; WhisperKit runs one decode at a
/// time anyway, and the pipeline already coalesces stale partials upstream.
public actor WhisperKitEngine: TranscriptionEngine {
    /// Model sizes worth offering in the UI, fastest first. Any other
    /// WhisperKit model name also works via `init(model:)`.
    public static let availableModels = ["tiny", "base", "small", "medium"]
    public static let defaultModel = "base"

    public let model: String
    private var whisper: WhisperKit?
    private var prepareHandler: (@Sendable (PrepareEvent) -> Void)?

    /// Milestones during `prepare()`, for honest status copy: downloading
    /// (with 0...1 progress) vs loading/compiling the already-downloaded model.
    public enum PrepareEvent: Sendable {
        case downloading(Double)
        case loading
    }

    public init(model: String = WhisperKitEngine.defaultModel) {
        self.model = model
    }

    /// Install before `prepare()`; called from a background thread.
    public func setPrepareHandler(_ handler: (@Sendable (PrepareEvent) -> Void)?) {
        prepareHandler = handler
    }

    /// Whether this model is already on disk (WhisperKit caches under
    /// ~/Documents/huggingface). A missing or partial cache means `prepare()`
    /// will download first, which can take minutes on the bigger models; the
    /// UI uses this to say so instead of a vague "warming up".
    public static func isModelCached(_ model: String) -> Bool {
        guard let modelDir = cachedModelFolder(model) else { return false }
        // The decoder weights land last; their compiled model is the
        // "download actually finished" marker.
        let decoder = modelDir.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin")
        return FileManager.default.fileExists(atPath: decoder.path)
    }

    static func cachedModelFolder(_ model: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(
                "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)"
            )
    }

    public func prepare() async throws {
        guard whisper == nil else { return }
        let handler = prepareHandler

        // Download explicitly (instead of letting WhisperKit.init do it
        // silently) so progress can reach the UI. Cached models skip this.
        var modelFolder = Self.isModelCached(model) ? Self.cachedModelFolder(model) : nil
        if modelFolder == nil {
            handler?(.downloading(0))
            do {
                modelFolder = try await WhisperKit.download(variant: model) { progress in
                    handler?(.downloading(progress.fractionCompleted))
                }
            } catch {
                throw TranscriptionError.modelLoadFailed(String(describing: error))
            }
        }

        handler?(.loading)
        // Init from the local folder: WhisperKit then never touches the
        // network (its model-name init phones home for a support config even
        // with a full cache; "everything stays on this Mac" should mean it).
        whisper = try await Self.loadGuardingAgainstStall(model: model, folder: modelFolder)
    }

    /// WhisperKit init can stall indefinitely right after an in-app download
    /// completes (observed: 8+ min at 0% CPU; a fresh init then loads in
    /// seconds). Guard: time the first attempt out and retry once with a
    /// brand-new init before giving up.
    private static func loadGuardingAgainstStall(model: String, folder: URL?) async throws -> WhisperKit {
        for attempt in 1...2 {
            do {
                return try await withTimeout(seconds: 180) {
                    try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder?.path))
                }
            } catch is LoadStallTimeout {
                if attempt == 2 {
                    throw TranscriptionError.modelLoadFailed("model load stalled twice")
                }
                // fall through to retry with a fresh WhisperKit init
            } catch {
                throw TranscriptionError.modelLoadFailed(String(describing: error))
            }
        }
        throw TranscriptionError.modelLoadFailed("unreachable")
    }

    private struct LoadStallTimeout: Error {}

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LoadStallTimeout()
            }
            guard let result = try await group.next() else { throw LoadStallTimeout() }
            group.cancelAll()
            return result
        }
    }

    public func transcribe(_ samples: [Float], task: TranscriptionTask, language: String?) async throws -> TranscriptionOutput {
        guard let whisper else { throw TranscriptionError.engineNotPrepared }
        // Whisper pads to its 30s window internally, but sub-0.1s blips only
        // produce hallucinations; the VAD already drops most of these.
        guard samples.count >= Int(AudioPipelineFormat.sampleRate / 10) else { return .empty }

        let options = DecodingOptions(
            task: task == .translate ? .translate : .transcribe,
            // Forcing the source language matters: with language nil WhisperKit
            // assumes English instead of detecting, so a Japanese utterance on
            // the transcribe task comes back in English. The caller detects
            // the language first and passes it here.
            language: language,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = Self.cleaned(
            results.map(\.text).joined(separator: " ")
        )
        // result.language is the SOURCE language on the transcribe task, but
        // the TARGET ("en") on the translate task (verified live: a Japanese
        // clip translates with result.language == "en"). Callers that need
        // the source language while translating use detectLanguage().
        let language = results.first?.language
        return TranscriptionOutput(
            text: Self.isNoise(text) ? "" : text,
            detectedLanguage: language
        )
    }

    /// Dedicated language detection (single forward pass, no full decode),
    /// so the translate path can label the real source language.
    public func detectLanguage(_ samples: [Float]) async throws -> String? {
        guard let whisper else { throw TranscriptionError.engineNotPrepared }
        guard samples.count >= Int(AudioPipelineFormat.sampleRate / 10) else { return nil }
        // WhisperKit's method name carries an upstream typo ("Langauge").
        let result = try await whisper.detectLangauge(audioArray: samples)
        return result.language
    }

    /// Whisper opens chunks that start mid-conversation with a dialog dash
    /// ("- I'm going to pause."); as a live caption line that reads like a
    /// stage direction, so the leading dash goes.
    static func cleaned(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, first == "-" || first == "\u{2013}" || first == "\u{2014}" {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Whisper labels non-speech with bracketed annotations ("[BLANK_AUDIO]",
    /// "(music)", "♪ ♪"); those are noise, not captions.
    static func isNoise(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let stripped = text.filter { !$0.isWhitespace && $0 != "♪" && $0 != "♫" }
        if stripped.isEmpty { return true }
        if let first = stripped.first, let last = stripped.last,
           (first == "[" && last == "]") || (first == "(" && last == ")") {
            return true
        }
        return false
    }
}
