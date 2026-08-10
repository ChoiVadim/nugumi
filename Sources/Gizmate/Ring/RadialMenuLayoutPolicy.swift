import AppKit
import Foundation

/// Pure geometry for the radial menu: where the four buttons sit around the
/// anchor and how the ring shifts to stay on screen. Kept free of AppKit
/// state so it is unit-testable.
enum RadialMenuLayoutPolicy {
    static let ringRadius: CGFloat = 78
    static let buttonDiameter: CGFloat = 46
    /// Room around the ring for the outermost hover-revealed orbit AND the
    /// label bubble that hangs off a button out there. Derived rather than
    /// typed in: the third orbit's bubbles are the far corner of the panel, so
    /// a wider bubble or a further orbit has to move the wall with it or it
    /// clips.
    static var panelPadding: CGFloat {
        thirdRingRadius - ringRadius + bubbleGap + bubbleMaxWidth + bubbleShadowRoom
    }

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

    /// `count` positions evenly spaced around a full circle of `radius`,
    /// starting where the main ring starts (slot 0 pointing right) and running
    /// counter-clockwise so the orbits share the ring's axes. Slot counts come
    /// from `RingLayout.capacity(atDepth:)`, which picks them so neighbours sit
    /// the same distance apart as they do in the main ring.
    static func orbitSlotCenters(radius: CGFloat, count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let step = 2 * Double.pi / Double(count)
        return (0..<count).map { index in
            let angle = Double(index) * step
            return CGPoint(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
        }
    }

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

    /// Which live button the cursor points at, from its offset to the panel
    /// center. `layers` lists the rings that can be picked right now, innermost
    /// first, each as its buttons' offsets — so it is one entry while only the
    /// ring is up, and grows as orbits open.
    ///
    /// The radius picks the layer and the ANGLE picks the button within it, so
    /// the cursor never has to land on a 46pt disc: pointing at one is enough,
    /// from anywhere in that layer's band. Nearest-by-angle rather than a fixed
    /// 45° sector, because a ring with empty slots would otherwise have
    /// directions that select nothing — the gap belongs to its closest
    /// neighbour instead.
    ///
    /// `nil` inside the center's dead zone (the ✕ lives there) and past the
    /// wall beyond the outermost live ring. Those are the only places left
    /// where a click still means "dismiss" rather than "run this".
    static func angularPick(cursor: CGPoint, layers: [[CGPoint]]) -> (layer: Int, index: Int)? {
        let radii = [ringRadius, outerRingRadius, thirdRingRadius]
        let last = min(layers.count, radii.count) - 1
        guard last >= 0 else { return nil }
        let distance = hypot(cursor.x, cursor.y)
        guard distance >= buttonDiameter / 2 else { return nil }
        // Half the ring-to-ring gap, reused as the outer wall so the band
        // around the outermost ring is as deep as the ones between rings.
        let slack = (outerRingRadius - ringRadius) / 2
        guard distance <= radii[last] + slack else { return nil }
        // Bands split at the midpoints between neighbouring live rings.
        let layer = (0..<last).first { distance < (radii[$0] + radii[$0 + 1]) / 2 } ?? last
        let centers = layers[layer]
        guard !centers.isEmpty else { return nil }
        let heading = atan2(Double(cursor.y), Double(cursor.x))
        guard let index = centers.indices.min(by: {
            angularGap(heading, centers[$0]) < angularGap(heading, centers[$1])
        }) else { return nil }
        return (layer, index)
    }

    /// Shortest angle between a heading and an offset's direction, 0...π.
    private static func angularGap(_ heading: Double, _ offset: CGPoint) -> Double {
        let gap = abs(heading - atan2(Double(offset.y), Double(offset.x)))
        return min(gap, 2 * .pi - gap)
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

    /// Widest a label bubble may draw; longer labels truncate. A bubble is
    /// what decides how far the panel has to reach past the outermost orbit,
    /// so letting one grow with its text would let a long tool name push the
    /// wall out — or, once the wall stops moving, clip against it.
    static let bubbleMaxWidth: CGFloat = 144
    /// The bubble's drop shadow draws outside its frame.
    static let bubbleShadowRoom: CGFloat = 6

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
