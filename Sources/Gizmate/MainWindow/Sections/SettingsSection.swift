import SwiftUI

// MARK: - Settings

/// How Gizmate behaves while you work, plus the hotkeys that reach it. Both
/// answer "how is this thing set up", so they share one sidebar entry.
struct SettingsSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailContainer(
            "Settings",
            subtitle: bridge.settingsTab == 0
                ? "How Gizmate shows up while you work."
                : "Global hotkeys that work from any app.",
            pinned: FlowTabBar(tabs: ["General", "Shortcuts"], selection: $bridge.settingsTab),
            accessory: bridge.settingsTab == 1
                ? AnyView(ResetDiscButton(accessibilityTitle: "Reset shortcuts to defaults") { bridge.perform(.resetShortcuts) })
                : nil
        ) {
            if bridge.settingsTab == 0 {
                GeneralTab()
            } else {
                ShortcutsTab()
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    /// Actions bucketed into their display groups, preserving allCases order
    /// within each group.
    private var groups: [(group: ShortcutGroup, actions: [GlobalShortcutAction])] {
        ShortcutGroup.allCases.compactMap { group in
            let actions = GlobalShortcutAction.allCases.filter { $0.group == group }
            return actions.isEmpty ? nil : (group, actions)
        }
    }

    var body: some View {
        Group {
            ForEach(groups, id: \.group) { group, actions in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .padding(.leading, 4)
                    SubCard {
                        VStack(spacing: 18) {
                            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                                if index > 0 { Divider().background(FlowTheme.hairline) }
                                shortcutRow(action)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: GlobalShortcutAction) -> some View {
        SettingRow(action.menuTitle) {
            HStack(spacing: 8) {
                KeyCap(text: bridge.settings.shortcut(for: action).displayString)
                // Ask Gizmate also fires on a fixed ⌃⌥A alias — shown muted since
                // "Change" only rebinds the primary (double-tap ⌃) shortcut.
                if action == .askGizmate {
                    KeyCap(text: GlobalShortcutAction.askGizmateAlias.displayString, muted: true)
                }
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
                    SettingRow("Main mode",
                               subtitle: "What the floating button and pet do on a single click.") {
                        PillPicker(options: [.translate, .smartReply],
                                   selection: bridge.binding(\.floatingDefaultMode) { .setFloatingDefaultMode($0) },
                                   label: { $0 == .translate ? "Translate" : "Reply" })
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("On selection",
                               subtitle: "What appears when you select text.") {
                        PillPicker(options: SelectionDisplayMode.allCases,
                                   selection: bridge.binding(\.selectionDisplayMode) { .setSelectionDisplayMode($0) },
                                   label: { $0.menuTitle })
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
        }
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
                symbol: "person.crop.circle"
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
