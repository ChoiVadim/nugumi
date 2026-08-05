import GizmateToolAgentCore
import XCTest

@testable import Gizmate

/// `ToolAgentLiveBuilder` converts a saved gizmo into the builder protocol's
/// shape by raw string, falling back to `.notify` / `.none` when the string is
/// unknown (`ToolAgentLiveBuilder.swift:135-136`, and the reverse at 478-479).
/// The fallback is right for a gizmo written by a newer version, and silently
/// destructive for a case someone added on only one side: the user opens their
/// Read-aloud gizmo in the chat builder and it comes back as Notify.
///
/// Nothing else fails when the two enums drift — not the build, not a run — so
/// this is the check.
final class ToolProtocolEnumParityTests: XCTestCase {
    func testEveryOutputSurvivesTheRoundTripToTheBuilderProtocol() {
        for output in ToolOutput.allCases {
            let encoded = ToolAgentCandidateOutputV1(rawValue: output.rawValue)
            XCTAssertNotNil(
                encoded,
                "ToolOutput.\(output.rawValue) has no ToolAgentCandidateOutputV1 case; "
                    + "editing such a gizmo in the builder would silently turn it into Notify."
            )
            XCTAssertEqual(encoded.flatMap { ToolOutput(rawValue: $0.rawValue) }, output)
        }
    }

    func testEveryInputSurvivesTheRoundTripToTheBuilderProtocol() {
        for input in ToolInput.allCases {
            let encoded = ToolAgentCandidateInputV1(rawValue: input.rawValue)
            XCTAssertNotNil(
                encoded,
                "ToolInput.\(input.rawValue) has no ToolAgentCandidateInputV1 case; "
                    + "editing such a gizmo in the builder would silently turn it into Nothing."
            )
            XCTAssertEqual(encoded.flatMap { ToolInput(rawValue: $0.rawValue) }, input)
        }
    }

    /// The editor is what the user picks from, and the protocol is what the chat
    /// builder validates against. When the editor offers more than the protocol
    /// accepts, saving works and opening that gizmo in the builder throws
    /// `invalidCandidate` — a gizmo the user can create but not edit.
    func testTheEditorOffersActionGizmosExactlyWhatTheProtocolAccepts() {
        let offered = Set(
            ToolEditorPanel.outputs(for: .native).compactMap {
                ToolAgentCandidateOutputV1(rawValue: $0.rawValue)
            }
        )
        XCTAssertEqual(offered, ToolAgentCandidateOutputV1.nativeDeliverable)
        XCTAssertFalse(offered.contains(.panel), "an Action has no model to write a panel's answer")
        XCTAssertFalse(offered.contains(.annotate), "an Action has no model to decide what to draw")
    }

    /// An Agent finishes with text, so files are the one thing it cannot hand
    /// over — `runAgentTool` always delivers `producedFiles: []`, and the pill
    /// would report "nothing produced" every run.
    func testAgentGizmosAreOfferedEveryResultButFiles() {
        let offered = Set(
            ToolEditorPanel.outputs(for: .agent).compactMap {
                ToolAgentCandidateOutputV1(rawValue: $0.rawValue)
            }
        )
        XCTAssertEqual(offered, ToolAgentCandidateOutputV1.agentDeliverable)
        XCTAssertFalse(offered.contains(.files))
        XCTAssertTrue(offered.contains(.annotate))
    }

    /// Script used to be the unrestricted kind. It no longer is: `.surface`
    /// needs a layout tree, and this editor has no control that writes one —
    /// that's composed by the build-time agent alone (Task 10), so a hand-
    /// built gizmo can never carry one. `.python` and `.prompt` end up
    /// excluding `.surface` for two unrelated reasons that happen to agree —
    /// `.python` because the editor can't author the layout it would need,
    /// `.prompt` because a model can't run on every pointer hover over a
    /// screen edge even if it had one — so no kind reaches this editor able
    /// to offer `.surface`, not even the one kind whose script could
    /// actually serve one at runtime.
    func testNoKindCanBeGivenSurfaceByHandInTheEditor() {
        XCTAssertFalse(ToolEditorPanel.outputs(for: .python).contains(.surface))
        XCTAssertFalse(ToolEditorPanel.outputs(for: .prompt).contains(.surface))
        XCTAssertFalse(ToolEditorPanel.outputs(for: .agent).contains(.surface))
        XCTAssertFalse(ToolEditorPanel.outputs(for: .native).contains(.surface))
        XCTAssertEqual(
            ToolEditorPanel.outputs(for: .python),
            ToolOutput.allCases.filter { $0 != .surface }
        )
        XCTAssertEqual(
            ToolEditorPanel.outputs(for: .prompt),
            ToolOutput.allCases.filter { $0 != .surface }
        )
    }

