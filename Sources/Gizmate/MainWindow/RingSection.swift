import AppKit
import SwiftUI

struct RingSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        RingSectionContent(layoutStore: bridge.ringLayout, toolsStore: bridge.tools)
    }
}

/// Deliberately the ring and nothing else: no list, no scroll view. The diagram
/// shrinks to whatever room the window leaves it, so the whole ring is always on
/// screen at once. Tools are created, edited, and deleted from a slot's picker.
private struct RingSectionContent: View {
    @ObservedObject var layoutStore: RingLayoutStore
    @ObservedObject var toolsStore: ToolsStore
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                // The diagram sizes itself to whatever room is left — it knows
                // how far its orbits currently reach, which changes as folders
                // open, so the fitting has to happen inside it.
                RingDiagram(
                    layout: layoutStore.layout,
                    tools: toolsStore.tools,
                    folders: layoutStore.folders,
                    onPick: { bridge.ringSheet = .slot($0) },
                    onEditFolder: { bridge.ringSheet = .folderEditor(id: $0, assignTo: nil) },
                    onClear: { clear($0) },
                    canMove: { layoutStore.canMove(from: $0, to: $1) },
                    onMove: { layoutStore.move(from: $0, to: $1) }
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ring")
                    .font(FlowTheme.serif(30))
                    .foregroundStyle(FlowTheme.ink)
                Text("Click a slot to change it. Drag a button to move it.\n"
                    + "Rest it on a sub-ring to open that one.")
                    .font(.system(size: 14))
                    .foregroundStyle(FlowTheme.inkSecondary)
            }
            Spacer(minLength: 12)
            ResetDiscButton(accessibilityTitle: "Reset ring to defaults") { layoutStore.resetToDefault() }
                .padding(.top, 6)
        }
        .padding(.horizontal, 38)
        .padding(.top, 38)
        .padding(.bottom, 20)
    }

    /// Clearing a folder slot throws away the ring inside it, so it asks first.
    private func clear(_ address: RingSlotAddress) {
        let ring = layoutStore.ring(at: address.path) ?? layoutStore.layout
        if case .folder(let id) = ring.slots[safe: address.index] ?? .empty,
           let folder = layoutStore.folder(id) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove “\(folder.name)”?"
            alert.informativeText = "The sub-ring and everything arranged inside it goes away. "
                + "Your gizmos themselves are kept."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            layoutStore.removeFolder(id)
            return
        }
        layoutStore.clear(address.index, in: address.path)
    }
}

// MARK: - Diagram

/// The ring, drawn from the same geometry the live one uses
/// (`RadialMenuLayoutPolicy`) so the preview can't drift from reality: slot *i*
/// sits where button *i* sits, and each label bubble hangs off the side it
/// hangs off on screen.
struct RingDiagram: View {
    let layout: RingLayout
    let tools: [GizmateTool]
    let folders: [RingFolder]
    let onPick: (RingSlotAddress) -> Void
    let onEditFolder: (UUID) -> Void
    let onClear: (RingSlotAddress) -> Void
    /// Asked before a slot lights up as a drop target, so a drag can't offer a
    /// landing the store would refuse.
    let canMove: (RingSlotAddress, RingSlotAddress) -> Bool
    let onMove: (RingSlotAddress, RingSlotAddress) -> Void

    /// Folders whose orbit is currently fanned out, outermost last. Hovering a
    /// folder opens it and keeps it open — the same sticky behaviour the live
    /// ring has, so nothing collapses while you reach for a button in it.
    @State private var openFolders: [UUID] = []
    /// The disc being carried right now, if any.
    @State private var drag: RingDragState?
    /// Counts down to opening the folder the carried disc is resting on.
    @State private var springLoadTask: Task<Void, Never>?

    /// The live ring is drawn at 1.0; the diagram runs larger so the label
    /// bubbles have room to sit outside the circles.
    private static let scale: CGFloat = 1.4
    /// A bubble runs outward from its own button, so the left and right ones
    /// need a full bubble width of clearance while the top and bottom ones need
    /// only its height. Reserving the wider figure on all four sides is what
    /// used to leave the ring floating in empty space.
    private static let sideLabelRoom: CGFloat = RingSlotButton.bubbleMaxWidth
        + RadialMenuLayoutPolicy.bubbleGap
    private static let stackedLabelRoom: CGFloat = RingSlotButton.bubbleHeight
        + RadialMenuLayoutPolicy.bubbleGap
    /// Ceiling on how far the diagram is allowed to grow into a large window.
    /// Without it a maximised window turns the ring into a wall of dinner plates.
    private static let maxButtonDiameter: CGFloat = 72

