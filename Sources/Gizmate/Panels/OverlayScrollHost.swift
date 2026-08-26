import AppKit
import SwiftUI

/// Flipped so content stacks from the top. An `NSScrollView`'s document view is
/// bottom-origin unless it says otherwise, which parks the content below the
/// viewport and shows an empty panel with a live scroller — the same reason
/// `Snippets.swift` has its own `FlippedDocumentView`.
private final class FlippedScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

/// SwiftUI content inside an `NSScrollView` we own, for use in borderless
/// floating panels.
///
/// `ScrollerConfigurator` is enough in the main window, but not here: in a
/// borderless panel AppKit *reverts* a manually-set `scrollerStyle = .overlay`
/// back to the system's wide legacy scroller, whose track never hides. The fix
/// is `OverlayScrollView`, which overrides the getter so there is nothing to
/// revert — and a SwiftUI `ScrollView` cannot be told to use a custom
/// `NSScrollView` subclass, so the nesting has to invert: AppKit owns the
/// scrolling, SwiftUI rides inside it.
struct OverlayScrollHost<Content: View>: NSViewRepresentable {
    /// Vertically centres content shorter than the viewport instead of
    /// pinning it to the top. Off by default — a list of notes reads from the
    /// top like any list — and on for a stats surface, whose slack under the
    /// last reading otherwise pools at the bottom and reads as a mistake.
    /// Content taller than the viewport scrolls exactly as before either way.
    var centersShortContent = false
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .light
        scroll.contentView.drawsBackground = false

        let document = FlippedScrollDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        let host = NSHostingView(rootView: AnyView(content()))
        host.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(host)
        scroll.documentView = document

        var constraints = [
            host.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            // Width tracks the viewport; height deliberately does not.
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ]
        if centersShortContent {
            // The document is at least the viewport and hugs the content past
            // it: the low-priority equality gives way exactly when the
            // viewport minimum wins, which is the only case where centring
            // has room to mean anything.
            let hug = document.heightAnchor.constraint(equalTo: host.heightAnchor)
            hug.priority = .defaultLow
            constraints += [
                host.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor),
                host.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
                host.centerYAnchor.constraint(equalTo: document.centerYAnchor),
                document.heightAnchor.constraint(
                    greaterThanOrEqualTo: scroll.contentView.heightAnchor
                ),
                hug,
            ]
        } else {
            // The document's height comes from the hosting view, which is what
            // gives the scroll view something to scroll.
            constraints += [
                host.topAnchor.constraint(equalTo: document.topAnchor),
                host.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let host = scroll.documentView?.subviews.first as? NSHostingView<AnyView> else {
            return
        }
        host.rootView = AnyView(content())
    }

    /// An `NSScrollView` has no intrinsic size, so without this SwiftUI has
    /// nothing to go on and the surrounding stack can grow past the panel.
    /// Taking exactly what is offered keeps it inside its container.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 320)
    }
}
