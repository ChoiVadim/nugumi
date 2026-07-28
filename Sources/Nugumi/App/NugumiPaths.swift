import Foundation

/// Every byte Nugumi writes outside UserDefaults lives under one directory, so a
/// full reset is a single `rm -rf` (see the `reset-new-user` flow) and nothing
/// Nugumi installs ever touches the user's own tooling.
///
/// `~/Library/Application Support/Nugumi/`
///   `Tools/<uuid>/tool.json` + `main.py`  — one folder per tool
///   `bin/`                               — the pinned `uv` binary
///   `python/`                            — uv's managed interpreters
///   `cache/`                             — uv's package cache
enum NugumiPaths {
    /// The app's support directory, created on first access. Shares the location
    /// `KeychainStore.storageDirectory` already uses for API keys.
    static let root: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appending(path: "Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var tools: URL { ensure(root.appending(path: "Tools", directoryHint: .isDirectory)) }
    static var toolAgentRuns: URL {
        ensure(root.appending(path: "ToolAgentRuns", directoryHint: .isDirectory))
    }
    static var bin: URL { ensure(root.appending(path: "bin", directoryHint: .isDirectory)) }
    static var pythonInstall: URL { ensure(root.appending(path: "python", directoryHint: .isDirectory)) }
    static var cache: URL { ensure(root.appending(path: "cache", directoryHint: .isDirectory)) }

    /// A fresh scratch directory for one tool run. The caller owns cleanup.
    static func makeRunDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "nugumi-tool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