    private var radius: CGFloat { RadialMenuLayoutPolicy.ringRadius * Self.scale }
    private var disc: CGFloat { RadialMenuLayoutPolicy.buttonDiameter * Self.scale }

    /// How far the outermost orbit this layout *can* open reaches — read from
    /// the folders that exist, NOT from what is expanded right now. Sizing on
    /// the open state instead made the whole diagram rescale under the cursor,
    /// so the ring itself appeared to move whenever a folder was hovered.
    /// This way it only changes when a folder is added or removed.
    private var outermostRadius: CGFloat {
        switch reachableDepth(in: layout, at: 0) {
        case 0: return RadialMenuLayoutPolicy.ringRadius
        case 1: return RadialMenuLayoutPolicy.outerRingRadius
        default: return RadialMenuLayoutPolicy.thirdRingRadius
        }
    }

    /// The deepest orbit reachable from `ring`, where 0 means "no folders".
    private func reachableDepth(in ring: RingLayout, at level: Int) -> Int {
        guard level < RingFolderDepth.maxNesting else { return level }
        var deepest = level
        for slot in ring.slots {
            guard case .folder(let id) = slot,
                  let folder = folders.first(where: { $0.id == id })
            else { continue }
            deepest = max(deepest, reachableDepth(in: folder.layout, at: level + 1))
        }
        return deepest
    }

    private var naturalSize: CGSize {
        let reach = outermostRadius * Self.scale + disc / 2
        return CGSize(
            width: (reach + Self.sideLabelRoom) * 2,
            height: (reach + Self.stackedLabelRoom) * 2
        )
    }

    var body: some View {
        GeometryReader { geo in
            let natural = naturalSize
            let fit = min(
                geo.size.width / natural.width,
                geo.size.height / natural.height,
                Self.maxButtonDiameter / disc
            )
            diagram(fit: fit)
                // Deliberately NOT animated: the diagram resizes to make room
                // for the orbit the instant it opens. Animating the resize as
                // well means the buttons fade in while everything is still
                // scaling, which reads as them sliding in from a corner.
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(fit)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// `fit` is how far the whole diagram has been scaled down to sit in the
    /// window — a drag reports screen points, which have to be divided by it to
    /// mean anything in here.
    private func diagram(fit: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(FlowTheme.hairline, lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)

            hub

            if let drag { vacatedSlot(drag) }

            ForEach(placedSlots) { placed in
                let carried = drag?.origin == placed.address
                slotButton(placed, fit: fit)
                    // Geometry is computed in AppKit space (y up); flip for SwiftUI.
                    .offset(
                        x: drawn(placed.center).x + (carried ? drag?.translation.width ?? 0 : 0),
                        y: drawn(placed.center).y + (carried ? drag?.translation.height ?? 0 : 0)
                    )
                    // Outer orbits sit above the ring they fan out of, so their
                    // label bubbles aren't painted over by it. A carried disc
                    // rides above every orbit, including ones it is crossing.
                    .zIndex(carried ? 100 : Double(placed.address.path.count))
                    .transition(entrance(for: placed))
            }
        }
        // Scoped to the buttons, so the diagram itself never animates: the ring
        // must stay put while an orbit springs out of one of its folders.
        // Curve and duration match the live ring's own reveal.
        .animation(.timingCurve(0.34, 1.45, 0.5, 1, duration: 0.22), value: openFolders)
        .onChange(of: drag?.target) { _, target in springLoad(target) }
    }

    /// Geometry is computed in AppKit space (y up); SwiftUI offsets run y down.
    private func drawn(_ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x * Self.scale, y: -center.y * Self.scale)
    }

    /// The slot a carried disc came out of, held open as an outline so the ring
    /// doesn't read as having lost a button mid-drag.
    @ViewBuilder
    private func vacatedSlot(_ drag: RingDragState) -> some View {
        if let home = placedSlots.first(where: { $0.address == drag.origin })?.center {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(FlowTheme.hairline)
                .frame(width: disc, height: disc)
                .offset(x: drawn(home).x, y: drawn(home).y)
        }
    }

