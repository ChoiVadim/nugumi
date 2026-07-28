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

/// Pure geometry for the radial menu: where the four buttons sit around the
/// anchor and how the ring shifts to stay on screen. Kept free of AppKit
/// state so it is unit-testable.
enum RadialMenuLayoutPolicy {
    static let ringRadius: CGFloat = 78
    static let buttonDiameter: CGFloat = 46
    /// Room around the ring for hover label bubbles AND the outermost
    /// hover-revealed orbit (`thirdRingRadius` + a button + margin).
    static let panelPadding: CGFloat = 160

    static var panelSide: CGFloat {
        (ringRadius + buttonDiameter / 2 + panelPadding) * 2
    }

    /// `count` evenly-spaced positions. 1–4 keep the original right/bottom arc
    /// order (reply top-right, explain right, ask bottom-right, rewrite bottom);
    /// extra items fill the free left arc counter-clockwise.
    static func buttonCenters(count: Int) -> [CGPoint] {
        let diagonal = ringRadius * sqrt(0.5)
        let base: [CGPoint] = [
            CGPoint(x: ringRadius, y: 0),            // right       (Explain)
            CGPoint(x: 0, y: -ringRadius),           // bottom      (Rewrite)
            CGPoint(x: diagonal, y: diagonal),       // top-right   (Reply)
            CGPoint(x: diagonal, y: -diagonal),      // bottom-right(Ask)
            CGPoint(x: -diagonal, y: -diagonal),     // bottom-left (5th: Capture)
            CGPoint(x: -ringRadius, y: 0),           // left        (6th: summarize)
            CGPoint(x: 0, y: ringRadius),            // top
            CGPoint(x: -diagonal, y: diagonal)       // top-left
        ]
        return Array(base.prefix(count))
    }

    /// Radius of the hover-revealed second orbit — a concentric ring well
    /// OUTSIDE the main one, clear of the inner buttons and their bubbles.
    static let outerRingRadius: CGFloat = 152

    /// Third orbit (sub-items of a second-layer item, e.g. the time ranges
    /// behind a picked messenger) — same ring-to-ring spacing again.
    static let thirdRingRadius: CGFloat = 226

    /// Offsets (from the panel center) for an outer-orbit cluster: buttons sit
    /// on a concentric ring of `radius`, occupying the arc that points outward
    /// from the parent (`parentOffset`), fanned symmetrically around it. Their
    /// center-to-center spacing matches the first ring's (buttons 45° apart at
    /// `ringRadius`) — so at larger radii the angular step is smaller. The
    /// inner rings are untouched; each cluster is a further orbit around the
    /// same center.
    static func subClusterCenters(
        parentOffset: CGPoint,
        count: Int,
        radius: CGFloat = outerRingRadius
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        let firstRingChord = 2 * Double(ringRadius) * sin((45.0 * .pi / 180) / 2)
        let stepAngle = 2 * asin(min(1, firstRingChord / (2 * Double(radius))))
        let parentAngle = atan2(Double(parentOffset.y), Double(parentOffset.x))
        let spreadStart = -Double(count - 1) / 2.0
        return (0..<count).map { i in
            let a = parentAngle + (spreadStart + Double(i)) * stepAngle
            return CGPoint(
                x: radius * CGFloat(cos(a)),
                y: radius * CGFloat(sin(a))
            )
        }
    }

    /// Which of the eight ring directions an offset points to — that
    /// button's hover bubble continues radially outward on the same side
    /// (Logi Options+ style), tail back toward the circle.
    static func labelPlacement(for offset: CGPoint) -> RadialMenuLabelPlacement {
        // Snap the offset's angle to the nearest 45° sector.
        let sector = Int((atan2(offset.y, offset.x) / .pi * 4).rounded())
        switch sector {
        case 0: return .right
        case 1: return .topRight
        case 2: return .top
        case 3: return .topLeft
        case -1: return .bottomRight
        case -2: return .bottom
        case -3: return .bottomLeft
        default: return .left
        }
    }

