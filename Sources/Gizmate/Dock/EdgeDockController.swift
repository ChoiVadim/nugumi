import AppKit
import SwiftUI

/// Panel that may hang off the screen edges and over the menu bar.
///
/// `constrainFrameRect` is overridden for the same reason `RadialMenuPanel`
/// overrides it: AppKit silently pulls windows out from under the menu bar and
/// back onto the screen, which is exactly where the top dock lives.
///
/// `canBecomeKey` for the same reason `KeyableLivePanel` needs it: the docked
/// notes view has a text field, and a `.nonactivatingPanel` will not take key
/// focus by default — it would reveal and then swallow every keystroke.
final class EdgeDockPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { true }
}

/// One dock, on one edge.
///
/// Hidden means no window: the panel is `orderOut` until `DockHoverMonitor`
/// reports the pointer inside this edge's reveal zone.
@MainActor
final class EdgeDockController {
    /// `strip` is the tabs alone, `expanded` is tabs plus the active item.
    enum DockState: Equatable {
        case hidden
        case strip
        case expanded(itemID: String)
    }

    let edge: DockEdge

    private let store: DockStore
    private weak var host: (any SettingsHost)?
    private let panel: EdgeDockPanel
    private var glass: GlassHostView?
    private var state: DockState = .hidden
    private var pointerLeftTimer: Timer?
    private var dismissMonitors: [Any] = []

    /// How long the pointer must be away before the dock closes. Long enough to
    /// cross the gap between a strip and the panel it opens, short enough not
    /// to linger over someone's work.
    private static let pointerLeftGrace: TimeInterval = 0.4

    /// ponytail: main screen only. Per-screen docks are a loop over
    /// `NSScreen.screens` here and a key change in `DockStore`; nothing below
    /// forbids it.
    private var screen: NSScreen? { NSScreen.main }

