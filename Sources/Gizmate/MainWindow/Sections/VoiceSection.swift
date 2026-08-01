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
        case 0: return AnyView(genZToggle)
        case 3, 4:
            return AnyView(
                SecondaryButton(title: snippetKind == .snippet ? "Add snippet" : "Add word") {
                    isAddingNew = true
                }
            )
        default: return nil
        }
    }

    private var genZToggle: some View {
        HStack(spacing: 8) {
            Text("Gen Z")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.inkSecondary)
            Toggle("", isOn: bridge.binding(\.genZMode) { .setGenZMode($0) })
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
        }
        .help("works both ways 💀 your texts come out in gen z AND gizmate explains everything back to you in it too, zero unc energy anywhere")
    }
}

private struct StyleTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        Group {
            PageBanner(
                title: "Your voice, per place",
                message: "Gizmate picks a category automatically from the app you're in. Set the register for each below.",
                symbol: "textformat.alt"
            )

            ForEach(AppCategory.allCases.filter { $0 != .custom }, id: \.self) { category in
                StyleCard(category: category, selection: bridge.writingStyleBinding(category))
            }

            CustomStyleCard()

            SubCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow("Auto Cleanup",
                               subtitle: "How much Gizmate tidies the text it writes.") {
                        PillPicker(
                            options: CleanupLevel.allCases,
                            selection: bridge.binding(\.cleanupLevel) { .setCleanupLevel($0) },
                            label: { $0.displayName }
                        )
                    }
                    Divider().background(FlowTheme.hairline)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(bridge.settings.cleanupLevel.settingsDescription)
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        CleanupExample(level: bridge.settings.cleanupLevel)
                    }
                    .animation(.easeInOut(duration: 0.15), value: bridge.settings.cleanupLevel)
                }
            }
        }
    }
}

/// Friendly settings copy for cleanup levels — `promptDescription` is raw
/// prompt text and reads poorly in the UI.
private extension CleanupLevel {
    var settingsDescription: String {
        switch self {
        case .none: return "Keeps your phrasing exactly as written."
        case .light: return "Fixes typos and obvious grammar slips, nothing more."
        case .medium: return "Smooths awkward phrasing for clarity and flow."
        case .high: return "Polishes thoroughly - tight, clear sentences with no filler."
        }
    }

    /// One shared raw input across every level so switching the picker changes
    /// only the output — the clearest way to show what each level actually does.
    var example: (before: String, after: String) {
        let before = "i think we shoud meet tommorow if thats ok with u"
        switch self {
        case .none:   return (before, "i think we shoud meet tommorow if thats ok with u")
        case .light:  return (before, "I think we should meet tomorrow if that's ok with you.")
        case .medium: return (before, "I think we should meet tomorrow, if that works for you.")
        case .high:   return (before, "Let's meet tomorrow - does that work for you?")
        }
    }
}

/// Before → after demonstration for the selected Auto Cleanup level. The "after"
/// bubble is accent-tinted to read as Gizmate's output, mirroring the rewrite side
/// of the Style previews.
private struct CleanupExample: View {
    let level: CleanupLevel

    var body: some View {
        // Two columns split by a hairline, mirroring the Style cards' Preview | Apps layout.
        HStack(alignment: .top, spacing: 22) {
            row(label: "You typed", text: level.example.before, accent: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(FlowTheme.hairline)
                .frame(width: 1)
            row(label: "Gizmate writes", text: level.example.after, accent: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(label: String, text: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(FlowTheme.inkTertiary)
                .padding(.leading, 2)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(accent ? FlowTheme.ink : FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accent ? FlowTheme.accent.opacity(0.18) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(accent ? FlowTheme.accent.opacity(0.30) : FlowTheme.hairline, lineWidth: 1)
                )
        }
    }
}