    /// The eval suite is the only thing that drives a real build end to end, so
    /// an input or result no case asks for ships having never been generated
    /// once. That is exactly how `drawnScreen` reached a user before it reached
    /// a test. Cheap to keep honest: adding a case to `ToolEvalSuite` is one
    /// literal, and this fails the moment the enum grows without one.
    func testTheEvalSuiteAsksForEveryInputAndEveryResult() {
        let missingInputs = Set(ToolInput.allCases)
            .subtracting(ToolEvalSuite.all.compactMap(\.input))
        let missingOutputs = Set(ToolOutput.allCases)
            .subtracting(ToolEvalSuite.all.compactMap(\.output))
        XCTAssertEqual(
            missingInputs.map(\.rawValue).sorted(), [],
            "no eval case asks for a gizmo with these inputs"
        )
        XCTAssertEqual(
            missingOutputs.map(\.rawValue).sorted(), [],
            "no eval case asks for a gizmo with these results"
        )
    }

    /// Every input the editor offers a prompt gizmo has to survive the builder's
    /// own validation.
    ///
    /// This has now failed twice for the same reason: a case was added to the
    /// enum, to the sidecar schema and to the capability description, while the
    /// allowlist inside `ToolAgentCandidateV1.validate` stayed where it was.
    /// Both times the model wrote exactly the candidate it had been told to
    /// write and the user saw "The model returned an invalid agent action",
    /// which names neither the field nor the value that was refused.
    func testEveryPromptPairingTheEditorOffersPassesCandidateValidation() throws {
        for input in ToolInput.allCases {
            for output in ToolEditorPanel.outputs(for: .prompt) {
                guard let wireInput = ToolAgentCandidateInputV1(rawValue: input.rawValue),
                      let wireOutput = ToolAgentCandidateOutputV1(rawValue: output.rawValue)
                else {
                    return XCTFail("\(input.rawValue)/\(output.rawValue) has no protocol case")
                }
                XCTAssertNoThrow(
                    try ToolAgentCandidateV1(
                        kind: .prompt,
                        name: "Explain",
                        brief: "Explains the thing.",
                        symbolName: "sparkles",
                        input: wireInput,
                        output: wireOutput,
                        trigger: .always,
                        prompt: "Explain what this is."
                    ),
                    "a prompt gizmo the editor offers as \(input.rawValue) → "
                        + "\(output.rawValue) is rejected by the builder"
                )
            }
        }
    }
}

/// The builder refuses a native candidate whose app it cannot find, so what it
/// can find has to be exactly what a run can open. When the two disagreed, the
/// model wrote a correct native candidate, was refused, and repaired into
/// Python — a worse tool for a request that was right the first time.
@MainActor
final class InstalledApplicationResolutionTests: XCTestCase {
    /// The name macOS shows and the name on disk are not the same string, and
    /// this is not only about localisation: FindMy.app is "Find My" everywhere
    /// a user can see it, in English.
    func testBothTheDisplayNameAndTheBundleNameResolveToOneApp() throws {
        let onDisk = "/System/Applications/FindMy.app"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: onDisk),
            "FindMy.app is not on this Mac"
        )
        XCTAssertEqual(NativeToolRunner.applicationURL(for: "FindMy")?.path, onDisk)
        XCTAssertEqual(NativeToolRunner.applicationURL(for: "Find My")?.path, onDisk)
        XCTAssertTrue(ToolAgentHostCandidateValidator.installedApplicationExists("Find My"))
    }

    func testAnAppThatIsNotInstalledStillResolvesToNothing() {
        XCTAssertNil(NativeToolRunner.applicationURL(for: "Definitely Not An App \(UUID())"))
        XCTAssertFalse(ToolAgentHostCandidateValidator.installedApplicationExists(""))
    }
}

