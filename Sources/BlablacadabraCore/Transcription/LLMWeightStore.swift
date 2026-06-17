import Foundation
import Hub

// MARK: - Phase 7B (B.3) — LLM weights store (download + on-disk cache)
//
// `LLMWeightStore` owns the on-disk cache for the Gemma checkpoints and orchestrates
// the first-run download, mirroring the WhisperKit model path (`isModelCached` +
// download-progress). It exists so the B.4 bake-off can fetch weights with one call;
// it is OFF the live captioning path (nothing in the app constructs it yet — live
// wiring, including the first-run banner, is Phase C).
//
// HOW IT CONNECTS TO B.2: the store resolves a local folder (config.json + tokenizer
// + *.safetensors), and the bake-off hands that folder to
// `GemmaTranslationService(weights: .localPath(folder))`. We deliberately do NOT route
// `GemmaTranslationService.start()`'s `.autoDownload` case through here in B.3: that
// would make the actor's `start()` hit the network and break B.2's offline contract
// tests. Keeping the store standalone preserves strict layering and offline tests.
//
// ⚠️ The actual HF download cannot be unit-tested without the network. So the store's
// LOGIC (cache validity, refetch decision, monotonic progress, integrity gate) is
// tested against an injected fake fetcher; the real fetcher (`HubWeightsSnapshotFetcher`)
// is a thin pass-through to `HubApi.snapshot`.

/// A downloadable model checkpoint, identified by its HF repo and on-disk folder. Lets the
/// store serve any backend (Gemma, MADLAD, ...) instead of being tied to one service's enum.
public protocol LLMWeightVariant: Sendable {
    /// The Hugging Face repo to fetch from.
    var repoId: String { get }
    /// The on-disk cache subdir name (informational; the store keys off `repoId` to match Hub).
    var folderName: String { get }
}

