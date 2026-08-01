// MARK: - Sections

/// The three ways to power Gizmate, as offered on the onboarding finale. Used
/// to float the picked group to the top of the Providers tab.
enum EngineSetupFocus: String, CaseIterable, Hashable {
    case local, subscription, apiKeys
}

/// Sidebar destinations. Related settings live together behind one entry with a
/// tab bar rather than as separate rows — `voice` covers how Gizmate writes plus
/// the words it reuses, `settings` behaviour plus hotkeys.
///
/// `home` **is** the ring: the ring is the app, so it takes the landing spot
/// rather than sitting in a tab of its own. The raw value stays `home` because
/// it is persisted as the restored selection — only the content changed.
enum MainWindowSection: String, CaseIterable, Identifiable, Hashable {
    case home, insights
    case voice
    case notes
    case settings, help

    var id: String { rawValue }

    static var primary: [MainWindowSection] {
        [.home, .notes, .voice, .insights]
    }
    static var secondary: [MainWindowSection] { [.settings, .help] }

    var title: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .voice: return "Voice"
        case .notes: return "Notes"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .insights: return "chart.bar"
        case .voice: return "textformat"
        case .notes: return "note.text"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}
