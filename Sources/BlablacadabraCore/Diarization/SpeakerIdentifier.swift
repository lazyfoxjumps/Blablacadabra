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

    public init(maxSpeakers: Int = 4, threshold: Float = 0.5) {
        self.clusterer = SpeakerClusterer(maxSpeakers: maxSpeakers, threshold: threshold)
    }

    public func identify(samples: [Float]) async -> SpeakerID? {
        guard !samples.isEmpty else { return nil }
        guard let diarizer = await loadedDiarizer() else { return nil }

        let embedding: [Float]
        do {
            embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        } catch {
            return nil
        }
        guard !embedding.isEmpty else { return nil }
        return clusterer.assign(embedding)
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
}
