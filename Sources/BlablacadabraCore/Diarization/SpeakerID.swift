import Foundation

/// A per-session speaker label attached to a caption line.
///
/// `.speaker(n)` is one of the first `maxSpeakers` distinct voices heard this
/// session: a small, stable, 1-based integer (Speaker 1, Speaker 2...). `.other`
/// is the overflow bucket: every voice beyond the cap shares it, because more
/// than a handful of distinct colors is cognitive load, not help (the ND rule).
///
/// Labels are session-scoped and never persisted: no voice prints touch disk
/// (Phase 6 keeps the privacy posture simple). A fresh session starts numbering
/// from Speaker 1 again.
public enum SpeakerID: Equatable, Hashable, Sendable {
    case speaker(Int)
    case other
}

extension SpeakerID {
    /// Short label for the leading caption chip ("S1", "S2"...). `.other` (the
    /// overflow bucket) reads "S+", so it's still a distinct, color-independent
    /// marker even when several voices share the overflow color.
    public var chipLabel: String {
        switch self {
        case .speaker(let n): return "S\(n)"
        case .other: return "S+"
        }
    }

    /// Full words for VoiceOver / hover ("Speaker 1"), the non-color signal the
    /// chip stands in for on screen (ND rule: never color alone).
    public var spokenLabel: String {
        switch self {
        case .speaker(let n): return "Speaker \(n)"
        case .other: return "Another speaker"
        }
    }
}