/// The class-header comment above argues that nothing but a hand check
/// catches an output reaching one allowlist and not another — this is that
/// same argument applied to `.surface`. `DockCatalog.gizmos` listed it,
/// `ToolAgentCandidateV1` validated it, the sidecar built it, and for one
/// whole review cycle no editor control could ever dock it, so nobody who
/// shipped it had ever seen one draw. `@MainActor` because `DockCatalog` is.
@MainActor
final class DockPlacementParityTests: XCTestCase {
    /// A gizmo `DockCatalog.gizmos` is willing to list has to be one
    /// `ToolEditorPanel` offers a placement control for, or the dock can name
    /// it and nothing can ever put it there. Comparing the two named sets
    /// directly — rather than, say, asserting `.surface` is in both — means
    /// narrowing either one independently fails here: this is what would have
    /// caught the gate this fixes, and it stays honest if a future output
    /// joins one side without the other.
    func testEveryDockableGizmoOutputHasAPlacementControlInTheEditor() {
        let undockable = DockCatalog.dockableGizmoOutputs
            .subtracting(ToolEditorPanel.outputsWithPlacementControl)
        XCTAssertTrue(
            undockable.isEmpty,
            "DockCatalog.gizmos would list a gizmo whose output — "
                + "\(undockable.map(\.rawValue).sorted()) — has no placement "
                + "control in the editor, so it could never be docked"
        )
    }

    /// The built-in half of the same gap: `DockCatalog.builtIns` is not built
    /// from a fixed enum like `ToolOutput`, so there is no static "every
    /// possible resident" list to diff against `dockableBuiltIns`. Comparing
    /// the actual returned ids instead is what caught the folder hub, which
    /// shipped in `DockCatalog.builtIns` a full review cycle before anything
    /// in the interface could dock it — the exact shape `testEveryDockable-
    /// GizmoOutputHasAPlacementControlInTheEditor` above catches for gizmos.
    func testEveryBuiltInDockResidentHasAPlacementControlSomewhereInTheInterface() {
        let suiteName = "DockPlacementParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = StubBuiltInResidentsHost(builtInOverrides: BuiltInOverridesStore(defaults: defaults))

        let residentIDs = Set(DockCatalog.builtIns(host: host).map(\.id))
        // The two ways a resident's id can be reachable today: a ring action
        // BuiltInEditor shows the picker for, or the one id General's own
        // placement control names because it has no ring slot to route
        // through instead.
        let ringReachable = Set(DockCatalog.dockableBuiltIns.map { ToolRef.builtIn($0).storageID })
        let unreachable = residentIDs
            .subtracting(ringReachable)
            .subtracting([SettingsSection.residentWithoutARingSlot])

        XCTAssertTrue(
            unreachable.isEmpty,
            "DockCatalog.builtIns lists a resident — \(unreachable.sorted()) — with no "
                + "placement control anywhere in the app: it names no RingActionID in "
                + "DockCatalog.dockableBuiltIns, and SettingsSection.residentWithoutARingSlot "
                + "doesn't cover it either"
        )
    }

