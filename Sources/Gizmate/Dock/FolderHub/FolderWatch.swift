import Foundation

/// Tells the folder hub when the folder it is showing changed on its own.
///
/// A dock rebuilds its resident's view every time it opens, so an auto-hiding
/// hub was current by accident: you never saw it long enough for the folder to
/// move underneath it. A pinned one stays open for hours, and it sat there
/// showing a download that had finished ten minutes ago and files that had been
/// trashed from Finder since.
///
/// `DispatchSource` on the folder's own descriptor rather than `FSEvents`:
/// there is exactly one folder on screen at a time and no interest in its
/// subtree, which is the one case the low-level source is simpler than the
/// stream API. A directory descriptor reports `.write` for anything added,
/// removed or renamed inside it, which is the whole question being asked.
@MainActor
final class FolderWatch {
    /// Copying a hundred files fires a hundred events. Reading the folder a
    /// hundred times would make the panel flicker through partial listings and
    /// spend the whole copy re-rendering, so the last event in a burst is the
    /// one that counts.
    private static let quietPeriod = Duration.milliseconds(250)

    private var source: DispatchSourceFileSystemObject?
    private var settle: Task<Void, Never>?
    private var watchedPath: String?

    /// Starts watching `folder`, or stops if it is nil. Re-watching the folder
    /// already being watched is a no-op, so this is safe to call from an
    /// `onChange` that also fires for unrelated reasons.
    func start(_ folder: URL?, onChange: @escaping () -> Void) {
        guard folder?.path != watchedPath else { return }
        stop()
        guard let folder else { return }

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // `.delete` and `.rename` are about the watched folder itself. Both
            // still mean "reload": the hub then reads an empty listing, which is
            // the truth about a folder that is gone.
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.schedule(onChange) }
        // Closing the descriptor is the source's job, not the caller's: it is
        // still using it right up to cancellation.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        watchedPath = folder.path
    }

    func stop() {
        settle?.cancel()
        settle = nil
        source?.cancel()
        source = nil
        watchedPath = nil
    }

    private func schedule(_ onChange: @escaping () -> Void) {
        settle?.cancel()
        settle = Task { @MainActor in
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }

    deinit {
        // `stop()` is main-actor isolated and this is not, so cancel directly.
        // Cancelling a source twice is harmless; the cancel handler runs once.
        source?.cancel()
    }
}
