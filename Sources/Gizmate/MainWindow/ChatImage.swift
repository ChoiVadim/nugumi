import AppKit

/// A picture riding along with a chat message.
///
/// Two encodings, because they answer two different questions. `input` is what
/// the model is sent: fitted to the 2048px edge cloud vision models tile at, so
/// a retina screenshot cannot trip the 5 MB payload guard in `OpenAIChatClient`.
/// `thumbnail` is what the person looks at, and it is a separate, small encoding
/// for a cost the transcript would otherwise pay on every chunk — a streaming
/// answer re-evaluates every row above it, and a chip that decodes the full-size
/// JPEG each time makes the whole conversation stutter while an answer arrives.
///
/// `Data` on both sides rather than an `NSImage`, and that is not a preference:
/// a `Turn` is handed to the backend closure across an async boundary, and
/// `NSImage` is not `Sendable`.
struct ChatImage: Identifiable, Equatable {
    let id: UUID
    /// What the model sees.
    let input: ImageInput
    /// What the person sees. JPEG, a few tens of kilobytes.
    let thumbnail: Data

    /// By identity. The alternative compares the pixels of every attachment on
    /// every SwiftUI diff, and `Turn` is diffed on each streamed chunk.
    static func == (lhs: ChatImage, rhs: ChatImage) -> Bool { lhs.id == rhs.id }
}

extension ChatImage {
    /// Matches the tile boundary cloud vision models snap to, same as
    /// `ScreenshotCapture`'s. Anything larger is bandwidth the model discards.
    private static let visionMaxEdge: CGFloat = 2048
    private static let thumbnailMaxEdge: CGFloat = 512

    init?(_ image: NSImage) {
        guard let full = Self.encode(image, maxEdge: Self.visionMaxEdge, quality: 0.85),
              let small = Self.encode(image, maxEdge: Self.thumbnailMaxEdge, quality: 0.6)
        else { return nil }
        self.init(
            id: UUID(),
            input: ImageInput(data: full, mediaType: "image/jpeg"),
            thumbnail: small
        )
    }

    /// A file someone picked or dropped. Nil for anything AppKit cannot open as
    /// a picture, which is also how a folder of mixed files filters itself.
    init?(contentsOf url: URL) {
        guard let image = NSImage(contentsOf: url) else { return nil }
        self.init(image)
    }

    /// Fitted, flattened and JPEG'd in one pass.
    ///
    /// Not `ScreenshotCapture.downscaledForVision`, which is the same size maths
    /// for a screen grab: that source is opaque by construction and this one is
    /// not. A transparent PNG handed straight to the JPEG encoder comes back
    /// black wherever it was see-through, so the redraw into an opaque context
    /// is the flattening as well as the resize.
    private static func encode(_ image: NSImage, maxEdge: CGFloat, quality: Double) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let longest = max(CGFloat(source.width), CGFloat(source.height))
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let drawn = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: drawn)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: - Where pictures come from

    /// Everything on the pasteboard that is a picture: raw image data, and image
    /// files by URL. Both halves of ⌘V — a screenshot taken to the clipboard,
    /// and a picture copied out of a browser.
    static func onPasteboard(_ pasteboard: NSPasteboard = .general) -> [ChatImage] {
        let classes: [AnyClass] = [NSImage.self, NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: classes, options: options) ?? []
        return objects.compactMap { object in
            if let image = object as? NSImage { return ChatImage(image) }
            if let url = object as? URL { return ChatImage(contentsOf: url) }
            return nil
        }
    }

    /// What ⌘V should attach, or nothing if ⌘V means what it always meant.
    ///
    /// Text wins whenever the board has any. Plenty of apps put a rendered image
    /// on the board beside the text they copied, and a person pasting a sentence
    /// wants the sentence. The cost is that a picture *file* copied in Finder,
    /// which arrives with its name as a string, pastes as its name — dropping it
    /// on the composer or using the clip attaches it instead.
    static func pasted(_ pasteboard: NSPasteboard = .general) -> [ChatImage] {
        guard !pasteboard.canReadObject(forClasses: [NSString.self], options: nil) else {
            return []
        }
        return onPasteboard(pasteboard)
    }

    /// The open panel, which is the third way in and the discoverable one.
    @MainActor
    static func pick() -> [ChatImage] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"
        panel.message = "Choose a picture to show Gizmate."
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(ChatImage.init(contentsOf:))
    }
}
