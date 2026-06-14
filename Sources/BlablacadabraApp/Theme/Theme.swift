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
/// changes nothing until a second voice appears. Speakers 2+ draw from a pool
/// of colors that both read clearly on the caption background AND look distinct
/// from each other and from Speaker 1.
///
/// The six MP072 brand colors alone only yielded ~3 distinct foregrounds in
/// dark mode and ~2 in light (the earthy palette is mostly warm and clusters),
/// so the user approved (Phase 6 Step 4, "option B") extending it with a
/// companion palette they supplied — a cohesive blue + terracotta + cream/brown
/// set that still reads as the same brand family. The pool is ordered for
/// maximum perceptual SPREAD across the first speakers (not brand order), since
/// the feature is unreleased and has no live numbering to preserve: dark mode
/// resolves S2 orange, S3 sky blue, S4 terracotta; light mode S2 rust, S3 steel
/// blue, S4 dark brown. Dark yields 6 distinct foregrounds, light 4 (every
/// named speaker S1-S4 gets its own color; S+ reuses the last and is told apart
/// by its chip).
///
/// Contrast floor is 4.5:1 (WCAG AAA for LARGE text, which captions are:
/// default 21pt, well past the 18pt large-text bar). Distinctness uses OKLab
/// ΔE, not raw sRGB distance, because sRGB distance collapses all dark colors
/// near black (so it could never tell dark navy from dark brown in light mode).
/// The chip ("S1"/"S2"/"S+") remains the real non-color signal regardless.
enum SpeakerPalette {
    /// Minimum caption-background contrast for a speaker color (large-text AAA).
    static let contrastFloor: Double = 4.5
    /// Two colors closer than this (OKLab ΔE, perceptually uniform) read as
    /// "the same color", so the later one is dropped. ~0.085 sits comfortably
    /// past the just-noticeable threshold (~0.02), so every kept color looks
    /// clearly different to the eye in BOTH light and dark modes.
    static let minPerceptualDistance: Double = 0.085

    /// Candidate foregrounds, ordered for perceptual SPREAD across the first
    /// speakers (a mix of MP072 brand colors and the user-supplied companion
    /// palette: blues, terracotta, cream/brown — same brand family). Light tones
    /// read on the dark caption background; dark tones read on the light one;
    /// the filter walks this order and keeps whichever clear contrast and stay
    /// perceptually distinct, so the earliest, most-separated hues win the
    /// low speaker numbers.
    private static let candidates = [
        "#FFB162", // Burning Flame — dark S2 (orange)
        "#86ABCB", // Sky Blue — dark S3 (blue); deepened from the source #9BB8CB
                   // so it stays distinct from Oatmeal on the dark background
        "#A35139", // Truffle Trouble — light S2 (rust)
        "#D17953", // Terracotta — dark S4 (burnt orange)
        "#355A69", // Steel Blue — light S3
        "#5D4239", // Dark Brown — light S4
        "#AF9B8C", // Taupe — dark S5
        "#C9C1B1", // Oatmeal — dark S+ overflow
        "#032B41", // Deep Navy
        "#F0E0C3", // Cream
        "#EEE9DF", // Palladian
        "#2C3B4D", // Blue Fantastic
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
            guard chosen.allSatisfy({ RGB.perceptualDistance($0, candidate) >= minPerceptualDistance }) else { continue }
            chosen.append(candidate)
        }
        return chosen
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
