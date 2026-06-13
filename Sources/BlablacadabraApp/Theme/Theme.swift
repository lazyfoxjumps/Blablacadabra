import AppKit
import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case dark, light, sun, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .sun: return "Sun"
        case .system: return "System"
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case nunito, system, atkinson, openDyslexic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nunito: return "Nunito"
        case .system: return "System"
        case .atkinson: return "Atkinson Hyperlegible"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    /// Short label for pill chips (mockup style).
    var shortLabel: String {
        switch self {
        case .nunito: return "Nunito"
        case .system: return "System"
        case .atkinson: return "Hyperlegible"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    /// PostScript family name to look up; nil means the system font.
    var familyName: String? {
        switch self {
        case .nunito: return "Nunito"
        case .system: return nil
        case .atkinson: return "Atkinson Hyperlegible"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    var isInstalled: Bool {
        guard let familyName else { return true }
        return NSFontManager.shared.availableFontFamilies.contains(familyName)
    }

    /// SwiftUI font at the given size; quietly falls back to the system font
    /// when the family isn't installed.
    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        guard let familyName, isInstalled else {
            return .system(size: size, weight: weight, design: .rounded)
        }
        return .custom(familyName, size: size)
    }
}

/// A pre-vetted caption color combo (text on background). The "theme" preset
/// follows the resolved theme; custom uses the user's picked colors.
struct CaptionPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let text: RGB?
    let background: RGB?

    static let theme = CaptionPreset(id: "theme", name: "Theme default", text: nil, background: nil)
    static let custom = CaptionPreset(id: "custom", name: "Custom", text: nil, background: nil)

    /// One swatch per mood, all MP072, all >= 7:1 contrast so every preset
    /// passes the checker comfortably: soft dark, ember dark, paper light,
    /// flame card, stone card. Removed ids quietly fall back to theme default.
    static let vetted: [CaptionPreset] = [
        .theme,
        CaptionPreset(
            id: "oatmeal-abyssal", name: "Oatmeal on Abyssal",
            text: RGB(hexString: "#C9C1B1"), background: RGB(hexString: "#1B2632")),
        CaptionPreset(
            id: "flame-abyssal", name: "Burning Flame on Abyssal",
            text: RGB(hexString: "#FFB162"), background: RGB(hexString: "#1B2632")),
        CaptionPreset(
            id: "blue-paper", name: "Blue Fantastic on warm paper",
            text: RGB(hexString: "#2C3B4D"), background: RGB(hexString: "#F7F4EC")),
        CaptionPreset(
            id: "abyssal-flame", name: "Abyssal on Burning Flame",
            text: RGB(hexString: "#1B2632"), background: RGB(hexString: "#FFB162")),
        CaptionPreset(
            id: "abyssal-oatmeal", name: "Abyssal on Oatmeal",
            text: RGB(hexString: "#1B2632"), background: RGB(hexString: "#C9C1B1")),
    ]
}

/// Per-speaker caption foregrounds (Phase 6 diarization). Speaker 1 always
/// keeps the user's chosen caption text color, so turning the feature on
/// changes nothing until a second voice appears. Speakers 2+ draw from MP072
/// colors that both read clearly on the caption background AND look distinct
/// from each other and from Speaker 1.
///
/// Floor is 4.5:1 (WCAG AAA for LARGE text, which captions are: default 21pt,
/// well past the 18pt large-text bar). 7:1 is the AAA bar for *body* text; on
/// this warm, earthy six-color palette it leaves light mode with almost no
/// distinct foregrounds, so we use the (still strict) large-text AAA floor and
/// lean on the always-present chip as the real non-color signal. A short list
/// is fine: speakers past the distinct-color count reuse a color but keep a
/// unique chip ("S3", "S4", "S+").
enum SpeakerPalette {
    /// Minimum caption-background contrast for a speaker color (large-text AAA).
    static let contrastFloor: Double = 4.5
    /// Two colors closer than this (squared sRGB distance) read as "the same",
    /// so the later one is dropped (keeps Palladian/Oatmeal-style near-dupes and
    /// navy/near-black pairs from looking like one color with two chips).
    static let minDistanceSquared: Double = 0.05

    /// Candidate foregrounds, ordered for visual distinctness (warm orange,
    /// light cream, deep navy, rust, tan, near-black). All MP072.
    private static let candidates = [
        "#FFB162", // Burning Flame
        "#EEE9DF", // Palladian
        "#2C3B4D", // Blue Fantastic
        "#A35139", // Truffle Trouble
        "#C9C1B1", // Oatmeal
        "#1B2632", // Abyssal
    ]

    /// Ordered speaker foregrounds for the given caption colors. Index 0 is the
    /// user's text color (Speaker 1); indices 1+ are the vetted distinct colors.
    /// At least one entry (the base text) always comes back.
    static func colors(text: RGB, background: RGB) -> [RGB] {
        var chosen = [text]
        for hex in candidates {
            guard let candidate = RGB(hexString: hex) else { continue }
            guard RGB.contrast(candidate, background) >= contrastFloor else { continue }
            guard chosen.allSatisfy({ distanceSquared($0, candidate) >= minDistanceSquared }) else { continue }
            chosen.append(candidate)
        }
        return chosen
    }

    private static func distanceSquared(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return dr * dr + dg * dg + db * db
    }
}

/// Everything the overlay and settings need to draw for the current mode.
/// Dark: Abyssal deepest layers, Blue Fantastic surfaces, Palladian text,
/// Oatmeal secondary, Burning Flame the single accent. Light: warm paper
/// surfaces, Blue Fantastic text, Truffle accent on soft Flame tints.
struct ResolvedTheme {
    let isDark: Bool

    var captionText: RGB { isDark ? RGB(hexString: "#EEE9DF")! : RGB(hexString: "#2C3B4D")! }
    var captionBackground: RGB { isDark ? RGB(hexString: "#1B2632")! : RGB(hexString: "#F7F4EC")! }

    var surface: Color { isDark ? Palette.blueFantastic : Palette.warmPaper }
    var deepSurface: Color { isDark ? Palette.abyssal : Palette.palladian }
    var primaryText: Color { isDark ? Palette.palladian : Palette.blueFantastic }
    var secondaryText: Color { isDark ? Palette.oatmeal : Palette.blueFantastic.opacity(0.72) }
    /// The single accent: Burning Flame fills in dark mode; in light mode
    /// accent TEXT is Truffle (Flame on cream is unreadable) while fills stay
    /// Flame.
    var accentFill: Color { Palette.burningFlame }
    var accentText: Color { isDark ? Palette.burningFlame : Palette.truffleTrouble }
    var sliderTrack: Color { isDark ? Palette.abyssal : Palette.oatmeal }
    var sliderFill: Color { isDark ? Palette.burningFlame : Palette.truffleTrouble }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}
