import CoreText
import SwiftUI

/// Blablacadabra typography, mirroring sibling app Loft Hours:
/// - **Nunito** (OFL, bundled) is the body face: labels, copy, controls.
/// - **Jua** (OFL, bundled) is the display face for headings only: window
///   titles, section openers, the welcome tagline.
/// SF Symbols and the system font remain for symbol glyphs. If a bundled font
/// fails to register, `Font.custom` falls back to the system font, so text
/// never disappears.
enum AppFont {
    static func nunito(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Nunito", size: size).weight(weight)
    }

    /// Jua only ships one weight; size carries the hierarchy.
    static func jua(_ size: CGFloat) -> Font {
        .custom("Jua", size: size)
    }

    // Headings (Jua)
    /// The big lowercase "blablacadabra" wordmark on the welcome card.
    static let appName = jua(31)
    static let windowTitle = jua(20)
    static let sectionHeading = jua(19)
    static let stepTitle = jua(18)

    // Body (Nunito)
    static let body = nunito(13)
    static let bodyMedium = nunito(13, .semibold)
    static let detail = nunito(12)
    static let footnote = nunito(11)
    static let control = nunito(12.5, .semibold)

    /// Registers the bundled fonts for this process. ATSApplicationFontsPath
    /// covers the .app bundle, but registering directly also makes dev runs
    /// (`swift run`, bare binary) render correctly.
    static func registerBundledFonts() {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("Fonts", isDirectory: true))
        }
        // Dev fallback: repo Resources/Fonts next to the built binary's package root.
        let repoFonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Theme
            .deletingLastPathComponent() // BlablacadabraApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/Fonts", isDirectory: true)
        dirs.append(repoFonts)

        let fm = FileManager.default
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
