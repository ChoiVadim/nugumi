import AppKit
import SwiftUI

/// SwiftUI content inside an `NSScrollView` we own, for use in borderless
/// floating panels.
///
/// `ScrollerConfigurator` is enough in the main window, but not here: in a
/// borderless panel AppKit *reverts* a manually-set `scrollerStyle = .overlay`
/// back to the system's wide legacy scroller, whose track never hides. The fix
/// is `OverlayScrollView`, which overrides the getter so there is nothing to
/// revert — and a SwiftUI `ScrollView` cannot be told to use a custom
/// `NSScrollView` subclass, so the content has to be hosted the other way round.
///
/// Only the width is pinned to the clip view. Height stays intrinsic, which is
/// what gives the document something to scroll.
struct OverlayScrollHost<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .light
        scroll.contentView.drawsBackground = false

        let host = NSHostingView(rootView: AnyView(content()))
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<AnyView> else { return }
        host.rootView = AnyView(content())
    }
}
