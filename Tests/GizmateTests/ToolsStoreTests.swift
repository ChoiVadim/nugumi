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
}