    /// Springs out of the folder button and collapses back into it — the same
    /// entrance `RadialActionMenuController` gives the real ring's orbits.
    private func entrance(for placed: PlacedSlot) -> AnyTransition {
        guard let parent = placed.parentCenter else { return .opacity }
        let delta = CGSize(
            width: (parent.x - placed.center.x) * Self.scale,
            height: -(parent.y - placed.center.y) * Self.scale
        )
        return .modifier(
            active: OrbitEntrance(delta: delta, parked: true),
            identity: OrbitEntrance(delta: delta, parked: false)
        )
    }

    // MARK: - Placement

    /// One entry per drawn button: the root ring, plus the fanned contents of
    /// every open folder. Built in one pass so each orbit can be positioned
    /// from the button that opens it.
    private var placedSlots: [PlacedSlot] {
        var result: [PlacedSlot] = []
        var ring = layout
        var centers = RadialMenuLayoutPolicy.buttonCenters(count: RingLayout.slotCount)
        var path: [UUID] = []
        append(ring: ring, path: path, centers: centers, into: &result)

        for (depth, id) in openFolders.enumerated() {
            guard let slotIndex = ring.slots.firstIndex(of: .folder(id)),
                  let folder = folders.first(where: { $0.id == id }),
                  // The folder button this orbit springs out of.
                  let parentCenter = centers[safe: slotIndex]
            else { break }
            path.append(id)
            // A full concentric circle, same geometry as the live ring: further
            // out means more positions at the same spacing, and slot *i* stays
            // put whether or not its neighbours are filled.
            centers = RadialMenuLayoutPolicy.orbitSlotCenters(
                radius: depth == 0
                    ? RadialMenuLayoutPolicy.outerRingRadius
                    : RadialMenuLayoutPolicy.thirdRingRadius,
                count: RingLayout.capacity(atDepth: path.count)
            )
            ring = folder.layout
            append(ring: ring, path: path, centers: centers, springingFrom: parentCenter, into: &result)
        }
        return result
    }

    private func append(
        ring: RingLayout,
        path: [UUID],
        centers: [CGPoint],
        springingFrom parentCenter: CGPoint? = nil,
        into result: inout [PlacedSlot]
    ) {
        for (index, center) in centers.enumerated() {
            result.append(
                PlacedSlot(
                    address: RingSlotAddress(path: path, index: index),
                    content: ring.content(at: index),
                    center: center,
                    parentCenter: parentCenter
                )
            )
        }
    }

    private struct PlacedSlot: Identifiable {
        let address: RingSlotAddress
        let content: RingSlotContent
        let center: CGPoint
        /// Centre of the folder button this slot's ring belongs to — where it
        /// springs out of on reveal. `nil` for the main ring, which is always
        /// on screen and never animates in.
        let parentCenter: CGPoint?

        var id: String { address.path.map(\.uuidString).joined() + "-\(address.index)" }
    }

    // MARK: - Buttons

    private func slotButton(_ placed: PlacedSlot, fit: CGFloat) -> some View {
        RingSlotButton(
            content: placed.content,
            tools: tools,
            folders: folders,
            diameter: disc,
            placement: RadialMenuLayoutPolicy.labelPlacement(for: placed.center),
            // Two rings of bubbles at once overlap into noise. Only the
            // innermost ring that is still the deepest one — or the orbit you
            // just opened — gets to name its buttons.
            showsLabel: placed.address.path.count == openFolders.count,
            // A folder's disc renames it — its contents are edited in the orbit
            // that hovering already opened, so the picker would have nothing to
            // offer here.
            action: {
                if let id = folderID(placed) {
                    onEditFolder(id)
                } else {
                    onPick(placed.address)
                }
            },
            clearAction: { onClear(placed.address) },
            onHover: { hovering in
                // Frozen while a disc is in flight: reaching across the ring
                // would otherwise collapse the very orbit being aimed at.
                guard drag == nil, hovering else { return }
                expose(placed)
            },
            // An empty slot has nothing to pick up — it stays a click target.
            onDragChanged: placed.content == .empty ? nil : { translation in
                carry(placed, translation: translation, fit: fit)
            },
            onDragEnded: { drop() },
            isDragging: drag?.origin == placed.address,
            isDropTarget: drag?.target == placed.address
        )
    }

