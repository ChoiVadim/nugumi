import AppKit
import Combine
import GizmateToolAgentCore
import SwiftUI

// MARK: - Bridge (ObservableObject the SwiftUI tree binds to)

@MainActor
final class GizmateSettingsBridge: ObservableObject {
    weak var host: (any SettingsHost)?
    let usageStats: UsageStatsStore
    let snippets: SnippetsStore
    let tools: ToolsStore
    let ringLayout: RingLayoutStore
    let history: TranslationHistoryStore

    @Published var section: MainWindowSection = .home
    /// Active tab inside the AI Engine section (0 = Models, 1 = Providers).
    /// Programmatic "go set up a provider" deep links set this to 1.
    @Published var aiEngineTab: Int = 0
    /// Active tab inside Voice (0 = Style, 1 = Languages, 2 = About you).
    @Published var voiceTab: Int = 0
    /// Active tab inside Library (0 = Dictionary, 1 = Snippets).
    @Published var libraryTab: Int = 0
    /// Active tab inside Settings (0 = General, 1 = Shortcuts).
    @Published var settingsTab: Int = 0
    /// Engine picked on the onboarding finale — that group's card leads the
    /// Providers tab. `nil` keeps the default order.
    @Published var engineSetupFocus: EngineSetupFocus?
    /// Non-nil while the "Choose a model" picker is open. Lives here (not in the
    /// section view) so the scrim is rendered at the window root and dims the
    /// sidebar too — a panel-scoped overlay can't paint past the detail column.
    @Published var modelPickerScope: ModelUseScope?
    /// Non-nil while the Ring tab's slot picker or prompt-tool editor is open.
    /// Same reason as `modelPickerScope`: the scrim belongs at the window root.
    @Published var ringSheet: RingSheet?
    @Published private(set) var settings: SettingsSnapshot
    @Published private(set) var bootstrap: BootstrapState
    /// True when a background check has found an update — drives the sidebar
    /// download badge. Mirrors `host.availableUpdateVersion != nil`.
    @Published private(set) var updateAvailable: Bool

    let ollamaModels: [OllamaModelOption]

    private var modelListObservers: [NSObjectProtocol] = []

    init(host: any SettingsHost) {
        self.host = host
        self.usageStats = host.usageStats
        self.snippets = host.snippets
        self.tools = host.tools
        self.ringLayout = host.ringLayout
        self.history = host.history
        self.settings = host.makeSettingsSnapshot()
        self.bootstrap = host.bootstrapState
        self.ollamaModels = host.ollamaModels
        self.updateAvailable = host.availableUpdateVersion != nil

        // Re-render the model picker when live discovery updates either catalog.
        for name in [Notification.Name.ollamaModelsUpdated, .codexModelsUpdated, .cloudModelsUpdated] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.objectWillChange.send()
            }
            modelListObservers.append(token)
        }

        let updateToken = NotificationCenter.default.addObserver(
            forName: .updateAvailabilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Posted on the main queue, so we're already on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateAvailable = self.host?.availableUpdateVersion != nil
            }
        }
        modelListObservers.append(updateToken)
    }

    deinit {
        modelListObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Re-read from the host. Called after every `perform`, and externally by the
    /// host when settings change from elsewhere (async credential save, reset,
    /// bootstrap readiness).
    func refreshFromHost() {
        guard let host else { return }
        settings = host.makeSettingsSnapshot()
        bootstrap = host.bootstrapState
    }

    /// Run a connectivity test for a cloud provider and return the result so the
    /// caller can surface it inline.
    func testCloud(_ provider: CloudProvider) async -> CloudTestResult {
        guard let host else { return .failure("Not available.") }
        return await host.runCloudTest(for: provider)
    }

    func perform(_ intent: SettingsIntent) {
        host?.performSettingsIntent(intent)
        refreshFromHost()
    }

    // Convenience bindings -----------------------------------------------------

    func binding<T: Equatable>(
        _ keyPath: KeyPath<SettingsSnapshot, T>,
        _ intent: @escaping (T) -> SettingsIntent
    ) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                guard newValue != self.settings[keyPath: keyPath] else { return }
                self.perform(intent(newValue))
            }
        )
    }

    func writingStyleBinding(_ category: AppCategory) -> Binding<WritingStyle> {
        Binding(
            get: { self.settings.writingStyle(for: category) },
            set: { self.perform(.setWritingStyle($0, category)) }
        )
    }

    func thinkingBinding(_ scope: ModelUseScope) -> Binding<ThinkingLevel> {
        Binding(
            get: { self.settings.thinkingLevel(for: scope) },
            set: { self.perform(.setThinkingLevel($0, scope)) }
        )
    }

    func hasCredentials(_ provider: CloudProvider) -> Bool {
        host?.cloudProviderHasCredentials(provider) ?? false
    }
    var uvReady: Bool { host?.uvIsReady ?? false }
    func testScriptTool(
        _ tool: GizmateTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState {
        guard let host else { return .failed("Not available.") }
        return await host.testScriptTool(tool, script: script, onOutput: onOutput)
    }
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        guard let host else { return .failure(ToolGeneratorError.emptyDescription) }
        return await host.generateScriptTool(
            description: description,
            onPartial: onPartial,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )
    }
    func reviseScriptTool(
        tool: GizmateTool,
        script: String,
        instruction: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        guard let host else { return .failure(ToolGeneratorError.emptyDescription) }
        return await host.reviseScriptTool(
            tool: tool,
            script: script,
            instruction: instruction,
            onPartial: onPartial,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )
    }
    func repairScriptTool(
        tool: GizmateTool,
        script: String,
        failure: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        guard let host else { return .failure(ToolGeneratorError.emptyDescription) }
        return await host.repairScriptTool(
            tool: tool,
            script: script,
            failure: failure,
            onPartial: onPartial,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )
    }
    var appVersion: String { host?.appVersionString ?? "" }
    var isAppBundle: Bool { host?.isAppBundle ?? false }
    func installUpdate() { host?.installAvailableUpdate() }
}

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

