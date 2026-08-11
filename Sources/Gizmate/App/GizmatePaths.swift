import Foundation

/// Every byte Gizmate writes outside UserDefaults lives under one directory, so a
/// full reset is a single `rm -rf` (see the `reset-new-user` flow) and nothing
/// Gizmate installs ever touches the user's own tooling.
///
/// `~/Library/Application Support/Gizmate/`
///   `Tools/<uuid>/tool.json` + `main.py`  — one folder per tool
///   `bin/`                               — the pinned `uv` binary
///   `python/`                            — uv's managed interpreters
///   `cache/`                             — uv's package cache
enum GizmatePaths {
    /// The app's support directory, created on first access. The one place it is
    /// named: `KeychainStore.storageDirectory` reads back through here so API
    /// keys cannot end up in a different folder than the gizmos.
    static let root: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appending(path: "Gizmate", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            seed(dir, from: appSupport.appending(path: "Nugumi", directoryHint: .isDirectory))
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Regenerable on demand, and large: uv's pinned binary, its managed
    /// interpreters, its package cache, and two run-scratch directories. Together
    /// they are most of the folder's bytes and none of its value.
    static let regenerable: Set<String> = [
        "bin", "python", "cache", "ToolAgentRuns", "ToolWorkerGate",
    ]

    /// Gizmate installs *beside* an existing Nugumi rather than over it, which
    /// means a different bundle ID and therefore its own support directory. A
    /// beta user should not have to re-enter API keys or rebuild gizmos to get
    /// that, so the first launch copies across what is not regenerable. A copy,
    /// not a move: the Nugumi still on their Mac has to keep working.
    static func seed(_ dir: URL, from legacy: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil
        ) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries where !regenerable.contains(entry.lastPathComponent) {
            try? fm.copyItem(at: entry, to: dir.appending(path: entry.lastPathComponent))
        }
    }

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
            .appending(path: "gizmate-tool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