    /// The converse of the two tests above. Both check "the dock will show
    /// this, so something must offer a control for it" — this checks the
    /// direction that actually broke: `EdgesSection`'s "not on an edge" list
    /// was first built off `DockCatalog.placeableIDs`, which is deliberately
    /// wider than the resident set (`prune` needs the extra room to keep a
    /// docked `.panel` gizmo's placement alive). Wider-than-resident is not
    /// the same as wider-than-controllable: the list offered a working-
    /// looking edge picker for e.g. a `.notify`-output gizmo, and placing one
    /// drew nothing anywhere, silently — indistinguishable from the app being
    /// broken. `EdgesSection.offeredIDs` is what the list actually consumes;
    /// pinning it against `DockCatalog.knownIDs` here means a future edit
    /// that widens it back to `placeableIDs` fails immediately rather than
    /// waiting for someone to notice a dead control. The stub below carries
    /// zero tools on purpose — `dockableBuiltIns` alone (Explain/Reply/
    /// Summarize have a control but no resident row) already makes
    /// `knownIDs` and `placeableIDs` disagree, so this cannot pass by
    /// comparing two sets that happen to be equal for an unrelated reason.
    func testEdgesSectionOnlyOffersAnEdgeForSomethingTheDockWillActuallyShow() {
        let suiteName = "DockPlacementParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = StubEdgesUnplacedHost(builtInOverrides: BuiltInOverridesStore(defaults: defaults))

        XCTAssertNotEqual(
            DockCatalog.knownIDs(host: host), DockCatalog.placeableIDs(host: host),
            "this stub's whole point is a host where the two sets differ — if they don't, "
                + "the assertion below would pass without checking anything"
        )
        XCTAssertEqual(EdgesSection.offeredIDs(host: host), DockCatalog.knownIDs(host: host))
    }
}

/// The smallest `SettingsHost` `DockCatalog.builtIns` needs: it only reads
/// `host.builtInOverrides` for each ring-action resident's display name and
/// icon. Everything else is `fatalError` per the convention
/// `DockCatalogSurfaceTests`'s own stub uses — a future test on this stub that
/// needs one more member gets told exactly which, instead of a stub that
/// silently returns a plausible-looking default.
@MainActor
private final class StubBuiltInResidentsHost: SettingsHost {
    let builtInOverrides: BuiltInOverridesStore

    init(builtInOverrides: BuiltInOverridesStore) {
        self.builtInOverrides = builtInOverrides
    }

