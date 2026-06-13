import Foundation
import AVFoundation
import FluidAudio
import Darwin

// ============================================================================
// Phase 6 Part A — Step 1 spike: FluidAudio diarization viability on this M4.
//
// Exit criteria (from Design/Phase6-SpeakerColors.md):
//   1. Model download + cache location confirmed.
//   2. Speaker embedding for a ~5s utterance extracted in WELL under 0.5s.
//   3. Same-voice cosine similarity is STABLE across minutes (within-speaker
//      similarity clearly > cross-speaker similarity), and online clustering
//      with speakerThreshold 0.65 yields a sane, stable speaker count.
//   4. Sane memory.
//   (5. Zero-network once cached is proved EXTERNALLY via lsof/nettop on run #2,
//       since the spike can't self-measure its own sockets reliably.)
//
// Usage:
//   swift run DiarizeSpike [audioPath] [--max-seconds N] [--window S] [--stride S] [--threshold T]
// Defaults: ~/Movies/Talk with Kevin.mov, 1200s analyzed, 5s windows, 10s stride, 0.65.
// ============================================================================

// ---- args -------------------------------------------------------------------
var argv = Array(CommandLine.arguments.dropFirst())
func popFlag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    let v = argv[i + 1]; argv.removeSubrange(i...(i + 1)); return v
}
let maxSeconds = Double(popFlag("--max-seconds") ?? "") ?? 1200.0
let windowSec  = Double(popFlag("--window") ?? "") ?? 5.0
let strideSec  = Double(popFlag("--stride") ?? "") ?? 10.0
let threshold  = Float(popFlag("--threshold") ?? "") ?? 0.65
let defaultAudio = ("~/Movies/Talk with Kevin.mov" as NSString).expandingTildeInPath
let audioPath = argv.first ?? defaultAudio

let sampleRate = 16_000.0

// ---- tiny utilities ---------------------------------------------------------
func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : -1
}
func l2(_ v: [Float]) -> [Float] {
    let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return n > 0 ? v.map { $0 / n } : v
}
func cosine(_ a: [Float], _ b: [Float]) -> Float { // expects l2-normalized inputs
    var s: Float = 0; let n = min(a.count, b.count)
    for i in 0..<n { s += a[i] * b[i] }
    return s
}
func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let m = s.count / 2
    return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
}
func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let i = max(0, min(s.count - 1, Int(p * Double(s.count - 1).rounded())))
    return s[i]
}

// ---- bounded audio load: native -> 16k mono Float32 -------------------------
func loadMono16k(from url: URL, maxSeconds: Double) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inFormat = file.processingFormat
    let wantFrames = min(AVAudioFramePosition(maxSeconds * inFormat.sampleRate), file.length)
    guard wantFrames > 0,
          let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(wantFrames)) else {
        throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not allocate input buffer"])
    }
    try file.read(into: inBuf, frameCount: AVAudioFrameCount(wantFrames))

    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
        throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not build converter"])
    }
    let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * (sampleRate / inFormat.sampleRate)) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
        throw NSError(domain: "spike", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not allocate output buffer"])
    }
    var supplied = false
    var convErr: NSError?
    converter.convert(to: outBuf, error: &convErr) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return inBuf
    }
    if let convErr { throw convErr }
    guard let ch = outBuf.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
}

// ============================================================================
print("=== DiarizeSpike: FluidAudio viability on this M4 ===\n")
print("audio      : \(audioPath)")
print("analyze    : first \(Int(maxSeconds))s  | window \(windowSec)s  stride \(strideSec)s  threshold \(threshold)\n")

let audioURL = URL(fileURLWithPath: audioPath)
guard FileManager.default.fileExists(atPath: audioPath) else {
    print("FATAL: audio not found at \(audioPath)")
    exit(1)
}

