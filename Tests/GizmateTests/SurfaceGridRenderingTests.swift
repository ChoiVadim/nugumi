import AppKit
import GizmateToolAgentCore
import SwiftUI
import XCTest
@testable import Gizmate

/// Pins the reasons a `.grid` surface can go blank on a real screen edge —
/// something 646 tests never checked, because every one of them stopped at
/// "did the right rows/bindings/candidate get produced" and none asked "does
/// hosting that in an actual `NSScrollView` produce anything visible".
///
/// The folder hub shipped exactly that gap (`86205fc`): its rows were real,
/// its layout matched its bindings, and the panel still showed nothing. The
/// cause was `LazyVGrid` inside `OverlayScrollHost`'s document view — that
/// document leaves height deliberately unbounded so the `NSScrollView` has
/// something to scroll (see `OverlayScrollHost`), and a `LazyVGrid` asked to
/// size itself against an unbounded axis collapses to zero rather than
/// picking some fallback height. `NotesGrid`'s single-column dock path hit
/// the identical failure earlier (`add5b4f`) and went eager; nothing carried
/// that lesson to the multi-column case a surface's grid actually needs.
@MainActor
final class SurfaceGridRenderingTests: XCTestCase {
    /// Hosts a real `SurfaceView` exactly the way `EdgeDockController.install`
    /// does — an `NSHostingView` pinned on all four edges (with
    /// `DockGeometry.contentInsets`) inside a window sized like the real top
    /// dock panel (`EdgeDockController`'s `expanded` case: 620×300) — and
    /// measures what the scroll view's document actually ends up with.
    func testAGridSurfaceWithManyRowsRendersNonCollapsedContent() {
        let rows = (0..<40).map { index in
            SurfaceRow(id: "\(index)", values: ["name": "file-\(index).txt"])
        }
        let layout = ToolAgentLayoutV1.grid(
            cell: .card(.init(title: .key("name"))),
            minimumWidth: 96,
            empty: "Nothing here yet."
        )

        let document = renderedScrollDocument(
            for: SurfaceView(layout: layout, rows: rows, stale: nil),
            panelSize: NSSize(width: 620, height: 300)
        )

        // A collapsed grid reports (0, 0) — see `OverlayScrollHostSurfaceTests`
        // probes in the investigation report. 40 cards at a 96pt minimum can't
        // fit in one row inside a 620pt panel, so a real render is several
        // rows tall; anything near zero means the grid never laid the rows
        // out at all, whatever `rows.isEmpty` says.
        XCTAssertGreaterThan(document.width, 100, "grid content collapsed to zero width instead of laying out \(rows.count) rows")
        XCTAssertGreaterThan(document.height, 100, "grid content collapsed to zero height instead of laying out \(rows.count) rows")
    }

    /// A single row must still render — this is the case `rows.isEmpty`
    /// itself does not cover, since one row is enough to prove the grid
    /// laid *something* out without needing the multi-row math above.
    func testAGridSurfaceWithOneRowRendersSomething() {
        let rows = [SurfaceRow(id: "1", values: ["name": "only.txt"])]
        let layout = ToolAgentLayoutV1.grid(
            cell: .card(.init(title: .key("name"))),
            minimumWidth: 96,
            empty: "Nothing here yet."
        )

        let document = renderedScrollDocument(
            for: SurfaceView(layout: layout, rows: rows, stale: nil),
            panelSize: NSSize(width: 380, height: 520)
        )

        XCTAssertGreaterThan(document.width, 0)
        XCTAssertGreaterThan(document.height, 0)
    }

    /// A cell's size is the grid's, not its content's: the same rows with
    /// names long enough to wrap to two lines must occupy exactly the same
    /// height. The folder hub shipped the opposite — one card per row of the
    /// grid grew to fit its filename and left its neighbours short — and the
    /// document's own height is the cheapest place that difference shows,
    /// since a card is SwiftUI-internal and has no `NSView` to measure.
    func testCardHeightDoesNotDependOnHowLongTheNameIs() {
        let layout = ToolAgentLayoutV1.grid(
            cell: .card(.init(title: .key("name"), subtitle: .key("size"))),
            minimumWidth: 96,
            empty: "Nothing here yet."
        )
        let panel = NSSize(width: 620, height: 300)

        func height(names: (Int) -> String) -> CGFloat {
            let rows = (0..<12).map { SurfaceRow(id: "\($0)", values: ["name": names($0), "size": "1 KB"]) }
            return renderedScrollDocument(for: SurfaceView(layout: layout, rows: rows, stale: nil), panelSize: panel).height
        }

        let short = height { "f\($0).txt" }
        let wrapping = height { "a-considerably-longer-file-name-\($0).txt" }

        XCTAssertEqual(short, wrapping, accuracy: 0.5, "card height tracked the title's line count instead of the grid's cell size")
    }

    // MARK: - Harness

    /// Reproduces `EdgeDockController.install`'s exact wiring: the content
    /// view is pinned to all four edges of a fixed-size container standing in
    /// for `GlassHostView.contentView`, whose own size comes from the panel —
    /// a real, resolved `NSWindow` frame, never an unbounded one. That
    /// resolved-on-every-side frame is what `SurfaceView`'s `GeometryReader`
    /// measures; the only place anything is deliberately left unbounded is
    /// one level down, inside `OverlayScrollHost`'s own document view.
    private func renderedScrollDocument<Content: View>(for content: Content, panelSize: NSSize) -> NSSize {
        let root = NSView(frame: NSRect(origin: .zero, size: panelSize))
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // A couple of passes: resolving the panel's own frame and resolving
        // the scroll document's height from it are two separate steps, and
        // this pins down that both have actually settled rather than
        // catching an in-between frame.
        for _ in 0..<3 {
            root.layoutSubtreeIfNeeded()
        }

        guard let scrollView = firstScrollView(in: hosting), let documentView = scrollView.documentView else {
            XCTFail("SurfaceView did not build an NSScrollView with a document view")
            return .zero
        }
        return documentView.frame.size
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
