import SwiftUI

struct DetailRouter: View {
    let section: MainWindowSection

    var body: some View {
        switch section {
        case .home: RingSection()
        case .insights: InsightsSection()
        case .voice: VoiceSection()
        case .notes: NotesSection()
        case .edges: EdgesSection()
        case .settings: SettingsSection()
        case .help: HelpSection()
        }
    }
}