    // Wide enough that the hover scale-up (+16% of the disc, ~4pt of radius)
    // still leaves visible air between the disc and its label bubble.
    static let bubbleGap: CGFloat = 10

    /// Where a hover bubble's frame starts so it sits outside the ring on
    /// the button's side, tail toward the circle. For diagonals the bubble's
    /// near corner (where its tail lives) anchors just off the circle's
    /// edge along the same diagonal.
    static func bubbleOrigin(
        for placement: RadialMenuLabelPlacement,
        buttonFrame: NSRect,
        bubbleSize: NSSize
    ) -> NSPoint {
        let diagonalInset = (buttonFrame.width / 2 + bubbleGap) * sqrt(0.5)
        switch placement {
        case .top:
            return NSPoint(
                x: buttonFrame.midX - bubbleSize.width / 2,
                y: buttonFrame.maxY + bubbleGap
            )
        case .bottom:
            return NSPoint(
                x: buttonFrame.midX - bubbleSize.width / 2,
                y: buttonFrame.minY - bubbleGap - bubbleSize.height
            )
        case .left:
            return NSPoint(
                x: buttonFrame.minX - bubbleGap - bubbleSize.width,
                y: buttonFrame.midY - bubbleSize.height / 2
            )
        case .right:
            return NSPoint(
                x: buttonFrame.maxX + bubbleGap,
                y: buttonFrame.midY - bubbleSize.height / 2
            )
        case .topRight:
            return NSPoint(
                x: buttonFrame.midX + diagonalInset,
                y: buttonFrame.midY + diagonalInset
            )
        case .topLeft:
            return NSPoint(
                x: buttonFrame.midX - diagonalInset - bubbleSize.width,
                y: buttonFrame.midY + diagonalInset
            )
        case .bottomRight:
            return NSPoint(
                x: buttonFrame.midX + diagonalInset,
                y: buttonFrame.midY - diagonalInset - bubbleSize.height
            )
        case .bottomLeft:
            return NSPoint(
                x: buttonFrame.midX - diagonalInset - bubbleSize.width,
                y: buttonFrame.midY - diagonalInset - bubbleSize.height
            )
        }
    }

    /// Panel frame centered on `anchor` — always. Deliberately no screen-edge
    /// clamping: near an edge part of the ring may fall off-screen (Logi
    /// Options+ behaves the same), but the ring never detaches from the
    /// button, which read as worse than a clipped button.
    static func panelFrame(anchor: NSPoint) -> NSRect {
        NSRect(
            x: anchor.x - panelSide / 2,
            y: anchor.y - panelSide / 2,
            width: panelSide,
            height: panelSide
        )
    }
}

