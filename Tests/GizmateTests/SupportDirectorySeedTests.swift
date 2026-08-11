import XCTest
@testable import Gizmate

/// Gizmate ships under its own bundle ID so it installs beside an existing
/// Nugumi rather than on top of it. The price of that is a fresh support
/// directory, and the one thing in the old one nobody can re-create by clicking
/// is their API keys. `GizmatePaths.seed` is what carries them across, once.
///
/// The interesting half is what it *skips*. uv's interpreters and package cache
/// are hundreds of megabytes and re-download on demand, so copying them would
/// turn a first launch into a disk-filling stall for no gain.
final class SupportDirectorySeedTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testCarriesCredentialsAndGizmosButNotRegenerableCaches() throws {
        let legacy = try makeLegacy(
            files: ["anthropic.key", "openai.codex.tokens.json"],
            directories: ["Tools", "Secrets", "python", "cache", "bin", "ToolAgentRuns"]
        )
        let fresh = scratch.appending(path: "Gizmate", directoryHint: .isDirectory)

        GizmatePaths.seed(fresh, from: legacy)

        for kept in ["anthropic.key", "openai.codex.tokens.json", "Tools", "Secrets"] {
            XCTAssertTrue(exists(kept, in: fresh), "\(kept) should have been carried across")
        }
        for skipped in ["python", "cache", "bin", "ToolAgentRuns"] {
            XCTAssertFalse(exists(skipped, in: fresh), "\(skipped) is regenerable and should be skipped")
        }
    }

    /// A copy, not a move: the Nugumi still installed has to keep working.
    func testLeavesTheLegacyDirectoryIntact() throws {
        let legacy = try makeLegacy(files: ["anthropic.key"], directories: ["Tools"])
        let fresh = scratch.appending(path: "Gizmate", directoryHint: .isDirectory)

        GizmatePaths.seed(fresh, from: legacy)

        XCTAssertTrue(exists("anthropic.key", in: legacy))
        XCTAssertTrue(exists("Tools", in: legacy))
    }

    /// Someone who never ran Nugumi has no legacy directory at all, and that is
    /// the common case for anyone new. It must not be an error, and it must not
    /// leave a half-made folder behind for the caller to trip over.
    func testNoLegacyDirectoryIsNotAnError() {
        let fresh = scratch.appending(path: "Gizmate", directoryHint: .isDirectory)

        GizmatePaths.seed(fresh, from: scratch.appending(path: "Nugumi", directoryHint: .isDirectory))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    private func makeLegacy(files: [String], directories: [String]) throws -> URL {
        let legacy = scratch.appending(path: "Nugumi", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: legacy.appending(path: file))
        }
        for directory in directories {
            let url = legacy.appending(path: directory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: url.appending(path: "entry"))
        }
        return legacy
    }

    private func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path)
    }
}
