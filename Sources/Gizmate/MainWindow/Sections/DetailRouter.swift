import SwiftUI

struct DetailRouter: View {
    let section: MainWindowSection

    var body: some View {
        switch section {
        case .home: HomeSection()
        case .insights: InsightsSection()
        case .voice: VoiceSection()
        case .notes: NotesSection()
        case .edges: EdgesSection()
        case .ring: RingSection()
        case .settings: SettingsSection()
        case .help: HelpSection()
        }
    }
}
