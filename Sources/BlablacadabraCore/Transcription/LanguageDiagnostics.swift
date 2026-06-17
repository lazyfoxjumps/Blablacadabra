import Foundation

/// Opt-in diagnostics for the "locked language X, captions come out in language
/// Y" class of bug. OFF by default; only writes when the hidden
/// `diagnosticsLanguageLog` UserDefault is set. Records, per finalized decode,
/// the language we FORCED on Whisper versus the dominant Unicode SCRIPT Whisper
/// actually emitted. The script (not the text) is the whole signal: if we force
/// `ko` and the output is Japanese script, the model drifted off the lock.
///
/// Privacy: the transcript text is NEVER written — only its script category and
/// character length. So the log carries no speech content, same bar as
/// `DiarizationDiagnostics`.
///
/// One line per decode, e.g.:
/// `2026-06-17T18:20:01Z  model=large-v3…turbo task=transcribe forced=ko script=japanese len=11`
public enum LanguageDiagnostics {
    /// Dominant writing system of a string, classified just finely enough to
    /// tell the confusable cases apart (Korean Hangul vs Japanese kana/kanji vs
    /// Chinese Han vs Latin). Japanese is detected by the presence of kana even
    /// when kanji (shared Han) dominate, so it's never misread as Chinese.
    public enum Script: String {
        case korean, japanese, chinese, latin, cyrillic, arabic, other, empty
    }

    public static func script(of text: String) -> Script {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        var hangul = 0, kana = 0, han = 0, latin = 0, cyrillic = 0, arabic = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF: kana += 1          // hiragana + katakana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1           // CJK ideographs
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0600...0x06FF: arabic += 1
            default: break
            }
        }
        // Kana presence is the decisive Japanese marker (kanji alone could be
        // Chinese; kana never is).
        if kana > 0 { return .japanese }
        let scores: [(Script, Int)] = [
            (.korean, hangul), (.chinese, han), (.latin, latin),
            (.cyrillic, cyrillic), (.arabic, arabic),
        ]
        guard let top = scores.max(by: { $0.1 < $1.1 }), top.1 > 0 else { return .other }
        return top.0
    }

    private static let lock = NSLock()
    private static let logURL: URL? = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/Blablacadabra/language.log")

    /// Records one decode if the diagnostic flag is on. `forced` is the language
    /// code we passed to Whisper (nil = none / auto). No-op when the flag is off.
    public static func record(model: String, task: TranscriptionTask, forced: String?, text: String) {
        guard UserDefaults.standard.bool(forKey: "diagnosticsLanguageLog"), let url = logURL else { return }
        let line = String(
            format: "%@  model=%@ task=%@ forced=%@ script=%@ len=%d\n",
            timestamp(), model, task.rawValue, forced ?? "auto",
            script(of: text).rawValue, text.count
        )
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func timestamp() -> String { formatter.string(from: Date()) }
}