// ---- 1. model download / cache ---------------------------------------------
print("[1] DiarizerModels.downloadIfNeeded() ...")
let memBefore = residentMB()
let tModel0 = Date()
let models: DiarizerModels
do {
    models = try await DiarizerModels.downloadIfNeeded()
} catch {
    print("FATAL: model download/load failed: \(error)")
    exit(1)
}
let modelWall = Date().timeIntervalSince(tModel0)
print(String(format: "    loaded in %.2fs (compilationDuration %.2fs)", modelWall, models.compilationDuration))
print("    models dir: \(DiarizerModels.defaultModelsDirectory().path)\n")

let diarizer = DiarizerManager()
diarizer.initialize(models: models)
print("    DiarizerManager.isAvailable = \(diarizer.isAvailable)\n")

// our own online clusterer, mirroring the Phase 6 Step 2 design (0.65)
var speakers = SpeakerManager(speakerThreshold: threshold)

// ---- load audio -------------------------------------------------------------
print("[load] decoding + resampling to 16k mono ...")
let tLoad0 = Date()
let samples: [Float]
do { samples = try loadMono16k(from: audioURL, maxSeconds: maxSeconds) }
catch { print("FATAL: audio load failed: \(error)"); exit(1) }
let loadWall = Date().timeIntervalSince(tLoad0)
let durSec = Double(samples.count) / sampleRate
print(String(format: "    %d samples = %.1fs of audio, decoded in %.2fs (resident %.0f MB)\n",
             samples.count, durSec, loadWall, residentMB()))

// ---- 2 + 3. windowed embeddings, timing, online clustering ------------------
struct Win { let startSec: Double; let emb: [Float]; let speakerId: String }
let winLen = Int(windowSec * sampleRate)
let strideLen = Int(strideSec * sampleRate)
var wins: [Win] = []
var extractMs: [Double] = []
var failures = 0
var start = 0
print("[2+3] extracting embeddings per \(windowSec)s window ...")
while start + winLen <= samples.count {
    let chunk = Array(samples[start..<(start + winLen)])
    let t0 = Date()
    do {
        let emb = try diarizer.extractSpeakerEmbedding(from: chunk)
        let ms = Date().timeIntervalSince(t0) * 1000.0
        extractMs.append(ms)
        let startSec = Double(start) / sampleRate
        if let spk = speakers.assignSpeaker(l2(emb), speechDuration: Float(windowSec)) {
            wins.append(Win(startSec: startSec, emb: l2(emb), speakerId: spk.id))
        } else {
            wins.append(Win(startSec: startSec, emb: l2(emb), speakerId: "(unassigned)"))
        }
    } catch {
        failures += 1
        if failures <= 3 { print("    window @\(Int(Double(start)/sampleRate))s extract failed: \(error)") }
    }
    start += strideLen
}
let peakMem = residentMB()
print(String(format: "    processed %d windows (%d extract failures)\n", wins.count, failures))

guard !extractMs.isEmpty else { print("FATAL: no embeddings extracted; cannot judge."); exit(1) }

// timing verdict
let medMs = median(extractMs), p95Ms = pct(extractMs, 0.95), maxMs = extractMs.max() ?? 0, minMs = extractMs.min() ?? 0
print("--- embedding extraction time (5s window) ---")
print(String(format: "    min %.1f ms | median %.1f ms | p95 %.1f ms | max %.1f ms", minMs, medMs, p95Ms, maxMs))
let timingPass = medMs < 500.0
print("    EXIT-2 (<500ms median): \(timingPass ? "PASS ✅" : "FAIL ❌")\n")

// ---- cluster distribution ---------------------------------------------------
var perSpeaker: [String: [Win]] = [:]
for w in wins { perSpeaker[w.speakerId, default: []].append(w) }
let ordered = perSpeaker.sorted { $0.value.count > $1.value.count }
print("--- online clustering @ threshold \(threshold) ---")
print("    distinct speakers: \(speakers.speakerCount)")
for (sid, ws) in ordered {
    let lo = ws.map(\.startSec).min() ?? 0, hi = ws.map(\.startSec).max() ?? 0
    print(String(format: "      %@: %3d windows, spanning %.0fs..%.0fs (%.1f min)",
                 sid, ws.count, lo, hi, (hi - lo) / 60.0))
}
print("")

