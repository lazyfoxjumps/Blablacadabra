import Foundation
import FluidAudio

/// What the pipeline needs from a speaker labeler. A protocol (not just the
/// concrete actor) so tests can inject a fake without loading the diarization
/// model, and so a future engine could supply speaker labels another way.
public protocol SpeakerIdentifying: Sendable {
    /// Labels one finalized utterance, or returns nil if no label is available
    /// (model not loaded, audio too short, extraction failed). Captions must
    /// never depend on this succeeding.
    func identify(samples: [Float]) async -> SpeakerID?
    /// Forgets all speakers; speaker numbers restart at 1. Called per session.
    func reset() async
}

/// A labeler that ignores the audio and always returns the same fixed label.
///
/// Used for the mic lane in "Both" mode: that lane IS the user, by definition,
/// so there's nothing to cluster — pin it to Speaker 1 and skip the embedding
/// entirely. This both removes the user's own voice from the system lane's
/// clustering job (the noisiest part) and gives a guaranteed-stable color for
/// "you", no voice model required.
///
/// (Single-source mic mode does NOT use this: a lone mic can carry several
/// people in a room, so it still clusters. Only the dedicated mic lane of a
/// two-lane "Both" session is the user alone.)
public struct PinnedSpeakerIdentifier: SpeakerIdentifying {
    public let id: SpeakerID
    public init(_ id: SpeakerID) { self.id = id }
    public func identify(samples: [Float]) async -> SpeakerID? { id }
    public func reset() async {}
}

/// Turns a finalized utterance into a stable per-session speaker label using
/// FluidAudio's on-device speaker-embedding model plus our own online
/// `SpeakerClusterer`.
///
/// Lazy + fail-soft by design. The model loads on the first `identify` (so a
/// session that never enables speaker colors pays nothing), and any failure
/// (offline first run, model load error, a too-short or silent utterance) just
/// yields nil. The caller commits the caption unlabeled; speaker color is
/// always additive, never on the critical path.
///
/// Privacy: once cached, the model loads from a local folder with zero network
/// (proved in the Step 1 spike, same bar as Phase 5). Clusters live only in
/// memory and are dropped on `reset`/dealloc; no voice prints are written.
public actor SpeakerIdentifier: SpeakerIdentifying {
    private var clusterer: SpeakerClusterer
    private var diarizer: DiarizerManager?
    /// Set once a load attempt has failed, so we don't retry the download on
    /// every utterance for a whole session.
    private var loadFailed = false

    /// Below this many samples an utterance is too short for a trustworthy
    /// embedding ("yeah", "ok", a laugh). Embedding it anyway produces a noisy
    /// vector that matches nobody and mints a bogus new cluster — the exact
    /// thing that walks one voice up to S+. We skip it and leave the caption
    /// uncolored instead. 12000 samples ≈ 0.75s at FluidAudio's 16 kHz input.
    private let minUtteranceSamples: Int
    /// Below this RMS the span is effectively silence (gain artifacts, room
    /// tone). Same treatment: skip, don't cluster noise into a speaker.
    private let minUtteranceRMS: Float

    /// Optional diagnostics sink. When set, every `identify` appends one line
    /// (span length, RMS, nearest-cluster similarity, the decision) to a log
    /// file — numbers only, no transcript text. This is how a live call gives us
    /// the REAL same-voice/different-voice similarity spread on call audio so we
    /// stop tuning `threshold` blind off the clean spike. Off (nil) by default;
    /// turned on via a hidden UserDefaults flag in the app layer.
    private let diagnostics: DiarizationDiagnostics?

    public init(
        maxSpeakers: Int = 4,
        threshold: Float = 0.5,
        firstSpeakerNumber: Int = 1,
        minUtteranceSamples: Int = 12000,
        minUtteranceRMS: Float = 0.005,
        diagnostics: DiarizationDiagnostics? = nil
    ) {
        self.clusterer = SpeakerClusterer(
            maxSpeakers: maxSpeakers,
            threshold: threshold,
            firstSpeakerNumber: firstSpeakerNumber
        )
        self.minUtteranceSamples = minUtteranceSamples
        self.minUtteranceRMS = minUtteranceRMS
        self.diagnostics = diagnostics
    }

    public func identify(samples: [Float]) async -> SpeakerID? {
        guard !samples.isEmpty else { return nil }

        // Junk-gate: too short or too quiet to embed reliably. Skipping these
        // keeps weak utterances from spawning phantom speakers.
        guard samples.count >= minUtteranceSamples else {
            diagnostics?.log(samples: samples.count, rms: Self.rms(samples), similarity: -1, decision: "gated-short")
            return nil
        }
        let level = Self.rms(samples)
        guard level >= minUtteranceRMS else {
            diagnostics?.log(samples: samples.count, rms: level, similarity: -1, decision: "gated-quiet")
            return nil
        }

        guard let diarizer = await loadedDiarizer() else {
            diagnostics?.log(samples: samples.count, rms: level, similarity: -1, decision: "no-model")
            return nil
        }

        let embedding: [Float]
        do {
            embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        } catch {
            diagnostics?.log(samples: samples.count, rms: level, similarity: -1, decision: "embed-failed")
            return nil
        }
        guard !embedding.isEmpty else {
            diagnostics?.log(samples: samples.count, rms: level, similarity: -1, decision: "empty-embedding")
            return nil
        }
        let result = clusterer.assignDetailed(embedding)
        diagnostics?.log(
            samples: samples.count,
            rms: level,
            similarity: result.bestSimilarity,
            decision: result.createdNewCluster ? "new:\(result.id.chipLabel)" : "match:\(result.id.chipLabel)"
        )
        return result.id
    }

    public func reset() {
        clusterer.reset()
    }

    /// Loads (and caches) the diarization model on first use. Returns nil if a
    /// previous attempt failed or this one does, so callers degrade silently.
    private func loadedDiarizer() async -> DiarizerManager? {
        if let diarizer { return diarizer }
        if loadFailed { return nil }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
            return manager
        } catch {
            loadFailed = true
            return nil
        }
    }

    /// Root-mean-square level of a sample span (0 for empty), the cheap
    /// loudness proxy the quiet-gate uses.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
