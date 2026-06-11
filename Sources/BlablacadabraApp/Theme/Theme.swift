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
    case system, atkinson, openDyslexic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .atkinson: return "Atkinson Hyperlegible"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    /// PostScript family name to look up; nil means the system font.
    var familyName: String? {
        switch self {
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

    static let vetted: [CaptionPreset] = [
        .theme,
        CaptionPreset(
            id: "palladian-abyssal", name: "Palladian on Abyssal",
            text: RGB(hexString: "#EEE9DF"), background: RGB(hexString: "#1B2632")),
        CaptionPreset(
            id: "oatmeal-abyssal", name: "Oatmeal on Abyssal",
            text: RGB(hexString: "#C9C1B1"), background: RGB(hexString: "#1B2632")),
        CaptionPreset(
            id: "palladian-blue", name: "Palladian on Blue Fantastic",
            text: RGB(hexString: "#EEE9DF"), background: RGB(hexString: "#2C3B4D")),
        CaptionPreset(
            id: "blue-paper", name: "Blue Fantastic on warm paper",
            text: RGB(hexString: "#2C3B4D"), background: RGB(hexString: "#F7F4EC")),
        CaptionPreset(
            id: "abyssal-palladian", name: "Abyssal on Palladian",
            text: RGB(hexString: "#1B2632"), background: RGB(hexString: "#EEE9DF")),
    ]
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
