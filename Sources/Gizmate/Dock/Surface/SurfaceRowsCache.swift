import Foundation

/// The last rows a surface gizmo's script printed, kept so a dock can draw
/// something the instant the pointer reaches the edge instead of staring at
/// an empty panel through a `uv` + Python cold start (~300 ms). Task 9 is
/// what turns that into a sequence: draw the cached rows, run the script in
/// the background, swap in whatever it returns.
///
/// On disk rather than `UserDefaults` — up to 500 rows × 32 keys is not a
/// defaults-sized object, and `GizmatePaths.cache` exists for exactly this.
/// One JSON file per gizmo, so a write for gizmo A can never land on gizmo
/// B's bytes.
@MainActor
final class SurfaceRowsCache {
    private let directory: URL
    private var memory: [UUID: [SurfaceRow]] = [:]

    /// Injectable so tests run against a scratch path rather than the user's
    /// real cache — the pattern `DockStore` uses for `UserDefaults`.
    init(directory: URL = GizmatePaths.cache) {
        self.directory = directory
    }

    /// Every failure reads as "nothing cached yet" rather than throwing. This
    /// is what the dock draws before a script has ever run for this gizmo,
    /// or after a file left behind by an older build stops decoding — a
    /// stale cache is not worth taking the panel down over.
    func rows(for id: UUID) -> [SurfaceRow] {
        if let cached = memory[id] {
            return cached
        }
        let loaded = (try? Data(contentsOf: fileURL(for: id)))
            .flatMap { try? JSONDecoder().decode([SurfaceRow].self, from: $0) } ?? []
        memory[id] = loaded
        return loaded
    }

    func store(_ rows: [SurfaceRow], for id: UUID) {
        memory[id] = rows
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "surface-\(id.uuidString).json")
    }
}
