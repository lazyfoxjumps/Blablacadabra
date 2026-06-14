import Foundation

/// Append-only diagnostics sink for speaker clustering. Off by default; wired up
/// only when the app's hidden `diagnosticsDiarizationLog` flag is set, so a live
/// call can record the REAL nearest-cluster similarity per utterance (codec +
/// noise included) instead of us tuning the merge `threshold` off the clean
/// Step 1 spike. Numbers only — span length, RMS, similarity, decision — never
/// any transcript text, so the log carries no speech content.
///
/// One line per finalized utterance, e.g.:
/// `2026-06-14T19:42:01Z  system  samples=22050 rms=0.041 sim=0.612 -> match:S2`
public final class DiarizationDiagnostics: @unchecked Sendable {
    private let url: URL
    private let label: String
    private let lock = NSLock()

    /// `label` tags which lane wrote the line ("single", "system"); the mic lane
    /// is pinned and never clusters, so it doesn't get a sink. Creates the parent
    /// directory if needed; a failure here is swallowed (diagnostics must never
    /// break a session).
    public init(url: URL, label: String) {
        self.url = url
        self.label = label
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func log(samples: Int, rms: Float, similarity: Float, decision: String) {
        let line = String(
            format: "%@  %@  samples=%d rms=%.4f sim=%.4f -> %@\n",
            Self.timestamp(), label, samples, rms, similarity, decision
        )
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func timestamp() -> String { formatter.string(from: Date()) }
}
