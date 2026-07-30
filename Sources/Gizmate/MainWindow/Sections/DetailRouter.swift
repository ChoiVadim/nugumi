import SwiftUI

struct DetailRouter: View {
    let section: MainWindowSection

    var body: some View {
        switch section {
        case .home: HomeSection()
        case .insights: InsightsSection()
        case .ring: RingSection()
        case .voice: VoiceSection()
        case .library: LibrarySection()
        case .aiEngine: AIEngineSection()
        case .settings: SettingsSection()
        case .help: HelpSection()
        }
    }
}
