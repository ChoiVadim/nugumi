import GizmateToolAgentCore
import XCTest
@testable import Gizmate

@MainActor
final class ToolsStoreTests: XCTestCase {
    func testEditorFingerprintChangesWhenScriptOrManifestChanges() {
        var tool = GizmateTool(
            name: "Uppercase",
            kind: .python,
            input: .selection,
            output: .clipboard,
            brief: "Uppercases text."
        )
        let original = ToolEditorDraftVerification.fingerprint(
            tool: tool,
            script: "print('one')",
            brief: tool.brief
        )
        let changedScript = ToolEditorDraftVerification.fingerprint(
            tool: tool,
            script: "print('two')",
            brief: tool.brief
        )
        tool.timeoutSeconds += 15
        let changedManifest = ToolEditorDraftVerification.fingerprint(
            tool: tool,
            script: "print('one')",
            brief: tool.brief
        )

        XCTAssertNotEqual(original, changedScript)
        XCTAssertNotEqual(original, changedManifest)
    }

    func testEditorFingerprintUsesEffectiveBrief() {
        let tool = GizmateTool(
            name: "Uppercase",
            kind: .python,
            input: .selection,
            output: .clipboard
        )

        XCTAssertNotEqual(
            ToolEditorDraftVerification.fingerprint(
                tool: tool,
                script: "print('ok')",
                brief: "First request"
            ),
            ToolEditorDraftVerification.fingerprint(
                tool: tool,
                script: "print('ok')",
                brief: "Changed request"
            )
        )
    }

    func testSavingNonPythonToolRemovesStalePythonSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-tools-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolsStore(directoryURL: directory, migrateLegacy: false)
        var tool = GizmateTool(
            name: "Uppercase",
            kind: .python,
            input: .selection,
            output: .clipboard,
            brief: "Uppercases text."
        )

        store.save(tool, script: "import sys\nprint(sys.argv[1].upper())\n")
        XCTAssertNotNil(store.script(for: tool.id))

        tool.kind = .native
        tool.nativeAction = .openApp
        tool.target = "Notes"
        store.save(tool, script: nil)

        XCTAssertNil(store.script(for: tool.id))
        XCTAssertNil(store.scriptHash(for: tool.id))
    }

    func testASurfaceGizmoKeepsItsLayoutAcrossASaveAndLoad() throws {
        let layout = ToolAgentLayoutV1.grid(
            cell: .card(title: .key("name"), subtitle: nil, icon: .file(key: "path"),
                        drag: .file(key: "path"), tap: .reveal(key: "path")),
            minimumWidth: 96, empty: "Nothing here"
        )
        var tool = GizmateTool()
        tool.name = "Downloads"
        tool.kind = .python
        tool.input = .none
        tool.output = .surface
        tool.layout = layout

        let reloaded = try JSONDecoder().decode(
            GizmateTool.self, from: JSONEncoder().encode(tool)
        )
        XCTAssertEqual(reloaded.layout, layout)
        XCTAssertEqual(reloaded.output, .surface)
    }

    /// Lenient, like every other field here: a layout this version cannot read
    /// must not take the gizmo's name, script and secrets down with it.
    func testAnUnreadableLayoutLeavesTheRestOfTheGizmoIntact() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Downloads","kind":"python","#
            + #""input":"none","output":"surface","layout":{"node":"webview"},"#
            + #""prompt":"","target":"","brief":"","symbolName":"tray","#
            + #""timeoutSeconds":120,"createdAt":0}"#
        let tool = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
        XCTAssertEqual(tool.name, "Downloads")
        XCTAssertNil(tool.layout)
    }

    /// A surface with no layout cannot draw. `isUsable` is what keeps it out of
    /// the dock catalog rather than a crash at render time.
    func testASurfaceWithoutALayoutIsNotUsable() {
        var tool = GizmateTool()
        tool.name = "Downloads"
        tool.kind = .python
        tool.output = .surface
        tool.layout = nil
        XCTAssertFalse(tool.isUsable)
    }
}
