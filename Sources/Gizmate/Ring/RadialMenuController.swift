import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreServices
import CoreText
import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications
import Vision

/// The ring of action buttons that opens around the floating bar.
/// Purely presentational: owns one transparent panel, reports the picked
/// action via `onSelect`, and calls `onDismiss` when it closed itself
/// (outside click, Escape, empty-area click). The presenter owns the
/// toggle state and calls `close()` for its own teardown paths.
@MainActor
final class RadialActionMenuController {
    private let panel: NSPanel
    /// Hover over the ring's center (the bar under the ✕). The presenter
    /// subscribes to drive its close-button hover tint — its own tracking
    /// area is occluded by this panel while the ring is open.
    var onCenterHoverChange: ((Bool) -> Void)?
    /// The bar panel that opened the menu. Its clicks are exempt from
    /// the local dismiss monitor: if a click reaches the presenter (past the
    /// menu's own backdrop), its handler must see the menu still open and
    /// toggle it — dismissing here first would make that handler reopen.
    private weak var presenterWindow: NSWindow?
    /// One entry per ring position, `nil` where the slot is empty or its action
    /// isn't available right now. Positions are fixed: a missing slot leaves a
    /// gap instead of shifting its neighbours, so a button never moves — not
    /// when the user empties a slot, and not when the contextual Summarize
    /// button comes and goes between apps.
    private let slots: [RingItem?]
    private let onDismiss: () -> Void
    /// Center of the panel in its own coordinates — the origin every offset and
    /// every cursor reading is measured from.
    private var panelCenter: NSPoint = .zero

    /// One rendered first-ring button. It carries its own offset because the
    /// pick is resolved from angles, not from frames: frames move during the
    /// open and collapse animations, the direction a button lives in never
    /// does. `slotIndex` is its position on the eight-way ring, which is what
    /// its orbit is keyed by — empty slots leave gaps, so it is not the index
    /// in this array.
    private struct RingButton {
        let slotIndex: Int
        let offset: CGPoint
        let item: RingItem
        let view: RadialMenuButtonView
        let bubble: RadialMenuLabelBubbleView?
    }

    private var ringButtons: [RingButton] = []
    /// An orbit revealed by pointing at its parent: the buttons behind one
    /// expandable parent, built hidden at init and parked on that parent until
    /// revealed. Kept out of `ringButtons` so the ring's own open/close
    /// animations ignore them.
    ///
    /// Keyed per parent rather than held as one shared set — the ring can carry
    /// several expandable buttons at once (a Summarize plus any number of
    /// folders), and hovering one must not reveal the others.
    private struct Orbit {
        /// The button this orbit belongs to — highlighted while it is open, and
        /// the point its buttons spring out of and collapse back into.
        weak var parent: RadialMenuButtonView?
        var origin: NSPoint
        var buttons: [RadialMenuButtonView] = []
        var targets: [NSRect] = []
        /// Direction each button lives in, parallel to `buttons` — what the
        /// angular pick is resolved against.
        var offsets: [CGPoint] = []
        var items: [RingItem] = []
        /// Each button's callout, parallel to `buttons`. `nil` where the
        /// button opens an orbit of its own — the callout would sit exactly
        /// where that orbit fans out — or carries no label at all.
        var bubbles: [RadialMenuLabelBubbleView?] = []
        /// Orbits owned by this orbit's own expandable buttons, by position.
        var children: [Int: Orbit] = [:]
    }

    /// Orbits owned by first-ring buttons, keyed by slot index.
    private var orbits: [Int: Orbit] = [:]
    /// Which first-ring orbit is open, and which of its buttons has opened a
    /// further one. Only one of each at a time, as before.
    private var openOrbitSlot: Int?
    private var openChildIndex: Int?
    /// The one thing the cursor points at: which layer (0 the ring, 1 the open
    /// orbit, 2 the open child orbit) and which button in it. `nil` when the
    /// cursor is in the center's dead zone or past the outer wall, the only
    /// places left where a click means "dismiss".
    private var pick: (layer: Int, index: Int)?
    /// Every button currently drawn swollen. See `refreshHighlights`.
    private var swollen: [RadialMenuButtonView] = []
    private var dismissMonitors: [Any] = []
    private var didClose = false

