import SwiftUI

// MARK: - Help

struct HelpSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailContainer("Help", subtitle: "Setup, support, and housekeeping.") {
            SubCard {
                VStack(spacing: 16) {
                    HelpRow(title: "How to use Gizmate",
                            subtitle: "Permission setup and a quick feature tour.",
                            button: "Open") {
                        bridge.perform(.openPermissionsHelp)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Contact support",
                            subtitle: "Found a bug or have a request? Email Vadim.",
                            button: "Email") {
                        bridge.perform(.contactSupport)
                    }
                    if bridge.isAppBundle {
                        Divider().background(FlowTheme.hairline)
                        HelpRow(title: "Check for updates",
                                subtitle: "Currently on v\(bridge.appVersion).",
                                button: "Check") {
                            bridge.perform(.checkForUpdates)
                        }
                    }
                }
            }
            SubCard {
                VStack(spacing: 16) {
                    HelpRow(title: "Reset all settings",
                            subtitle: "Restore defaults. Snippets, dictionary, and stats are kept.",
                            button: "Reset",
                            destructive: true) {
                        bridge.perform(.resetSettings)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Quit Gizmate",
                            subtitle: "Close Gizmate completely.",
                            button: "Quit",
                            destructive: true) {
                        bridge.perform(.quit)
                    }
                }
            }
        }
    }
}

private struct HelpRow: View {
    let title: String
    let subtitle: String
    let button: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            SecondaryButton(title: button, destructive: destructive, minWidth: 76, action: action)
        }
    }
}