// MARK: - Window

@MainActor
final class MainWindow: NSWindow {
    // Transparent-titlebar windows swallow Cmd+A/C/V/X before SwiftUI TextFields
    // see them. Re-dispatch to the first responder, mirroring SnippetsWindow.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            super.sendEvent(event)
            return
        }
        let selector: Selector?
        switch key {
        case "a": selector = #selector(NSText.selectAll(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        default: selector = nil
        }
        guard let selector else {
            super.sendEvent(event)
            return
        }
        if let responder = firstResponder, responder.responds(to: selector) {
            responder.perform(selector, with: self)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let bridge: GizmateSettingsBridge
    private let onClose: () -> Void

    init(host: any SettingsHost, onClose: @escaping () -> Void) {
        self.bridge = GizmateSettingsBridge(host: host)
        self.onClose = onClose

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // Deliberately NOT movable by its background: a press anywhere in the
        // content would start dragging the window, which is the same press the
        // Ring uses to carry a button to another slot. `WindowDragStrip` puts
        // the drag back where it belongs — the header, alongside the traffic
        // lights.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 720)
        window.setFrameAutosaveName("GizmateMainWindowV5")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        // Programmatic windows don't auto-restore from the autosave name — do it
        // explicitly. Center only when there's no remembered frame (first launch).
        if !window.setFrameUsingName("GizmateMainWindowV5") {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        // Liquid-glass backdrop: everything that isn't the black settings card
        // shows this translucent material (the same look as the status-bar menu).
        let root = MainWindowRootView().environmentObject(bridge)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The window's frame is authoritative — don't let tall SwiftUI content
        // (e.g. Insights' fixed cards) push the window past its set size and off-screen.
        hosting.sizingOptions = []

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop

        // Respect invisibility mode before the window is ever shown.
        InvisibilityState.apply(to: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndFocus(section: MainWindowSection? = nil) {
        if let section { bridge.section = section }
        // Re-detect engine health (not just copy cached state) so the setup card
        // is current — e.g. Ollama uninstalled / its server stopped since launch.
        bridge.host?.refreshBootstrap()
        bridge.refreshFromHost()
        bridge.usageStats.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up changes made elsewhere (e.g. the status-bar menu, or Ollama
        // being quit/uninstalled) while away — re-detect, then sync the UI.
        bridge.host?.refreshBootstrap()
        bridge.refreshFromHost()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.onClose() }
    }
}

// MARK: - Root view

struct MainWindowRootView: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 256)
                .frame(maxHeight: .infinity)
            DetailRouter(section: bridge.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The header is the whole window's drag handle now, so the content below
        // it is free to use presses for its own purposes. It goes on before the
        // panels, which cover the window while they are up and take the top
        // band with it.
        .overlay(alignment: .top) {
            WindowDragStrip().frame(height: WindowDragStrip.height)
        }
        .overlay {
            if let scope = bridge.modelPickerScope {
                ModelPickerOverlay(
                    scope: scope,
                    onDismiss: { bridge.modelPickerScope = nil },
                    onChoose: { id in
                        bridge.modelPickerScope = nil
                        bridge.perform(.chooseModel(id, scope))
                    }
                )
            }
        }
        .overlay {
            if let sheet = bridge.ringSheet {
                RingSheetOverlay(sheet: sheet)
            }
        }
    }
}

/// The strip of window across the top — the band the traffic lights sit in.
/// Pressing it drags the window, the way pressing a title bar does; everything
/// else is left to the content underneath.
private struct WindowDragStrip: NSViewRepresentable {
    /// A standard title bar's height. The sidebar and every detail card already
    /// keep their contents clear of it.
    static let height: CGFloat = 28

    func makeNSView(context: Context) -> NSView { DragStripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragStripView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        /// Dragging an inactive window shouldn't cost a click to focus it first.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Claims presses and nothing else. Scrolling with the pointer up here,
        /// or hovering something that peeks into the strip, still reaches
        /// whatever is underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandHeader
                .padding(.horizontal, 6)
                .padding(.bottom, 20)

            ForEach(MainWindowSection.primary) { NavItem(section: $0) }

            Spacer(minLength: 16)

            Divider().background(FlowTheme.hairline).padding(.vertical, 6)
            ForEach(MainWindowSection.secondary) { NavItem(section: $0) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 30)   // clear the traffic lights
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(nsImage: Self.brandIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 32, height: 32)
            // "Gizmate" with a small round β badge raised like a superscript.
            HStack(alignment: .top, spacing: 1) {
                Text("Gizmate")
                    .font(.gizmatePixel(18))
                    .foregroundStyle(.white)
                    .fixedSize()
                Text("β")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(FlowTheme.accent)
                    .offset(y: -2)
            }
            Spacer(minLength: 0)
            if bridge.updateAvailable {
                Button(action: { bridge.installUpdate() }) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(FlowTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Update available - click to install")
            }
        }
        .frame(height: 34)
    }

    private static let brandIcon: NSImage = BrandMark.trimmedIcon ?? NSApp.applicationIconImage
}

struct NavItem: View {
    let section: MainWindowSection
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        let isSelected = bridge.section == section
        Button {
            bridge.section = section
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color(white: 0.82))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? FlowTheme.selected : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? FlowTheme.hairline : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reusable building blocks

/// The floating rounded card (dark menu material) that every section sits in.
/// No scroll of its own — sections decide what scrolls.
struct DetailCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                VisualEffectBackground(material: .menu)
                    .overlay(Color.black.opacity(0.26))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FlowTheme.hairline, lineWidth: 1)
            )
            .padding(EdgeInsets(top: 28, leading: 10, bottom: 16, trailing: 16))
    }
}