    /// Stand-in for the live ring's center: the bar with the ✕ over it.
    /// Reaching it collapses every open orbit, exactly as it does in the ring.
    private var hub: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.inkTertiary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.white.opacity(0.07)))
            .onHover { if $0, drag == nil { openFolders = [] } }
    }

    // MARK: - Dragging

    /// The press on `placed` has travelled: pick the disc up if it isn't up
    /// already, then re-aim it. `translation` arrives in screen points, so the
    /// window's fit-to-size scaling has to come back out of it first.
    private func carry(_ placed: PlacedSlot, translation: CGSize, fit: CGFloat) {
        var state: RingDragState
        if let current = drag, current.origin == placed.address {
            state = current
        } else {
            state = RingDragState(origin: placed.address, content: placed.content)
        }
        state.translation = CGSize(width: translation.width / fit, height: translation.height / fit)
        state.target = target(under: state)
        drag = state
    }

    /// The slot under the carried disc: the nearest one it could actually land
    /// in, or nil out in the open space between orbits.
    private func target(under state: RingDragState) -> RingSlotAddress? {
        let slots = placedSlots
        guard let home = slots.first(where: { $0.address == state.origin })?.center else { return nil }
        let point = CGPoint(
            x: drawn(home).x + state.translation.width,
            y: drawn(home).y + state.translation.height
        )
        return RingDragTargeting.nearest(
            to: point,
            among: slots
                .filter { canMove(state.origin, $0.address) }
                .map { RingDragCandidate(address: $0.address, center: drawn($0.center)) },
            snap: disc * RingDragTargeting.snapFraction
        )
    }

    /// Let go: the disc lands in whatever slot it was over. Over open space it
    /// travels back to where it came from rather than blinking home.
    private func drop() {
        springLoadTask?.cancel()
        springLoadTask = nil
        guard let state = drag else { return }
        guard let target = state.target else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { drag = nil }
            return
        }
        onMove(state.origin, target)
        drag = nil
    }

    /// Resting the carried disc on a sub-ring opens it, so a button can be put
    /// inside one that wasn't already fanned out. The delay is what keeps a disc
    /// merely passing over a sub-ring from opening it.
    private func springLoad(_ target: RingSlotAddress?) {
        springLoadTask?.cancel()
        springLoadTask = nil
        guard drag != nil,
              let target,
              let placed = placedSlots.first(where: { $0.address == target }),
              let id = folderID(placed),
              openFolders.last != id,
              RingFolderDepth.allowsFolder(at: placed.address.path)
        else { return }
        springLoadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, drag?.target == target else { return }
            expose(placed)
        }
    }

    // MARK: - Hover

    private func folderID(_ placed: PlacedSlot) -> UUID? {
        guard case .folder(let id) = placed.content,
              folders.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    /// Hovering a button decides what stays open: a folder opens its own orbit,
    /// anything else closes whatever was open *below* the ring it lives in.
    private func expose(_ placed: PlacedSlot) {
        let depth = placed.address.path.count
        let kept = Array(openFolders.prefix(depth))
        // A folder in the outermost ring has no orbit left to open — the live
        // ring stops at three, and the diagram must not promise a fourth.
        guard let id = folderID(placed), RingFolderDepth.allowsFolder(at: placed.address.path) else {
            openFolders = kept
            return
        }
        openFolders = kept + [id]
    }
}

/// Parks an orbit button on the folder it belongs to, invisible. Interpolating
/// between the parked and settled states is the fly-out.
private struct OrbitEntrance: ViewModifier {
    let delta: CGSize
    let parked: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: parked ? delta.width : 0, y: parked ? delta.height : 0)
            .opacity(parked ? 0 : 1)
    }
}

/// Small status pill used by the Ring tab (in ring / unfinished / assigned).
struct RingTag: View {
    let text: String
    var accent: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent ? FlowTheme.accent : FlowTheme.inkTertiary)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                Capsule().fill(accent ? FlowTheme.accentSoft : Color.white.opacity(0.07))
            )
    }
}
