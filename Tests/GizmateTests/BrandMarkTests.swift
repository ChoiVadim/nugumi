import AppKit
import XCTest
@testable import Gizmate

/// The menu bar mark is derived from the artwork at runtime rather than shipped
/// as a hand-made asset, so the mask builder is the thing that can silently
/// break — either by filling the eye slots in (a featureless blob) or by biting
/// chunks out of the silhouette where the plate meets the body.
final class BrandMarkTests: XCTestCase {
    func testTemplateMarkIsATemplateWithSaneProportions() throws {
        let mark = try XCTUnwrap(BrandMark.templateImage(height: 18))
        XCTAssertTrue(mark.isTemplate, "A coloured status item would vanish on a dark menu bar.")
        XCTAssertEqual(mark.size.height, 18, accuracy: 0.5)
        // The artwork is roughly square; a wildly different ratio means the
        // content box was measured wrong.
        let ratio = mark.size.width / mark.size.height
        XCTAssertGreaterThan(ratio, 0.6)
        XCTAssertLessThan(ratio, 1.6)
    }

    func testEyeSlotsArePunchedThroughTheSilhouette() throws {
        // Ask for a large mark so the slots survive the box filter and the
        // assertion is about the mask, not about downsampling.
        let mark = try XCTUnwrap(BrandMark.templateImage(height: 128))
        let rep = try XCTUnwrap(mark.representations.first as? NSBitmapImageRep)
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let data = try XCTUnwrap(rep.bitmapData)
        let samples = rep.samplesPerPixel

        func alpha(_ x: Int, _ y: Int) -> Int {
            Int(data[y * rep.bytesPerRow + x * samples + 3])
        }

        // Walk each row and count transparent runs that have opaque pixels on
        // both sides — those are holes rather than background. The eyes are the
        // only holes in the mark, so finding none means they were filled in.
        var rowsWithHoles = 0
        for y in 0..<height {
            var firstOpaque = -1, lastOpaque = -1
            for x in 0..<width where alpha(x, y) > 127 {
                if firstOpaque < 0 { firstOpaque = x }
                lastOpaque = x
            }
            guard firstOpaque >= 0, lastOpaque > firstOpaque else { continue }
            let hasHole = (firstOpaque...lastOpaque).contains { alpha($0, y) <= 127 }
            if hasHole { rowsWithHoles += 1 }
        }

        XCTAssertGreaterThan(
            rowsWithHoles, 0,
            "No enclosed transparent region — the eye slots were filled in, leaving a blob."
        )
        // The slots are a small feature. If most of the mark is holes, the mask
        // inverted or the brightness threshold caught the body too.
        XCTAssertLessThan(rowsWithHoles, height / 2)
    }
}
