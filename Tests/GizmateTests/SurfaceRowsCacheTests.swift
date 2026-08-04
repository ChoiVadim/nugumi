import XCTest
@testable import Gizmate

@MainActor
final class SurfaceRowsCacheTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testItGivesBackWhatItWasGiven() throws {
        let cache = SurfaceRowsCache(directory: try scratch())
        let id = UUID()
        cache.store([SurfaceRow(id: "1", values: ["name": "a.txt"])], for: id)
        XCTAssertEqual(cache.rows(for: id).first?["name"], "a.txt")
    }

    func testAnUnknownGizmoHasNoRows() throws {
        XCTAssertEqual(SurfaceRowsCache(directory: try scratch()).rows(for: UUID()), [])
    }

    /// The cache is what the dock draws before the script has finished. A file
    /// left behind by an older build must read as "nothing cached", never as a
    /// throw on the render path.
    func testUnreadableCacheReadsAsEmpty() throws {
        let directory = try scratch()
        let id = UUID()
        try Data("not json".utf8).write(
            to: directory.appending(path: "surface-\(id.uuidString).json")
        )
        XCTAssertEqual(SurfaceRowsCache(directory: directory).rows(for: id), [])
    }
}