/// The ring of action buttons that opens around the floating bar / pet.
/// Purely presentational: owns one transparent panel, reports the picked
/// action via `onSelect`, and calls `onDismiss` when it closed itself
/// (outside click, Escape, empty-area click). The presenter owns the
/// toggle state and calls `close()` for its own teardown paths.
@MainActor
final class RadialActionMenuController {
    private let panel: NSPanel
    /// Hover over the ring's center (the bar/pet under the ✕). The presenter
    /// subscribes to drive its close-button hover tint — its own tracking
    /// area is occluded by this panel while the ring is open.
    var onCenterHoverChange: ((Bool) -> Void)?
    /// The bar/pet panel that opened the menu. Its clicks are exempt from
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
    /// Second-layer buttons for a hover-expandable item (the time-range orbit).
    /// Kept separate from `buttons` so the open/close ring animations ignore
    /// them — they show/hide only on hover.
    private var subButtons: [RadialMenuButtonView] = []
    /// The expandable (messenger) button that owns the second orbit, and the
    /// index of the sub-button highlighted by default (the middle one).
    private weak var expandableButton: RadialMenuButtonView?
    private var middleSubIndex = 0
    /// Which sub-button the cursor is currently over — overrides the default
    /// middle highlight while hovered.
    private var hoveredSubIndex: Int?
    private var subClusterVisible = false
    /// The expandable button's center (sub-buttons spring out from / collapse
    /// into it) and their final outer-ring frames. `isSubAnimating` ignores
    /// hover while the fly-out plays so the highlight doesn't jump to a button
    /// passing under the cursor.
    private var subOrigin: NSPoint = .zero
    private var subTargets: [NSRect] = []
    private var isSubAnimating = false
    /// Third orbit — sub-items of an expandable SECOND-layer button (e.g. a
    /// messenger in the app picker expanding into time ranges). Pre-built
    /// hidden at init, keyed by the sub button's index; only one open at a
    /// time (`expandedThirdIndex`).
    private var thirdButtons: [Int: [RadialMenuButtonView]] = [:]
    private var thirdTargets: [Int: [NSRect]] = [:]
    private var thirdOrigins: [Int: NSPoint] = [:]
    private var expandedThirdIndex: Int?
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
            // Hovering the center ✕ dismisses the open second orbit too.
            if hovered { self?.hideSubCluster() }
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
        for (slot, offset) in zip(slots, RadialMenuLayoutPolicy.buttonCenters(count: slots.count)) {
            guard let item = slot else { continue }
            let isExpandable = !item.subItems.isEmpty
            let button = RadialMenuButtonView(image: item.image) { [weak self] in
                // Expandable parents (the messenger button) reveal their
                // second layer instead of firing/closing — the first ring stays.
                if isExpandable { self?.showSubCluster() } else { self?.finish(with: item) }
            }
            button.setFrameOrigin(NSPoint(
                x: panelCenter.x + offset.x - button.frame.width / 2,
                y: panelCenter.y + offset.y - button.frame.height / 2
            ))
            container.addSubview(button)
            buttons.append(button)

            if isExpandable {
                // Hovering the messenger button opens the second orbit and keeps
                // it open (sticky) — it closes only when a DIFFERENT first-ring
                // button is hovered. The messenger and sub highlights are driven
                // by the controller, not each button's own hover tint.
                expandableButton = button
                button.suppressHoverTint = true
                middleSubIndex = item.subItems.count / 2
                subOrigin = NSPoint(x: panelCenter.x + offset.x, y: panelCenter.y + offset.y)
                let subOffsets = RadialMenuLayoutPolicy.subClusterCenters(
                    parentOffset: offset, count: item.subItems.count
                )
                for (index, pair) in zip(item.subItems, subOffsets).enumerated() {
                    let (sub, subOffset) = pair
                    let subButton = RadialMenuButtonView(image: sub.image) { [weak self] in
                        // An expandable sub (messenger with time ranges)
                        // reveals its third orbit on click; leaves fire.
                        if sub.subItems.isEmpty {
                            self?.finish(with: sub)
                        } else {
                            self?.showThirdCluster(index)
                        }
                    }
                    subButton.setFrameOrigin(NSPoint(
                        x: panelCenter.x + subOffset.x - subButton.frame.width / 2,
                        y: panelCenter.y + subOffset.y - subButton.frame.height / 2
                    ))
                    subTargets.append(subButton.frame)
                    subButton.isHidden = true
                    subButton.alphaValue = 0
                    subButton.suppressHoverTint = true
                    subButton.onHoverChange = { [weak self] hovered in
                        self?.subHoverChanged(index: index, hovered: hovered)
                    }
                    container.addSubview(subButton)
                    subButtons.append(subButton)

                    if !sub.subItems.isEmpty {
                        let thirdOffsets = RadialMenuLayoutPolicy.subClusterCenters(
                            parentOffset: subOffset,
                            count: sub.subItems.count,
                            radius: RadialMenuLayoutPolicy.thirdRingRadius
                        )
                        var thirds: [RadialMenuButtonView] = []
                        var targets: [NSRect] = []
                        for (subSub, thirdOffset) in zip(sub.subItems, thirdOffsets) {
                            let thirdButton = RadialMenuButtonView(image: subSub.image) { [weak self] in
                                self?.finish(with: subSub)
                            }
                            thirdButton.setFrameOrigin(NSPoint(
                                x: panelCenter.x + thirdOffset.x - thirdButton.frame.width / 2,
                                y: panelCenter.y + thirdOffset.y - thirdButton.frame.height / 2
                            ))
                            targets.append(thirdButton.frame)
                            thirdButton.isHidden = true
                            thirdButton.alphaValue = 0
                            container.addSubview(thirdButton)
                            thirds.append(thirdButton)
                        }
                        thirdButtons[index] = thirds
                        thirdTargets[index] = targets
                        thirdOrigins[index] = NSPoint(
                            x: panelCenter.x + subOffset.x,
                            y: panelCenter.y + subOffset.y
                        )
                    }
                }
                button.onHoverChange = { [weak self] hovered in
                    if hovered { self?.showSubCluster() }
                }
                continue
            }

            // An empty label means "highlight only, no callout" — the app
            // summarize button carries its identity in its app icon, so its
            // hover shows just the glass highlight (no "Telegram" bubble).
            guard !item.label.isEmpty else { continue }

            let placement = RadialMenuLayoutPolicy.labelPlacement(for: offset)
            let bubble = RadialMenuLabelBubbleView(
                text: item.label,
                tailEdge: placement.opposite
            )
            bubble.setFrameOrigin(RadialMenuLayoutPolicy.bubbleOrigin(
                for: placement,
                buttonFrame: button.frame,
                bubbleSize: bubble.frame.size
            ))
            bubble.alphaValue = 0
            container.addSubview(bubble)
            button.onHoverChange = { [weak self, weak bubble] hovered in
                // The collapse animation flies every button into the center —
                // right under the cursor when the ✕ was clicked — and each
                // pass fires a phantom mouseEntered. Dead ring, no bubbles.
                guard let self, !self.didClose else { return }
                // Hovering any other first-ring button dismisses the open
                // second orbit (the only thing that closes it besides picking).
                if hovered { self.hideSubCluster() }
                NSAnimationContext.runAnimationGroup { context in
                    // Ease the bubble in gently; hide fast so it never lags
                    // behind the cursor leaving the button.
                    context.duration = hovered ? 0.3 : 0.15
                    bubble?.animator().alphaValue = hovered ? 1 : 0
                }
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

    // MARK: - Hover-revealed second layer (sticky)

    /// Opens the second orbit and keeps it open. Hovering the messenger button
    /// calls this; it stays up until a DIFFERENT first-ring button is hovered,
    /// the ring is dismissed, or a time button is picked. The messenger button
    /// stays highlighted while it's open, and the middle sub-button is
    /// highlighted by default.
    private func showSubCluster() {
        guard !didClose else { return }
        expandableButton?.setHighlighted(true)
        if !subClusterVisible {
            subClusterVisible = true
            isSubAnimating = true
            // Stage the starting state (parked on the messenger button,
            // invisible) and let this CA transaction commit BEFORE animating:
            // animations scheduled in the same commit that unhides a layer are
            // skipped by Core Animation — the reveal used to pop in fully
            // settled while the collapse (already-visible layers) animated fine.
            for (sub, target) in zip(subButtons, subTargets) {
                sub.frame = NSRect(
                    x: subOrigin.x - target.width / 2,
                    y: subOrigin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                sub.isHidden = false
                sub.alphaValue = 0
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.subClusterVisible, !self.didClose else { return }
                for (sub, target) in zip(self.subButtons, self.subTargets) {
                    // Spring out from the messenger button to the outer slot —
                    // the same feel/timing as the first ring opening. Hover is
                    // ignored until it settles (isSubAnimating) so the highlight
                    // doesn't jump to a button passing under the cursor
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
        hoveredSubIndex = nil
        refreshSubHighlight()
        hideThirdCluster()
    }

    private func subHoverChanged(index: Int, hovered: Bool) {
        // Sticky: hovering a time button moves the highlight to it and it STAYS
        // there after the cursor leaves into empty space. Only re-hovering the
        // messenger button resets the default back to the middle (in
        // `showSubCluster`). Ignore hover while the fly-out animates.
        guard !isSubAnimating, hovered else { return }
        hoveredSubIndex = index
        refreshSubHighlight()
        // Expandable subs (messenger → ranges) open their third orbit on
        // hover; hovering a plain sub (browser) closes any open one.
        if thirdButtons[index] != nil {
            showThirdCluster(index)
        } else {
            hideThirdCluster()
        }
    }

    /// Reveals the third orbit for the expandable sub at `index`, collapsing
    /// any other open one. Same two-transaction reveal as `showSubCluster` —
    /// animations scheduled in the commit that unhides a layer are skipped.
    private func showThirdCluster(_ index: Int) {
        guard !didClose, expandedThirdIndex != index else { return }
        hideThirdCluster()
        guard let thirds = thirdButtons[index],
              let targets = thirdTargets[index],
              let origin = thirdOrigins[index]
        else { return }
        expandedThirdIndex = index
        for (third, target) in zip(thirds, targets) {
            third.frame = NSRect(
                x: origin.x - target.width / 2,
                y: origin.y - target.height / 2,
                width: target.width,
                height: target.height
            )
            third.isHidden = false
            third.alphaValue = 0
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expandedThirdIndex == index, !self.didClose else { return }
            for (third, target) in zip(thirds, targets) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
                    third.animator().frame = target
                    third.animator().alphaValue = 1
                }, completionHandler: { [weak third] in
                    third?.updateTrackingAreas()
                })
            }
        }
    }

    private func hideThirdCluster() {
        guard let index = expandedThirdIndex else { return }
        expandedThirdIndex = nil
        guard let thirds = thirdButtons[index],
              let targets = thirdTargets[index],
              let origin = thirdOrigins[index]
        else { return }
        for (third, target) in zip(thirds, targets) {
            NSAnimationContext.runAnimationGroup({ context in
                // Collapse back INTO the parent sub button, mirroring the
                // second orbit's close.
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                third.animator().frame = NSRect(
                    x: origin.x - target.width / 2,
                    y: origin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                third.animator().alphaValue = 0
            }, completionHandler: { [weak third] in
                third?.isHidden = true
                third?.frame = target   // reset for the next reveal
            })
        }
    }

    /// Highlights the hovered sub-button, or the middle one by default.
    private func refreshSubHighlight() {
        guard subClusterVisible else { return }
        let active = hoveredSubIndex ?? middleSubIndex
        for (i, sub) in subButtons.enumerated() {
            sub.setHighlighted(i == active)
        }
    }

    private func hideSubCluster() {
        hideThirdCluster()
        guard subClusterVisible else { return }
        subClusterVisible = false
        hoveredSubIndex = nil
        isSubAnimating = true
        expandableButton?.setHighlighted(false)
        for (sub, target) in zip(subButtons, subTargets) {
            sub.setHighlighted(false)
            NSAnimationContext.runAnimationGroup({ context in
                // Collapse back INTO the messenger button, mirroring the first
                // ring's close.
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                sub.animator().frame = NSRect(
                    x: subOrigin.x - target.width / 2,
                    y: subOrigin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                sub.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak sub] in
                sub?.isHidden = true
                sub?.frame = target   // reset for the next reveal
                self?.isSubAnimating = false
            })
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
    /// local monitor (Gizmo frontmost) and a global one (another app
    /// frontmost — observed, not consumed). Mouse clicks: the global monitor
    /// covers other apps, the local one covers Gizmo's own windows — except
    /// the menu itself and the presenting bar/pet, whose click handler owns
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