/// Abstracts the HF snapshot download so the store's cache / resume / integrity logic
/// is unit-testable offline. The real impl hits the network via `HubApi`; tests inject
/// a fake that writes files locally and reports synthetic progress.
public protocol WeightsSnapshotFetcher: Sendable {
    /// Download every model file for `repoId` into `destinationBase` (HF layout:
    /// `destinationBase/models/<repoId>`), resuming any partial download already on
    /// disk. Reports fractional progress in [0, 1]. Returns the local repo folder.
    func fetchSnapshot(
        repoId: String,
        destinationBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

/// The production fetcher: a thin wrapper over `HubApi.snapshot`. Hub handles the
/// resume-partial-download and per-file hash validation internally, so the store
/// delegates both to it (open decision #2 = HF direct; resume = yes).
public struct HubWeightsSnapshotFetcher: WeightsSnapshotFetcher {
    public init() {}

    public func fetchSnapshot(
        repoId: String,
        destinationBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let hub = HubApi(downloadBase: destinationBase)
        // Fetch only the files the decoder + tokenizer need; skip READMEs, images,
        // and other repo clutter so the ~2.5GB download isn't padded.
        return try await hub.snapshot(
            from: repoId,
            matching: ["*.safetensors", "*.json", "*.model", "*.txt"]
        ) { (p: Progress) in
            progress(p.fractionCompleted)
        }
    }
}

/// Owns the on-disk cache of LLM weights and the first-run download. Actor-isolated so
/// the cache check + download decision can't race when several pipelines ask at once.
public actor LLMWeightStore {

    /// HF-style download base. Defaults to the SAME Application Support tree WhisperKit
    /// uses (`~/Library/Application Support/Blablacadabra/huggingface`), so Gemma weights
    /// sit alongside the Whisper models under one cache.
    ///
    /// NOTE — deliberate deviation from the B.3 scaffold's `~/Library/Caches/.../llm`:
    /// `Caches` is OS-purgeable, and re-downloading a ~2.5GB checkpoint is exactly the
    /// pain the WhisperKit Documents→Application Support migration was built to avoid.
    /// Application Support is the right home for large, expensive-to-refetch blobs.
    private let cacheRoot: URL
    private let fetcher: WeightsSnapshotFetcher

    /// Written (empty) into a variant folder only after a snapshot fully completes and
    /// passes the file-presence check. Its presence is the "download actually finished"
    /// marker (the WhisperKit `TextDecoder.mlmodelc` trick): a half-downloaded folder
    /// has the files but NOT this sentinel, so it's never mistaken for cached.
    private static let completionSentinel = ".blabla-download-complete"

    public init(
        cacheRoot: URL? = nil,
        fetcher: WeightsSnapshotFetcher = HubWeightsSnapshotFetcher()
    ) {
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        self.fetcher = fetcher
    }

    static func defaultCacheRoot() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Blablacadabra/huggingface", isDirectory: true)
    }

    /// Local folder a variant's weights live in: `cacheRoot/models/<repoId>`, matching
    /// `HubApi.localRepoLocation` exactly so `isCached` and the fetcher agree on the path.
    public func variantFolder(_ variant: any LLMWeightVariant) -> URL {
        cacheRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(variant.repoId, isDirectory: true)
    }

    /// True only when the variant is fully downloaded: all required files present AND the
    /// completion sentinel written. A partial/interrupted download returns false so the
    /// caller refetches (Hub then resumes the missing bytes).
    public func isCached(_ variant: any LLMWeightVariant) -> Bool {
        let folder = variantFolder(variant)
        return hasCompletionSentinel(folder) && hasRequiredFiles(folder)
    }

    /// Ensure the variant is on disk, downloading (or resuming) if needed, then return its
    /// local folder. Progress is forwarded monotonically in [0, 1]; the final value is
    /// always 1.0 on success. Throws `LLMWeightStoreError` on download failure or if the
    /// fetched folder is missing required files.
    public func ensureAvailable(
        _ variant: any LLMWeightVariant,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let folder = variantFolder(variant)

        // Fast path: a complete, sentinel-marked cache is trusted as-is — no network.
        if isCached(variant) {
            progress(1.0)
            return folder
        }

        // Absent OR present-but-incomplete (interrupted / corrupt): (re)fetch. Hub
        // resumes any partial bytes already on disk; we never trust an unsentineled
        // folder as done. Progress is clamped monotonic so the UI bar never jumps back.
        let clamp = MonotonicProgressSink(progress)
        let downloaded: URL
        do {
            downloaded = try await fetcher.fetchSnapshot(
                repoId: variant.repoId,
                destinationBase: cacheRoot
            ) { fraction in
                clamp.report(fraction)
            }
        } catch {
            throw LLMWeightStoreError.downloadFailed(String(describing: error))
        }

        // Integrity gate: a snapshot that "succeeded" but is missing config/tokenizer/
        // weights is unusable — surface it rather than letting the decoder fail opaquely.
        guard hasRequiredFiles(downloaded) else {
            throw LLMWeightStoreError.integrityCheckFailed
        }
        markComplete(downloaded)
        progress(1.0)
        return downloaded
    }

    // Concrete Gemma-typed overloads. The protocol-typed methods above can't be called with
    // leading-dot syntax (`.gemma3_4B`); these let existing call sites keep that, delegating
    // to the neutral implementation. New backends pass their variant value directly.
    public func variantFolder(_ variant: GemmaTranslationService.ModelVariant) -> URL {
        variantFolder(variant as any LLMWeightVariant)
    }

    public func isCached(_ variant: GemmaTranslationService.ModelVariant) -> Bool {
        isCached(variant as any LLMWeightVariant)
    }

    public func ensureAvailable(
        _ variant: GemmaTranslationService.ModelVariant,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try await ensureAvailable(variant as any LLMWeightVariant, progress: progress)
    }

    // MARK: - On-disk checks

    /// The minimum the Gemma decoder + tokenizer need to load (B.2's `start()`):
    /// architecture config, a tokenizer, and at least one weights shard.
    private func hasRequiredFiles(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("config.json").path) else {
            return false
        }
        let hasTokenizer =
            fm.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) ||
            fm.fileExists(atPath: folder.appendingPathComponent("tokenizer_config.json").path)
        guard hasTokenizer else { return false }
        let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension == "safetensors" }
    }

    private func hasCompletionSentinel(_ folder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(Self.completionSentinel).path
        )
    }

    private func markComplete(_ folder: URL) {
        let sentinel = folder.appendingPathComponent(Self.completionSentinel)
        try? Data().write(to: sentinel)
    }
}

/// Failures `LLMWeightStore.ensureAvailable` can throw. Both route the caller back to a
/// fallback translator (Apple/Whisper) before any audio is captured.
public enum LLMWeightStoreError: LocalizedError, Equatable {
    /// The HF snapshot download itself failed (network, auth, disk).
    case downloadFailed(String)
    /// The download reported success but the folder lacks config / tokenizer / weights.
    case integrityCheckFailed

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return "LLM weights download failed: \(detail)"
        case .integrityCheckFailed:
            return "LLM weights downloaded but failed the integrity check."
        }
    }
}

/// Clamps a progress stream to be monotonic non-decreasing and bounded to [0, 1]. The
/// fetcher's `@Sendable` progress closure may fire from any task, so the running max is
/// guarded by a lock. `@unchecked Sendable` is sound: the only mutable state is `last`,
/// and every access is inside the lock.
private final class MonotonicProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private let sink: @Sendable (Double) -> Void

    init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

    func report(_ value: Double) {
        lock.lock()
        last = max(last, min(1.0, value))
        let clamped = last
        lock.unlock()
        sink(clamped)
    }
}