    init(
        centeredOn anchor: NSPoint,
        ignoring presenterWindow: NSWindow?,
        slots: [RingItem?],
        onDismiss: @escaping () -> Void
    ) {
        self.presenterWindow = presenterWindow
        self.slots = slots
        self.onDismiss = onDismiss

        let frame = RadialMenuLayoutPolicy.panelFrame(anchor: anchor)

        panel = RadialMenuPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        // The app forces darkAqua globally, but the ring's glass should match
        // the SYSTEM look (Control Center behavior): inherited forced-dark
        // renders the smoky dark glass variant even on a light-mode system.
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        panel.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)

        let container = RadialMenuBackdropView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        container.onClick = { [weak self] in self?.activatePick() }
        container.onDismissClick = { [weak self] in self?.dismiss() }
        container.onCenterHoverChange = { [weak self] hovered in
            // Hovering the center ✕ dismisses any open orbit too.
            if hovered { self?.hideOrbit() }
            self?.onCenterHoverChange?(hovered)
        }
        let centerDiameter = RadialMenuLayoutPolicy.buttonDiameter
        container.trackCenterHover(in: NSRect(
            x: frame.width / 2 - centerDiameter / 2,
            y: frame.height / 2 - centerDiameter / 2,
            width: centerDiameter,
            height: centerDiameter
        ))

        let panelCenter = NSPoint(x: frame.width / 2, y: frame.height / 2)
        self.panelCenter = panelCenter
        let ringCenters = RadialMenuLayoutPolicy.buttonCenters(count: slots.count)
        for (slotIndex, pair) in zip(slots, ringCenters).enumerated() {
            let (slot, offset) = pair
            guard let item = slot else { continue }
            let button = RadialMenuButtonView(image: item.image)
            button.setFrameOrigin(NSPoint(
                x: panelCenter.x + offset.x - button.frame.width / 2,
                y: panelCenter.y + offset.y - button.frame.height / 2
            ))
            container.addSubview(button)

            if item.expandsOnHover {
                orbits[slotIndex] = buildOrbit(
                    for: item,
                    parent: button,
                    parentOffset: offset,
                    depth: 1,
                    panelCenter: panelCenter,
                    container: container
                )
            }

            // An expandable parent gets no callout: its own orbit fans out into
            // exactly the space the callout would occupy. An empty label means
            // "highlight only" — the app summarize button carries its identity
            // in its app icon, so pointing at it shows no "Telegram" bubble.
            let bubble = item.expandsOnHover
                ? nil
                : makeBubble(
                    for: item,
                    at: offset,
                    buttonFrame: button.frame,
                    in: container
                )
            ringButtons.append(RingButton(
                slotIndex: slotIndex,
                offset: offset,
                item: item,
                view: button,
                bubble: bubble
            ))
        }

