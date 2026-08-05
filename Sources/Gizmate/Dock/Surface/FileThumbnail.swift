import AppKit
import QuickLookThumbnailing
import SwiftUI

/// What a path actually looks like: the picture itself for an image, a frame
/// for a video, the folder icon for a folder, the type icon for everything
/// else.
///
/// `NSWorkspace.icon(forFile:)` — what a card drew before this — only ever
/// answers the *type* question, so a folder of screenshots rendered forty
/// identical grey glyphs and the one thing a person picks a file out of a
/// shelf by was missing. QuickLook is the same source Finder's own icon view
/// reads, and `representationTypes: .all` is what makes it degrade to that
/// type icon rather than to nothing when a file has no preview to give.
struct FileThumbnail: View {
    let path: String

    /// Seeded from the cache in `init` rather than inside `.task`, the same
    /// reasoning `FolderHubView` seeds its rows with: `.task` runs after the
    /// first frame, so a preview already in memory would still flash the
    /// fallback glyph every single time the panel opens.
    @State private var thumbnail: NSImage?

    init(path: String) {
        self.path = path
        _thumbnail = State(initialValue: FileThumbnails.cached(path))
    }

    var body: some View {
        // The generic icon stands in until QuickLook answers — never a spinner
        // or a blank box. A shelf that flickers empty on every open reads as
        // broken, and the fallback is exactly what the card used to show
        // anyway, so the worst case is what shipped before.
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .task(id: path) {
                guard thumbnail == nil else { return }
                thumbnail = await FileThumbnails.generate(for: path)
            }
    }
}

/// The QuickLook call and the memory it is worth keeping.
///
/// Split from the view so the cache survives the view: a dock panel's SwiftUI
/// tree is rebuilt from scratch every time the pointer nears the edge, and a
/// cache owned by a card would be thrown away with it — which is the whole
/// difference between a shelf that opens instantly and one that redraws
/// itself a hundred previews at a time.
@MainActor
enum FileThumbnails {
    /// One request size for every caller, not one per cell: a surface's column
    /// is at most twice its 96pt minimum before the grid adds a column
    /// instead, so 128pt covers the widest cell that can exist and a single
    /// cache entry then serves every panel that asks for the same path.
    private static let side: CGFloat = 128

    /// `NSCache` rather than a dictionary: a shelf pointed at a Downloads
    /// folder holds hundreds of previews, and eviction under memory pressure
    /// is the one thing a hand-rolled cache would have to reimplement.
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    // ponytail: keyed by path alone, so a file edited in place keeps its old
    // preview until the app restarts. Fold the modification date into the key
    // if that ever bites — the rows already read it for sorting.
    static func generate(for path: String) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        // A failure here is not worth surfacing: the caller already draws the
        // type icon, which is a correct answer to "what is this file", just a
        // less specific one.
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        cache.setObject(representation.nsImage, forKey: path as NSString)
        return representation.nsImage
    }
}
