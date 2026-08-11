import AppKit
import XCTest
@testable import Gizmate

/// The encoder behind an attached picture. Everything here is what stops a
/// dropped screenshot from being refused by the backend it is sent to.
final class ChatImageTests: XCTestCase {
    /// A picture bigger than the vision edge comes back fitted to it, and the
    /// thumbnail comes back smaller still — the two encodings exist precisely
    /// because one of them is redrawn on every streamed chunk.
    func testAHugePictureIsFittedForTheModelAndSmallerForTheEye() throws {
        let picture = try XCTUnwrap(ChatImage(Self.solid(width: 4000, height: 3000)))

        let sent = try XCTUnwrap(NSBitmapImageRep(data: picture.input.data))
        XCTAssertEqual(max(sent.pixelsWide, sent.pixelsHigh), 2048)
        XCTAssertEqual(sent.pixelsWide * 3, sent.pixelsHigh * 4, "aspect ratio kept")
        XCTAssertEqual(picture.input.mediaType, "image/jpeg")

        let shown = try XCTUnwrap(NSBitmapImageRep(data: picture.thumbnail))
        XCTAssertEqual(max(shown.pixelsWide, shown.pixelsHigh), 512)
        XCTAssertLessThan(picture.thumbnail.count, picture.input.data.count)
    }

    /// Under the 5 MB every cloud backend guards on, which a lossless retina
    /// screenshot is not.
    func testWhatIsSentFitsTheCloudPayloadLimit() throws {
        let picture = try XCTUnwrap(ChatImage(Self.solid(width: 5120, height: 2880)))

        XCTAssertLessThan(picture.input.data.count, 5 * 1024 * 1024)
    }

    /// A small picture is not blown up to the vision edge on the way out.
    func testASmallPictureIsLeftAtItsOwnSize() throws {
        let picture = try XCTUnwrap(ChatImage(Self.solid(width: 120, height: 80)))

        let sent = try XCTUnwrap(NSBitmapImageRep(data: picture.input.data))
        XCTAssertEqual(sent.pixelsWide, 120)
        XCTAssertEqual(sent.pixelsHigh, 80)
    }

    /// Transparency is flattened onto white rather than handed to a format with
    /// no alpha, which is what turns a logo into a black rectangle.
    func testTransparencyIsFlattenedRatherThanDroppedToBlack() throws {
        // A fresh context's buffer is zeroed, which in premultiplied RGBA is
        // fully transparent everywhere.
        let picture = try XCTUnwrap(ChatImage(Self.image(from: Self.context(64, 64))))

        let sent = try XCTUnwrap(NSBitmapImageRep(data: picture.input.data))
        let corner = try XCTUnwrap(sent.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))

        XCTAssertEqual(corner.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(corner.greenComponent, 1, accuracy: 0.02)
        XCTAssertEqual(corner.blueComponent, 1, accuracy: 0.02)
    }

    // MARK: - What ⌘V is carrying

    /// A screenshot on the clipboard is pixels and nothing else, so nobody
    /// else needs the event.
    func testPixelsAloneAreAttachedAndTheEventIsSpent() throws {
        let board = Self.board("pictures-only")
        board.writeObjects([Self.solid(width: 40, height: 40)])

        let paste = ChatImage.pasted(board)

        XCTAssertEqual(paste.pictures.count, 1)
        XCTAssertFalse(paste.keepsText)
    }

    /// A picture copied as a file carries its own name as text. The name is
    /// noise in a message, so the file is attached and the paste ends there.
    func testAPictureFileIsAttachedWithoutPastingItsName() throws {
        let file = try Self.write(Self.solid(width: 40, height: 40))
        defer { try? FileManager.default.removeItem(at: file) }
        let board = Self.board("picture-file")
        board.writeObjects([file as NSURL])

        let paste = ChatImage.pasted(board)

        XCTAssertEqual(paste.pictures.count, 1)
        XCTAssertFalse(paste.keepsText)
    }

    /// Pixels *and* words is a spreadsheet cell, which carries a rendered copy
    /// of itself. Both halves get through rather than one being chosen for you.
    func testPixelsBesideWordsKeepBoth() throws {
        let board = Self.board("pictures-and-words")
        board.writeObjects([Self.solid(width: 40, height: 40), "40" as NSString])

        let paste = ChatImage.pasted(board)

        XCTAssertEqual(paste.pictures.count, 1)
        XCTAssertTrue(paste.keepsText)
    }

    /// And an ordinary copied sentence is untouched: nothing to attach, and the
    /// field editor never sees the watcher.
    func testWordsAloneAreNotAPaste() throws {
        let board = Self.board("words-only")
        board.writeObjects(["just a sentence" as NSString])

        let paste = ChatImage.pasted(board)

        XCTAssertTrue(paste.pictures.isEmpty)
        XCTAssertTrue(paste.keepsText)
    }

    // MARK: - Fixtures

    private static func board(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("com.gizmate.app.tests.\(name)"))
        board.clearContents()
        return board
    }

    private static func write(_ image: NSImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    /// Drawn through Core Graphics rather than `lockFocus`, so the picture has
    /// exactly the pixels it is asked for. `lockFocus` inherits the main
    /// display's scale, and on a retina Mac a "120 x 80" fixture is really 240
    /// x 160 — which grades the test machine instead of the encoder.
    private static func solid(width: Int, height: Int) -> NSImage {
        let context = self.context(width, height)
        context?.setFillColor(CGColor(red: 0, green: 0.6, blue: 0.7, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return image(from: context)
    }

    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func image(from context: CGContext?) -> NSImage {
        guard let drawn = context?.makeImage() else { return NSImage() }
        return NSImage(
            cgImage: drawn,
            size: NSSize(width: drawn.width, height: drawn.height)
        )
    }
}

extension ChatImage {
    /// A picture with no pixels worth decoding, for tests about everything
    /// except the encoder.
    static var stub: ChatImage {
        ChatImage(
            id: UUID(),
            input: ImageInput(data: Data([0xFF, 0xD8]), mediaType: "image/jpeg"),
            thumbnail: Data()
        )
    }
}
