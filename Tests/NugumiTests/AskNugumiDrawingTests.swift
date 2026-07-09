import AppKit
import XCTest

@testable import Nugumi

final class AskNugumiDrawingTests: XCTestCase {
    /// Solid-white square capture with a configurable screen mapping.
    private func makeWhiteCapture(
        pixelSide: Int,
        screenFrame: CGRect
    ) -> AskNugumiScreenCapture {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSide,
            pixelsHigh: pixelSide,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pixelSide, height: pixelSide).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        return AskNugumiScreenCapture(
            image: ImageInput(data: png, mediaType: "image/png"),
            imagePixelSize: CGSize(width: pixelSide, height: pixelSide),
            screenFrame: screenFrame,
            visibleFrame: screenFrame
        )
    }

    private func decode(_ image: ImageInput) -> NSBitmapImageRep {
        NSBitmapImageRep(data: image.data)!
    }

    func testAnnotatedBurnsRedStrokeIntoImage() {
        let capture = makeWhiteCapture(
            pixelSide: 80,
            screenFrame: CGRect(x: 0, y: 0, width: 80, height: 80)
        )
        // Horizontal stroke through the vertical center of the screen.
        let stroke = [NSPoint(x: 10, y: 40), NSPoint(x: 70, y: 40)]

        let annotated = capture.annotated(with: [stroke])

        let bitmap = decode(annotated.image)
        // The center pixel sits on the stroke regardless of y-flip.
        let center = bitmap.colorAt(x: 40, y: 40)!
        XCTAssertGreaterThan(center.redComponent, 0.7, "stroke should be red")
        XCTAssertLessThan(center.greenComponent, 0.5, "stroke should be red")
        // A corner pixel stays white (JPEG artifacts allowed for).
        let corner = bitmap.colorAt(x: 3, y: 3)!
        XCTAssertGreaterThan(corner.redComponent, 0.85)
        XCTAssertGreaterThan(corner.greenComponent, 0.85)
        XCTAssertGreaterThan(corner.blueComponent, 0.85)
    }

    func testAnnotatedWithNoStrokesReturnsImageUntouched() {
        let capture = makeWhiteCapture(
            pixelSide: 40,
            screenFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let annotated = capture.annotated(with: [])
        XCTAssertEqual(annotated.image.data, capture.image.data)
        XCTAssertEqual(annotated.image.mediaType, capture.image.mediaType)
    }

    func testAnnotatedMapsScreenPointsToImagePixels() {
        // Screen region is 160 pt at origin (100, 200); image is only
        // 80 px — 0.5× scale plus offset, like a Retina capture downscaled
        // for vision.
        let capture = makeWhiteCapture(
            pixelSide: 80,
            screenFrame: CGRect(x: 100, y: 200, width: 160, height: 160)
        )
        // Horizontal stroke through the screen-space center → must land on
        // the image center after scale + offset mapping.
        let stroke = [NSPoint(x: 120, y: 280), NSPoint(x: 240, y: 280)]

        let bitmap = decode(capture.annotated(with: [stroke]).image)

        let center = bitmap.colorAt(x: 40, y: 40)!
        XCTAssertGreaterThan(center.redComponent, 0.7)
        XCTAssertLessThan(center.greenComponent, 0.5)
    }

    func testAnnotatedIgnoresSinglePointStrokes() {
        // A click without a drag produces a 1-point stroke; it must not mark
        // the image (stray clicks stay harmless).
        let capture = makeWhiteCapture(
            pixelSide: 40,
            screenFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let bitmap = decode(capture.annotated(with: [[NSPoint(x: 20, y: 20)]]).image)
        let center = bitmap.colorAt(x: 20, y: 20)!
        XCTAssertGreaterThan(center.greenComponent, 0.85, "single point must not draw")
    }
}
