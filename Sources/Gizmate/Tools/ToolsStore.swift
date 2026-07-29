import AppKit
import Combine
import CryptoKit
import Foundation

/// The user's tools, one folder each under `GizmatePaths.tools`:
///
///   `Tools/<uuid>/tool.json`   the manifest
///   `Tools/<uuid>/main.py`     the script, for `.python` tools only
///
/// On disk rather than in UserDefaults because a script wants to be a file the
/// user can read, and because a folder makes export/import a zip later. Same
/// `@Published` + `onChange` contract as `SnippetsStore` so the UI binds the
/// same way.
@MainActor
final class ToolsStore: ObservableObject {
    @Published private(set) var tools: [GizmateTool] = []
    var onChange: (() -> Void)?

    /// The pre-disk storage key. Read once to migrate, then removed.
    private static let legacyDefaultsKey = "promptTools"
    private static let manifestName = "tool.json"
    static let scriptName = "main.py"
    private let directoryURL: URL

    init(directoryURL: URL = GizmatePaths.tools, migrateLegacy: Bool = true) {
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if migrateLegacy {
            migrateFromDefaultsIfNeeded()
        }
        load()
    }

    // MARK: - Reads

    func tool(id: UUID) -> GizmateTool? {
        tools.first { $0.id == id }
    }

    func usableTools() -> [GizmateTool] {
        tools.filter(\.isUsable)
    }

    func directory(for id: UUID) -> URL {
        directoryURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func scriptURL(for id: UUID) -> URL {
        directory(for: id).appending(path: Self.scriptName, directoryHint: .notDirectory)
    }

    func script(for id: UUID) -> String? {
        try? String(contentsOf: scriptURL(for: id), encoding: .utf8)
    }

    /// A script tool with no script can't run — the ring skips it and the editor
    /// shows it as unfinished.
    func isRunnable(_ tool: GizmateTool) -> Bool {
        guard tool.isUsable else { return false }
        guard tool.kind == .python else { return true }
        // A script tool with no script can't run; the other kinds carry
        // everything they need in the manifest.
        let script = script(for: tool.id)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(script ?? "").isEmpty
    }

    /// SHA-256 of what the user is actually approving: the current script **and**
    /// the secrets it will be handed. Used to re-ask for confirmation whenever
    /// either changes — bolting `AWS_SECRET_KEY` onto an already-approved tool
    /// widens what it can reach, and is not something to wave through on an
    /// approval the user gave for a script that had no keys at all.
    ///
    /// nil for a prompt tool or a missing script. The secret names are folded in
    /// only when there are some, so every tool approved before secrets existed
    /// keeps its approval instead of re-prompting on upgrade.
    func scriptHash(for id: UUID) -> String? {
        guard let data = try? Data(contentsOf: scriptURL(for: id)) else { return nil }
        let names = tool(id: id)?.secretNames.sorted() ?? []
        guard !names.isEmpty else {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var hasher = SHA256()
        hasher.update(data: data)
        hasher.update(data: Data("\nsecrets:\(names.joined(separator: ","))".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What the user's approval is *of*, which differs by kind. A script tool is
    /// approved for its exact code; an agent tool has no code to approve, so the
    /// approval covers the three things that decide what it may do — its
    /// instruction, how many scripts it may run, and which keys it is handed.
    /// A prompt or native tool needs no approval at all.
    func approvalHash(for tool: GizmateTool) -> String? {
        switch tool.kind {
        case .python:
            return scriptHash(for: tool.id)
        case .agent:
            var hasher = SHA256()
            hasher.update(data: Data(tool.prompt.utf8))
            hasher.update(data: Data("\nsteps:\(tool.maxSteps)".utf8))
            hasher.update(
                data: Data("\nsecrets:\(tool.secretNames.sorted().joined(separator: ","))".utf8)
            )
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .prompt, .native:
            return nil
        }
    }

    // MARK: - Writes

    @discardableResult
    func save(_ tool: GizmateTool, script: String? = nil) -> GizmateTool {
        let dir = directory(for: tool.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(tool) {
            try? data.write(to: dir.appending(path: Self.manifestName), options: .atomic)
        }
        if let script {
            try? script.write(to: scriptURL(for: tool.id), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: scriptURL(for: tool.id))
        }

        if let idx = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[idx] = tool
        } else {
            tools.append(tool)
        }
        onChange?()
        return tool
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        tools.removeAll { $0.id == id }
        onChange?()
    }

    // MARK: - Loading

    private func load() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        tools = entries.compactMap { dir -> GizmateTool? in
            let manifest = dir.appending(path: Self.manifestName, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? decoder.decode(GizmateTool.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// One-time move of the prompt tools that shipped in the UserDefaults blob.
    /// Runs before `load()`, then drops the key so it can't run twice.
    private func migrateFromDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else { return }
        defer { defaults.removeObject(forKey: Self.legacyDefaultsKey) }

        guard let legacy = try? JSONDecoder().decode([GizmateTool].self, from: data) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for tool in legacy {
            let dir = directory(for: tool.id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let encoded = try? encoder.encode(tool) {
                try? encoded.write(to: dir.appending(path: Self.manifestName), options: .atomic)
            }
        }
    }
}

/// Tools whose code the user has read and approved, keyed by tool id → script
/// hash. A script tool asks for confirmation on its first run and again whenever
/// its code changes; nothing here grants standing permission to a *different*
/// script under the same name.
enum ToolApprovals {
    private static let defaultsKey = "toolApprovedScriptHashes"

    static func isApproved(_ id: UUID, hash: String?) -> Bool {
        guard let hash else { return false }
        return stored()[id.uuidString] == hash
    }

    static func approve(_ id: UUID, hash: String?) {
        guard let hash else { return }
        var map = stored()
        map[id.uuidString] = hash
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    static func revoke(_ id: UUID) {
        var map = stored()
        map.removeValue(forKey: id.uuidString)
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
