import CryptoKit
import GizmateToolAgentCore
import XCTest

@testable import Gizmate

final class ToolSecretsTests: XCTestCase {
    func testValidNamesAreEnvironmentVariableShaped() {
        XCTAssertTrue(ToolSecrets.isValidName("OPENAI_API_KEY"))
        XCTAssertTrue(ToolSecrets.isValidName("A"))
        XCTAssertTrue(ToolSecrets.isValidName("KEY2"))
    }

    func testInvalidNamesAreRejected() {
        for name in [
            "",
            "openai_api_key",        // lowercase can't be exported predictably
            "OPENAI KEY",            // space
            "OPENAI-KEY",            // hyphen
            "2FA_TOKEN",             // leading digit is not a valid identifier
            "_PRIVATE",              // leading underscore
            "КЛЮЧ",                  // uppercase, but not ASCII
            String(repeating: "A", count: 65),
        ] {
            XCTAssertFalse(ToolSecrets.isValidName(name), "should reject \(name)")
        }
    }

    /// The name is spliced straight into a path. This is the check that stops a
    /// tool manifest — which a model writes — from reading anything on disk it
    /// likes by declaring it as a secret.
    func testNamesCannotEscapeTheSecretsDirectory() {
        for name in [
            "../../../../etc/passwd",
            "..",
            "SOME/PATH",
            ".ssh",
        ] {
            XCTAssertFalse(ToolSecrets.isValidName(name), "should reject \(name)")
            XCTAssertNil(ToolSecrets.value(for: name), "should not read \(name)")
            XCTAssertTrue(ToolSecrets.environment(for: [name]).isEmpty)
        }
    }

    /// A declared-but-unstored secret is absent rather than empty, so a script's
    /// `os.environ.get(...)` says something true about whether the user filled
    /// it in.
    func testUnstoredSecretsAreAbsentFromTheEnvironment() {
        let missing = "GIZMATE_TEST_DEFINITELY_NOT_STORED"
        XCTAssertNil(ToolSecrets.environment(for: [missing])[missing])
    }

    /// `ToolAgentModelActionValidator` accepts a candidate by re-encoding it and
    /// comparing byte for byte against what the model sent. If `secretNames` is
    /// ever encoded unconditionally, every Python candidate written without it —
    /// which is nearly all of them — starts failing validation, and the symptom
    /// is builds that die at write_candidate with no useful diagnostic.
    func testCandidateWithoutSecretsDoesNotEncodeTheKey() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .python,
            name: "Uppercase",
            brief: "Uppercases text.",
            symbolName: "textformat",
            input: .clipboardText,
            output: .clipboard,
            trigger: .always,
            source: "print('OK')",
            timeoutSeconds: 30
        )
        let json = try XCTUnwrap(
            String(data: ToolAgentCanonicalJSONV1.encode(candidate), encoding: .utf8)
        )
        XCTAssertFalse(json.contains("secretNames"))

        let withSecret = try ToolAgentCandidateV1(
            kind: .python,
            name: "Uppercase",
            brief: "Uppercases text.",
            symbolName: "textformat",
            input: .clipboardText,
            output: .clipboard,
            trigger: .always,
            source: "print('OK')",
            timeoutSeconds: 30,
            secretNames: ["OPENAI_API_KEY"]
        )
        let withSecretJSON = try XCTUnwrap(
            String(data: ToolAgentCanonicalJSONV1.encode(withSecret), encoding: .utf8)
        )
        XCTAssertTrue(withSecretJSON.contains("OPENAI_API_KEY"))
    }

    /// A manifest is a file on disk and the names in it reach `ToolSecrets`, so
    /// the shape is enforced on the way in too.
    func testManifestDecodeDropsUnusableSecretNames() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Leaky",
          "kind": "python",
          "secretNames": ["OPENAI_API_KEY", "../../../../etc/passwd", "lowercase"]
        }
        """
        let tool = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
        XCTAssertEqual(tool.secretNames, ["OPENAI_API_KEY"])
    }
}

@MainActor
final class ToolSecretApprovalTests: XCTestCase {
    private func makeStore() throws -> ToolsStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-secret-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ToolsStore(directoryURL: directory, migrateLegacy: false)
    }

    /// The approval gate is "you approved *this* script"; handing that same
    /// script a key it did not have is a different thing to approve. If this
    /// fails, adding a secret to an already-approved tool takes effect silently.
    func testHashChangesWhenSecretsChangeAndScriptDoesNot() throws {
        let store = try makeStore()
        var tool = GizmateTool(name: "Fetch", kind: .python, brief: "Fetches.")
        store.save(tool, script: "print('hi')")
        let before = store.scriptHash(for: tool.id)
        XCTAssertNotNil(before)

        tool.secretNames = ["OPENAI_API_KEY"]
        store.save(tool, script: "print('hi')")
        let after = store.scriptHash(for: tool.id)

        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after)
        XCTAssertFalse(ToolApprovals.isApproved(tool.id, hash: after))
    }

    /// Order is not a permission change, so re-saving the same set in a different
    /// order must not re-prompt.
    func testHashIgnoresSecretOrder() throws {
        let store = try makeStore()
        var tool = GizmateTool(name: "Fetch", kind: .python, brief: "Fetches.")
        tool.secretNames = ["A_KEY", "B_KEY"]
        store.save(tool, script: "print('hi')")
        let first = store.scriptHash(for: tool.id)

        tool.secretNames = ["B_KEY", "A_KEY"]
        store.save(tool, script: "print('hi')")

        XCTAssertEqual(first, store.scriptHash(for: tool.id))
    }

    /// Every tool approved before secrets existed has none, and must keep its
    /// approval across the upgrade instead of re-prompting on next use.
    func testHashIsUnchangedForToolsWithoutSecrets() throws {
        let store = try makeStore()
        let tool = GizmateTool(name: "Fetch", kind: .python, brief: "Fetches.")
        store.save(tool, script: "print('hi')")

        let plain = SHA256.hash(data: Data("print('hi')".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(store.scriptHash(for: tool.id), plain)
    }
}