    init(edge: DockEdge, store: DockStore, host: any SettingsHost) {
        self.edge = edge
        self.store = store
        self.host = host
        panel = EdgeDockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Placement changed. An edge with nothing left on it must not reveal.
    func rebuild() {
        guard store.items(on: edge).isEmpty else { return }
        transition(to: .hidden)
    }

    // MARK: - Hover

    func pointerMoved(to point: NSPoint) {
        guard let screen else { return }
        let items = dockItems()
        guard !items.isEmpty else { return }

        if state != .hidden, panel.frame.insetBy(dx: -12, dy: -12).contains(point) {
            // Back over the dock — cancel any pending close.
            pointerLeftTimer?.invalidate()
            pointerLeftTimer = nil
            return
        }

        if state == .hidden {
            guard DockGeometry.revealZone(edge, on: screen).contains(point) else { return }
            // The notch is a handle you can already see, so hovering it can
            // commit. The side edges show nothing until you get there, so their
            // hover has to produce the affordance first — otherwise crossing
            // the screen opens a panel.
            transition(to: edge == .top ? .expanded(itemID: items[0].id) : .strip)
            return
        }

        schedulePointerLeftClose()
    }

    private func schedulePointerLeftClose() {
        guard pointerLeftTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerLeftGrace, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeIfPointerStillAway() }
        }
        // `.common` rather than the default mode: a scroll or a menu tracking
        // loop would otherwise stall the timer and strand the dock open.
        RunLoop.main.add(timer, forMode: .common)
        pointerLeftTimer = timer
    }

    /// Never closes out from under someone typing. While the panel holds key
    /// focus in a text field the pointer is parked elsewhere by definition, and
    /// closing would throw away what was written.
    private func closeIfPointerStillAway() {
        pointerLeftTimer = nil
        if panel.isKeyWindow, panel.firstResponder is NSTextView { return }
        transition(to: .hidden)
    }

    // MARK: - States

    private func dockItems() -> [DockItem] {
        guard let host else { return [] }
        return store.items(on: edge).compactMap { DockCatalog.item(id: $0, host: host) }
    }

    private func transition(to next: DockState) {
        guard next != state, let screen else { return }
        let items = dockItems()
        guard !items.isEmpty else {
            if state != .hidden { fadeOut() }
            state = .hidden
            removeDismissMonitors()
            return
        }
        let wasVisible = state != .hidden

        switch next {
        case .hidden:
            pointerLeftTimer?.invalidate()
            pointerLeftTimer = nil
            fadeOut()
            removeDismissMonitors()
            state = .hidden

        case .strip:
            install(view: hostingView(
                DockTabStrip(
                    items: items,
                    activeID: nil,
                    edge: edge
                ) { [weak self] id in
                    self?.transition(to: .expanded(itemID: id))
                }
            ))
            present(
                frame: DockGeometry.stripFrame(edge, tabCount: items.count, on: screen),
                animateFrame: wasVisible
            )
            state = .strip
            installDismissMonitors()

        case .expanded(let itemID):
            guard let item = items.first(where: { $0.id == itemID }) ?? items.first else { return }
            install(view: expandedView(items: items, active: item))
            let size = NSSize(
                width: edge == .top ? 620 : 380,
                height: edge == .top ? 300 : 520
            )
            present(
                frame: DockGeometry.expandedFrame(edge, contentSize: size, on: screen),
                animateFrame: wasVisible
            )
            state = .expanded(itemID: item.id)
            installDismissMonitors()
        }
    }

    /// Tabs beside the content, so switching items never means collapsing
    /// first. Skipped for a single item: one tab is chrome naming the thing you
    /// are already looking at.
    private func expandedView(items: [DockItem], active: DockItem) -> NSView {
        let content = active.makeView()
        guard items.count > 1 else { return content }

        let strip = hostingView(
            DockTabStrip(
                items: items,
                activeID: active.id,
                edge: edge
            ) { [weak self] id in
                self?.transition(to: .expanded(itemID: id))
            }
        )

        let ordered: [NSView] = edge == .right ? [content, strip] : [strip, content]
        let stack = NSStackView(views: ordered)
        stack.orientation = edge == .top ? .vertical : .horizontal
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let axis: NSLayoutConstraint.Orientation = edge == .top ? .vertical : .horizontal
        strip.setContentHuggingPriority(.required, for: axis)
        strip.setContentCompressionResistancePriority(.required, for: axis)
        content.setContentHuggingPriority(.defaultLow, for: axis)
        return stack
    }

    private func hostingView(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    // MARK: - Window

    private func present(frame: NSRect, animateFrame: Bool) {
        if animateFrame {
            // Growing is fine to animate: the glass fills `contentView` and
            // follows the model frame. Only closing must not move.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    private func fadeOut() {
        // Fade in place — never shrink. Liquid glass takes its shape from the
        // model frame and teleports on frame-one of a closing frame animation,
        // popping a disc at the centre. The ring paid for this lesson already.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    private func install(view: NSView) {
        guard let root = panel.contentView else { return }
        glass?.removeFromSuperview()
        let host = GlassHostView(
            frame: root.bounds,
            cornerRadius: DockGeometry.panelCornerRadius,
            tintColor: nil,
            style: .regular,
            maskedCorners: DockGeometry.maskedCorners(for: edge)
        )
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        glass = host

        view.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.contentView.bottomAnchor),
        ])
    }

    // MARK: - Dismiss

    /// Escape and clicks outside, the same pair `RadialMenuController` installs.
    /// Global monitors never see our own events, so a click inside the dock is
    /// not a click outside it.
    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        var monitors: [Any?] = []
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.transition(to: .hidden) }
        })
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // Escape
            Task { @MainActor [weak self] in self?.transition(to: .hidden) }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in self?.transition(to: .hidden) }
            return nil
        })
        dismissMonitors = monitors.compactMap { $0 }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
    }
}
