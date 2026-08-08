import AppKit
import SwiftUI

// MARK: - Root view

struct MainWindowRootView: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        HStack(spacing: 0) {
            // Narrower than it was, and it does not collapse. Six short labels
            // never filled 256pt, and a sidebar this small buys the content
            // more by simply being smaller than a toggle could buy it by going
            // away — a control to hide six rows costs a decision every time you
            // look at it, to reclaim less width than trimming did for free.
            SidebarView()
                .frame(width: 212)
                .frame(maxHeight: .infinity)
            DetailRouter(section: bridge.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let scope = bridge.modelPickerScope {
                ModelPickerOverlay(
                    scope: scope,
                    onDismiss: { bridge.modelPickerScope = nil },
                    onChoose: { id in
                        bridge.modelPickerScope = nil
                        bridge.perform(.chooseModel(id, scope))
                    }
                )
            }
        }
        .overlay {
            if let sheet = bridge.ringSheet {
                RingSheetOverlay(sheet: sheet)
            }
        }
    }
}

/// The strip of window across the top — the band the traffic lights sit in.
/// Pressing it drags the window, the way pressing a title bar does; everything
/// else is left to the content underneath.
private struct WindowDragStrip: NSViewRepresentable {
    /// A standard title bar's height. The sidebar and every detail card already
    /// keep their contents clear of it.
    static let height: CGFloat = 28

    func makeNSView(context: Context) -> NSView { DragStripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragStripView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        /// Dragging an inactive window shouldn't cost a click to focus it first.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Claims presses and nothing else. Scrolling with the pointer up here,
        /// or hovering something that peeks into the strip, still reaches
        /// whatever is underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }
    }
}
