import XCTest
@testable import Gizmate

/// One gizmo's draft and its run, away from any view.
///
/// This is the half of the builder that can be checked without a model, and
/// every case here is a claim about code that has or has not been run in front
/// of the user. Getting one wrong means either asking for consent that was
/// already given, or running a script nobody has seen.
@MainActor
final class GizmoDraftTests: XCTestCase {
    private func scratchTools() -> ToolsStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GizmoDraftTests.\(UUID().uuidString)")
        return ToolsStore(directoryURL: dir, migrateLegacy: false)
    }

    private func makeDraft(
        tools: ToolsStore? = nil,
        runner: @escaping GizmoDraft.Runner = { _, _, _ in .passed("ok") }
    ) -> GizmoDraft {
        GizmoDraft(subject: .new, tools: tools ?? scratchTools(), runner: runner)
    }

    private func python(_ name: String = "Runner") -> GizmateTool {
        GizmateTool(name: name, kind: .python, input: .selection, output: .clipboard)
    }

    // MARK: - What saving approves

    /// Code Gizmate itself ran while building needs no second consent: this
    /// exact script already executed in front of the user.
    func testAppliedCodeThatAlreadyRanApprovesOnSave() {
        let tools = scratchTools()
        let gizmo = makeDraft(tools: tools)
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "prints one",
            summary: "prints one", assurance: .verified, ranAlready: true
        )

        let saved = gizmo.save()

        XCTAssertNotNil(saved)
        XCTAssertTrue(ToolApprovals.isApproved(saved!.id, hash: tools.approvalHash(for: saved!)))
    }

    /// A candidate nobody ran still meets the run gate.
    func testAppliedCodeThatNeverRanDoesNotApprove() {
        let tools = scratchTools()
        let gizmo = makeDraft(tools: tools)
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "prints one",
            summary: nil, assurance: .unverified, ranAlready: false
        )

        let saved = gizmo.save()

        XCTAssertFalse(ToolApprovals.isApproved(saved!.id, hash: tools.approvalHash(for: saved!)))
    }

    /// The one the `didSet` exists for. Editing anything after code has run
    /// means the thing that ran is not the thing being saved, so the approval
    /// has to go with it — and it must not be possible to route around by
    /// writing the field directly.
    func testEditingAfterARunTakesTheApprovalWithIt() {
        let tools = scratchTools()
        let gizmo = makeDraft(tools: tools)
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "prints one",
            summary: nil, assurance: .verified, ranAlready: true
        )

        gizmo.draft.timeoutSeconds = 99

        let saved = gizmo.save()
        XCTAssertFalse(ToolApprovals.isApproved(saved!.id, hash: tools.approvalHash(for: saved!)))
    }

    /// `apply` writes three fields in a row, and the invalidation edge must not
    /// fire between them: seeing the draft half-written would throw away the
    /// standing the build just earned.
    func testApplyingDoesNotInvalidateItsOwnWrite() {
        let gizmo = makeDraft()
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "prints one",
            summary: nil, assurance: .verified, ranAlready: true
        )
        XCTAssertTrue(gizmo.candidateIsFresh)
    }

    // MARK: - Running

    func testAPassedRunIsRemembered() async {
        let gizmo = makeDraft(runner: { _, _, _ in .passed("done") })
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "b",
            summary: nil, assurance: nil, ranAlready: false
        )

        let outcome = await gizmo.runTest()

        XCTAssertEqual(outcome?.report, "done")
        if case .passed = gizmo.test {} else { XCTFail("expected passed, got \(gizmo.test)") }
    }

    /// A verdict about code that no longer exists must not be adopted by the
    /// code that replaced it.
    func testAResultIsDiscardedWhenTheDraftMovedWhileItRan() async {
        let gizmo = makeDraft()
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "b",
            summary: nil, assurance: nil, ranAlready: false
        )
        // Slow on purpose: the edit has to land while the run is genuinely in
        // flight, which is the only moment the guard is doing anything.
        let moving = GizmoDraft(
            subject: .new,
            tools: scratchTools(),
            runner: { _, _, _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
                return .passed("stale")
            }
        )
        moving.apply(
            tool: python(), script: "print(1)", brief: "b",
            summary: nil, assurance: nil, ranAlready: false
        )
        // Edit while the run is in flight, which is what a user typing does.
        async let outcome = moving.runTest()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 30_000_000)
        moving.script = "print(2)"

        let result = await outcome
        XCTAssertNil(result, "a stale run's verdict must not be adopted")
        _ = gizmo
    }

    func testCancellingARunLeavesItIdleRatherThanRunning() async {
        let gizmo = makeDraft(runner: { _, _, _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .passed("late")
        })
        gizmo.apply(
            tool: python(), script: "print(1)", brief: "b",
            summary: nil, assurance: nil, ranAlready: false
        )

        async let running = gizmo.runTest()
        await Task.yield()
        gizmo.cancelRun()
        _ = await running

        XCTAssertFalse(gizmo.test.isRunning)
    }

    // MARK: - Hydration

    func testAnExistingGizmoOpensOnWhatWasSaved() {
        let tools = scratchTools()
        var tool = python("Saved one")
        tool.brief = "does a thing"
        let stored = tools.save(tool, script: "print('hi')")

        let gizmo = GizmoDraft(subject: .existing(stored.id), tools: tools, runner: { _, _, _ in .idle })

        XCTAssertEqual(gizmo.draft.name, "Saved one")
        XCTAssertEqual(gizmo.script, "print('hi')")
        XCTAssertEqual(gizmo.brief, "does a thing")
        XCTAssertTrue(gizmo.hasTool)
    }

    func testANewGizmoStartsEmptyAndUnsaveable() {
        let gizmo = makeDraft()
        XCTAssertFalse(gizmo.hasTool)
        XCTAssertFalse(gizmo.canSave)
        XCTAssertNil(gizmo.save())
    }

    /// A python gizmo with no script cannot be saved, whatever else is filled
    /// in: there would be nothing to run.
    func testAPythonGizmoWithNoScriptCannotBeSaved() {
        let gizmo = makeDraft()
        gizmo.draft = python()
        XCTAssertFalse(gizmo.canSave)
        gizmo.script = "print(1)"
        XCTAssertTrue(gizmo.canSave)
    }
}

/// One gizmo, one draft, however many surfaces are looking at it.
@MainActor
final class GizmoBuilderTests: XCTestCase {
    private func makeBuilder() -> GizmoBuilder {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GizmoBuilderTests.\(UUID().uuidString)")
        return GizmoBuilder(
            tools: ToolsStore(directoryURL: dir, migrateLegacy: false),
            runner: { _, _, _ in .idle }
        )
    }

    /// The bug this prevents is silent: the chat changing a gizmo while its
    /// Details modal is open, each with its own copy, and the second save
    /// overwriting the first without either surface noticing.
    func testTwoAsksForTheSameGizmoGetTheSameDraft() {
        let builder = makeBuilder()
        let id = UUID()

        let first = builder.draft(for: .existing(id))
        let second = builder.draft(for: .existing(id))

        XCTAssertTrue(first === second)
    }

    func testDifferentGizmosGetDifferentDrafts() {
        let builder = makeBuilder()
        XCTAssertFalse(builder.draft(for: .existing(UUID())) === builder.draft(for: .new))
    }

    /// After saving or abandoning, the next open has to show what is on disk
    /// rather than what was typed before it.
    func testDiscardingMeansTheNextAskHydratesAfresh() {
        let builder = makeBuilder()
        let first = builder.draft(for: .new)

        builder.discard(.new)

        XCTAssertFalse(builder.draft(for: .new) === first)
    }
}
