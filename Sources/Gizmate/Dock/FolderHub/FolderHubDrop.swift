import AppKit
import Foundation

/// What happens when files are dropped onto the folder hub.
///
/// Finder's own rule, because the hub shows real folders and a drop onto one is
/// the same act as a drop onto its window: within a volume a drag moves, across
/// volumes it copies, and Option forces a copy either way. Anything else would
/// mean the same gesture doing two different things depending on which window
/// caught it.
enum FolderHubDrop {
    enum Operation: Equatable {
        case move
        case copy
    }

    /// Pure, and separate from the filesystem work below, because this is the
    /// half worth a test: the volume check and the modifier are two booleans,
    /// and getting their combination wrong is what turns a copy into a move.
    static func operation(optionHeld: Bool, sameVolume: Bool) -> Operation {
        optionHeld || !sameVolume ? .copy : .move
    }

    /// Where `source` lands in `folder` without overwriting anything.
    ///
    /// Never overwrites, and the reason is that this has no undo: a drop that
    /// replaced a file of the same name would destroy it with no way back, from
    /// a gesture the user makes by aim. Finder's own suffix, so `a.txt` becomes
    /// `a 2.txt` and `a.tar.gz` becomes `a.tar 2.gz` — the last extension is the
    /// extension, which is what `pathExtension` already says.
    ///
    /// `taken` is injected so the naming can be tested without a disk.
    static func destination(for source: URL, in folder: URL, taken: (URL) -> Bool) -> URL {
        let name = source.lastPathComponent
        let first = folder.appendingPathComponent(name)
        guard taken(first) else { return first }

        let ext = source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        // From 2, like Finder: "a 2.txt" is the first copy, not "a 1.txt".
        for suffix in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let url = folder.appendingPathComponent(candidate)
            if !taken(url) { return url }
        }
        // A thousand collisions is not a case worth a second naming scheme;
        // the caller reports the error the filesystem gives it.
        return folder.appendingPathComponent(name)
    }

    /// Moves or copies each url into `folder`, and reports what landed.
    ///
    /// Not `@MainActor`: copying a folder is unbounded work, and the caller
    /// runs it off the main actor so a dropped 5GB directory does not freeze the
    /// panel it was dropped on.
    ///
    /// Throws on the first failure rather than continuing, and the caller shows
    /// it. A drop that silently does nothing is indistinguishable from a drop
    /// that missed, which is the worse of the two to leave a user with.
    static func perform(
        _ urls: [URL],
        into folder: URL,
        optionHeld: Bool,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        var landed: [URL] = []
        for source in urls {
            let mode = operation(
                optionHeld: optionHeld,
                sameVolume: sameVolume(source, folder, fileManager: fileManager)
            )
            // Dropping something back into the folder it already lives in is
            // Finder's own no-op, not a rename to "x 2". Only for a move: an
            // Option-drag onto the same folder is a deliberate duplicate.
            if mode == .move, source.deletingLastPathComponent().path == folder.path {
                landed.append(source)
                continue
            }
            let target = destination(for: source, in: folder) {
                fileManager.fileExists(atPath: $0.path)
            }
            switch mode {
            case .move: try fileManager.moveItem(at: source, to: target)
            case .copy: try fileManager.copyItem(at: source, to: target)
            }
            landed.append(target)
        }
        return landed
    }

    /// Unknown means "not the same", so a volume this cannot read falls to a
    /// copy. The safe half of the pair: a copy that should have been a move
    /// leaves an extra file, a move that should have been a copy takes the
    /// original off a disk the user may not be able to get it back from.
    private static func sameVolume(_ a: URL, _ b: URL, fileManager: FileManager) -> Bool {
        let left = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let right = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let left = left ?? nil, let right = right ?? nil else { return false }
        return left.isEqual(right)
    }
}
