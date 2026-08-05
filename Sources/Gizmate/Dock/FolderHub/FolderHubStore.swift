import Combine
import Foundation

/// The folders the built-in folder hub offers, and which one it last showed.
///
/// No `onChange` callback the way `DockStore` carries one: `DockStore`'s
/// consumers are `EdgeDockController`s, plain `NSView` code outside SwiftUI's
/// observation tree, so they need an explicit hook to know when to rebuild.
/// `FolderHubView` is a SwiftUI view holding this store as `@ObservedObject`,
/// so `@Published folders` already redraws it on its own — a second callback
/// here would have no caller.
@MainActor
final class FolderHubStore: ObservableObject {
    @Published private(set) var folders: [URL]

    static let defaultsKey = "com.nugumi.app.folderHub.v1"

    private let defaults: UserDefaults

    /// Injectable so tests run against a scratch suite rather than the user's
    /// real folder list — the pattern `DockStore` already uses.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = Self.load(from: defaults)
    }

    /// No-op on a folder already offered. Compared by `.path` rather than
    /// `URL` equality: a directory URL's string form gains or loses a
    /// trailing slash depending on how it was minted — `NSOpenPanel` versus
    /// `FileManager.urls(for:in:)` versus reloading a saved path — and `.path`
    /// is the one representation that reads the same regardless.
    func add(_ url: URL) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        folders.append(url)
        save()
    }

    /// Removing the last folder leaves the list empty rather than reviving
    /// the Downloads default — the user just said no to that folder, and
    /// bringing a default back the moment the list goes empty would make
    /// "remove" feel like it silently failed.
    func remove(_ url: URL) {
        folders.removeAll { $0.path == url.path }
        save()
    }

    // MARK: - Persistence

    /// `array(forKey:)` returning nil means "never saved" — the one case that
    /// falls back to Downloads. Once anything has been saved, even `[]`, that
    /// array is the answer, or the fallback would reappear on every launch
    /// after the user removed their last folder.
    private static func load(from defaults: UserDefaults) -> [URL] {
        let raw: [URL]
        if let paths = defaults.array(forKey: defaultsKey) as? [String] {
            raw = paths.map(URL.init(fileURLWithPath:))
        } else {
            raw = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
        }
        // Lenient: a folder deleted, unmounted, or permission-revoked since it
        // was added is dropped quietly rather than kept as a chip that opens
        // nothing.
        return raw.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        defaults.set(folders.map(\.path), forKey: Self.defaultsKey)
    }
}
