import XCTest

@testable import Nugumi

final class AskNugumiAnnotationTests: XCTestCase {
    private func parse(_ annotationsJSON: String) -> AskNugumiResponse {
        AskNugumiResponse.parse(
            "{\"message\":\"here\",\"annotations\":\(annotationsJSON)}"
        )
    }

    func testParsesAllFourShapeTypes() {
        let response = parse("""
        [{"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05},
         {"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10},
         {"type":"arrow","fromX":0.42,"fromY":0.45,"toX":0.55,"toY":0.32},
         {"type":"label","x":0.42,"y":0.50,"text":"click here"}]
        """)
        XCTAssertEqual(response.annotations.count, 4)
        XCTAssertEqual(response.annotations[0].type, .ellipse)
        XCTAssertEqual(response.annotations[1].type, .rect)
        XCTAssertEqual(response.annotations[2].type, .arrow)
        XCTAssertEqual(response.annotations[3].type, .label)
        XCTAssertEqual(response.annotations[3].text, "click here")
    }

    func testAbsentAnnotationsFieldYieldsEmptyArray() {
        let response = AskNugumiResponse.parse("{\"message\":\"plain\"}")
        XCTAssertEqual(response.annotations, [])
    }

    func testUnknownTypeIsDroppedOthersSurvive() {
        let response = parse("""
        [{"type":"starburst","cx":0.5,"cy":0.5,"w":0.1,"h":0.1},
         {"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05}]
        """)
        XCTAssertEqual(response.annotations.count, 1)
        XCTAssertEqual(response.annotations[0].type, .ellipse)
    }

    func testOutOfRangeAndMissingFieldsAreDropped() {
        let response = parse("""
        [{"type":"ellipse","cx":1.42,"cy":0.31,"w":0.10,"h":0.05},
         {"type":"ellipse","cx":0.42,"cy":0.31,"w":0.0,"h":0.05},
         {"type":"arrow","fromX":0.42,"fromY":0.45},
         {"type":"label","x":0.42,"y":0.50,"text":"   "},
         {"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10}]
        """)
        XCTAssertEqual(response.annotations.count, 1)
        XCTAssertEqual(response.annotations[0].type, .rect)
    }

    func testWrongFieldTypeDropsOnlyThatElement() {
        let response = parse("""
        [{"type":"ellipse","cx":"middle","cy":0.31,"w":0.10,"h":0.05},
         {"type":"arrow","fromX":0.1,"fromY":0.1,"toX":0.9,"toY":0.9}]
        """)
        XCTAssertEqual(response.annotations.count, 1)
        XCTAssertEqual(response.annotations[0].type, .arrow)
    }

    func testLabelLongerThan60CharactersIsDropped() {
        let longText = String(repeating: "a", count: 61)
        let response = parse(
            "[{\"type\":\"label\",\"x\":0.5,\"y\":0.5,\"text\":\"\(longText)\"}]"
        )
        XCTAssertEqual(response.annotations, [])
    }

    func testAnnotationsCappedAtTwelve() {
        let one = "{\"type\":\"ellipse\",\"cx\":0.5,\"cy\":0.5,\"w\":0.1,\"h\":0.1}"
        let fifteen = "[" + Array(repeating: one, count: 15).joined(separator: ",") + "]"
        let response = parse(fifteen)
        XCTAssertEqual(response.annotations.count, 12)
    }

    func testRoundTripPreservesValidAnnotations() throws {
        let original = AskNugumiResponse(
            message: "look",
            petTarget: nil,
            emotion: .happy,
            annotations: [
                AskNugumiAnnotation(
                    type: .arrow,
                    cx: nil, cy: nil, w: nil, h: nil,
                    fromX: 0.1, fromY: 0.2, toX: 0.8, toY: 0.9,
                    x: nil, y: nil, text: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AskNugumiResponse.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMalformedAnnotationsFieldFallsBackToEmpty() {
        let response = AskNugumiResponse.parse(
            "{\"message\":\"ok\",\"annotations\":\"not an array\"}"
        )
        XCTAssertEqual(response.annotations, [])
        XCTAssertEqual(response.message, "ok")
    }

    // Non-zero-origin frame (second monitor) + asymmetric y so a y-flip
    // regression fails loudly: normalized y is top-to-bottom, AppKit y is
    // bottom-up.
    private let frame = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testExactScreenPointMapsAsymmetricPoint() {
        let point = AskNugumiCoordinateMapper.exactScreenPoint(
            normalizedX: 0.25,
            normalizedY: 0.10,
            screenFrame: frame
        )
        // x: 100 + 0.25 * 400 = 200. y: near the TOP of the screen →
        // AppKit y near maxY: 500 - 0.10 * 300 = 470 (a flip would give 230).
        XCTAssertEqual(point.x, 200, accuracy: 0.001)
        XCTAssertEqual(point.y, 470, accuracy: 0.001)
    }

    func testExactScreenPointClampsToFrame() {
        let point = AskNugumiCoordinateMapper.exactScreenPoint(
            normalizedX: 1.0,
            normalizedY: 0.0,
            screenFrame: frame
        )
        XCTAssertEqual(point.x, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(point.y, frame.maxY, accuracy: 0.001)
    }

    func testScreenRectCentersOnMappedPoint() {
        let rect = AskNugumiCoordinateMapper.screenRect(
            centerX: 0.5,
            centerY: 0.25,
            normalizedWidth: 0.1,
            normalizedHeight: 0.2,
            screenFrame: frame
        )
        // Center: x = 300, y = 500 - 0.25*300 = 425. Size: 40 × 60.
        XCTAssertEqual(rect.midX, 300, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 425, accuracy: 0.001)
        XCTAssertEqual(rect.width, 40, accuracy: 0.001)
        XCTAssertEqual(rect.height, 60, accuracy: 0.001)
    }

    func testPetTargetMappingStillDelegatesUnchanged() {
        let target = AskNugumiPetTarget(x: 0.25, y: 0.10, coordinateSpace: .screenshotNormalized)
        let viaTarget = AskNugumiCoordinateMapper.exactScreenPoint(for: target, screenFrame: frame)
        let viaRaw = AskNugumiCoordinateMapper.exactScreenPoint(
            normalizedX: 0.25, normalizedY: 0.10, screenFrame: frame
        )
        XCTAssertEqual(viaTarget, viaRaw)
    }
}
