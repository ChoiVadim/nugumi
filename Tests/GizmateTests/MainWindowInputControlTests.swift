import Foundation
import XCTest

/// Guards the one rule about this window that cannot be expressed in code.
///
/// Presenting a SwiftUI `TextEditor` inside a main-window panel and then
/// dismissing that panel leaves the window's entire SwiftUI content ignoring
/// clicks — the sidebar and every control go dead until the window is closed
/// and reopened. AppKit is healthy throughout: an event monitor proves every
/// click still reaches the window, the first responder is clean, no modal
/// session is left over, and `hitTest` returns the normal hosting view.
/// SwiftUI simply swallows the events internally, and it reproduces even when
/// the field was never focused.
///
/// Because nothing about it is detectable at runtime, it comes back every time
/// someone adds a multi-line input without knowing the history. Use
/// `TextField(text:, axis: .vertical)`, or the `PlainTextEditor` NSTextView
/// wrapper — both are AppKit-backed, like every control that closes cleanly.
final class MainWindowInputControlTests: XCTestCase {

    private func mainWindowSources() throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/Gizmate/MainWindow")
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )?.compactMap({ $0 as? URL }).filter({ $0.pathExtension == "swift" }),
            !files.isEmpty else {
            throw XCTSkip("Source tree is unavailable")
        }
        return files
    }

    func testNoMainWindowViewUsesSwiftUITextEditor() throws {
        // Given
        let files = try mainWindowSources()

        // When
        let offenders = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
                .contains { line in
                    // `PlainTextEditor(` is the sanctioned NSTextView wrapper.
                    line.contains("TextEditor(") && !line.contains("PlainTextEditor(")
                }
        }

        // Then
        XCTAssertEqual(
            offenders.map(\.lastPathComponent),
            [],
            "SwiftUI TextEditor in a main-window view leaves the window "
                + "ignoring clicks after a panel is dismissed. Use "
                + "TextField(text:, axis: .vertical) or PlainTextEditor."
        )
    }

    /// The other half of the same freeze, and the one that keeps coming back:
    /// a Ring panel that clears `ringSheet` itself closes inside the very click
    /// that asked for it, and hands the responder back through `NSApp.keyWindow`
    /// — which is not the main window when a panel or an alert is up. Both
    /// leave the window's SwiftUI content dead. `closeRingSheet()` is the only
    /// place allowed to do either.
    func testRingPanelsCloseThroughTheBridge() throws {
        // Given
        let files = try mainWindowSources()

        // When
        let offenders = try files.filter { file in
            // The bridge is where the sanctioned implementation lives.
            guard file.lastPathComponent != "GizmateSettingsBridge.swift" else { return false }
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.contains("ringSheet = nil")
                || source.contains("NSApp.keyWindow?.makeFirstResponder")
        }

        // Then
        XCTAssertEqual(
            offenders.map(\.lastPathComponent),
            [],
            "A Ring panel must close via bridge.closeRingSheet() — clearing "
                + "ringSheet inline, or handing the responder to NSApp.keyWindow, "
                + "leaves the main window ignoring clicks."
        )
    }
}
