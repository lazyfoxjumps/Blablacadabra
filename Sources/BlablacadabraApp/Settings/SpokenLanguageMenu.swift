import BlablacadabraCore
import SwiftUI

/// Dropdown for picking the spoken language, or leaving it on auto-detect.
/// Used both in Settings and as the clickable chip on the caption overlay, so
/// the caller supplies the label view and styles it to match its surroundings
/// (theme text in Settings, caption text on the overlay).
///
/// A locked language is the fix for misdetection: when set, the engine stops
/// guessing the language per utterance (which flip-flops on short or ambiguous
/// audio) and decodes everything as the chosen language.
struct SpokenLanguageMenu<Label: View>: View {
    /// nil = auto-detect; otherwise an ISO 639-1 code.
    @Binding var selection: String?
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                row("Auto-detect", checked: selection == nil)
            }
            Divider()
            ForEach(SpokenLanguage.pickerList, id: \.code) { item in
                Button {
                    selection = item.code
                } label: {
                    row(item.name, checked: selection == item.code)
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func row(_ title: String, checked: Bool) -> some View {
        if checked {
            SwiftUI.Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