/// A scrolling "page": serif title + content, all scrolling together. Sections
/// that need a pinned header use `DetailCard` directly instead.
struct DetailContainer<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Optional control pinned to the header's top-right (e.g. an Add button).
    var accessory: AnyView?
    /// Optional control pinned below the header, above the scroll area (e.g. a
    /// tab bar) — stays put while the content scrolls.
    var pinned: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = nil
        self.content = content
    }

    init<Accessory: View>(
        _ title: String,
        subtitle: String? = nil,
        accessory: Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = AnyView(accessory)
        self.content = content
    }

    init<Pinned: View>(
        _ title: String,
        subtitle: String? = nil,
        pinned: Pinned,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = nil
        self.pinned = AnyView(pinned)
        self.content = content
    }

    /// Tabbed section whose header button belongs to the selected tab — pass
    /// `nil` for tabs that have no button of their own.
    init<Pinned: View>(
        _ title: String,
        subtitle: String? = nil,
        pinned: Pinned,
        accessory: AnyView?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.pinned = AnyView(pinned)
        self.content = content
    }

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 0) {
                // Pinned header — only the content below scrolls.
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(FlowTheme.serif(30))
                            .foregroundStyle(FlowTheme.ink)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(FlowTheme.inkSecondary)
                        }
                    }
                    if let accessory {
                        Spacer(minLength: 12)
                        accessory.padding(.top, 6)
                    }
                }
                .padding(.horizontal, 38)
                .padding(.top, 38)
                .padding(.bottom, 20)

                if let pinned {
                    pinned
                        .padding(.horizontal, 38)
                        .padding(.bottom, 16)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        content()
                    }
                    .padding(.horizontal, 38)
                    .padding(.bottom, 38)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScrollerConfigurator())
                }
            }
        }
    }
}

