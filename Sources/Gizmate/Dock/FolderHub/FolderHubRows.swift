import Foundation

/// Turns a folder's contents into the rows a surface renders — the filesystem
/// equivalent of `SurfaceRows.decode`, but for a fixed local listing instead
/// of a script's stdout, so there is no JSON to parse and nothing for a model
/// to have gotten wrong.
enum FolderHubRows {
    /// A downloads shelf is for what you just got, not an archive — capping
    /// the count keeps a folder with years of history from turning the grid
    /// into something that has to scroll to be useful.
    static let defaultLimit = 200

    /// Never throws. An unreadable folder, a revoked permission, or a folder
    /// deleted since it was added must all read as "nothing to show" rather
    /// than crash or propagate an error — this runs every time the pointer
    /// nears a screen edge, with no user action to blame for a failure.
    static func rows(in folder: URL, limit: Int) -> [SurfaceRow] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // A folder inside Downloads is not something you drag into Slack, so
        // it is filtered out here rather than left for the layout to ignore.
        // A file whose resource values can't be read (a broken symlink, a
        // permission edge case) is skipped rather than failing the whole
        // listing — one bad entry should not blank the shelf.
        let files: [(url: URL, modified: Date, size: Int)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }

        let formatter = ByteCountFormatter()
        // Newest first: that is what a downloads shelf is for, and it is the
        // ordering that puts the file you just got in the top-left cell.
        return files
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { entry in
                SurfaceRow(id: entry.url.path, values: [
                    "path": entry.url.path,
                    "name": entry.url.lastPathComponent,
                    "size": formatter.string(fromByteCount: Int64(entry.size))
                ])
            }
    }
}
