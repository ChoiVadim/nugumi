import Foundation

/// Credentials the user hands to their own tools — an OpenAI key, a search API
/// token, whatever a script needs to authenticate with. One file per secret:
///
///   `~/Library/Application Support/Gizmate/Secrets/<NAME>`
///
/// Plain 0600 files, exactly like the provider keys `KeychainStore` writes next
/// door (which, despite the name, has never used the Keychain either). The point
/// is that a key stays something the user can rotate with a text editor and that
/// `reset-new-user`'s single `rm -rf` still takes everything with it.
///
/// A tool receives **only** the secrets it declares in `GizmateTool.secretNames`
/// (see `ToolRunner.run(secrets:)`). Handing every tool every key would make one
/// leaky script a total compromise, and tool scripts are written by a model.
enum ToolSecrets {
    /// Uppercase, digits, underscore. Env-var shaped because that is exactly
    /// what these become in the child process, and because it doubles as the
    /// path guard: a name that cannot hold `/`, `.` or a null byte cannot walk
    /// out of the secrets directory. Names arrive from tool manifests, which a
    /// model writes, so this is checked on every read — not just at entry.
    private static let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    static var directory: URL {
        let url = GizmatePaths.root.appending(path: "Secrets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count),
              name.allSatisfy(allowedCharacters.contains),
              let first = name.first,
              !first.isNumber,
              first != "_"
        else { return false }
        return true
    }

    /// Every stored secret's name, sorted. Values are never read here — the
    /// editor and the build context both want names only.
    static func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.map(\.lastPathComponent).filter(isValidName).sorted()
    }

    static func value(for name: String) -> String? {
        guard isValidName(name) else { return nil }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// - Returns: whether it was written. False for an invalid name or an empty
    ///   value, so the editor can say so instead of silently storing nothing.
    @discardableResult
    static func set(_ value: String, for name: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name), !trimmed.isEmpty else { return false }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        do {
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    static func delete(_ name: String) {
        guard isValidName(name) else { return }
        try? FileManager.default.removeItem(
            at: directory.appending(path: name, directoryHint: .notDirectory)
        )
    }

    /// The environment a tool run gets, built from the names it declared. A name
    /// with nothing stored under it is simply absent rather than empty, so a
    /// script's `os.environ.get(...)` tells the truth about whether the user has
    /// actually filled that secret in.
    static func environment(for names: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for name in names {
            guard let value = value(for: name) else { continue }
            result[name] = value
        }
        return result
    }
}
