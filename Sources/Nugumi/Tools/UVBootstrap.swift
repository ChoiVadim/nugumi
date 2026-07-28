import Combine
import CryptoKit
import Foundation

/// Locates (or installs) `uv`, the single binary that runs script tools.
///
/// Why uv rather than an embedded CPython: macOS ships an unusable interpreter
/// (`/usr/bin/python3` is a 3.9 Command Line Tools stub), and bundling a
/// relocatable CPython would put several hundred `.so` files inside the signed
/// app — every one of which has to be codesigned and notarized, and every one of
/// which rides along in each Sparkle delta. uv is one executable that downloads
/// its own interpreters and resolves per-script dependencies, and it lives in
/// Application Support, outside the bundle and outside the signature entirely.
///
/// Mirrors `OllamaBootstrap`'s shape: `BootstrapStepStatus` states, a `refresh()`
/// that re-detects, and an action the UI can offer.
@MainActor
final class UVBootstrap: ObservableObject {
    @Published private(set) var status: BootstrapStepStatus = .unknown
    /// The uv we found or installed. nil until `refresh()` finds one.
    @Published private(set) var executable: URL?

    var isReady: Bool { executable != nil && status.isTerminalOK }

    /// Pinned release. The SHA-256s below are the ones Astral publishes as
    /// `<asset>.sha256` for exactly this tag — bump all three together, never
    /// just the version.
    static let pinnedVersion = "0.11.26"
    private static let checksums: [String: String] = [
        "aarch64": "8f7fbf1708399b921857bce71e1d60f0d3ccf52a30caebc1c1a2f175dce13ab6",
        "x86_64": "922b460202707dd5f4ccacbadbe7f6a546cc46e82a99bf50ca99a7977a78eddd",
    ]

    #if arch(arm64)
    private static let assetArch = "aarch64"
    #else
    private static let assetArch = "x86_64"
    #endif

    private static var assetName: String { "uv-\(assetArch)-apple-darwin.tar.gz" }
    private static var assetURL: URL {
        URL(string: "https://github.com/astral-sh/uv/releases/download/\(pinnedVersion)/\(assetName)")!
    }

    /// Where we look, in order. Gizmo's own copy wins so an install we made is
    /// used even if the user later adds a different one to their PATH.
    private static var candidatePaths: [URL] {
        [
            NugumiPaths.bin.appending(path: "uv", directoryHint: .notDirectory),
            URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ]
    }

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        for candidate in Self.candidatePaths where fm.isExecutableFile(atPath: candidate.path) {
            executable = candidate
            status = .ok
            return
        }
        executable = nil
        status = .needsAction("Script tools need the uv runtime (about 35 MB).")
    }

    /// Downloads the pinned release, verifies its checksum, and unpacks the single
    /// `uv` executable into Application Support.
    ///
    /// A URLSession download carries no quarantine attribute, so the result runs
    /// without a Gatekeeper prompt — which is precisely why the checksum check is
    /// not optional and why the version is pinned rather than "latest".
    func install() async {
        guard let expected = Self.checksums[Self.assetArch] else {
            status = .failed("No uv build pinned for this architecture.")
            return
        }
        status = .working("Downloading uv…")

        do {
            let (downloaded, response) = try await URLSession.shared.download(from: Self.assetURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UVBootstrapError.download("HTTP \(http.statusCode)")
            }

            let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw UVBootstrapError.checksumMismatch(expected: expected, actual: actual)
            }

            status = .working("Unpacking…")
            let destination = try Self.unpack(archive: downloaded)
            try? FileManager.default.removeItem(at: downloaded)

            executable = destination
            status = .ok
        } catch {
            executable = nil
            status = .failed(Self.message(for: error))
        }
    }

    /// The archive holds `uv-<arch>-apple-darwin/uv` (plus `uvx`, which we don't
    /// need). Extracts to a scratch directory, then moves just `uv` into place.
    private static func unpack(archive: URL) throws -> URL {
        let scratch = try NugumiPaths.makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", scratch.path]
        let errorPipe = Pipe()
        tar.standardError = errorPipe
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw UVBootstrapError.unpack(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let fm = FileManager.default
        guard let found = fm.enumerator(at: scratch, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == "uv" })
        else {
            throw UVBootstrapError.unpack("no uv executable in the archive")
        }

        let destination = NugumiPaths.bin.appending(path: "uv", directoryHint: .notDirectory)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: found, to: destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    /// Environment every uv invocation runs with. Keeps uv's interpreters and
    /// package cache inside Application Support so Gizmo never writes into the
    /// user's own `~/.local`, and forces uv's managed Python so the unusable
    /// system 3.9 can never be picked.
    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_CACHE_DIR"] = NugumiPaths.cache.path
        env["UV_PYTHON_INSTALL_DIR"] = NugumiPaths.pythonInstall.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_PYTHON_DOWNLOADS"] = "automatic"
        env["UV_NO_MODIFY_PATH"] = "1"
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        // A bundled app inherits a bare PATH from launchd (`/usr/bin:/bin:…`), so a
        // tool that shells out to a Homebrew binary would work under `swift run`
        // and then fail in the shipped app. Append the usual locations so both
        // behave the same. Prefer declaring the dependency in the script's PEP 723
        // header over relying on this.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        var search = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for path in extraPaths where !search.contains(path) {
            search.append(path)
        }
        env["PATH"] = search.joined(separator: ":")
        return env
    }

    private static func message(for error: Error) -> String {
        switch error {
        case UVBootstrapError.checksumMismatch:
            return "The uv download didn't match its published checksum. Nothing was installed."
        case UVBootstrapError.download(let detail):
            return "Couldn't download uv: \(detail)"
        case UVBootstrapError.unpack(let detail):
            return detail.isEmpty ? "Couldn't unpack uv." : "Couldn't unpack uv: \(detail)"
        default:
            return error.localizedDescription
        }
    }
}

enum UVBootstrapError: Error {
    case download(String)
    case checksumMismatch(expected: String, actual: String)
    case unpack(String)
}