        // Batch every button's NSGlassEffectView into one backdrop pass via
        // NSGlassEffectContainerView (resolved by name — see GlassHostView).
        // Standalone glass views each capture the backdrop on their own,
        // asynchronously: buttons came up as darker placeholders and snapped
        // to real glass seconds later, one by one.
        if let containerCls = NSClassFromString("NSGlassEffectContainerView") as? NSView.Type {
            let glassGroup = containerCls.init(frame: NSRect(origin: .zero, size: frame.size))
            if glassGroup.responds(to: NSSelectorFromString("setContentView:")) {
                glassGroup.setValue(container, forKey: "contentView")
                panel.contentView = glassGroup
            } else {
                panel.contentView = container
            }
        } else {
            panel.contentView = container
        }
    }

    func show() {
        panel.orderFrontRegardless()
        animateButtonsIn()
        installDismissMonitors()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        removeDismissMonitors()
        // Dissolve in place — no frame animation at all. NSGlassEffectView
        // renders its shape from the MODEL frame, so any flight toward the
        // center makes the stacked glass pop up there as a full-opacity disc
        // on the very first frame (verified frame-by-frame from a screen
        // recording). With the frames untouched there is nothing to appear
        // in the center; the whole ring just fades where it stands.
        // The panel dies in the completion and is captured strongly, so the
        // teardown outlives self (presenters drop their reference right after
        // calling close). Mouse events stop immediately.
        panel.ignoresMouseEvents = true
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
    }

    private func dismiss() {
        guard !didClose else { return }
        close()
        onDismiss()
    }

    private func finish(with item: RingItem) {
        guard !didClose else { return }
        close()
        item.handler()
    }

    // MARK: - Hover-revealed orbits (sticky)

    /// Builds one orbit's buttons, hidden and parked on their parent, plus the
    /// orbits any of them own in turn. `depth` picks the radius: 1 is the orbit
    /// outside the ring, 2 the one outside that.
    private func buildOrbit(
        for item: RingItem,
        parent: RadialMenuButtonView,
        parentOffset: CGPoint,
        depth: Int,
        panelCenter: NSPoint,
        container: NSView
    ) -> Orbit {
        let radius = depth == 1
            ? RadialMenuLayoutPolicy.outerRingRadius
            : RadialMenuLayoutPolicy.thirdRingRadius
        var orbit = Orbit(
            parent: parent,
            origin: NSPoint(x: panelCenter.x + parentOffset.x, y: panelCenter.y + parentOffset.y)
        )

        // `.slots` keeps every button on its own ring direction, so an empty
        // slot leaves a gap; `.fan` packs what's there next to the parent.
        let placed: [(item: RingItem, offset: CGPoint)]
        switch item.subLayout {
        case .slots:
            let centers = RadialMenuLayoutPolicy.orbitSlotCenters(
                radius: radius,
                count: item.subItems.count
            )
            placed = item.subItems.enumerated().compactMap { index, sub in
                guard let sub, let offset = centers[safe: index] else { return nil }
                return (sub, offset)
            }
        case .fan:
            let present = item.subItems.compactMap { $0 }
            let centers = RadialMenuLayoutPolicy.subClusterCenters(
                parentOffset: parentOffset,
                count: present.count,
                radius: radius
            )
            placed = Array(zip(present, centers))
        }

        for (index, entry) in placed.enumerated() {
            let sub = entry.item
            let expands = sub.expandsOnHover && depth < 2
            let subButton = RadialMenuButtonView(image: sub.image)
            subButton.setFrameOrigin(NSPoint(
                x: panelCenter.x + entry.offset.x - subButton.frame.width / 2,
                y: panelCenter.y + entry.offset.y - subButton.frame.height / 2
            ))
            orbit.targets.append(subButton.frame)
            orbit.offsets.append(entry.offset)
            orbit.items.append(sub)
            subButton.isHidden = true
            subButton.alphaValue = 0
            container.addSubview(subButton)
            orbit.buttons.append(subButton)
            // An expandable sub gets no callout: its own orbit fans out into
            // exactly the space the callout would occupy.
            orbit.bubbles.append(
                expands
                    ? nil
                    : makeBubble(
                        for: sub,
                        at: entry.offset,
                        buttonFrame: subButton.frame,
                        in: container
                    )
            )

            if expands {
                orbit.children[index] = buildOrbit(
                    for: sub,
                    parent: subButton,
                    parentOffset: entry.offset,
                    depth: depth + 1,
                    panelCenter: panelCenter,
                    container: container
                )
            }
        }
        return orbit
    }

    // MARK: - Angular selection

    /// The layers a pick can currently land on, innermost first: the ring
    /// always, then whichever orbits are open. Directions, not frames — a
    /// button flying out of its parent is already selectable at the place it
    /// is flying to.
    private var liveLayers: [[CGPoint]] {
        var layers = [ringButtons.map(\.offset)]
        guard let orbit = openOrbit else { return layers }
        layers.append(orbit.offsets)
        if let index = openChildIndex, let child = orbit.children[index] {
            layers.append(child.offsets)
        }
        return layers
    }

    /// Where the cursor is relative to the ring's center, read from the screen
    /// rather than from an event: mouse-moved events reach a non-activating
    /// panel that is never key only through the monitors, and those carry
    /// screen coordinates.
    private var cursorOffset: CGPoint {
        let location = NSEvent.mouseLocation
        return CGPoint(
            x: location.x - panel.frame.minX - panelCenter.x,
            y: location.y - panel.frame.minY - panelCenter.y
        )
    }

    private func refreshPick() {
        guard !didClose else { return }
        let next = RadialMenuLayoutPolicy.angularPick(cursor: cursorOffset, layers: liveLayers)
        guard next?.layer != pick?.layer || next?.index != pick?.index else { return }
        apply(next)
    }

    /// Moves the selection, and with it whichever orbit that selection implies.
    /// The old callout is faded before the orbits move, while the layer it
    /// belongs to still resolves.
    private func apply(_ next: (layer: Int, index: Int)?) {
        fadeBubble(for: pick, to: false)
        pick = next

        if let next {
            switch next.layer {
            case 0:
                // Pointing at an expandable parent reveals its orbit; pointing
                // at any other ring button puts away whatever was open. That is
                // still the only thing besides picking that closes one.
                let slot = ringButtons[next.index].slotIndex
                if orbits[slot] != nil { showOrbit(slot) } else { hideOrbit() }
            case 1:
                if openOrbit?.children[next.index] != nil {
                    showChildOrbit(next.index)
                } else {
                    hideChildOrbit()
                }
            default:
                // The third layer is the outermost thing on screen: nothing
                // further to reveal.
                break
            }
        }

        fadeBubble(for: next, to: true)
        refreshHighlights()
    }

    private func fadeBubble(for target: (layer: Int, index: Int)?, to visible: Bool) {
        guard let target, let layer = orbitLayer(target.layer) else { return }
        Self.fade(layer.bubbles[safe: target.index] ?? nil, to: visible)
    }

    /// The one place a button swells, at every layer. Swollen means picked, or
    /// parent of an open orbit — the breadcrumb saying which button these
    /// others came out of, which has to survive the cursor travelling past it
    /// into its own orbit.
    ///
    /// Diffed against what is already swollen rather than reasserted, because
    /// `setHighlighted` starts a spring animation and restarting it on every
    /// mouse move would leave the discs permanently mid-bounce.
    private func refreshHighlights() {
        var next: [RadialMenuButtonView] = []
        if let slot = openOrbitSlot, let parent = orbits[slot]?.parent {
            next.append(parent)
        }
        if let index = openChildIndex, let button = openOrbit?.buttons[safe: index] {
            next.append(button)
        }
        if let pick,
           let layer = orbitLayer(pick.layer),
           let button = layer.buttons[safe: pick.index] {
            next.append(button)
        }
        for button in swollen where !next.contains(where: { $0 === button }) {
            button.setHighlighted(false)
        }
        for button in next where !swollen.contains(where: { $0 === button }) {
            button.setHighlighted(true)
        }
        swollen = next
    }

    /// The buttons and callouts of one layer, with the ring itself dressed up
    /// as an orbit so a pick reads the same at every depth.
    private func orbitLayer(_ layer: Int) -> Orbit? {
        switch layer {
        case 0:
            return Orbit(
                origin: panelCenter,
                buttons: ringButtons.map(\.view),
                bubbles: ringButtons.map(\.bubble)
            )
        case 1:
            return openOrbit
        default:
            return openChildIndex.flatMap { openOrbit?.children[$0] }
        }
    }

    /// Runs whatever the cursor points at. Nothing picked means the cursor is
    /// in the dead zone or past the outer wall, which is the one gesture left
    /// that means "put this away".
    private func activatePick() {
        guard !didClose else { return }
        // A click can be the first thing that happens after the ring opens, or
        // land somewhere the last move monitor never reported. Read the cursor
        // once more so what runs is what the user is pointing at now.
        refreshPick()
        guard let pick, let layer = orbitLayer(pick.layer) else {
            dismiss()
            return
        }
        let item: RingItem?
        switch pick.layer {
        case 0: item = ringButtons[safe: pick.index]?.item
        default: item = layer.items[safe: pick.index]
        }
        guard let item else { return }
        // An expandable parent reveals its orbit instead of firing and closing —
        // the ring stays. Unless it has a default of its own to run
        // (`firesOnClick`), in which case pointing at it is what opened the
        // orbit and clicking runs the default. Note is usually inside the More
        // folder, so that exception is the path its click actually takes.
        let expands = pick.layer == 0
            ? orbits[ringButtons[pick.index].slotIndex] != nil
            : layer.children[pick.index] != nil
        guard !expands || item.firesOnClick else { return }
        finish(with: item)
    }

    /// Opens the orbit behind first-ring slot `slotIndex` and keeps it open.
    /// It stays up until a DIFFERENT first-ring button is pointed at, the ring
    /// is dismissed, or something in it is picked.
    private func showOrbit(_ slotIndex: Int) {
        guard !didClose, openOrbitSlot != slotIndex, let orbit = orbits[slotIndex] else { return }
        // Only one orbit at a time: whatever was open collapses first.
        hideOrbit()
        openOrbitSlot = slotIndex
        reveal(orbit)
    }

    /// A button's hover callout, parked outside it on the side it sits on, or
    /// `nil` when the item carries no label to show.
    private func makeBubble(
        for item: RingItem,
        at offset: CGPoint,
        buttonFrame: NSRect,
        in container: NSView
    ) -> RadialMenuLabelBubbleView? {
        guard !item.label.isEmpty else { return nil }
        let placement = RadialMenuLayoutPolicy.labelPlacement(for: offset)
        let bubble = RadialMenuLabelBubbleView(text: item.label, tailEdge: placement.opposite)
        bubble.setFrameOrigin(RadialMenuLayoutPolicy.bubbleOrigin(
            for: placement,
            buttonFrame: buttonFrame,
            bubbleSize: bubble.frame.size
        ))
        bubble.alphaValue = 0
        container.addSubview(bubble)
        return bubble
    }

    /// Ease the callout in gently; hide it fast so it never lags behind the
    /// cursor leaving the button.
    private static func fade(_ bubble: RadialMenuLabelBubbleView?, to visible: Bool) {
        guard let bubble else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.3 : 0.15
            bubble.animator().alphaValue = visible ? 1 : 0
        }
    }

    private var openOrbit: Orbit? {
        openOrbitSlot.flatMap { orbits[$0] }
    }

    /// Reveals the orbit owned by the open orbit's button at `index`,
    /// collapsing any other open one.
    private func showChildOrbit(_ index: Int) {
        guard !didClose, openChildIndex != index else { return }
        hideChildOrbit()
        guard let child = openOrbit?.children[index] else { return }
        openChildIndex = index
        reveal(child)
    }

    private func hideChildOrbit() {
        guard let index = openChildIndex else { return }
        openChildIndex = nil
        guard let child = openOrbit?.children[index] else { return }
        collapse(child)
        refreshHighlights()
    }

    private func hideOrbit() {
        hideChildOrbit()
        guard let orbit = openOrbit else { return }
        openOrbitSlot = nil
        collapse(orbit)
        refreshHighlights()
    }

    /// Springs the orbit out of its parent button — the same feel and timing as
    /// the ring itself opening.
    ///
    /// Staged over two CA transactions: an animation scheduled in the same
    /// commit that unhides a layer is skipped outright, which used to make the
    /// reveal pop in fully settled while the collapse animated fine.
    ///
    /// Nothing is gated on the fly-out finishing. Selection reads the direction
    /// a button lives in, not the frame it currently occupies, so a button
    /// crossing under the cursor mid-flight cannot steal the pick — which is
    /// what the old hover tracking had to be suspended to prevent.
    private func reveal(_ orbit: Orbit) {
        for (sub, target) in zip(orbit.buttons, orbit.targets) {
            sub.frame = NSRect(
                x: orbit.origin.x - target.width / 2,
                y: orbit.origin.y - target.height / 2,
                width: target.width,
                height: target.height
            )
            sub.isHidden = false
            sub.alphaValue = 0
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didClose else { return }
            for (sub, target) in zip(orbit.buttons, orbit.targets) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
                    sub.animator().frame = target
                    sub.animator().alphaValue = 1
                }
            }
        }
    }

    /// Collapse back INTO the parent button, mirroring the ring's own close.
    /// Highlights are not touched here — `refreshHighlights` owns every one of
    /// them, and it runs right after, once the open-orbit state is settled.
    private func collapse(_ orbit: Orbit) {
        // The callouts go with the orbit. Letting one ride out the collapse
        // leaves a label naming a button that is no longer on screen.
        for bubble in orbit.bubbles { Self.fade(bubble, to: false) }
        for (sub, target) in zip(orbit.buttons, orbit.targets) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                sub.animator().frame = NSRect(
                    x: orbit.origin.x - target.width / 2,
                    y: orbit.origin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                sub.animator().alphaValue = 0
            }, completionHandler: { [weak sub] in
                sub?.isHidden = true
                sub?.frame = target   // reset for the next reveal
            })
        }
    }

    private func animateButtonsIn() {
        guard let container = panel.contentView else { return }
        for button in ringButtons.map(\.view) {
            let target = button.frame
            button.frame = NSRect(
                x: container.bounds.midX - target.width / 2,
                y: container.bounds.midY - target.height / 2,
                width: target.width,
                height: target.height
            )
            button.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                // Same springy overshoot as the bar's hover scale.
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.34, 1.45, 0.5, 1
                )
                button.animator().frame = target
                button.animator().alphaValue = 1
            }
        }
    }

    /// The panel is non-activating and never key, so Escape needs both a
    /// local monitor (Gizmate frontmost) and a global one (another app
    /// frontmost — observed, not consumed). Mouse clicks: the global monitor
    /// covers other apps, the local one covers Gizmate's own windows — except
    /// the menu itself and the presenting bar, whose click handler owns
    /// the toggle.
    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        var monitors: [Any?] = []
        // Selection follows the cursor's angle, so every move has to be seen.
        // Both monitors are needed for the same reason Escape needs both, and
        // they run straight through rather than hopping onto a Task: this fires
        // at the mouse's sample rate, and a queued hop per sample would let the
        // highlight trail the cursor.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refreshPick() }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            MainActor.assumeIsolated { [weak self] in self?.refreshPick() }
            return event
        })
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window !== self.panel,
                  event.window !== self.presenterWindow
            else { return event }
            Task { @MainActor [weak self] in self?.dismiss() }
            return event
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            Task { @MainActor [weak self] in self?.dismiss() }
            return nil
        })
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        dismissMonitors = monitors.compactMap { $0 }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
    }
}

/// Panel that may hang off the screen edges. AppKit's default
/// `constrainFrameRect` silently pulls windows below the menu bar and back
/// onto the screen at the top/left — which detached the ring from its button
/// there while the bottom/right edges worked. The ring must stay centered on
/// the button even when part of it is off-screen.
private final class RadialMenuPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

