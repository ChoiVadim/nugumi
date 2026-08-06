import Foundation

/// Turns a folder's contents into the rows a surface renders — the filesystem
/// equivalent of `SurfaceRows.decode`, but for a fixed local listing instead
/// of a script's stdout, so there is no JSON to parse and nothing for a model
/// to have gotten wrong.
enum FolderHubRows {
    /// A downloads shelf is for what you just got, not an archive — capping
    /// the count keeps a folder with years of history from turning the grid
    /// into something that has to scroll to be useful.
    ///
    /// ponytail: 80 because `SurfaceGrid` is eager, so this is literally the
    /// number of cards built on every folder switch — and a 380pt panel shows
    /// about fifteen of them. Measured on a 2292-entry Downloads, the
    /// filesystem side of a switch is ~10ms and the type icons ~13ms, so the
    /// cost that was left is the cards themselves. The upgrade path is real
    /// laziness, not a bigger number: `LazyVGrid` collapses to zero inside
    /// `OverlayScrollHost`'s unbounded document view (see `SurfaceView`), so
    /// it needs the scroll host to publish its visible rect first.
    static let defaultLimit = 80

    /// Whether opening this entry means walking into it rather than handing it
    /// to `NSWorkspace`. A bundle — an `.app`, an `.rtfd`, an `.xcodeproj` — is
    /// a directory to `FileManager` and a single document to everyone else, so
    /// checking `isDirectory` alone would unfold Calendar.app into its own guts
    /// instead of launching it.
    static func isBrowsable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return false
        }
        return values.isDirectory == true && values.isPackage != true
    }

    /// Never throws. An unreadable folder, a revoked permission, or a folder
    /// deleted since it was added must all read as "nothing to show" rather
    /// than crash or propagate an error — this runs every time the pointer
    /// nears a screen edge, with no user action to blame for a failure.
    static func rows(in folder: URL, limit: Int) -> [SurfaceRow] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Folders are listed alongside files. They used to be filtered out on
        // the grounds that you don't drag a folder into Slack — true of Slack,
        // false of the Finder, a Terminal prompt, or any of the other places a
        // shelf actually drops onto, and a Downloads folder that hides the
        // unpacked half of every archive is answering a question nobody asked.
        // Anything that is neither (a broken symlink, a device node) is still
        // skipped, as is an entry whose resource values can't be read at all —
        // one bad entry should not blank the shelf.
        let files: [(url: URL, modified: Date, size: Int?)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            if values.isRegularFile == true {
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            // A directory's own `fileSize` is the size of its record, not of
            // what's inside it, so it carries no size rather than a number
            // that would read as a lie.
            guard values.isDirectory == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, nil)
        }

        let formatter = ByteCountFormatter()
        // Newest first: that is what a downloads shelf is for, and it is the
        // ordering that puts the file you just got in the top-left cell.
        return files
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { entry in
                var values = [
                    "path": entry.url.path,
                    "name": entry.url.lastPathComponent
                ]
                if let size = entry.size {
                    values["size"] = formatter.string(fromByteCount: Int64(size))
                }
                return SurfaceRow(id: entry.url.path, values: values)
            }
    }
}