/// A bordered sub-panel inside a page.
struct SubCard<Content: View>: View {
    var padding: CGFloat = 20
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(FlowTheme.hairline, lineWidth: 1)
            )
    }
}

/// The dark promo strip Flow shows at the top of each page.
struct PageBanner: View {
    let title: String
    let message: String
    var symbol: String = "sparkles"

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(FlowTheme.serif(22))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [FlowTheme.accent.opacity(0.32), FlowTheme.accent.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
    }
}

/// Custom Flow-style segmented control (capsule pills).
struct PillPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : FlowTheme.inkSecondary)
                        // Pills never wrap — "Floating bar" stays on one line
                        // even at the window's minimum width.
                        .fixedSize()
                        .padding(.vertical, 6)
                        .padding(.horizontal, 13)
                        .frame(minWidth: 78)
                        .background(
                            // The selected pill is a sheet lifted off the track,
                            // not a painted slab: a thin veil, a lit top edge and
                            // a short shadow. That reads as depth while leaving
                            // the label at full white-on-dark contrast.
                            Capsule()
                                .fill(isSelected ? FlowTheme.raised : Color.clear)
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected ? FlowTheme.edge : Color.clear,
                                        lineWidth: 1
                                    )
                                )
                                .shadow(
                                    color: .black.opacity(isSelected ? 0.28 : 0),
                                    radius: 3,
                                    y: 1
                                )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(FlowTheme.recess))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(FlowTheme.serif(28, weight: .medium))
                .foregroundStyle(accent ? FlowTheme.accent : FlowTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }
}

/// A label + trailing control row.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A GitHub-style activity calendar that fills the available width: weekday
/// labels down the left, square cells sized to the card, and a Less–More legend.
struct ActivityHeatmap: View {
    let weeks: [[UsageStatsDayBucket]]

    private let spacing: CGFloat = 5
    private let labelWidth: CGFloat = 22
    @State private var availableWidth: CGFloat = 0

    private var maxWords: Int { max(1, weeks.flatMap { $0 }.map(\.wordCount).max() ?? 1) }
    private var columns: Int { max(weeks.count, 1) }
    private var cell: CGFloat {
        guard availableWidth > 0 else { return 18 }
        let usable = availableWidth - labelWidth - spacing * CGFloat(columns)
        return max(14, min(36, usable / CGFloat(columns)))
    }
    private var gridHeight: CGFloat { cell * 7 + spacing * 6 }
    private var weekdayLabels: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(alignment: .top, spacing: spacing) {
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(weekdayLabels[row])
                                .font(.system(size: 9))
                                .foregroundStyle(FlowTheme.inkTertiary)
                                .frame(width: labelWidth, height: cell, alignment: .leading)
                        }
                    }
                    HStack(spacing: spacing) {
                        ForEach(weeks.indices, id: \.self) { column in
                            VStack(spacing: spacing) {
                                ForEach(weeks[column]) { bucket in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(fill(for: bucket))
                                        .frame(width: cell, height: cell)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(bucket.isToday ? FlowTheme.accent : .clear, lineWidth: 1.5)
                                        )
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .onAppear { availableWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newValue in availableWidth = newValue }
            }
            .frame(height: gridHeight)

            HStack(spacing: 5) {
                Text("Less").font(.system(size: 10)).foregroundStyle(FlowTheme.inkTertiary)
                ForEach(Array([0.12, 0.35, 0.58, 0.8, 1.0].enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FlowTheme.accent.opacity(value))
                        .frame(width: 11, height: 11)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(FlowTheme.inkTertiary)
            }
        }
    }

    private func fill(for bucket: UsageStatsDayBucket) -> Color {
        guard bucket.wordCount > 0 else { return Color.white.opacity(0.06) }
        let intensity = min(1.0, 0.2 + 0.8 * Double(bucket.wordCount) / Double(maxWords))
        return FlowTheme.accent.opacity(intensity)
    }
}