    func makeSettingsSnapshot() -> SettingsSnapshot { fatalError("unused by DockPlacementParityTests") }
    func performSettingsIntent(_ intent: SettingsIntent) { fatalError("unused by DockPlacementParityTests") }
    var usageStats: UsageStatsStore { fatalError("unused by DockPlacementParityTests") }
    var snippets: SnippetsStore { fatalError("unused by DockPlacementParityTests") }
    var notes: NotesStore { fatalError("unused by DockPlacementParityTests") }
    var tools: ToolsStore { fatalError("unused by DockPlacementParityTests") }
    var ringLayout: RingLayoutStore { fatalError("unused by DockPlacementParityTests") }
    var dock: DockStore { fatalError("unused by DockPlacementParityTests") }
    var folderHub: FolderHubStore { fatalError("unused by DockPlacementParityTests") }
    var surfaceRows: SurfaceRowsCache { fatalError("unused by DockPlacementParityTests") }
    func refreshSurface(_ tool: GizmateTool) async -> SurfaceRefreshOutcome {
        fatalError("unused by DockPlacementParityTests")
    }
    func runTool(_ tool: GizmateTool, selection: String) { fatalError("unused by DockPlacementParityTests") }
    func performBuiltIn(_ id: RingActionID) { fatalError("unused by DockPlacementParityTests") }
    func presentMainWindow(section: MainWindowSection?) { fatalError("unused by DockPlacementParityTests") }
    var uvIsReady: Bool { fatalError("unused by DockPlacementParityTests") }
    func testScriptTool(
        _ tool: GizmateTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState {
        fatalError("unused by DockPlacementParityTests")
    }
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error> {
        fatalError("unused by DockPlacementParityTests")
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
        fatalError("unused by DockPlacementParityTests")
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
        fatalError("unused by DockPlacementParityTests")
    }
    func cloudProviderHasCredentials(_ provider: CloudProvider) -> Bool {
        fatalError("unused by DockPlacementParityTests")
    }
    func runCloudTest(for provider: CloudProvider) async -> CloudTestResult {
        fatalError("unused by DockPlacementParityTests")
    }
    var bootstrapState: BootstrapState { fatalError("unused by DockPlacementParityTests") }
    func refreshBootstrap() { fatalError("unused by DockPlacementParityTests") }
    var ollamaModels: [OllamaModelOption] { fatalError("unused by DockPlacementParityTests") }
    var appVersionString: String { fatalError("unused by DockPlacementParityTests") }
    var isAppBundle: Bool { fatalError("unused by DockPlacementParityTests") }
    var availableUpdateVersion: String? { fatalError("unused by DockPlacementParityTests") }
    func installAvailableUpdate() { fatalError("unused by DockPlacementParityTests") }
}

/// The smallest `SettingsHost` `EdgesSection.offeredIDs`/`DockCatalog.all`
/// need: `builtInOverrides` for a ring resident's title and icon, `tools` so
/// `usableTools()` (reached through `DockCatalog.gizmos`) has something real
/// to filter rather than crashing. Left empty on purpose — the disagreement
/// this test needs between `knownIDs` and `placeableIDs` already comes from
/// `dockableBuiltIns` alone, so no tool needs seeding. Same `fatalError`-
/// everything-else convention as `StubBuiltInResidentsHost` above and
/// `DockCatalogSurfaceTests`'s stub, whose scratch-directory `tools` this
/// mirrors exactly.
@MainActor
private final class StubEdgesUnplacedHost: SettingsHost {
    let builtInOverrides: BuiltInOverridesStore
    private let toolsDirectory = FileManager.default.temporaryDirectory
        .appending(path: "gizmate-edges-unplaced-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    lazy var tools = ToolsStore(directoryURL: toolsDirectory, migrateLegacy: false)

    init(builtInOverrides: BuiltInOverridesStore) {
        self.builtInOverrides = builtInOverrides
    }

    deinit {
        try? FileManager.default.removeItem(at: toolsDirectory)
    }

    func makeSettingsSnapshot() -> SettingsSnapshot { fatalError("unused by DockPlacementParityTests") }
    func performSettingsIntent(_ intent: SettingsIntent) { fatalError("unused by DockPlacementParityTests") }
    var usageStats: UsageStatsStore { fatalError("unused by DockPlacementParityTests") }
    var snippets: SnippetsStore { fatalError("unused by DockPlacementParityTests") }
    var notes: NotesStore { fatalError("unused by DockPlacementParityTests") }
    var ringLayout: RingLayoutStore { fatalError("unused by DockPlacementParityTests") }
    var dock: DockStore { fatalError("unused by DockPlacementParityTests") }
    var folderHub: FolderHubStore { fatalError("unused by DockPlacementParityTests") }
    var surfaceRows: SurfaceRowsCache { fatalError("unused by DockPlacementParityTests") }
    func refreshSurface(_ tool: GizmateTool) async -> SurfaceRefreshOutcome {
        fatalError("unused by DockPlacementParityTests")
    }
    func runTool(_ tool: GizmateTool, selection: String) { fatalError("unused by DockPlacementParityTests") }
    func performBuiltIn(_ id: RingActionID) { fatalError("unused by DockPlacementParityTests") }
    func presentMainWindow(section: MainWindowSection?) { fatalError("unused by DockPlacementParityTests") }
    var uvIsReady: Bool { fatalError("unused by DockPlacementParityTests") }
    func testScriptTool(
        _ tool: GizmateTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState {
        fatalError("unused by DockPlacementParityTests")
    }
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest
    ) async -> Result<GeneratedTool, Error> {
        fatalError("unused by DockPlacementParityTests")
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
        fatalError("unused by DockPlacementParityTests")
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
        fatalError("unused by DockPlacementParityTests")
    }
    func cloudProviderHasCredentials(_ provider: CloudProvider) -> Bool {
        fatalError("unused by DockPlacementParityTests")
    }
    func runCloudTest(for provider: CloudProvider) async -> CloudTestResult {
        fatalError("unused by DockPlacementParityTests")
    }
    var bootstrapState: BootstrapState { fatalError("unused by DockPlacementParityTests") }
    func refreshBootstrap() { fatalError("unused by DockPlacementParityTests") }
    var ollamaModels: [OllamaModelOption] { fatalError("unused by DockPlacementParityTests") }
    var appVersionString: String { fatalError("unused by DockPlacementParityTests") }
    var isAppBundle: Bool { fatalError("unused by DockPlacementParityTests") }
    var availableUpdateVersion: String? { fatalError("unused by DockPlacementParityTests") }
    func installAvailableUpdate() { fatalError("unused by DockPlacementParityTests") }
}
