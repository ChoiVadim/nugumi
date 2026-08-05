import XCTest
@testable import Gizmate

/// `FolderHubRows` is the whole reason this feature can skip a gizmo's script
/// and approval machinery — it has to get the filesystem-facing details right
/// on its own: newest first, hidden files and subdirectories left out, the
/// limit actually capping, and a bad path never throwing.
final class FolderHubRowsTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderHubRowsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `/var` is itself a symlink to `/private/var` on macOS, and
        // `FileManager.contentsOfDirectory` hands back the fully-resolved
        // form — but `URL.resolvingSymlinksInPath()` deliberately leaves
        // `/tmp`, `/var` and `/etc` alone, so it can't be used to match that.
        // `realpath(3)` has no such special case, so it is what actually
        // keeps the path comparisons below honest.
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    @discardableResult
    private func write(_ name: String, in dir: URL, content: String = "x", modified: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testNewestFileComesFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try write("old.txt", in: dir, modified: now.addingTimeInterval(-100))
        try write("new.txt", in: dir, modified: now)

        let rows = FolderHubRows.rows(in: dir, limit: 10)

        XCTAssertEqual(rows.map { $0["name"] }, ["new.txt", "old.txt"])
    }

    func testLimitCapsTheRowCount() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<5 {
            try write("file\(index).txt", in: dir, modified: Date().addingTimeInterval(Double(index)))
        }

        let rows = FolderHubRows.rows(in: dir, limit: 3)

        XCTAssertEqual(rows.count, 3)
    }

    func testHiddenFilesAreSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(".DS_Store", in: dir, modified: Date())
        try write("visible.txt", in: dir, modified: Date())

        let rows = FolderHubRows.rows(in: dir, limit: 10)

        XCTAssertEqual(rows.map { $0["name"] }, ["visible.txt"])
    }

    func testSubdirectoriesAreExcluded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try write("file.txt", in: dir, modified: Date())

        let rows = FolderHubRows.rows(in: dir, limit: 10)

        XCTAssertEqual(rows.map { $0["name"] }, ["file.txt"])
    }

    func testAnUnreadableFolderYieldsNoRowsRatherThanThrowing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderHubRowsTests-missing-\(UUID().uuidString)")

        XCTAssertEqual(FolderHubRows.rows(in: missing, limit: 10), [])
    }

    func testRowCarriesPathNameAndAFormattedSize() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("file.txt", in: dir, content: String(repeating: "a", count: 2048), modified: Date())

        let rows = FolderHubRows.rows(in: dir, limit: 10)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, url.path)
        XCTAssertEqual(rows[0]["path"], url.path)
        XCTAssertEqual(rows[0]["name"], "file.txt")
        // Not pinned to a literal string — `ByteCountFormatter`'s exact
        // wording ("2 KB" vs "2 kB") is locale/OS-version behaviour, not
        // something this feature owns. What it owns is that it ran at all.
        XCTAssertNotEqual(rows[0]["size"], "")
        XCTAssertNotNil(rows[0]["size"])
    }
}
