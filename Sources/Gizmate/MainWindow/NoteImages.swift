import AppKit
import Quartz

/// Where a note's pictures live: two JPEGs per attachment under
/// `GizmatePaths.noteImages`, named by the id the note carries.
///
/// The full one is what `ChatImage` already encodes for a vision model —
/// fitted to 2048px, alpha flattened — and it is what Quick Look opens. The
/// thumbnail is the separate small encoding a card shows, and it is not a
/// nicety: a note card is re-evaluated on every keystroke, and a strip of cards
/// each decoding a 2048px JPEG per character typed stutters the whole list.
enum NoteImages {
    static func url(_ id: UUID, in directory: URL = GizmatePaths.noteImages) -> URL {
        directory.appending(path: "\(id.uuidString).jpg")
    }

    static func thumbnailURL(_ id: UUID, in directory: URL = GizmatePaths.noteImages) -> URL {
        directory.appending(path: "\(id.uuidString)-thumb.jpg")
    }

    /// Nil when either file could not be written, and neither is left behind.
    static func write(_ picture: ChatImage, in directory: URL = GizmatePaths.noteImages) -> UUID? {
        let id = UUID()
        do {
            try picture.input.data.write(to: url(id, in: directory))
            try picture.thumbnail.write(to: thumbnailURL(id, in: directory))
            return id
        } catch {
            remove(id, in: directory)
            return nil
        }
    }

    static func remove(_ id: UUID, in directory: URL = GizmatePaths.noteImages) {
        try? FileManager.default.removeItem(at: url(id, in: directory))
        try? FileManager.default.removeItem(at: thumbnailURL(id, in: directory))
        thumbnails.removeObject(forKey: id.uuidString as NSString)
    }

    /// Decoded once per id; the same card asks for it on every render.
    private static let thumbnails = NSCache<NSString, NSImage>()

    static func thumbnail(_ id: UUID, in directory: URL = GizmatePaths.noteImages) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(id, in: directory)) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }
}

/// The full view of a note's pictures: Quick Look, the same panel Finder opens
/// on the space bar. It already zooms, pages with the arrow keys and closes on
/// Esc, so there is no picture window of Gizmate's own to draw or to keep up.
///
/// Fed directly rather than through the responder chain's
/// `acceptsPreviewPanelControl`: the cards live in a borderless edge panel and
/// in the main window both, and one object that owns the panel's data source
/// is simpler than teaching each host to claim it.
@MainActor
final class NoteImagePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = NoteImagePreview()

    private var urls: [URL] = []

    static func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        shared.urls = urls
        panel.dataSource = shared
        panel.delegate = shared
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        // The edge panel sits at status-bar level; a preview opened from it
        // has to be above it or it opens behind the thing that opened it.
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { Self.shared.urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { Self.shared.urls[index] as NSURL }
    }
}
