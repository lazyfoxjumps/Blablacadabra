import Foundation
import Testing
@testable import BlablacadabraCore

/// Phase 7B (B.3) — contract tests for the LLM weights store.
///
/// The real HF download can't run offline, so these inject a fake fetcher and prove the
/// store's LOGIC: cache validity (sentinel-gated), the refetch decision for a partial
/// cache, monotonic progress forwarding, and the integrity gate. No network, no model.
@Suite struct LLMWeightStoreTests {

    // A scratch cacheRoot per test, removed on deinit.
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blabla-llmstore-\(UUID().uuidString)", isDirectory: true)
    }

    private static func variantFolder(root: URL, _ variant: GemmaTranslationService.ModelVariant) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(variant.repoId, isDirectory: true)
    }

    /// Write the minimum files the store treats as a usable checkpoint.
    private static func writeRequiredFiles(into folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try Data().write(to: folder.appendingPathComponent("model.safetensors"))
    }

    // MARK: - isCached

    @Test func isCachedFalseWhenAbsent() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LLMWeightStore(cacheRoot: root, fetcher: FakeFetcher())
        #expect(await store.isCached(.gemma3_4B) == false)
    }

    @Test func isCachedFalseWhenFilesPresentButNoSentinel() async throws {
        // A half-downloaded folder has the files but not the completion sentinel, so it
        // must NOT count as cached (the partial/corrupt-cache case).
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeRequiredFiles(into: Self.variantFolder(root: root, .gemma3_4B))

        let store = LLMWeightStore(cacheRoot: root, fetcher: FakeFetcher())
        #expect(await store.isCached(.gemma3_4B) == false)
    }

    // MARK: - ensureAvailable progress

    @Test func ensureAvailableCallsProgressMonotonically() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The fetcher emits a deliberately jittery stream (including a backward step);
        // the store must clamp it to monotonic non-decreasing, ending at 1.0.
        let fetcher = FakeFetcher(emit: [0.0, 0.4, 0.3, 0.8, 1.0])
        let store = LLMWeightStore(cacheRoot: root, fetcher: fetcher)

        let recorder = ProgressRecorder()
        let folder = try await store.ensureAvailable(.gemma3_4B) { recorder.record($0) }

        let values = recorder.values
        #expect(values.isEmpty == false)
        #expect(values == values.sorted(), "progress must be non-decreasing, got \(values)")
        #expect(values.allSatisfy { $0 >= 0.0 && $0 <= 1.0 })
        #expect(values.last == 1.0)
        // And it actually produced the variant folder the service will load from.
        #expect(folder == Self.variantFolder(root: root, .gemma3_4B))
        #expect(await store.isCached(.gemma3_4B) == true)
    }

    // MARK: - resume / refetch decision

    @Test func ensureAvailableResumesPartialDownload() async throws {
        // A folder with files but no sentinel = an interrupted download. ensureAvailable
        // must NOT trust it as done; it re-invokes the fetcher (which, in production, is
        // where Hub resumes the missing bytes), then marks it complete.
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeRequiredFiles(into: Self.variantFolder(root: root, .gemma3_4B))

        let fetcher = FakeFetcher()
        let store = LLMWeightStore(cacheRoot: root, fetcher: fetcher)

        _ = try await store.ensureAvailable(.gemma3_4B)
        #expect(fetcher.callCount == 1, "partial cache must trigger a (resuming) fetch")
        #expect(await store.isCached(.gemma3_4B) == true)
    }

    @Test func ensureAvailableSkipsFetchWhenFullyCached() async throws {
        // The inverse guard: a complete, sentinel-marked cache must skip the network.
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fetcher = FakeFetcher()
        let store = LLMWeightStore(cacheRoot: root, fetcher: fetcher)
        _ = try await store.ensureAvailable(.gemma3_4B)   // first call downloads + marks
        #expect(fetcher.callCount == 1)

        _ = try await store.ensureAvailable(.gemma3_4B)   // second call is a cache hit
        #expect(fetcher.callCount == 1, "a complete cache must not refetch")
    }

    // MARK: - integrity gate (corrupted cache)

    @Test func corruptedCacheIsDetectedAndReFetched() async throws {
        // The fetcher "succeeds" but writes an incomplete folder (no safetensors). The
        // store's integrity gate must reject it rather than mark it complete.
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LLMWeightStore(cacheRoot: root, fetcher: IncompleteFetcher())
        await #expect(throws: LLMWeightStoreError.integrityCheckFailed) {
            _ = try await store.ensureAvailable(.gemma3_4B)
        }
        // Nothing was marked complete, so a later run with a healthy fetcher refetches.
        #expect(await store.isCached(.gemma3_4B) == false)
    }
}

// MARK: - Test doubles

/// Writes a complete checkpoint to the expected variant folder and replays a progress
/// stream. Records how many times it was invoked.
private final class FakeFetcher: WeightsSnapshotFetcher, @unchecked Sendable {
    private let emit: [Double]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    init(emit: [Double] = [0.0, 0.5, 1.0]) { self.emit = emit }

    func fetchSnapshot(
        repoId: String,
        destinationBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        lock.lock(); _callCount += 1; lock.unlock()
        for value in emit { progress(value) }
        let folder = destinationBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoId, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try Data().write(to: folder.appendingPathComponent("model.safetensors"))
        return folder
    }
}

/// Reports success but writes a folder missing the weights shard — exercises the
/// integrity gate.
private struct IncompleteFetcher: WeightsSnapshotFetcher {
    func fetchSnapshot(
        repoId: String,
        destinationBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(1.0)
        let folder = destinationBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        // No tokenizer, no safetensors → integrity check fails.
        return folder
    }
}

/// Thread-safe collector for the progress callback (fired from the fetcher's task).
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
    func record(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
}
