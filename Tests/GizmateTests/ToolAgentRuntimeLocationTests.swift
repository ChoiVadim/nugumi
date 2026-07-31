import Foundation
import XCTest

@testable import Gizmate

final class ToolAgentRuntimeLocationTests: XCTestCase {
    func testPackagedRuntimePrecedesEveryDevelopmentCandidate() throws {
        let root = try temporaryDirectory()
        let bundleURL = root.appendingPathComponent("Gizmate.app", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let packaged = try packagedRuntime(bundleURL: bundleURL)

        _ = try developmentRuntime(root: currentDirectory, staged: false)
        _ = try developmentRuntime(root: currentDirectory, staged: true)
        _ = try developmentRuntime(root: sourceRoot, staged: false)
        _ = try developmentRuntime(root: sourceRoot, staged: true)

        let resolved = try ToolAgentRuntimeLocation.resolve(
            bundleURL: bundleURL,
            currentDirectory: currentDirectory,
            sourceRoot: sourceRoot
        )

        XCTAssertEqual(resolved.node.path, packaged.node.path)
        XCTAssertEqual(resolved.agent.path, packaged.agent.path)
    }

    func testIncompleteAppRejectsUsableDevelopmentFallbacks() throws {
        let root = try temporaryDirectory()
        let bundleURL = root.appendingPathComponent("Gizmate.app", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let incomplete = packagedPaths(bundleURL: bundleURL)
        try writeFile(incomplete.node, permissions: 0o700)

        _ = try developmentRuntime(root: currentDirectory, staged: false)
        _ = try developmentRuntime(root: currentDirectory, staged: true)
        _ = try developmentRuntime(root: sourceRoot, staged: false)
        _ = try developmentRuntime(root: sourceRoot, staged: true)

        XCTAssertThrowsError(
            try ToolAgentRuntimeLocation.resolve(
                bundleURL: bundleURL,
                currentDirectory: currentDirectory,
                sourceRoot: sourceRoot
            )
        ) { error in
            guard case ToolAgentLiveBuilderError.runtimeUnavailable = error else {
                return XCTFail("Expected runtimeUnavailable, received \(error)")
            }
        }
    }

    func testDevelopmentCandidatesResolveInExactFourCandidateOrder() throws {
        let root = try temporaryDirectory()
        let bundleURL = root.appendingPathComponent("Gizmate", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)

        let currentSource = try developmentRuntime(
            root: currentDirectory,
            staged: false
        )
        let currentStaged = try developmentRuntime(
            root: currentDirectory,
            staged: true
        )
        let sourceSource = try developmentRuntime(
            root: sourceRoot,
            staged: false
        )
        let sourceStaged = try developmentRuntime(
            root: sourceRoot,
            staged: true
        )
        let candidates = [
            currentSource,
            currentStaged,
            sourceSource,
            sourceStaged,
        ]

        for expected in candidates {
            let resolved = try ToolAgentRuntimeLocation.resolve(
                bundleURL: bundleURL,
                currentDirectory: currentDirectory,
                sourceRoot: sourceRoot
            )

            XCTAssertEqual(resolved.node.path, expected.node.path)
            XCTAssertEqual(resolved.agent.path, expected.agent.path)
            try FileManager.default.removeItem(at: expected.agent)
        }
    }

    func testDefaultAndCustomEntriesResolveIndependently() throws {
        let root = try temporaryDirectory()
        let bundleURL = root.appendingPathComponent("Gizmate", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let defaultRuntime = try developmentRuntime(
            root: currentDirectory,
            entry: "agent.mjs",
            staged: false
        )
        let customRuntime = try developmentRuntime(
            root: currentDirectory,
            entry: "run.mjs",
            staged: false
        )

        let resolvedDefault = try ToolAgentRuntimeLocation.resolve(
            bundleURL: bundleURL,
            currentDirectory: currentDirectory,
            sourceRoot: sourceRoot
        )
        let resolvedCustom = try ToolAgentRuntimeLocation.resolve(
            entry: "run.mjs",
            bundleURL: bundleURL,
            currentDirectory: currentDirectory,
            sourceRoot: sourceRoot
        )

        XCTAssertEqual(resolvedDefault.agent.path, defaultRuntime.agent.path)
        XCTAssertEqual(resolvedCustom.agent.path, customRuntime.agent.path)
    }

    func testDevelopmentRuntimeRequiresExecutableNodeAndReadableAgent() throws {
        let root = try temporaryDirectory()
        let bundleURL = root.appendingPathComponent("Gizmate", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let runtime = try developmentRuntime(
            root: currentDirectory,
            staged: false,
            nodePermissions: 0o600
        )

        XCTAssertThrowsError(
            try ToolAgentRuntimeLocation.resolve(
                bundleURL: bundleURL,
                currentDirectory: currentDirectory,
                sourceRoot: sourceRoot
            )
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtime.node.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: runtime.agent.path
        )

        XCTAssertThrowsError(
            try ToolAgentRuntimeLocation.resolve(
                bundleURL: bundleURL,
                currentDirectory: currentDirectory,
                sourceRoot: sourceRoot
            )
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: runtime.agent.path
        )
        let resolved = try ToolAgentRuntimeLocation.resolve(
            bundleURL: bundleURL,
            currentDirectory: currentDirectory,
            sourceRoot: sourceRoot
        )
        XCTAssertEqual(resolved.node.path, runtime.node.path)
        XCTAssertEqual(resolved.agent.path, runtime.agent.path)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gizmate-tool-agent-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func packagedPaths(bundleURL: URL) -> (node: URL, agent: URL) {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        return (
            contents
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("ToolAgentNode"),
            contents
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ToolAgent", isDirectory: true)
                .appendingPathComponent("dist", isDirectory: true)
                .appendingPathComponent("agent.mjs")
        )
    }

    private func packagedRuntime(
        bundleURL: URL
    ) throws -> (node: URL, agent: URL) {
        let runtime = packagedPaths(bundleURL: bundleURL)
        try writeFile(runtime.node, permissions: 0o700)
        try writeFile(runtime.agent, permissions: 0o600)
        return runtime
    }

    private func developmentRuntime(
        root: URL,
        entry: String = "agent.mjs",
        staged: Bool,
        nodePermissions: Int = 0o700,
        agentPermissions: Int = 0o600
    ) throws -> (node: URL, agent: URL) {
        let stagedRoot = root
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("tool-agent-runtime", isDirectory: true)
            .appendingPathComponent("arm64", isDirectory: true)
        let node = stagedRoot.appendingPathComponent("node")
        let agentRoot = staged
            ? stagedRoot.appendingPathComponent("dist", isDirectory: true)
            : root
                .appendingPathComponent("ToolAgent", isDirectory: true)
                .appendingPathComponent("dist", isDirectory: true)
        let agent = agentRoot.appendingPathComponent(entry)
        try writeFile(node, permissions: nodePermissions)
        try writeFile(agent, permissions: agentPermissions)
        return (node, agent)
    }

    private func writeFile(_ url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}