// ---- 3. separability: within vs cross speaker similarity --------------------
func avgPairwise(_ embs: [[Float]]) -> Float? {
    guard embs.count >= 2 else { return nil }
    var sum: Float = 0; var n = 0
    for i in 0..<embs.count { for j in (i+1)..<embs.count { sum += cosine(embs[i], embs[j]); n += 1 } }
    return n > 0 ? sum / Float(n) : nil
}
// within: average over each speaker that has >=2 windows
var withinVals: [Float] = []
for (_, ws) in ordered where ws.count >= 2 {
    if let a = avgPairwise(ws.map(\.emb)) { withinVals.append(a) }
}
let withinAvg = withinVals.isEmpty ? Float.nan : withinVals.reduce(0,+) / Float(withinVals.count)
// cross: average cosine between centroids of different speakers
func centroid(_ embs: [[Float]]) -> [Float] {
    guard let first = embs.first else { return [] }
    var acc = [Float](repeating: 0, count: first.count)
    for e in embs { for i in 0..<acc.count { acc[i] += e[i] } }
    return l2(acc.map { $0 / Float(embs.count) })
}
let centroids = ordered.filter { $0.value.count >= 2 }.map { centroid($0.value.map(\.emb)) }
var crossVals: [Float] = []
for i in 0..<centroids.count { for j in (i+1)..<centroids.count { crossVals.append(cosine(centroids[i], centroids[j])) } }
let crossAvg = crossVals.isEmpty ? Float.nan : crossVals.reduce(0,+) / Float(crossVals.count)

print("--- separability (cosine; embeddings L2-normalized) ---")
print(String(format: "    within-speaker  avg similarity: %.3f", withinAvg))
print(String(format: "    cross-speaker   avg similarity: %.3f", crossAvg))
let gap = withinAvg - crossAvg
print(String(format: "    gap (within - cross)          : %.3f", gap))

// cross-minute stability for the dominant speaker: compare windows >5min apart
if let (domId, domWs) = ordered.first, domWs.count >= 2 {
    let early = domWs.filter { $0.startSec < 120 }
    let late  = domWs.filter { $0.startSec > 600 }
    if let e = early.first, let l = late.last {
        let sim = cosine(e.emb, l.emb)
        print(String(format: "    dominant speaker %@: window @%.0fs vs @%.0fs (%.1f min apart) similarity %.3f",
                     domId, e.startSec, l.startSec, (l.startSec - e.startSec)/60.0, sim))
    }
}
let sepPass = gap.isFinite && gap > 0.10 && withinAvg > crossAvg
print("    EXIT-3 (within > cross, gap > 0.10): \(sepPass ? "PASS ✅" : (gap.isFinite ? "WEAK ⚠️" : "N/A — only one speaker clustered"))\n")

// ---- 4. memory --------------------------------------------------------------
print("--- memory ---")
print(String(format: "    resident before models: %.0f MB | peak during run: %.0f MB | delta %.0f MB",
             memBefore, peakMem, peakMem - memBefore))
let memPass = peakMem < 4096
print("    EXIT-4 (peak < 4 GB): \(memPass ? "PASS ✅" : "FAIL ❌")\n")

// ---- summary ----------------------------------------------------------------
print("=== VERDICT ===")
print("  [2] timing      : \(timingPass ? "PASS" : "FAIL")  (median \(String(format: "%.0f", medMs))ms)")
print("  [3] separability: \(sepPass ? "PASS" : (gap.isFinite ? "WEAK" : "N/A"))  (gap \(String(format: "%.3f", gap)))")
print("  [4] memory      : \(memPass ? "PASS" : "FAIL")  (peak \(String(format: "%.0f", peakMem))MB)")
print("  [5] zero-network: run again with `lsof -a -p <pid> -i` / `nettop -P -p <pid>` — must be silent once cached")
print("\nModels cached at: \(DiarizerModels.defaultModelsDirectory().path)")
