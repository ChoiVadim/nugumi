import Foundation

/// Where the Node runtime and a sidecar entry point live. `entry` is the file
/// name inside `dist`: `agent.mjs` builds a tool, `run.mjs` runs an agent tool.
/// Both ship in the same place and are found the same way.
struct ToolAgentRuntimeLocation {
    let node: URL
    let agent: URL

    static let defaultSourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func resolve(
        entry: String = "agent.mjs",
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        sourceRoot: URL = ToolAgentRuntimeLocation.defaultSourceRoot
    ) throws -> Self {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let packaged = Self(
            node: contents
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("ToolAgentNode"),
            agent: contents
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ToolAgent", isDirectory: true)
                .appendingPathComponent("dist", isDirectory: true)
                .appendingPathComponent(entry)
        )
        if packaged.isUsable {
            return packaged
        }

        // A real app bundle must be self-contained. The source-tree fallback is
        // only for local `swift run` and XCTest development.
        guard bundleURL.pathExtension.lowercased() != "app" else {
            throw ToolAgentLiveBuilderError.runtimeUnavailable
        }
        for root in [currentDirectory, sourceRoot] {
            let runtime = root
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("tool-agent-runtime", isDirectory: true)
                .appendingPathComponent("arm64", isDirectory: true)
            let node = runtime.appendingPathComponent("node")
            // The source tree's own build wins over the copy staged into
            // .build. They are two different files, and a stale copy does not
            // fail loudly — it fails as a protocol violation halfway through a
            // build, with nothing pointing at the real cause. Editing the
            // sidecar and running its build should be enough.
            let candidates = [
                root
                    .appendingPathComponent("ToolAgent", isDirectory: true)
                    .appendingPathComponent("dist", isDirectory: true)
                    .appendingPathComponent(entry),
                runtime
                    .appendingPathComponent("dist", isDirectory: true)
                    .appendingPathComponent(entry),
            ]
            for agent in candidates {
                let development = Self(node: node, agent: agent)
                if development.isUsable {
                    return development
                }
            }
        }
        throw ToolAgentLiveBuilderError.runtimeUnavailable
    }

    private var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: node.path)
            && FileManager.default.isReadableFile(atPath: agent.path)
    }
}
