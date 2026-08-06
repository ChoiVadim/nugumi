import SwiftUI

/// How Gizmate sounds: the register it writes in, the languages it answers in,
/// the background it keeps about you, and the words it reuses. One sidebar entry.
struct VoiceSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// Owned here, not in `SnippetsList`, because the "Add" button that flips it
    /// lives in the section header alongside the tab bar.
    @State private var isAddingNew = false

    private var snippetKind: SnippetKind { bridge.voiceTab == 4 ? .snippet : .dictionaryTerm }

    var body: some View {
        DetailContainer(
            "Voice",
            subtitle: subtitle,
            pinned: FlowTabBar(
                tabs: ["Style", "Languages", "About you", "Dictionary", "Snippets"],
                selection: tabSelection
            ),
            accessory: accessory
        ) {
            switch bridge.voiceTab {
            case 0: StyleTab()
            case 1: LanguagesTab()
            case 2: AboutYouTab()
            default:
                SnippetsList(store: bridge.snippets, kind: snippetKind, isAddingNew: $isAddingNew)
                    // Fresh identity per tab so a row left open for editing in one
                    // list doesn't reappear as an open editor in the other.
                    .id(snippetKind)
            }
        }
    }

    /// Switching tabs abandons a half-written new entry rather than carrying
    /// the open editor across to the other list.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { bridge.voiceTab },
            set: { bridge.voiceTab = $0; isAddingNew = false }
        )
    }

    private var subtitle: String {
        switch bridge.voiceTab {
        case 3: return "Words and names Gizmate keeps exactly as written."
        case 4: return "Short phrases Gizmate expands before rewriting."
        default: return "How Gizmate sounds when it writes for you."
        }
    }

    private var accessory: AnyView? {
        switch bridge.voiceTab {
        case 3, 4:
            let label = snippetKind == .snippet ? "Add snippet" : "Add word"
            return AnyView(
                ResetDiscButton(symbol: "plus", label: label, accessibilityTitle: label) {
                    isAddingNew = true
                }
            )
        default: return nil
        }
    }
}

private struct StyleTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        Group {
            ForEach(AppCategory.allCases, id: \.self) { category in
                StyleCard(category: category, selection: bridge.writingStyleBinding(category))
            }
        }
    }
}
