// Phase 7B (B.4) — translation bake-off CLI.
//
// Drives each model over each clip from a manifest and writes a JSON row set with the
// locked metric columns (tokens/sec, per-line latency, peak RAM, thermal state). These
// are the numbers behind the Phase C GO/NO-GO call. QUALITY is deliberately NOT scored
// here — `quality_bleu` / `quality_human` ship null and are filled by hand by a native
// speaker. Do NOT decide GO/NO-GO on latency alone (see scaffold § B.4).
//
// Usage:
//   swift run BakeOff \
//     --models gemma-3-4b,gemma-3-1b \
//     --clips ar,id,es,ja \
//     --concurrent-with-whisper true \
//     --runs 3 \
//     --manifest Resources/BakeOff/manifest.json \
//     --out bakeoff-2026-06-17.json
//
// Off the live caption path; this target is never linked into the app.

import Foundation
import BakeOffKit
import BlablacadabraCore

// MARK: - Tiny flag parser (no ArgumentParser dep, matching the other CLI tools)

func flagValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())

guard !args.contains("--help"), !args.contains("-h") else {
    print("""
    BakeOff — Phase 7B translation bake-off
      --models   comma list: gemma-3-4b,gemma-3-1b,madlad-400-3b  (default: gemma-3-4b)
      --clips    comma list of source ISO codes to include       (default: all in manifest)
      --runs     repetitions per (model,clip), averaged          (default: 3)
      --concurrent-with-whisper true|false                       (default: false)
      --manifest path to manifest.json     (default: Resources/BakeOff/manifest.json)
      --out      path to write the JSON rows               (default: stdout only)
    """)
    exit(0)
}

let modelNames = (flagValue("--models", in: args) ?? "gemma-3-4b")
    .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
let models = modelNames.compactMap { BakeOffModel(cliName: $0) }
let unknownModels = zip(modelNames, modelNames.map { BakeOffModel(cliName: $0) })
    .filter { $0.1 == nil }.map { $0.0 }
if !unknownModels.isEmpty {
    print("ignoring unknown model(s): \(unknownModels.joined(separator: ", "))")
}
guard !models.isEmpty else {
    print("FAIL: no valid --models. Known: \(BakeOffModel.allCases.map { $0.rawValue }.joined(separator: ", "))")
    exit(2)
}

let clipFilter: Set<String>? = flagValue("--clips", in: args).map {
    Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
}
let runs = flagValue("--runs", in: args).flatMap { Int($0) } ?? 3
let whisperConcurrent = (flagValue("--concurrent-with-whisper", in: args) ?? "false").lowercased() == "true"
let manifestPath = flagValue("--manifest", in: args) ?? "Resources/BakeOff/manifest.json"
let outPath = flagValue("--out", in: args)

// MARK: - Load manifest

let manifestURL = URL(fileURLWithPath: manifestPath)
let manifest: BakeOffManifest
do {
    manifest = try BakeOffManifest.load(from: manifestURL)
} catch {
    print("FAIL: could not load manifest at \(manifestPath): \(error.localizedDescription)")
    exit(1)
}

let macID = detectMacID()
print("Bake-off on \(macID)")
print("models: \(models.map { $0.rawValue }.joined(separator: ", "))")
print("clips:  \(clipFilter.map { $0.sorted().joined(separator: ",") } ?? "all"); runs: \(runs); whisper-concurrent: \(whisperConcurrent)\n")

let semaphore = DispatchSemaphore(value: 0)

Task {
    // Optional contention: hold a WhisperKit model resident while the bake-off runs, so
    // the translation numbers reflect the real two-models-in-memory caption scenario.
    // HONESTY: this reproduces the RAM/ANE residency pressure of Whisper being loaded
    // alongside Gemma; it does NOT yet drive Whisper inference in a loop (that needs the
    // committed audio clips). The whisper_concurrent column is recorded regardless.
    var whisperEngine: WhisperKitEngine?
    if whisperConcurrent {
        let engine = WhisperKitEngine()
        do {
            print("loading Whisper model for concurrent residency...")
            try await engine.prepare()
            whisperEngine = engine
            print("Whisper resident; running translation bake-off alongside it.\n")
        } catch {
            print("warning: could not load Whisper for contention (\(error.localizedDescription)); continuing without.\n")
        }
    }

    let factory = LLMTranslatorFactory(
        onDownloadProgress: { model, fraction in
            FileHandle.standardError.write(Data("\r  [\(model.rawValue)] downloading \(Int(fraction * 100))%\u{1B}[K".utf8))
        }
    )
    let runner = BakeOffRunner(factory: factory)
    let config = BakeOffConfig(
        models: models,
        clipISOFilter: clipFilter,
        runs: runs,
        whisperConcurrent: whisperConcurrent,
        macID: macID
    )

    let rows = await runner.run(config: config, clips: manifest.clips) { msg in
        print(msg)
    }

    // Keep the engine alive until here so it stays resident for the whole run.
    _ = whisperEngine

    guard !rows.isEmpty else {
        print("FAIL: no rows produced (did any clips match --clips?)")
        exit(1)
    }

    // Print a compact table to stdout and the full JSON to --out.
    print("\n=== results ===")
    for row in rows {
        if let err = row.error {
            print("  \(row.model)/\(row.clipId) [\(row.sourceISO)]  ERROR: \(err)")
        } else {
            let tps = row.tokensPerSec.map { String(format: "%.1f", $0) } ?? "—"
            let lat = row.perLineLatencyMs.map { String(format: "%.0fms", $0) } ?? "—"
            let ram = row.ramPeakMB.map { String(format: "%.0fMB", $0) } ?? "—"
            print("  \(row.model)/\(row.clipId) [\(row.sourceISO)]  \(tps) tok/s · \(lat)/line · \(ram) peak · \(row.thermalState ?? "—")")
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = (try? encoder.encode(rows)) ?? Data()

    if let outPath {
        do {
            try jsonData.write(to: URL(fileURLWithPath: outPath))
            print("\nwrote \(rows.count) row(s) to \(outPath)")
        } catch {
            print("FAIL: could not write \(outPath): \(error.localizedDescription)")
            print(String(data: jsonData, encoding: .utf8) ?? "")
            exit(1)
        }
    } else {
        print("\n(no --out; JSON below)\n")
        print(String(data: jsonData, encoding: .utf8) ?? "")
    }

    let failures = rows.filter { $0.error != nil }.count
    print("\nDONE: \(rows.count - failures) ok, \(failures) failed.")
    print("⚠️  quality_bleu / quality_human are null by design — fill them by hand before any GO/NO-GO call.")
    exit(failures == rows.count ? 1 : 0)
}

semaphore.wait()
