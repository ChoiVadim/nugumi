import XCTest
@testable import Gizmate

/// The store's job is "which folders, remembered across launches, without
/// ever silently reviving a default the user removed" — so that is what is
/// worth pinning: the Downloads default, the add/remove round trip, and that
/// an explicitly-emptied list stays empty rather than snapping back.
final class FolderHubStoreTests: XCTestCase {

    @MainActor
    private func store() -> (UserDefaults, () -> Void) {
        let suiteName = "FolderHubStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderHubStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testFreshStoreDefaultsToDownloads() {
        let (defaults, cleanup) = store()
        defer { cleanup() }

        let expected = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).map(\.path)
        let sut = FolderHubStore(defaults: defaults)

        XCTAssertEqual(sut.folders.map(\.path), expected)
    }

    @MainActor
    func testAddPersistsAcrossReload() throws {
        let (defaults, cleanup) = store()
        defer { cleanup() }
        // Start from "already saved, empty" so the Downloads default doesn't
        // leak into what this test is actually checking.
        defaults.set([String](), forKey: FolderHubStore.defaultsKey)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sut = FolderHubStore(defaults: defaults)
        sut.add(dir)
        let reloaded = FolderHubStore(defaults: defaults)

        XCTAssertEqual(reloaded.folders.map(\.path), [dir.path])
    }

    @MainActor
    func testRemovingLastFolderStaysEmptyAcrossReload() throws {
        let (defaults, cleanup) = store()
        defer { cleanup() }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        defaults.set([dir.path], forKey: FolderHubStore.defaultsKey)

        let sut = FolderHubStore(defaults: defaults)
        XCTAssertEqual(sut.folders.map(\.path), [dir.path])
        sut.remove(dir)
        XCTAssertTrue(sut.folders.isEmpty)

        let reloaded = FolderHubStore(defaults: defaults)
        XCTAssertTrue(
            reloaded.folders.isEmpty,
            "removing the user's last folder must not fall back to the Downloads default"
        )
    }

    @MainActor
    func testAddIgnoresATrailingSlashDuplicate() throws {
        let (defaults, cleanup) = store()
        defer { cleanup() }
        defaults.set([String](), forKey: FolderHubStore.defaultsKey)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sut = FolderHubStore(defaults: defaults)
        sut.add(dir)
        sut.add(URL(fileURLWithPath: dir.path + "/"))

        XCTAssertEqual(sut.folders.count, 1, "the same directory named two ways is still one folder")
    }

    @MainActor
    func testAddingAnAlreadyOfferedFolderDoesNothing() throws {
        let (defaults, cleanup) = store()
        defer { cleanup() }
        defaults.set([String](), forKey: FolderHubStore.defaultsKey)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sut = FolderHubStore(defaults: defaults)
        sut.add(dir)
        sut.add(dir)

        XCTAssertEqual(sut.folders.count, 1)
    }

    @MainActor
    func testLoadDropsAPathThatNoLongerExists() {
        let (defaults, cleanup) = store()
        defer { cleanup() }
        let missing = "/private/tmp/FolderHubStoreTests-missing-\(UUID().uuidString)"
        defaults.set([missing], forKey: FolderHubStore.defaultsKey)

        let sut = FolderHubStore(defaults: defaults)

        XCTAssertTrue(sut.folders.isEmpty)
    }
}
