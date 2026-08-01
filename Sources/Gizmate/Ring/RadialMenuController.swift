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
    private var buttons: [RadialMenuButtonView] = []
    /// A hover-revealed orbit: the buttons behind one expandable parent, built
    /// hidden at init and parked on that parent until revealed. Kept out of
    /// `buttons` so the ring's own open/close animations ignore them.
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
        /// Each button's hover callout, parallel to `buttons`. `nil` where the
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
    /// Which button of the open orbit the cursor is over — overrides the
    /// default middle highlight while hovered.
    private var hoveredSubIndex: Int?
    /// Ignores hover while a fly-out plays, so the highlight doesn't jump to a
    /// button passing under the cursor mid-flight.
    private var isSubAnimating = false
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
        container.onEmptyClick = { [weak self] in self?.dismiss() }
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
        let ringCenters = RadialMenuLayoutPolicy.buttonCenters(count: slots.count)
        for (slotIndex, pair) in zip(slots, ringCenters).enumerated() {
            let (slot, offset) = pair
            guard let item = slot else { continue }
            let isExpandable = item.expandsOnHover
            let button = RadialMenuButtonView(image: item.image) { [weak self] in
                // Expandable parents (a folder, or the messenger button) reveal
                // their orbit instead of firing/closing — the ring stays. Unless
                // the parent has a default of its own to run (`firesOnClick`),
                // in which case hovering is what opens the orbit.
                if isExpandable, !item.firesOnClick {
                    self?.showOrbit(slotIndex)
                } else {
                    self?.finish(with: item)
                }
            }
            button.setFrameOrigin(NSPoint(
                x: panelCenter.x + offset.x - button.frame.width / 2,
                y: panelCenter.y + offset.y - button.frame.height / 2
            ))
            container.addSubview(button)
            buttons.append(button)

            if isExpandable {
                // Hovering an expandable button opens its orbit and keeps it
                // open (sticky) — it closes only when a DIFFERENT first-ring
                // button is hovered. Parent and sub highlights are driven by the
                // controller, not each button's own hover tint.
                button.suppressHoverTint = true
                orbits[slotIndex] = buildOrbit(
                    for: item,
                    parent: button,
                    parentOffset: offset,
                    depth: 1,
                    panelCenter: panelCenter,
                    container: container
                )
                button.onHoverChange = { [weak self] hovered in
                    if hovered { self?.showOrbit(slotIndex) }
                }
                continue
            }

            // An empty label means "highlight only, no callout" — the app
            // summarize button carries its identity in its app icon, so its
            // hover shows just the glass highlight (no "Telegram" bubble).
            guard let bubble = makeBubble(
                for: item,
                at: offset,
                buttonFrame: button.frame,
                in: container
            ) else { continue }
            button.onHoverChange = { [weak self, weak bubble] hovered in
                // The collapse animation flies every button into the center —
                // right under the cursor when the ✕ was clicked — and each
                // pass fires a phantom mouseEntered. Dead ring, no bubbles.
                guard let self, !self.didClose else { return }
                // Hovering any other first-ring button dismisses the open
                // orbit (the only thing that closes it besides picking).
                if hovered { self.hideOrbit() }
                Self.fade(bubble, to: hovered)
            }
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
            let subButton = RadialMenuButtonView(image: sub.image) { [weak self] in
                // An expandable sub reveals its own orbit on click; leaves fire.
                // Same `firesOnClick` exception the first ring makes — Note is
                // usually inside the More folder, so this is the path its click
                // actually takes.
                if expands, !sub.firesOnClick {
                    self?.showChildOrbit(index)
                } else {
                    self?.finish(with: sub)
                }
            }
            subButton.setFrameOrigin(NSPoint(
                x: panelCenter.x + entry.offset.x - subButton.frame.width / 2,
                y: panelCenter.y + entry.offset.y - subButton.frame.height / 2
            ))
            orbit.targets.append(subButton.frame)
            subButton.isHidden = true
            subButton.alphaValue = 0
            subButton.suppressHoverTint = true
            subButton.onHoverChange = { [weak self] hovered in
                self?.subHoverChanged(index: index, depth: depth, hovered: hovered)
            }
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

    /// Opens the orbit behind first-ring slot `slotIndex` and keeps it open.
    /// It stays up until a DIFFERENT first-ring button is hovered, the ring is
    /// dismissed, or something in it is picked.
    private func showOrbit(_ slotIndex: Int) {
        guard !didClose, let orbit = orbits[slotIndex] else { return }
        if openOrbitSlot != slotIndex {
            // Only one orbit at a time: whatever was open collapses first.
            hideOrbit()
            openOrbitSlot = slotIndex
            reveal(orbit)
        }
        orbit.parent?.setHighlighted(true)
        hoveredSubIndex = nil
        refreshSubHighlight()
        hideChildOrbit()
    }

    /// `depth` says which orbit the hovered button belongs to — 1 is the ring
    /// outside the main one, 2 the ring outside that. It has to be carried in:
    /// without it every layer's hover was resolved against the second layer, so
    /// a third-layer button grew its second-layer neighbour at the same index
    /// and never grew itself.
    private func subHoverChanged(index: Int, depth: Int, hovered: Bool) {
        guard !isSubAnimating, !didClose else { return }
        guard depth == 1 else {
            childHoverChanged(index: index, hovered: hovered)
            return
        }
        guard let orbit = openOrbit else { return }
        Self.fade(orbit.bubbles[safe: index] ?? nil, to: hovered)
        // Sticky: hovering a sub moves the highlight to it and it STAYS there
        // after the cursor leaves into empty space. Only re-hovering the parent
        // resets the default back to the middle (in `showOrbit`).
        guard hovered else { return }
        hoveredSubIndex = index
        refreshSubHighlight()
        // An expandable sub opens its own orbit on hover; a plain one closes
        // whichever was open.
        if orbit.children[index] != nil {
            showChildOrbit(index)
        } else {
            hideChildOrbit()
        }
    }

    /// The third layer. Only one of its orbits is ever open, and its buttons
    /// are the outermost thing on screen, so there is nothing further to reveal
    /// — a hover here is just this button's own highlight and callout.
    private func childHoverChanged(index: Int, hovered: Bool) {
        guard let parentIndex = openChildIndex,
              let child = openOrbit?.children[parentIndex]
        else { return }
        Self.fade(child.bubbles[safe: index] ?? nil, to: hovered)
        guard hovered else { return }
        for (i, sub) in child.buttons.enumerated() {
            sub.setHighlighted(i == index)
        }
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
        collapse(child, restoringHighlight: false)
    }

    private func hideOrbit() {
        hideChildOrbit()
        guard let orbit = openOrbit else { return }
        openOrbitSlot = nil
        hoveredSubIndex = nil
        isSubAnimating = true
        collapse(orbit, restoringHighlight: true)
    }

    /// Springs the orbit out of its parent button — the same feel and timing as
    /// the ring itself opening.
    ///
    /// Staged over two CA transactions: an animation scheduled in the same
    /// commit that unhides a layer is skipped outright, which used to make the
    /// reveal pop in fully settled while the collapse animated fine.
    private func reveal(_ orbit: Orbit) {
        isSubAnimating = true
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
                // Hover is ignored until it settles (isSubAnimating) so the
                // highlight doesn't jump to a button passing under the cursor
                // mid-flight; tracking re-arms at the settled frame.
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
                    sub.animator().frame = target
                    sub.animator().alphaValue = 1
                }, completionHandler: { [weak self, weak sub] in
                    sub?.updateTrackingAreas()
                    self?.isSubAnimating = false
                })
            }
        }
    }

    /// Collapse back INTO the parent button, mirroring the ring's own close.
    private func collapse(_ orbit: Orbit, restoringHighlight: Bool) {
        if restoringHighlight { orbit.parent?.setHighlighted(false) }
        // The callouts go with the orbit. Letting one ride out the collapse
        // leaves a label naming a button that is no longer on screen.
        for bubble in orbit.bubbles { Self.fade(bubble, to: false) }
        for (sub, target) in zip(orbit.buttons, orbit.targets) {
            sub.setHighlighted(false)
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
            }, completionHandler: { [weak self, weak sub] in
                sub?.isHidden = true
                sub?.frame = target   // reset for the next reveal
                if restoringHighlight { self?.isSubAnimating = false }
            })
        }
    }

    /// Highlights whichever button of the open orbit the cursor is actually on,
    /// and none while it is still on the parent. Opening an orbit deliberately
    /// pre-selects nothing: the highlight is a size bump, and bumping a button
    /// the user never pointed at reads as the ring picking for them.
    private func refreshSubHighlight() {
        guard let orbit = openOrbit else { return }
        for (i, sub) in orbit.buttons.enumerated() {
            sub.setHighlighted(i == hoveredSubIndex)
        }
    }

    private func animateButtonsIn() {
        guard let container = panel.contentView else { return }
        for button in buttons {
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

