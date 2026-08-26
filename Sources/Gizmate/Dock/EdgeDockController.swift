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
/// The dock panel's content view, whose one job is to keep whatever is inside
/// it exactly its own size.
///
/// Neither of the usual mechanisms does that here. An autoresizing mask drops
/// its deltas when an in-flight `animator().frame` animation is interrupted,
/// which a dock's is on every hover cycle — the reason `GlassHostView` heals its
/// own subviews the same way. Constraints against this view do not re-solve
/// either: nothing in a borderless panel's subtree triggers a layout pass when
/// the window is resized with `display: false`, which is how a dock arrives.
/// Measured, not guessed: the panel read 380x520 while the glass inside it sat
/// at 380x189 across four reveals, having been pinned once at the size it
/// happened to have when it was installed.
///
/// Setting the frame on every resize is self-healing — any later resize
/// restores exact geometry no matter what was missed.
final class DockContentView: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        subviews.forEach { $0.frame = bounds }
    }
}

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
    /// Where the pointer and the panel were when a drag on the handle started.
    private var dragStart: NSPoint?
    private var dragStartFrame: NSRect = .zero

    /// How long the pointer must be away before the dock closes. Long enough to
    /// cross the gap between a strip and the panel it opens, short enough not
    /// to linger over someone's work.
    private static let pointerLeftGrace: TimeInterval = 0.4

    /// ponytail: main screen only. Per-screen docks are a loop over
    /// `NSScreen.screens` here and a key change in `DockStore`; nothing below
    /// forbids it.
    private var screen: NSScreen? { NSScreen.main }

    /// What a top dock has to keep clear at its own top edge.
    ///
    /// The panel deliberately starts at `screenFrame.maxY` so it reads as the
    /// notch growing rather than as a window appearing under it
    /// (`DockGeometry.expandedFrame`) — which means its first menu-bar-height
    /// points are physically behind the housing on a notched Mac. Content
    /// there isn't dim or clipped, it is simply not visible, and the folder
    /// hub's chips landed in exactly that strip. Zero for the side docks,
    /// which have no such overlap to pay for.
    private var topContentInset: CGFloat {
        guard edge == .top, let screen else { return 0 }
        return DockGeometry.menuBarHeight(of: screen)
    }

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
        panel.contentView = DockContentView()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: macOS pairs a window shadow with a thin light rim, and on a
        // panel that hugs the bezel that rim reads as a border drawn along the
        // screen edge. The concave flare is what separates the dock from the
        // desktop; it does not need a second cue.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        observeMenuTracking()
    }

    /// A context menu is its own window, so the pointer moving onto the menu a
    /// card just opened reads as the pointer leaving the panel — and a peek
    /// would close underneath the menu the user is still choosing from. Any
    /// menu counts, not just a card's: while one is tracking, the pointer is
    /// not saying anything about this dock.
    private func observeMenuTracking() {
        let center = NotificationCenter.default
        for (name, tracking) in [
            (NSMenu.didBeginTrackingNotification, true),
            (NSMenu.didEndTrackingNotification, false),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.menuIsTracking = tracking }
            }
        }
    }

    /// An open side dock is a window the user asked for, so it stays until they
    /// say otherwise — dragged shut by the handle, or Escape. Only the tab strip
    /// still comes and goes with the pointer, and the notch keeps its old
    /// hover-in, hover-out behaviour: it is a peek, not a window.
    private var staysOpen: Bool {
        guard case .expanded(let itemID) = state else { return false }
        return isPinned(itemID)
    }

    /// The user's choice for the tool currently open. Separate from
    /// `staysOpen` because the drag handle is installed while the panel is
    /// still being built, before there is an `.expanded` state for `staysOpen`
    /// to read — and because the tab strip is a peek whatever this says.
    private func isPinned(_ itemID: String) -> Bool {
        store.dismissal(of: itemID) == .pinned
    }

    /// Placement changed. An edge with nothing left on it must not reveal.
    func rebuild() {
        guard store.items(on: edge).isEmpty else { return }
        transition(to: .hidden)
    }

    // MARK: - Hover

    func pointerMoved(to point: NSPoint) {
        guard let screen else { return }
        // A result is showing: it owns the edge until it closes itself.
        guard transientResult == nil else { return }
        // A menu is open somewhere — see `observeMenuTracking`.
        guard !menuIsTracking else { return }
        let items = dockItems()
        guard !items.isEmpty else { return }

        // A revealed side strip tracks the pointer: the closer it gets to the
        // bezel, the further the tab comes out to meet it. Horizontal distance
        // only — how far down the screen the pointer is says nothing about
        // whether it is heading for this edge.
        if state == .strip, edge != .top {
            resizeStrip(items: items, pointerX: point.x, on: screen)
        }

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

        guard !staysOpen else { return }
        schedulePointerLeftClose()
    }

    /// Set directly rather than animated: the pointer's own motion is the
    /// animation, and a 0.1s easing on top of a 30Hz stream would lag behind it.
    private func resizeStrip(items: [DockItem], pointerX: CGFloat, on screen: NSScreen) {
        let nearness = DockGeometry.proximity(
            pointerX: pointerX,
            edge: edge,
            screenFrame: screen.frame
        )
        let frame = DockGeometry.stripFrame(
            edge,
            tabCount: items.count,
            proximity: nearness,
            on: screen
        )
        guard abs(frame.width - panel.frame.width) > 0.5 else { return }
        panel.setFrame(frame, display: true)
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

    // MARK: - Hosting a result

    /// A result panel routed here instead of floating. It takes the edge over
    /// while it is up, and the edge's own surface comes back when it closes.
    private var transientResult: NSView?

    /// Whether any menu is on screen right now — see `observeMenuTracking`.
    private var menuIsTracking = false

    /// The seam `TranslationPanelController` uses. Weak on the way in, so a dock
    /// that goes away cannot keep a result alive.
    func resultHost() -> ResultSurfaceHost {
        ResultSurfaceHost(
            present: { [weak self] view in self?.presentResult(view) },
            dismiss: { [weak self] in self?.dismissResult() }
        )
    }

    private func presentResult(_ view: NSView) {
        guard let screen else { return }
        view.autoresizingMask = [.width, .height]
        // A window still fading out counts as visible: a new result replacing
        // one that closed a moment ago rides in from wherever the old one got
        // to, rather than jumping past the bezel to slide in over it.
        let wasVisible = state != .hidden || panel.isVisible
        transientResult = view
        pointerLeftTimer?.invalidate()
        pointerLeftTimer = nil
        // A result owns the edge until it closes itself (`pointerMoved` refuses
        // to touch a dock while one is up), so it always carries a way out —
        // it is a panel that stays open by definition, whatever the tool that
        // produced it does the rest of the time.
        install(view: view, showsDragHandle: true)
        let size = NSSize(
            width: edge == .top ? 620 : 380,
            height: edge == .top ? 300 : 520
        )
        present(
            frame: DockGeometry.expandedFrame(edge, contentSize: size, on: screen),
            animateFrame: wasVisible
        )
        state = .expanded(itemID: Self.transientID)
        installDismissMonitors()
    }

    private func dismissResult() {
        guard transientResult != nil else { return }
        transientResult = nil
        transition(to: .hidden)
    }

    /// Not a real item id — nothing in `DockCatalog` answers to it, which is
    /// what keeps a hosted result out of the tab strip.
    private static let transientID = "\u{0}result"

    // MARK: - Drag to close

    /// How far toward the bezel the panel must be pulled before letting go
    /// closes it. Short of that it springs back, so a nudge is not a dismissal.
    private static let dragCloseThreshold: CGFloat = 64

    func dragBegan() {
        dragStart = NSEvent.mouseLocation
        dragStartFrame = panel.frame
    }

    /// Measured from the absolute pointer position, not the gesture's own
    /// translation: this moves the window the gesture lives in, and a
    /// translation read inside a moving window compounds with itself.
    func dragChanged() {
        guard let dragStart else { return }
        let offset = bezelwardOffset(from: dragStart)
        panel.setFrame(dragStartFrame.offsetBy(dx: offset.x, dy: offset.y), display: true)
    }

    func dragEnded() {
        guard let start = dragStart else { return }
        let travel = bezelwardOffset(from: start)
        // Only one axis is ever non-zero, so this is that axis's distance.
        let offset = abs(travel.x) + abs(travel.y)
        dragStart = nil
        guard offset < Self.dragCloseThreshold else {
            transition(to: .hidden)
            return
        }
        // Not far enough — put it back rather than leaving it half off-screen.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(dragStartFrame, display: true)
        }
    }

    /// Drag only counts toward the bezel. Pulling a right-hand dock further left
    /// would tear it off its edge, which is not a thing this dock does.
    ///
    /// A point rather than a scalar because the notch closes upward: this used
    /// to measure `x` alone and return zero for `.top`, which was fine while a
    /// top dock could not stay open and so never carried a handle. Now that how
    /// a dock closes is the user's choice, a pinned notch needs the same way out
    /// as a pinned side dock.
    private func bezelwardOffset(from start: NSPoint) -> NSPoint {
        let now = NSEvent.mouseLocation
        switch edge {
        case .right: return NSPoint(x: max(now.x - start.x, 0), y: 0)
        case .left: return NSPoint(x: min(now.x - start.x, 0), y: 0)
        case .top: return NSPoint(x: 0, y: max(now.y - start.y, 0))
        }
    }

    // MARK: - States

    private func dockItems() -> [DockItem] {
        guard let host else { return [] }
        return store.items(on: edge).compactMap { DockCatalog.item(id: $0, host: host) }
    }

    /// Opens this dock straight onto one of its residents and hands it the
    /// keyboard, for a shortcut rather than for the pointer arriving.
    ///
    /// Every other way in is a hover, which is why nothing needed this before:
    /// the pointer is already at the edge by the time the panel exists. Ask's
    /// shortcut is pressed with the pointer anywhere, and it has to leave the
    /// caret in the chat's composer, so both steps are explicit here.
    /// Nothing here pins the panel open: a side dock already stays open in
    /// `.expanded` (`staysOpen`), and on the notch what keeps it up is
    /// `closeIfPointerStillAway` refusing to close over a focused text field,
    /// which is exactly the state this leaves it in.
    @discardableResult
    func reveal(itemID: String) -> Bool {
        guard dockItems().contains(where: { $0.id == itemID }) else { return false }
        transition(to: .expanded(itemID: itemID))
        SelfActivationGuard.activate()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    /// Opens and closes this dock a few times, reporting every frame that is
    /// supposed to be full-bleed after each one.
    ///
    /// Gated behind `GIZMATE_DOCK_DEBUG` and driven from `startDocks`, so it
    /// needs no pointer: the shrink-on-every-reveal it exists to measure is a
    /// cumulative one, which is exactly the kind a person cannot report
    /// accurately ("it was fine, now it is small") and a screenshot cannot
    /// either. Four rounds of guessing at that symptom is what this replaces.
    func debugRevealCycle(times: Int) async {
        guard let item = dockItems().first else { return }
        func rect(_ r: NSRect) -> String {
            "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))"
        }
        for round in 1...times {
            reveal(itemID: item.id)
            try? await Task.sleep(nanoseconds: 600_000_000)
            NSLog(
                "[dock:\(edge)] #\(round) panel=\(rect(panel.frame)) "
                    + "glass=\(rect(glass?.frame ?? .zero)) "
                    + "glassContent=\(rect(glass?.contentView.frame ?? .zero)) "
                    + "installed=\(rect(glass?.contentView.subviews.first?.frame ?? .zero)) "
                    + "state=\(state)"
            )
            transition(to: .hidden)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func transition(to next: DockState) {
        guard next != state, let screen else { return }
        let items = dockItems()
        guard !items.isEmpty, next != .hidden else {
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
            install(
                view: expandedView(items: items, active: item),
                showsDragHandle: isPinned(item.id)
            )
            // The notch's height is added to the panel rather than taken out
            // of it, so a top dock still gets its full 300pt of content.
            let size = NSSize(
                width: edge == .top ? 620 : 380,
                height: (edge == .top ? 300 : 520) + topContentInset
            )
            // Only a panel already expanded morphs into the next one — that is
            // one object resizing, and it keeps the tab you clicked on screen
            // throughout. Coming from the strip is not that: a 40pt tab
            // stretching into a 380pt panel drags the glass across the whole
            // trip and lays out squashed content at every frame of it. The tab
            // is a trigger, so it leaves the instant it is pressed, and the
            // panel arrives out of the bezel exactly as it does from hidden.
            var morph = false
            if case .expanded = state { morph = wasVisible }
            present(
                frame: DockGeometry.expandedFrame(edge, contentSize: size, on: screen),
                animateFrame: morph
            )
            state = .expanded(itemID: item.id)
            installDismissMonitors()
        }
    }

    /// Tabs beside the content, so switching items never means collapsing
    /// first. Skipped for a single item: one tab is chrome naming the thing you
    /// are already looking at.
    /// The panel's contents when an edge holds more than one resident: the
    /// active tool, and the rail for switching to another.
    ///
    /// Laid out with plain constraints rather than an `NSStackView`, after that
    /// stack got this wrong twice in two different ways. It centres arranged
    /// views at their intrinsic size on the cross axis, and an `NSHostingView`'s
    /// intrinsic size is whatever its SwiftUI content would ideally be — so the
    /// content took its own height instead of the panel's, and the folder hub's
    /// chips sat halfway down an empty panel with its files cut off. Pinning
    /// each view to the stack's cross axis fixed that until the rail's own
    /// intrinsic height stopped being flexible, at which point the negotiation
    /// went wrong again in the other direction and the content collapsed to a
    /// couple of lines.
    ///
    /// None of that is a mystery worth keeping: there are two subviews and the
    /// geometry is completely known. The rail is a fixed `stripMaxBreadth` on
    /// the bezel side, the content takes the rest, and both run the panel's
    /// full length. Nothing here negotiates.
    private func expandedView(items: [DockItem], active: DockItem) -> NSView {
        let content = margined(active.makeView())
        guard items.count > 1 else { return content }

        let strip = hostingView(
            DockTabStrip(
                items: items,
                activeID: active.id,
                edge: edge,
                inPanel: true
            ) { [weak self] id in
                self?.transition(to: .expanded(itemID: id))
            }
        )

        let container = NSView()
        for view in [content, strip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        let breadth = DockGeometry.stripMaxBreadth
        var rules: [NSLayoutConstraint] = []
        if edge == .top {
            // The rail hangs under the notch, the content fills the rest.
            rules = [
                strip.topAnchor.constraint(equalTo: container.topAnchor),
                strip.heightAnchor.constraint(equalToConstant: breadth),
                content.topAnchor.constraint(equalTo: strip.bottomAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ] + [strip, content].flatMap {
                [$0.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                 $0.trailingAnchor.constraint(equalTo: container.trailingAnchor)]
            }
        } else {
            // The rail hugs the bezel; on a right dock that is the right side.
            let bezelIsTrailing = edge == .right
            rules = [
                strip.widthAnchor.constraint(equalToConstant: breadth),
                bezelIsTrailing
                    ? strip.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                    : strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bezelIsTrailing
                    ? content.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                    : content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                bezelIsTrailing
                    ? content.trailingAnchor.constraint(equalTo: strip.leadingAnchor)
                    : content.leadingAnchor.constraint(equalTo: strip.trailingAnchor),
            ] + [strip, content].flatMap {
                [$0.topAnchor.constraint(equalTo: container.topAnchor),
                 $0.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
            }
        }
        NSLayoutConstraint.activate(rules)
        return container
    }

    /// The resident's view, held off the glass on every side.
    ///
    /// Here rather than inside each tool, and only around the tool: the tab rail
    /// hugs the bezel by design and the drag handle owns a gutter of its own, so
    /// neither may inherit this. See `DockGeometry.contentMargin`.
    private func margined(_ view: NSView) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        let margin = DockGeometry.contentMargin
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: margin),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -margin),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: margin),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -margin),
        ])
        return box
    }

    private func hostingView(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    // MARK: - Window

    private func present(frame: NSRect, animateFrame: Bool) {
        if !animateFrame {
            // Coming from nothing: start fully past the bezel so the panel
            // slides out of the screen edge rather than fading in on top of the
            // desktop. Only closing must not move — see `fadeOut`.
            panel.setFrame(DockGeometry.offscreenFrame(frame, for: edge), display: false)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            // The top dock travels its whole height on the way in — further
            // than a side strip's few points — so it gets the longer ride.
            context.duration = animateFrame ? 0.2 : (edge == .top ? 0.3 : 0.26)
            // Decelerating rather than `.easeOut`: the panel arrives from
            // off-screen at speed and settles, which reads as coming out of the
            // bezel instead of being placed there.
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.16, 0.9, 0.24, 1
            )
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Every dock leaves the way it came: back into its own bezel, fading as
    /// it goes.
    ///
    /// Never a shrink — liquid glass takes its shape from the model frame and
    /// teleports on frame-one of a *resizing* close, popping a disc at the
    /// centre; the ring paid for that lesson already. A pure translation is a
    /// different animal: the window moves, the glass keeps its own geometry
    /// inside it, and nothing has a new shape to snap to. Measured from
    /// `panel.frame` rather than from the frame the dock opened at, which is
    /// what makes this continue a drag-to-close instead of fighting it: a
    /// panel pulled halfway to the bezel by hand carries on in the same
    /// direction from wherever the hand let go.
    private func fadeOut() {
        let retract = DockGeometry.offscreenFrame(panel.frame, for: edge)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            // Accelerating away, the exact mirror of `present`'s decelerating
            // arrival: a panel that leaves the way it came reads as one thing
            // moving, not as two effects sharing an edge.
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.5, 0, 0.84, 0.4
            )
            panel.animator().setFrame(retract, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Only if nothing re-presented in the meantime: a result opened
            // during this fade would otherwise be ordered out by it.
            guard let self, self.state == .hidden else { return }
            self.panel.orderOut(nil)
        }
    }

    private func install(view: NSView, showsDragHandle: Bool = false) {
        guard let root = panel.contentView else { return }
        glass?.removeFromSuperview()
        let dockEdge = edge
        let host = GlassHostView(
            frame: root.bounds,
            cornerRadius: DockGeometry.panelCornerRadius,
            tintColor: nil,
            style: .regular,
            cornerPath: { DockGeometry.panelPath(for: dockEdge, in: $0) }
        )
        // No autoresizing mask and no constraints: `DockContentView` sets this
        // frame to its own bounds on every resize, which is the only one of the
        // three that survives an interrupted frame animation. See its doc.
        root.addSubview(host)
        host.frame = root.bounds
        glass = host

        // Every edge sits on black, not on whatever the desktop happens to be.
        // The glass stays underneath for the flare and the rim; this is the
        // sheet the rows are read off. Painted on the content view, which is a
        // subview of the material, so the concave `cornerPath` mask clips it
        // for free.
        host.contentView.wantsLayer = true
        host.contentView.layer?.backgroundColor = NSColor.black.cgColor

        // Keep the content off the flare — the shape pulls in by
        // `inverseCornerRadius` on the bezel side — and, at the top, off the
        // notch as well.
        let insets = DockGeometry.contentInsets(for: edge)
        let topInset = insets.top + topContentInset
        // The handle owns a column, and the content starts after it. It used to
        // be an overlay pinned on top of the content, which meant its hit area
        // ate clicks aimed at the panel underneath and its tooltip appeared in
        // the middle of the text.
        let gutter = showsDragHandle ? DockDragHandle.width : 0
        view.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(
                equalTo: host.contentView.leadingAnchor,
                constant: insets.left + (edge == .right ? gutter : 0)
            ),
            view.trailingAnchor.constraint(
                equalTo: host.contentView.trailingAnchor,
                constant: -insets.right - (edge == .left ? gutter : 0)
            ),
            view.topAnchor.constraint(equalTo: host.contentView.topAnchor, constant: topInset),
            view.bottomAnchor.constraint(
                equalTo: host.contentView.bottomAnchor,
                constant: -insets.bottom - (edge == .top ? gutter : 0)
            ),
        ])

        guard showsDragHandle else { return }
        let handle = NSHostingView(rootView: DockDragHandle(
            edge: edge,
            onTap: { [weak self] in self?.transition(to: .hidden) },
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragBegan: { [weak self] in self?.dragBegan() },
            onDragEnded: { [weak self] in self?.dragEnded() }
        ))
        handle.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(handle)
        // On the inner edge — the side away from the bezel, which is the only
        // direction there is anywhere to drag to. For the notch that is the
        // bottom, so the gutter runs across rather than down.
        let content = host.contentView
        let rules: [NSLayoutConstraint]
        switch edge {
        case .top:
            rules = [
                handle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                handle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: insets.left),
                handle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -insets.right),
            ]
        case .left, .right:
            rules = [
                edge == .left
                    ? handle.trailingAnchor.constraint(equalTo: content.trailingAnchor)
                    : handle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                handle.topAnchor.constraint(equalTo: content.topAnchor, constant: topInset),
                handle.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -insets.bottom),
            ]
        }
        NSLayoutConstraint.activate(rules)
    }

    // MARK: - Dismiss

    /// Escape and clicks outside, the same pair `RadialMenuController` installs.
    /// Global monitors never see our own events, so a click inside the dock is
    /// not a click outside it.
    private func installDismissMonitors() {
        removeDismissMonitors()
        var monitors: [Any?] = []
        // A click elsewhere dismisses a peek, but not a dock the user opened —
        // clicking into another app is how you *use* what is on that edge.
        if !staysOpen {
            monitors.append(NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.transition(to: .hidden) }
            })
        }
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
