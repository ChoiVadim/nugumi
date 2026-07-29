import CoreGraphics
import Foundation

/// A slot the carried disc could land on, at its drawn position in the ring
/// diagram: relative to the hub, y running down the way SwiftUI's offsets do.
struct RingDragCandidate: Equatable {
    let address: RingSlotAddress
    let center: CGPoint
}

/// A ring button in flight between two slots.
struct RingDragState: Equatable {
    /// Where it was picked up — also where it snaps back to when the drop
    /// lands on nothing.
    let origin: RingSlotAddress
    /// Carried along so the disc keeps drawing itself while the store still
    /// has it in its old slot.
    let content: RingSlotContent
    /// How far it has been carried from its own slot, in diagram points.
    var translation: CGSize = .zero
    /// The slot under it right now. Nil over open space, which cancels.
    var target: RingSlotAddress?
}

enum RingDragTargeting {
    /// How far a press has to travel before it stops being a click and becomes
    /// a drag. Screen points, so it means the same thing however far the
    /// diagram has been scaled down to fit the window.
    static let clickSlop: CGFloat = 4

    /// How close the carried disc has to come to a slot, as a fraction of its
    /// own diameter, before that slot claims it. Nearest wins, so catch areas
    /// overlapping is harmless — this only sets how wide the open space
    /// between orbits is, where a drop snaps back instead.
    static let snapFraction: CGFloat = 0.75

    /// The slot the carried disc is over: the nearest candidate within reach,
    /// or nil when it is over open space.
    static func nearest(
        to point: CGPoint,
        among candidates: [RingDragCandidate],
        snap: CGFloat
    ) -> RingSlotAddress? {
        var best: (address: RingSlotAddress, distance: CGFloat)?
        for candidate in candidates {
            let distance = hypot(candidate.center.x - point.x, candidate.center.y - point.y)
            guard distance <= snap, distance < best?.distance ?? .greatestFiniteMagnitude else { continue }
            best = (candidate.address, distance)
        }
        return best?.address
    }
}
