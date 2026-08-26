import AppKit
import XCTest

@testable import Gizmate

/// A note's pictures are files the note points at by id. The three ways that
/// pointer can dangle: a reload, a removed picture, a deleted note.
final class NoteImagesTests: XCTestCase {

    @MainActor
    private func store() -> (UserDefaults, URL, () -> Void) {
        let suiteName = "NoteImagesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (defaults, dir, {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        })
    }

    private func picture() -> ChatImage {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        return ChatImage(image)!
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @MainActor
    func testAttachWritesBothFilesAndSurvivesAReload() throws {
        let (defaults, dir, cleanup) = store()
        defer { cleanup() }
        let store = NotesStore(defaults: defaults, imagesDirectory: dir)
        let note = store.add(text: "with a picture")

        store.attach([picture()], to: note.id)

        let id = try XCTUnwrap(store.notes[0].images.first)
        XCTAssertTrue(exists(NoteImages.url(id, in: dir)))
        XCTAssertTrue(exists(NoteImages.thumbnailURL(id, in: dir)))
        XCTAssertNotNil(store.thumbnail(id))

        let reloaded = NotesStore(defaults: defaults, imagesDirectory: dir)
        XCTAssertEqual(reloaded.notes[0].images, [id])
    }

    @MainActor
    func testRemovingAPictureDeletesItsFiles() {
        let (defaults, dir, cleanup) = store()
        defer { cleanup() }
        let store = NotesStore(defaults: defaults, imagesDirectory: dir)
        let note = store.add()
        store.attach([picture(), picture()], to: note.id)
        let (first, second) = (store.notes[0].images[0], store.notes[0].images[1])

        store.removeImage(first, from: note.id)

        XCTAssertEqual(store.notes[0].images, [second])
        XCTAssertFalse(exists(NoteImages.url(first, in: dir)))
        XCTAssertFalse(exists(NoteImages.thumbnailURL(first, in: dir)))
        XCTAssertTrue(exists(NoteImages.url(second, in: dir)))
    }

    @MainActor
    func testDeletingANoteDeletesItsPictures() {
        let (defaults, dir, cleanup) = store()
        defer { cleanup() }
        let store = NotesStore(defaults: defaults, imagesDirectory: dir)
        let note = store.add()
        store.attach([picture()], to: note.id)
        let id = store.notes[0].images[0]

        store.delete(note.id)

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(exists(NoteImages.url(id, in: dir)))
        XCTAssertFalse(exists(NoteImages.thumbnailURL(id, in: dir)))
    }

    /// Notes saved before pictures existed have no `images` key at all.
    func testNotesSavedBeforePicturesDecodeWithNone() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","title":"t","text":"body",
          "usedAsContext":true,"createdAt":0,"updatedAt":0}]
        """
        let decoded = try JSONDecoder().decode([Note].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded[0].images, [])
    }
}
