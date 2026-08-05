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
/// `home` is the front door: every tool in one list, shipped actions and
/// generated gizmos together, each row saying where it lives. `ring` is the
/// radial menu on its own, split out from `home` by Task 4 of the navigation
/// restructure — before that, `home` rendered the ring directly. `home` keeps
/// its raw value regardless, because it is persisted as the restored
/// selection — a rename here silently drops every user on a different screen
/// than the one they left.
enum MainWindowSection: String, CaseIterable, Identifiable, Hashable {
    case home, insights
    case voice
    case notes, edges, ring
    case settings, help

    var id: String { rawValue }

    static var primary: [MainWindowSection] {
        [.home, .ring, .edges, .notes, .voice, .insights]
    }
    static var secondary: [MainWindowSection] { [.settings, .help] }

    var title: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .voice: return "Voice"
        case .notes: return "Notes"
        case .edges: return "Edges"
        case .ring: return "Ring"
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
        case .edges: return "rectangle.lefthalf.inset.filled"
        case .ring: return "circle.grid.cross"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}
