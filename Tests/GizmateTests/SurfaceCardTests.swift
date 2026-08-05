import GizmateToolAgentCore
import XCTest
@testable import Gizmate

final class SurfaceCardTests: XCTestCase {
    func testAPresentNonEmptyValueResolves() {
        let row = SurfaceRow(id: "1", values: ["path": "/tmp/a.txt"])
        XCTAssertEqual(SurfaceCard.path(for: "path", in: row), "/tmp/a.txt")
    }

    /// The bug this closes (I2): `URL(fileURLWithPath: "")` resolves to the
    /// process's working directory, and `NSItemProvider(contentsOf:)` hands
    /// out a live provider for it. Treating an empty value as "no path"
    /// rather than "the path is empty" is what keeps a stale row from
    /// dragging out the volume root.
    func testAnEmptyValueResolvesToNilNotAnEmptyString() {
        let row = SurfaceRow(id: "1", values: ["path": ""])
        XCTAssertNil(SurfaceCard.path(for: "path", in: row))
    }

    func testAMissingKeyResolvesToNil() {
        let row = SurfaceRow(id: "1", values: [:])
        XCTAssertNil(SurfaceCard.path(for: "path", in: row))
    }

    // MARK: - dragProvider

    func testATextDragWithAPresentValueIsLive() {
        let row = SurfaceRow(id: "1", values: ["note": "hello"])
        let provider = SurfaceCard.dragProvider(for: .text(key: "note"), in: row)
        XCTAssertFalse(provider.registeredTypeIdentifiers.isEmpty)
    }

    /// New Breakage #4 in the surface gizmos final re-review: a `.text`
    /// drag on a row missing its key used to build
    /// `NSItemProvider(object: "" as NSString)` — a provider that looks
    /// live and drops an empty string. It must be as inert as the `.file`
    /// case is for the same missing key.
    func testATextDragWithAMissingKeyIsInert() {
        let row = SurfaceRow(id: "1", values: [:])
        let provider = SurfaceCard.dragProvider(for: .text(key: "note"), in: row)
        XCTAssertTrue(provider.registeredTypeIdentifiers.isEmpty)
    }

    func testATextDragWithAnEmptyValueIsInert() {
        let row = SurfaceRow(id: "1", values: ["note": ""])
        let provider = SurfaceCard.dragProvider(for: .text(key: "note"), in: row)
        XCTAssertTrue(provider.registeredTypeIdentifiers.isEmpty)
    }
}
