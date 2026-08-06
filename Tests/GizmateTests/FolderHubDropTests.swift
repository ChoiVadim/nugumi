import XCTest
@testable import Gizmate

/// What a file dropped on the folder hub does, and what it must never do.
///
/// The hub shows real folders, so a drop onto it is the same act as a drop onto
/// a Finder window, and it gets Finder's rule. Both halves of that rule are one
/// line of logic each and both are worth pinning: the wrong combination turns a
/// copy into a move, and the wrong name silently destroys a file.
final class FolderHubDropTests: XCTestCase {
    // MARK: - Move or copy

    func testWithinAVolumeADropMoves() {
        XCTAssertEqual(
            FolderHubDrop.operation(optionHeld: false, sameVolume: true), .move
        )
    }

    func testAcrossVolumesADropCopies() {
        XCTAssertEqual(
            FolderHubDrop.operation(optionHeld: false, sameVolume: false), .copy
        )
    }

    /// Option is the override, and it only ever overrides toward the safe side.
    func testOptionAlwaysCopies() {
        XCTAssertEqual(FolderHubDrop.operation(optionHeld: true, sameVolume: true), .copy)
        XCTAssertEqual(FolderHubDrop.operation(optionHeld: true, sameVolume: false), .copy)
    }

    // MARK: - Naming

    private let folder = URL(fileURLWithPath: "/tmp/hub")

    private func landing(_ name: String, taken: Set<String>) -> String {
        FolderHubDrop.destination(
            for: URL(fileURLWithPath: "/elsewhere/\(name)"),
            in: folder,
            taken: { taken.contains($0.lastPathComponent) }
        ).lastPathComponent
    }

    func testAFreeNameIsUsedAsIs() {
        XCTAssertEqual(landing("notes.txt", taken: []), "notes.txt")
    }

    /// The rule that matters most here: a drop has no undo, so a name already
    /// in use must never be overwritten. Finder's suffix, starting at 2.
    func testATakenNameGetsFindersSuffixRatherThanOverwriting() {
        XCTAssertEqual(landing("notes.txt", taken: ["notes.txt"]), "notes 2.txt")
        XCTAssertEqual(
            landing("notes.txt", taken: ["notes.txt", "notes 2.txt"]), "notes 3.txt"
        )
    }

    func testAnExtensionlessNameKeepsItsSuffixOffTheEnd() {
        XCTAssertEqual(landing("README", taken: ["README"]), "README 2")
    }

    /// The last extension is the extension, which is what Finder does too:
    /// `a.tar.gz` becomes `a.tar 2.gz`, never `a 2.tar.gz`.
    func testOnlyTheLastExtensionIsTreatedAsOne() {
        XCTAssertEqual(landing("bundle.tar.gz", taken: ["bundle.tar.gz"]), "bundle.tar 2.gz")
    }

    /// A leading dot is a name, not an extension — Foundation agrees, and a
    /// ".gitignore" that came back as " 2.gitignore" would be a hidden file
    /// renamed into a visible one.
    func testADotfileIsNamedNotExtended() {
        XCTAssertEqual(landing(".gitignore", taken: [".gitignore"]), ".gitignore 2")
    }

    // MARK: - On disk

    /// Dropping something back where it already lives is Finder's no-op, not a
    /// duplicate. Without this, nudging a file within its own folder quietly
    /// leaves a second copy behind every time.
    func testMovingAFileIntoItsOwnFolderChangesNothing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderHubDropTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let landed = try FolderHubDrop.perform([file], into: root, optionHeld: false)

        XCTAssertEqual(landed, [file])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), ["a.txt"]
        )
    }

    /// The same drop with Option is a deliberate duplicate, so it is allowed to
    /// make one — and it still must not overwrite the original.
    func testOptionDroppingIntoTheSameFolderDuplicates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderHubDropTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let landed = try FolderHubDrop.perform([file], into: root, optionHeld: true)

        XCTAssertEqual(landed.first?.lastPathComponent, "a 2.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }
}
