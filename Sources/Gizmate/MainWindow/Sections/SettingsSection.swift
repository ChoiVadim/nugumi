import SwiftUI

// MARK: - Settings

/// How Gizmate behaves while you work, the hotkeys that reach it, and the engine
/// behind it. All answer "how is this thing set up", so they share one sidebar
/// entry.
struct SettingsSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailContainer(
            "Settings",
            subtitle: subtitle,
            pinned: FlowTabBar(
                tabs: ["General", "Models", "Providers", "Shortcuts"],
                selection: $bridge.settingsTab
            ),
            accessory: bridge.settingsTab == 3
                ? AnyView(ResetDiscButton(accessibilityTitle: "Reset shortcuts to defaults") { bridge.perform(.resetShortcuts) })
                : nil
        ) {
            switch bridge.settingsTab {
            case 0: GeneralTab()
            case 1: ModelsTab()
            case 2: ProvidersTab()
            default: ShortcutsTab()
            }
        }
    }

    private var subtitle: String {
        switch bridge.settingsTab {
        case 0: return "How Gizmate shows up while you work."
        case 1: return "Which model does the thinking - and how hard."
        case 2: return "Where those models come from. Stored locally on this Mac."
        default: return "Global hotkeys that work from any app."
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    /// App-level hotkeys only. Everything a tool does is bound from that tool's
    /// own settings, so grouping by `ShortcutGroup` no longer buys anything —
    /// one card, one group.
    private var actions: [GlobalShortcutAction] {
        GlobalShortcutAction.allCases.filter { $0.group == .app }
    }

    var body: some View {
        SubCard {
            VStack(spacing: 18) {
                ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                    if index > 0 { Divider().background(FlowTheme.hairline) }
                    shortcutRow(action)
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: GlobalShortcutAction) -> some View {
        SettingRow(action.menuTitle) {
            HStack(spacing: 8) {
                KeyCap(text: bridge.settings.shortcut(for: action).displayString)
                SecondaryButton(title: "Change") {
                    bridge.perform(.recordShortcut(action))
                }
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: - General behaviour

private struct GeneralTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        Group {
            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Show button on selection",
                               subtitle: "Off means the ring only opens from the shortcut.") {
                        Toggle("", isOn: Binding(
                            get: { bridge.settings.selectionDisplayMode == .floatingBar },
                            set: { bridge.perform(.setSelectionDisplayMode($0 ? .floatingBar : .off)) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(FlowTheme.accent)
                    }
                }
            }

            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Launch at login",
                               subtitle: "Start Gizmate automatically when you log in to your Mac.") {
                        Toggle("", isOn: bridge.binding(\.launchAtLogin) { .setLaunchAtLogin($0) })
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(FlowTheme.accent)
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("Invisibility mode",
                               subtitle: "Hide Gizmate's windows from screen recording and screenshots.") {
                        Toggle("", isOn: Binding(
                            get: { bridge.settings.invisibilityEnabled },
                            set: { _ in bridge.perform(.toggleInvisibility) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(FlowTheme.accent)
                    }
                }
            }

            SubCard {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(dockableBuiltIns, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(FlowTheme.ink)
                            Text("Keep \(item.title) a hover away from the edge of your screen.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(FlowTheme.inkSecondary)
                            DockPlacementPicker(store: bridge.dock, itemID: item.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Built-ins only. A gizmo picks its edge in its own editor, next to
    /// everything else about it.
    ///
    /// Reads through `host` rather than the bridge: `DockCatalog` builds its
    /// items against the app itself, which outlives this window.
    private var dockableBuiltIns: [DockItem] {
        bridge.host.map { DockCatalog.builtIns(host: $0) } ?? []
    }
}

/// Free-text background about the user, appended to every prompt so answers
/// pick the meaning most relevant to them (e.g. "RLS" → Row-Level Security for
/// a developer). Written straight to UserDefaults — prompts read it at request
/// time, so no bridge state is involved.
struct AboutYouTab: View {
    @State private var draft = UserAboutContext.text

    var body: some View {
        Group {
            PageBanner(
                title: "Better answers, your context",
                message: "When a term has several meanings, Gizmate picks the one most relevant to you - \"RLS\" means row-level security to a developer, not a sleep disorder.",
                symbol: "person.crop.circle",
                dismissKey: "aboutYouBannerDismissed"
            )

            SubCard {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Who you are")
                            .font(FlowTheme.serif(19))
                            .foregroundStyle(FlowTheme.ink)

                        Text("A couple of sentences is plenty. Worth mentioning:")
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 12) {
                            hintRow("briefcase", "What you do - \"iOS developer\", \"nurse\", \"law student\".")
                            hintRow("wrench.and.screwdriver", "Tools and topics you live in - PostgreSQL, Figma, crypto.")
                            hintRow("sparkles", "Anything that shapes what you read and write every day.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(FlowTheme.hairline)
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Background")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FlowTheme.inkSecondary)

                        PlainTextEditor(text: $draft)
                            .frame(minHeight: 150, maxHeight: 280)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                if draft.isEmpty {
                                    Text("I'm a software developer at a fintech startup.\nI work with PostgreSQL, Swift, and TypeScript.\nOutside work I follow F1 and read about space.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(FlowTheme.inkTertiary.opacity(0.55))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.vertical, 9)
                                        .padding(.horizontal, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                            .onChange(of: draft) { _, newValue in
                                UserAboutContext.text = newValue
                            }

                        Text("\(draft.count) / \(UserAboutContext.maxLength)")
                            .font(.system(size: 11))
                            .foregroundStyle(draft.count > UserAboutContext.maxLength ? Color(red: 1.0, green: 0.62, blue: 0.62) : FlowTheme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func hintRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
