// MARK: - Sections

/// The three ways to power Gizmate, as offered on the onboarding finale. Used
/// to float the picked group to the top of the Providers tab.
enum EngineSetupFocus: String, CaseIterable, Hashable {
    case local, subscription, apiKeys
}

/// Sidebar destinations. Related settings live together behind one entry with a
/// tab bar rather than as separate rows — `voice` covers how Gizmate writes,
/// `library` the words it reuses, `settings` behaviour plus hotkeys.
enum MainWindowSection: String, CaseIterable, Identifiable, Hashable {
    case home, ring, insights
    case voice, library, aiEngine
    case settings, help

    var id: String { rawValue }

    static var primary: [MainWindowSection] {
        [.home, .ring, .insights, .voice, .library, .aiEngine]
    }
    static var secondary: [MainWindowSection] { [.settings, .help] }

    var title: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .ring: return "Ring"
        case .voice: return "Voice"
        case .library: return "Library"
        case .aiEngine: return "AI Engine"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .insights: return "chart.bar"
        case .ring: return "circle.hexagongrid"
        case .voice: return "textformat"
        case .library: return "books.vertical"
        case .aiEngine: return "cpu"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}
