import AppKit
import SwiftUI

// MARK: - Root view

struct MainWindowRootView: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 256)
                .frame(maxHeight: .infinity)
            DetailRouter(section: bridge.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The header is the whole window's drag handle now, so the content below
        // it is free to use presses for its own purposes. It goes on before the
        // panels, which cover the window while they are up and take the top
        // band with it.
        .overlay(alignment: .top) {
            WindowDragStrip().frame(height: WindowDragStrip.height)
        }
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
