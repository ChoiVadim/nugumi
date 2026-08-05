import GizmateToolAgentCore
import XCTest
@testable import Gizmate

/// A gizmo earns a place on the edge dock exactly when it has something to
/// show while nothing is running — `.surface` is the one result that's true
/// of. Every other result is still something you summon, and a tab for one
/// of those would be a second launcher, which is what the dock replaced.
@MainActor
final class DockCatalogSurfaceTests: XCTestCase {
    func testASurfaceGizmoIsDockable() {
        let host = StubSettingsHost()
        var tool = GizmateTool()
        tool.name = "Downloads"
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        host.tools.save(tool)

        let ids = DockCatalog.gizmos(host: host).map(\.id)
        XCTAssertEqual(ids, [ToolRef.generated(tool.id).storageID])
    }

    /// Named and left `.python`/usable on purpose: an *unnamed* tool would
    /// already be dropped by `ToolsStore.usableTools()` before `gizmos` ever
    /// sees it, which would make this pass whether or not the `.output ==
    /// .surface` filter still existed. Giving it a name is what keeps this
    /// test honest about which line it's guarding.
    func testANonSurfaceGizmoIsNotDockable() {
        let host = StubSettingsHost()
        var tool = GizmateTool()
        tool.name = "Copy loud"
        tool.kind = .python
        tool.output = .clipboard
        host.tools.save(tool)

        XCTAssertEqual(DockCatalog.gizmos(host: host).count, 0)
    }
}

/// The smallest `SettingsHost` `DockCatalog.gizmos` needs: it only ever
/// reaches into `host.tools`. `tools` is a real, disk-backed `ToolsStore`
/// under a scratch directory — the same isolation `ToolsStoreTests` uses —
/// because `gizmos` reads it through `usableTools()`, a real filter over
/// real data, not something worth mocking. Everything else on `SettingsHost`
/// is wired to `fatalError` on purpose: if a later test on this stub needs
/// one, the crash names exactly which member still wants a real body.
@MainActor
private final class StubSettingsHost: SettingsHost {
    private let toolsDirectory = FileManager.default.temporaryDirectory
        .appending(path: "gizmate-dock-catalog-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    lazy var tools = ToolsStore(directoryURL: toolsDirectory, migrateLegacy: false)

    deinit {
        try? FileManager.default.removeItem(at: toolsDirectory)
    }

    func makeSettingsSnapshot() -> SettingsSnapshot { fatalError("unused by DockCatalogSurfaceTests") }
    func performSettingsIntent(_ intent: SettingsIntent) { fatalError("unused by DockCatalogSurfaceTests") }
    var usageStats: UsageStatsStore { fatalError("unused by DockCatalogSurfaceTests") }
    var snippets: SnippetsStore { fatalError("unused by DockCatalogSurfaceTests") }
    var notes: NotesStore { fatalError("unused by DockCatalogSurfaceTests") }
    var ringLayout: RingLayoutStore { fatalError("unused by DockCatalogSurfaceTests") }
    var builtInOverrides: BuiltInOverridesStore { fatalError("unused by DockCatalogSurfaceTests") }
    var dock: DockStore { fatalError("unused by DockCatalogSurfaceTests") }
    var folderHub: FolderHubStore { fatalError("unused by DockCatalogSurfaceTests") }
    var surfaceRows: SurfaceRowsCache { fatalError("unused by DockCatalogSurfaceTests") }
    func refreshSurface(_ tool: GizmateTool) async -> SurfaceRefreshOutcome {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    func runTool(_ tool: GizmateTool, selection: String) { fatalError("unused by DockCatalogSurfaceTests") }
    func performBuiltIn(_ id: RingActionID) { fatalError("unused by DockCatalogSurfaceTests") }
    func presentMainWindow(section: MainWindowSection?) { fatalError("unused by DockCatalogSurfaceTests") }
    var uvIsReady: Bool { fatalError("unused by DockCatalogSurfaceTests") }
    func testScriptTool(
        _ tool: GizmateTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error> {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    func reviseScriptTool(
        tool: GizmateTool,
        script: String,
        instruction: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error> {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    func repairScriptTool(
        tool: GizmateTool,
        script: String,
        failure: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error> {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    func cloudProviderHasCredentials(_ provider: CloudProvider) -> Bool {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    func runCloudTest(for provider: CloudProvider) async -> CloudTestResult {
        fatalError("unused by DockCatalogSurfaceTests")
    }
    var bootstrapState: BootstrapState { fatalError("unused by DockCatalogSurfaceTests") }
    func refreshBootstrap() { fatalError("unused by DockCatalogSurfaceTests") }
    var ollamaModels: [OllamaModelOption] { fatalError("unused by DockCatalogSurfaceTests") }
    var appVersionString: String { fatalError("unused by DockCatalogSurfaceTests") }
    var isAppBundle: Bool { fatalError("unused by DockCatalogSurfaceTests") }
    var availableUpdateVersion: String? { fatalError("unused by DockCatalogSurfaceTests") }
    func installAvailableUpdate() { fatalError("unused by DockCatalogSurfaceTests") }
}
