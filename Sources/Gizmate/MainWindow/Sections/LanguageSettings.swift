import SwiftUI

struct LanguagesTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        Group {
            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Reading language",
                               subtitle: "Selected text or a screen area renders into this language.") {
                        LanguageMenu(current: bridge.settings.targetLanguage) {
                            bridge.perform(.setTargetLanguage($0))
                        }
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("Writing language",
                               subtitle: "Rewriting your own draft produces this language.") {
                        LanguageMenu(current: bridge.settings.draftTargetLanguage) {
                            bridge.perform(.setDraftTargetLanguage($0))
                        }
                    }
                }
            }

            SubCard {
                SettingRow("Quick switch",
                           subtitle: "Press \(bridge.settings.shortcut(for: .toggleWritingLanguage).displayString) anywhere to flip the writing language with this one.") {
                    HStack(spacing: 10) {
                        LanguageMenu(current: bridge.settings.writingToggleAlternate) {
                            bridge.perform(.setWritingToggleAlternate($0))
                        }
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FlowTheme.inkTertiary)
                        // The other side is fixed to the live writing language —
                        // read-only target, no picker.
                        ReadOnlyField(text: bridge.settings.draftTargetLanguage.displayName)
                    }
                }
            }
        }
    }
}

private struct LanguageMenu: View {
    let current: TranslationLanguage
    let onSelect: (TranslationLanguage) -> Void

    var body: some View {
        Menu {
            ForEach(TranslationLanguage.all, id: \.id) { language in
                Button {
                    onSelect(language)
                } label: {
                    if language.id == current.id {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            MenuFieldLabel(text: current.displayName)
        }
        .menuStyle(.borderlessButton)
        .cursor(.pointingHand)
        .fixedSize()
    }
}
