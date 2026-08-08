import GizmateToolAgentCore

// MARK: - Settings snapshot (reads)

/// Plain value-type mirror of every window-configurable setting. The host builds
/// one cheaply from UserDefaults; the bridge re-reads it after each mutation.
struct SettingsSnapshot {
    var targetLanguage: TranslationLanguage
    var draftTargetLanguage: TranslationLanguage
    var writingToggleAlternate: TranslationLanguage
    var floatingDefaultMode: FloatingButtonDefaultMode
    var selectionDisplayMode: SelectionDisplayMode
    var invisibilityEnabled: Bool
    var launchAtLogin: Bool = false
    var writingStyles: [AppCategory: WritingStyle]
    var textModelID: String
    var askGizmateModelID: String
    var textThinkingLevel: ThinkingLevel
    var askGizmateThinkingLevel: ThinkingLevel
    var shortcuts: [GlobalShortcutAction: GlobalShortcut]
    var appsByCategory: [AppCategory: [AppRef]] = [:]

    func writingStyle(for category: AppCategory) -> WritingStyle {
        writingStyles[category] ?? category.defaultWritingStyle
    }
    func apps(for category: AppCategory) -> [AppRef] {
        appsByCategory[category] ?? []
    }
    func modelID(for scope: ModelUseScope) -> String {
        scope == .textActions ? textModelID : askGizmateModelID
    }
    func thinkingLevel(for scope: ModelUseScope) -> ThinkingLevel {
        scope == .textActions ? textThinkingLevel : askGizmateThinkingLevel
    }
    func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }
}

/// One app shown in a category's icon strip. `isBuiltIn` apps come from the
/// classifier's static map (removal suppresses them); others are user-added.
struct AppRef: Equatable, Hashable {
    let bundleID: String
    let name: String
    let isBuiltIn: Bool
}

// MARK: - Settings intents (writes with side effects)

/// Every write the window can make. The host routes each case through the SAME
/// code path the status-bar menu uses, so side effects (hotkey re-registration,
/// sharing-type, status icon, analytics, cache invalidation) fire identically.
enum SettingsIntent {
    case setTargetLanguage(TranslationLanguage)
    case setDraftTargetLanguage(TranslationLanguage)
    case setWritingToggleAlternate(TranslationLanguage)
    case setFloatingDefaultMode(FloatingButtonDefaultMode)
    case setSelectionDisplayMode(SelectionDisplayMode)
    case setWritingStyle(WritingStyle, AppCategory)
    case addAppToCategory(AppCategory)
    case removeApp(String)
    case setThinkingLevel(ThinkingLevel, ModelUseScope)
    case chooseModel(String, ModelUseScope)
    case toggleInvisibility
    case setLaunchAtLogin(Bool)
    case recordShortcut(GlobalShortcutAction)
    case resetShortcuts
    case signInCloud(CloudProvider)
    case signOutCloud(CloudProvider)
    case openOllamaInstall
    case launchOllama
    case openOllamaSignIn
    case refreshBootstrap
    case startModelPull(String)
    case cancelModelPull(String)
    case checkForUpdates
    case contactSupport
    case openPermissionsHelp
    case resetSettings
    case quit
}

// MARK: - Host

/// Implemented by `GizmateApp` in `GizmateApp+Settings.swift`.
@MainActor
protocol SettingsHost: AnyObject {
    func makeSettingsSnapshot() -> SettingsSnapshot
    func performSettingsIntent(_ intent: SettingsIntent)
    var usageStats: UsageStatsStore { get }
    var snippets: SnippetsStore { get }
    var notes: NotesStore { get }
    var tools: ToolsStore { get }
    var ringLayout: RingLayoutStore { get }
    var builtInOverrides: BuiltInOverridesStore { get }
    var dock: DockStore { get }
    var folderHub: FolderHubStore { get }
    /// Every gizmo being edited or built. On the host rather than the bridge
    /// because the bridge dies with the main window, and a build outliving that
    /// window is the point of moving it off a view in the first place.
    var gizmoBuilder: GizmoBuilder { get }
    /// The plain half of Home's chat. Owned here rather than by the section so
    /// leaving Home and coming back does not wipe what was said.
    var homeChat: ToolChatConversation { get }
    /// The one Ask conversation, shared by the capsule at the cursor and the
    /// docked chat. On `SettingsHost` rather than reached for through
    /// `GizmateSettingsBridge` for the reason every store here is: a dock
    /// outlives the main window by design.
    var askConversation: AskConversationStore { get }
    /// The last rows each surface gizmo's script printed. The dock draws
    /// from this the instant the pointer reaches the edge, before a refresh
    /// has had a chance to run.
    var surfaceRows: SurfaceRowsCache { get }
    /// Runs a surface gizmo's script because the pointer crossed a screen
    /// edge — never because the user pressed anything, so this can't ask for
    /// approval the way `runTool` can. An unapproved surface reports
    /// `.failed` instead of running; see `SurfaceRefresh`.
    func refreshSurface(_ tool: GizmateTool) async -> SurfaceRefreshOutcome
    /// Already implemented on `GizmateApp`; exposed so a docked gizmo's run
    /// button reaches the same path the Ring uses.
    func runTool(_ tool: GizmateTool, selection: String)
    /// The same, for the shipped actions.
    func performBuiltIn(_ id: RingActionID)
    /// Already implemented on `GizmateApp`; exposed here so a surface outside
    /// the main window (the dock) can lead back into it.
    func presentMainWindow(section: MainWindowSection?)
    /// Whether the uv runtime script tools need is present.
    var uvIsReady: Bool { get }
    /// Installs uv if needed, then runs `script` once on the current context and
    /// reports what happened — the editor's Install & test button. `onOutput`
    /// receives stdout/stderr as they arrive, so a long run isn't a silent spinner.
    func testScriptTool(
        _ tool: GizmateTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState
    /// Writes a tool from a plain-language description. Never runs it.
    ///
    /// - Parameter secretRequest: called with the name of a credential the
    ///   candidate declared and the user has not stored, before anything tries
    ///   to run it. Answering false lets the run fail on the missing key.
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error>
    /// Amends an existing tool from one instruction. Never runs it.
    func reviseScriptTool(
        tool: GizmateTool,
        script: String,
        instruction: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error>
    /// Repairs the complete tool after a failed run.
    func repairScriptTool(
        tool: GizmateTool,
        script: String,
        failure: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error>
    func cloudProviderHasCredentials(_ provider: CloudProvider) -> Bool
    func runCloudTest(for provider: CloudProvider) async -> CloudTestResult
    var bootstrapState: BootstrapState { get }
    /// Re-run the live engine health detection (pings the Ollama server, checks
    /// app presence, re-reads cloud keys). The window calls this on show/focus
    /// so the setup card reflects current reality — a server that died after
    /// launch must flip the steps back to "needs action".
    func refreshBootstrap()
    var ollamaModels: [OllamaModelOption] { get }
    var appVersionString: String { get }
    var isAppBundle: Bool { get }
    /// Display version of a pending update found by a background check, or nil.
    var availableUpdateVersion: String? { get }
    /// Bring up the install dialog for the pending update.
    func installAvailableUpdate()
}
