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

    /// The exact defect class this file exists for, on the two booleans instead
    /// of the enums: `usesNotes`/`usesVoice` shipped on `GizmateTool` without a
    /// wire field, so every chat edit silently reset them to off. The contract
    /// now: the installed snapshot carries them in, a candidate that omits them
    /// keeps what the tool had, and only an explicit false turns them off.
    func testNotesAndVoiceFlagsSurviveAChatEditThatNeverMentionedThem() throws {
        var existing = GizmateTool(name: "Digest", kind: .prompt, prompt: "Summarize.")
        existing.usesNotes = true
        existing.usesVoice = true

        let snapshot = try ToolAgentLiveBuilder.installedTool(from: existing, script: "")
        XCTAssertEqual(snapshot.usesNotes, true, "an edit session must see the current value")
        XCTAssertEqual(snapshot.usesVoice, true)

        func candidate(usesNotes: Bool?, usesVoice: Bool?) throws -> ToolAgentCandidateV1 {
            try ToolAgentCandidateV1(
                kind: .prompt,
                name: "Digest",
                brief: "Summarizes the notes.",
                symbolName: "sparkles",
                input: .none,
                output: .panel,
                trigger: .always,
                prompt: "Summarize.",
                usesNotes: usesNotes,
                usesVoice: usesVoice
            )
        }
        let silent = ToolAgentLiveBuilder.generatedTool(
            from: try candidate(usesNotes: nil, usesVoice: nil),
            preserving: existing
        )
        XCTAssertEqual(silent.tool.usesNotes, true, "nil is \"didn't say\", not \"turn it off\"")
        XCTAssertEqual(silent.tool.usesVoice, true)

        let cleared = ToolAgentLiveBuilder.generatedTool(
            from: try candidate(usesNotes: false, usesVoice: false),
            preserving: existing
        )
        XCTAssertEqual(cleared.tool.usesNotes, false, "an explicit false must still win")
        XCTAssertEqual(cleared.tool.usesVoice, false)

        let fresh = ToolAgentLiveBuilder.generatedTool(
            from: try candidate(usesNotes: true, usesVoice: nil)
        )
        XCTAssertEqual(fresh.tool.usesNotes, true, "a new build takes the candidate's word")
        XCTAssertEqual(fresh.tool.usesVoice, false, "and nil on a new build means off")
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
    /// `ToolEditorPanel` says something about — a locality pointer since Task
    /// 3, a picker before it — or the dock can name it and its own editor
    /// never even tells the user it's dockable at all. Comparing the two
    /// named sets directly — rather than, say, asserting `.surface` is in
    /// both — means narrowing either one independently fails here: this is
    /// what would have caught the gate this fixes, and it stays honest if a
    /// future output joins one side without the other.
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
        // BuiltInEditor names in its own locality pointer, or the one id
        // EdgesSection itself names because it has no ring slot to route
        // a pointer through instead.
        let ringReachable = Set(DockCatalog.dockableBuiltIns.map { ToolRef.builtIn($0).storageID })
        let unreachable = residentIDs
            .subtracting(ringReachable)
            .subtracting([EdgesSection.residentWithoutARingSlot])

        XCTAssertTrue(
            unreachable.isEmpty,
            "DockCatalog.builtIns lists a resident — \(unreachable.sorted()) — whose own "
                + "editor has no way to tell the user where it sits: it names no RingActionID "
                + "in DockCatalog.dockableBuiltIns, and EdgesSection.residentWithoutARingSlot "
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

    /// The third occurrence of the shape the class header names, and the one
    /// that survived the Edges rework: every dockable thing has to have exactly
    /// one control, in exactly one place. `.surface` gizmos reached
    /// `DockCatalog.gizmos` with no editor control once; the folder hub reached
    /// `DockCatalog.builtIns` with no control hours later.
    ///
    /// The split is now by kind rather than by screen. A resident — Note, the
    /// folder hub, a `.surface` gizmo — is placed on the `EdgesDiagram`, where
    /// its order relative to its neighbours is visible. Everything else with a
    /// dockable result panel (Explain, Reply, Summarize, a `.panel` gizmo) is
    /// placed in its own editor, because a panel never shares an edge and has
    /// no order to arrange. `PanelPlacement.offersPicker(for:)` is the live gate
    /// both editors call; the two halves must not overlap, or a thing gets a
    /// picker in its editor *and* a tile on the figure.
    ///
    /// Built against the live sets — `DockCatalog.dockableBuiltIns`/
    /// `residentBuiltIns` for the built-in half, `ToolEditorPanel.outputsWithPlacementControl`
    /// minus `DockCatalog.dockableGizmoOutputs` for the gizmo half — rather
    /// than a literal `[.explain, .reply, .summarize]` or `.panel`, so a
    /// future change to any of those four sets is what this test actually
    /// tracks, not a snapshot of today's values.
    func testEveryPanelOnlyPlaceableGetsItsPickerInItsOwnEditor() {
        let suiteName = "DockPlacementParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = StubEdgesUnplacedHost(builtInOverrides: BuiltInOverridesStore(defaults: defaults))

        // Seeded so the gizmo half of `editorsPointAt` below isn't vacuously
        // empty — the built-in half (Explain/Reply/Summarize) can never be
        // empty on its own, since it's driven by the fixed `dockableBuiltIns`/
        // `residentBuiltIns` arrays rather than anything this stub seeds, so
        // without this the test could still pass while checking nothing about
        // gizmos at all.
        let panelGizmo = GizmateTool(name: "Panel Gizmo", kind: .python, input: .selection, output: .panel)
        _ = host.tools.save(panelGizmo)
        XCTAssertTrue(
            host.tools.usableTools().contains { $0.output == .panel },
            "this stub's whole point is a seeded, usable .panel gizmo — without one the "
                + "assertion below would pass by comparing two sets that are each missing "
                + "the half this test means to check"
        )

        let nonResidentBuiltIns = DockCatalog.dockableBuiltIns
            .filter { !DockCatalog.residentBuiltIns.contains($0) }
            .map { ToolRef.builtIn($0).storageID }
        let gizmoOnlyOutputs = ToolEditorPanel.outputsWithPlacementControl
            .subtracting(DockCatalog.dockableGizmoOutputs)
        let panelOnlyGizmos = host.tools.usableTools()
            .filter { gizmoOnlyOutputs.contains($0.output) }
            .map { ToolRef.generated($0.id).storageID }
        let editorsPointAt = Set(nonResidentBuiltIns).union(panelOnlyGizmos)

        XCTAssertEqual(
            PanelPlacement.placeableIDs(host: host), editorsPointAt,
            "PanelPlacement disagrees with the sets BuiltInEditor and ToolEditorPanel are "
                + "gated on — either an id promised a picker gets none, or one gets a picker "
                + "nothing points at"
        )

        // The two halves must not overlap. Let a resident through (drop the
        // `!residentBuiltIns.contains` filter, say) and it gets a picker in its
        // own editor *and* a tile on the Edges figure — two controls writing
        // one `DockStore` key, which is the duplication both this split and the
        // one-screen rule before it existed to prevent.
        XCTAssertTrue(
            PanelPlacement.placeableIDs(host: host)
                .isDisjoint(with: EdgesSection.offeredIDs(host: host)),
            "something is both panel-placeable in its own editor and a resident on the Edges "
                + "figure — it would carry two placement controls for one id"
        )
    }

    /// The fourth occurrence of the class-header shape, and the one Task 5
    /// created: decoupling "New gizmo" from picking a ring slot first means a
    /// tool can now be saved on neither a ring slot nor an edge, something
    /// that used to be impossible by construction. `HomeSectionContent.location`
    /// is the one place that has to keep saying so — this pins it against real
    /// stores rather than trusting the row still renders `.nowhere`'s label by
    /// eye.
    ///
    /// The stranded tool's output is deliberately `.clipboard`, not `.panel`
    /// or `.surface`: those two are the ones `DockCatalog` and `EdgesSection`
    /// already reason about, but a `.clipboard` (or `.notify`) gizmo has no
    /// edge it could ever sit on — for one of those, "reachable" collapses to
    /// "on a ring slot", and nothing outside this test's target function has
    /// ever had to get that narrower case right.
    func testAToolOnNeitherARingSlotNorAnEdgeIsReportedAsLivingNowhere() {
        let toolsDirectory = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-home-reachability-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }
        let tools = ToolsStore(directoryURL: toolsDirectory, migrateLegacy: false)

        let ringSuiteName = "HomeReachabilityParityTests.ring.\(UUID().uuidString)"
        let ringDefaults = UserDefaults(suiteName: ringSuiteName)!
        defer { ringDefaults.removePersistentDomain(forName: ringSuiteName) }
        let ringLayout = RingLayoutStore(defaults: ringDefaults)

        let dockSuiteName = "HomeReachabilityParityTests.dock.\(UUID().uuidString)"
        let dockDefaults = UserDefaults(suiteName: dockSuiteName)!
        defer { dockDefaults.removePersistentDomain(forName: dockSuiteName) }
        let dock = DockStore(defaults: dockDefaults)

        let overridesSuiteName = "HomeReachabilityParityTests.overrides.\(UUID().uuidString)"
        let overridesDefaults = UserDefaults(suiteName: overridesSuiteName)!
        defer { overridesDefaults.removePersistentDomain(forName: overridesSuiteName) }
        let overrides = BuiltInOverridesStore(defaults: overridesDefaults)

        let home = HomeSectionContent(tools: tools, ringLayout: ringLayout, dock: dock, overrides: overrides)

        let ringed = tools.save(GizmateTool(name: "Ringed", kind: .python, input: .selection, output: .clipboard))
        let docked = tools.save(GizmateTool(name: "Docked", kind: .python, input: .selection, output: .clipboard))
        let stranded = tools.save(GizmateTool(name: "Stranded", kind: .python, input: .selection, output: .clipboard))

        ringLayout.assign(.tool(ringed.id), to: 0)
        dock.dock(ToolRef.generated(docked.id).storageID, to: .left)
        // `stranded` is saved and usable but never placed anywhere — the
        // scenario Task 5 made possible for the first time.

        func location(for tool: GizmateTool) -> HomeLocation {
            home.location(for: .tool(tool.id), storageID: ToolRef.generated(tool.id).storageID)
        }

        // The fixture has to actually discriminate before the real assertion
        // below means anything: if placing a tool on the ring or an edge
        // still came back `.nowhere`, the assertion on `stranded` would pass
        // for the wrong reason — every tool reading `.nowhere` regardless of
        // where it sits — rather than for catching the one truly unplaced
        // tool.
        for (tool, label) in [(ringed, "ringed"), (docked, "docked")] {
            if case .nowhere = location(for: tool) {
                XCTFail("this stub's whole point is a \(label) tool that isn't `.nowhere` — "
                    + "without that, the assertion below would pass by comparing a case "
                    + "against itself")
            }
        }

        guard case .nowhere = location(for: stranded) else {
            return XCTFail("a tool on no ring slot and no edge must read back as `.nowhere`")
        }
        XCTAssertEqual(
            location(for: stranded).label, "Nowhere",
            "the row's own copy for this state changed without this test noticing"
        )
        XCTAssertTrue(
            location(for: stranded).needsAttention,
            "an unplaced tool is the one state on Home worth noticing, so it must "
                + "keep the treatment that separates it from nine identical values"
        )
    }

    /// I2: a built-in has a third home a gizmo never can — its own global
    /// shortcut. `GlobalShortcutStore` always resolves one, saved or default,
    /// for any `RingActionID` with a `shortcutAction`, so taking Explain off
    /// the ring to free a slot (an ordinary act) must not make `location`
    /// claim it lives nowhere while ⌃⌥T still runs it.
    func testABuiltInWithAGlobalShortcutIsNeverReportedAsLivingNowhere() {
        let toolsDirectory = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-home-shortcut-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }
        let tools = ToolsStore(directoryURL: toolsDirectory, migrateLegacy: false)

        let ringSuiteName = "HomeShortcutParityTests.ring.\(UUID().uuidString)"
        let ringDefaults = UserDefaults(suiteName: ringSuiteName)!
        defer { ringDefaults.removePersistentDomain(forName: ringSuiteName) }
        let ringLayout = RingLayoutStore(defaults: ringDefaults)

        let dockSuiteName = "HomeShortcutParityTests.dock.\(UUID().uuidString)"
        let dockDefaults = UserDefaults(suiteName: dockSuiteName)!
        defer { dockDefaults.removePersistentDomain(forName: dockSuiteName) }
        let dock = DockStore(defaults: dockDefaults)

        let overridesSuiteName = "HomeShortcutParityTests.overrides.\(UUID().uuidString)"
        let overridesDefaults = UserDefaults(suiteName: overridesSuiteName)!
        defer { overridesDefaults.removePersistentDomain(forName: overridesSuiteName) }
        let overrides = BuiltInOverridesStore(defaults: overridesDefaults)

        // A scratch suite, never written to — an untouched install, where
        // `GlobalShortcutStore` falls back to the action's default binding.
        let shortcutSuiteName = "HomeShortcutParityTests.shortcuts.\(UUID().uuidString)"
        let shortcutDefaults = UserDefaults(suiteName: shortcutSuiteName)!
        defer { shortcutDefaults.removePersistentDomain(forName: shortcutSuiteName) }

        let home = HomeSectionContent(
            tools: tools, ringLayout: ringLayout, dock: dock, overrides: overrides,
            shortcutDefaults: shortcutDefaults
        )

        // A fresh `RingLayoutStore` starts from `RingLayout.default`, which
        // seeds Explain at root slot 0 — clear it to reach the state the
        // review names: Explain taken off the ring to free the slot, and
        // never docked either.
        ringLayout.clear(0)
        XCTAssertFalse(
            ringLayout.layout.slots.contains(.builtIn(.explain)),
            "this stub's whole point is Explain off the ring — without that, the assertion "
                + "below would pass by reading `.ring`, not by reaching the shortcut fallback"
        )

        let location = home.location(
            for: .builtIn(.explain), storageID: ToolRef.builtIn(.explain).storageID
        )

        guard case .shortcut(let shortcut) = location else {
            return XCTFail(
                "Explain has no ring slot and no edge here, but it still has a "
                    + "shortcutAction — location must not read that back as .nowhere, or "
                    + "Home tells the user Explain lives nowhere while its shortcut still runs it"
            )
        }
        XCTAssertEqual(
            shortcut, GlobalShortcutAction.explainSelection.defaultShortcut,
            "an untouched suite should resolve to the action's default binding"
        )
        // The binding itself, not a sentence about it. See DESIGN.md §16: with
        // nearly every built-in on the ring, a column of full sentences printed
        // "In the ring." eight times and buried the two rows that differed.
        XCTAssertEqual(location.label, shortcut.displayString)
        XCTAssertFalse(
            location.needsAttention,
            "a built-in its shortcut still runs is reachable, so it must not take "
                + "the treatment Home uses to mark a tool nothing points at"
        )
    }

    /// I3: `RingLayoutStore.assign` and `DockStore.dock` never call each
    /// other, so a tool can genuinely sit on a ring slot and an edge at once
    /// — the ordinary way that happens is a `.surface` gizmo approved via
    /// `SurfaceRefresh`'s "run it once from the ring" message, which needs a
    /// slot, for a gizmo whose entire point is the edge. When both are true,
    /// `location` has to report the edge: it's the answer that actually
    /// describes what the gizmo is for.
    func testASurfaceGizmoOnBothARingSlotAndAnEdgeReportsTheEdge() {
        let toolsDirectory = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-home-surface-both-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }
        let tools = ToolsStore(directoryURL: toolsDirectory, migrateLegacy: false)

        let ringSuiteName = "HomeSurfaceBothParityTests.ring.\(UUID().uuidString)"
        let ringDefaults = UserDefaults(suiteName: ringSuiteName)!
        defer { ringDefaults.removePersistentDomain(forName: ringSuiteName) }
        let ringLayout = RingLayoutStore(defaults: ringDefaults)

        let dockSuiteName = "HomeSurfaceBothParityTests.dock.\(UUID().uuidString)"
        let dockDefaults = UserDefaults(suiteName: dockSuiteName)!
        defer { dockDefaults.removePersistentDomain(forName: dockSuiteName) }
        let dock = DockStore(defaults: dockDefaults)

        let overridesSuiteName = "HomeSurfaceBothParityTests.overrides.\(UUID().uuidString)"
        let overridesDefaults = UserDefaults(suiteName: overridesSuiteName)!
        defer { overridesDefaults.removePersistentDomain(forName: overridesSuiteName) }
        let overrides = BuiltInOverridesStore(defaults: overridesDefaults)

        let home = HomeSectionContent(tools: tools, ringLayout: ringLayout, dock: dock, overrides: overrides)

        let surfaceGizmo = tools.save(
            GizmateTool(name: "Surface Gizmo", kind: .python, input: .selection, output: .surface)
        )

        // Both writes are real and independent, the same way a user actually
        // gets here: approve it once from the ring per SurfaceRefresh's
        // message, then dock it too, since the edge is the gizmo's real job.
        ringLayout.assign(.tool(surfaceGizmo.id), to: 0)
        dock.dock(ToolRef.generated(surfaceGizmo.id).storageID, to: .left)

        XCTAssertTrue(
            ringLayout.layout.slots.contains(.tool(surfaceGizmo.id)),
            "this stub's whole point is a tool that really is on the ring — without that, "
                + "the assertion below would pass without checking that the ring is ever "
                + "suppressed in favor of the edge"
        )

        let location = home.location(
            for: .tool(surfaceGizmo.id), storageID: ToolRef.generated(surfaceGizmo.id).storageID
        )
        guard case .edge(let edge) = location else {
            return XCTFail(
                "a .surface gizmo on both a ring slot and an edge must report the edge — "
                    + "it's what the gizmo is for; the ring slot is likely just a leftover "
                    + "from approving it once"
            )
        }
        XCTAssertEqual(edge, .left)
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
    var askConversation: AskConversationStore { fatalError("unused by DockPlacementParityTests") }
    var homeChat: ToolChatConversation { fatalError("unused by DockPlacementParityTests") }
    var gizmoBuilder: GizmoBuilder { fatalError("unused by DockPlacementParityTests") }
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
    var askConversation: AskConversationStore { fatalError("unused by DockPlacementParityTests") }
    var homeChat: ToolChatConversation { fatalError("unused by DockPlacementParityTests") }
    var gizmoBuilder: GizmoBuilder { fatalError("unused by DockPlacementParityTests") }
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
