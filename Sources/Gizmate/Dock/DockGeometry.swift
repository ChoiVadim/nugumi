import AppKit

/// Where a dock's window goes, and when the pointer is close enough to open it.
///
/// Every function comes in two shapes: one taking plain rects, one taking an
/// `NSScreen`. The rect versions hold all the logic, because an `NSScreen`
/// cannot be constructed in a test and this is exactly the code that needs
/// pinning down — a notch is 200pt of screen that only exists on some Macs.
enum DockGeometry {
    /// The fake notch drawn on Macs without a camera housing. Roughly the size
    /// of a real one, so the top dock looks deliberate rather than arbitrary.
    static let virtualNotchWidth: CGFloat = 200
    /// How close to a side edge the pointer must come before that dock reveals.
    static let revealThickness: CGFloat = 4
    static let tabSize: CGFloat = 34
    static let tabSpacing: CGFloat = 6
    static let stripPadding: CGFloat = 6
    static let tabCornerRadius: CGFloat = 9
    static let panelCornerRadius: CGFloat = 18
    /// The concave flare where a dock meets the bezel.
    static let inverseCornerRadius: CGFloat = 12
    /// Gap between the notch's bottom edge and a strip hanging below it.
    static let topStripGap: CGFloat = 0

    // MARK: - Notch

    static func notchRect(
        screenFrame: NSRect,
        menuBarHeight: CGFloat,
        auxLeft: NSRect?,
        auxRight: NSRect?
    ) -> NSRect {
        let height = max(menuBarHeight, 1)
        if let auxLeft, let auxRight {
            let width = auxRight.minX - auxLeft.maxX
            // A non-positive gap means the two areas met or overlapped, which
            // is not a housing. Fall through to the virtual notch rather than
            // hand back an inverted rect that every later frame inherits.
            if width > 0 {
                return NSRect(
                    x: auxLeft.maxX,
                    y: screenFrame.maxY - height,
                    width: width,
                    height: height
                )
            }
        }
        return NSRect(
            x: screenFrame.midX - virtualNotchWidth / 2,
            y: screenFrame.maxY - height,
            width: virtualNotchWidth,
            height: height
        )
    }

    static func notchRect(on screen: NSScreen) -> NSRect {
        notchRect(
            screenFrame: screen.frame,
            menuBarHeight: menuBarHeight(of: screen),
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea
        )
    }

    /// `visibleFrame` excludes the menu bar, so the difference at the top is
    /// its height — and on a notched Mac that is the housing's height too.
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 1)
    }

    // MARK: - Reveal zones

    static func revealZone(
        for edge: DockEdge,
        screenFrame: NSRect,
        menuBarHeight: CGFloat,
        auxLeft: NSRect?,
        auxRight: NSRect?
    ) -> NSRect {
        switch edge {
        case .top:
            return notchRect(
                screenFrame: screenFrame,
                menuBarHeight: menuBarHeight,
                auxLeft: auxLeft,
                auxRight: auxRight
            )
        case .left, .right:
            // Middle half only. The corners belong to the menu bar, the Dock,
            // and every window's resize handle — a dock that opened there
            // would fire on the way to something else.
            let height = screenFrame.height / 2
            let y = screenFrame.midY - height / 2
            let x = edge == .left ? screenFrame.minX : screenFrame.maxX - revealThickness
            return NSRect(x: x, y: y, width: revealThickness, height: height)
        }
    }

    static func revealZone(_ edge: DockEdge, on screen: NSScreen) -> NSRect {
        revealZone(
            for: edge,
            screenFrame: screen.frame,
            menuBarHeight: menuBarHeight(of: screen),
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea
        )
    }

    // MARK: - Strip

    /// Length of a strip holding `tabCount` tabs, along its long axis. The ends
    /// clear `inverseCornerRadius` rather than `stripPadding`, because that is
    /// where the flare eats into the shape.
    static func stripLength(tabCount: Int) -> CGFloat {
        let count = CGFloat(max(tabCount, 1))
        return count * tabSize + (count - 1) * tabSpacing + inverseCornerRadius * 2
    }

    /// Thickness of a strip, across its short axis. Padded on one side only:
    /// the other faces the bezel, where the tab sits flush.
    static func stripBreadth() -> CGFloat {
        tabSize + stripPadding
    }

    // MARK: - Shape

    /// The outline of a dock's glass: rounded outward on the three free sides,
    /// curved *inward* where it meets the bezel, so the panel reads as growing
    /// out of the screen edge rather than being laid on top of it.
    ///
    /// Built once for a top-facing dock and rotated, because getting one piece
    /// of concave geometry right is cheaper than getting three right.
    static func panelPath(for edge: DockEdge, in bounds: CGRect) -> CGPath {
        switch edge {
        case .top:
            return flaredTopPath(width: bounds.width, height: bounds.height)
        case .left:
            // (x, y) → (width - y, x): a quarter turn that lands the flared
            // side on the left.
            var turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.width, ty: 0)
            let path = flaredTopPath(width: bounds.height, height: bounds.width)
            return path.copy(using: &turn) ?? path
        case .right:
            // (x, y) → (y, height - x): the other quarter turn.
            var turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: bounds.height)
            let path = flaredTopPath(width: bounds.height, height: bounds.width)
            return path.copy(using: &turn) ?? path
        }
    }

    /// A `w`×`h` box whose top edge runs the full width, whose sides pull in by
    /// `inverseCornerRadius` through a concave arc, and whose bottom corners are
    /// rounded the ordinary way.
    ///
    /// Layer coordinates, so y grows upward and `h` is the bezel side.
    private static func flaredTopPath(width w: CGFloat, height h: CGFloat) -> CGPath {
        // Clamped so a small strip degrades into a plausible shape instead of
        // an inside-out one.
        let r = min(inverseCornerRadius, w / 3, h / 3)
        let R = min(panelCornerRadius, (w - 2 * r) / 2, h / 2)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: r, y: R))
        path.addArc(
            tangent1End: CGPoint(x: r, y: 0),
            tangent2End: CGPoint(x: r + R, y: 0),
            radius: R
        )
        path.addLine(to: CGPoint(x: w - r - R, y: 0))
        path.addArc(
            tangent1End: CGPoint(x: w - r, y: 0),
            tangent2End: CGPoint(x: w - r, y: R),
            radius: R
        )
        path.addLine(to: CGPoint(x: w - r, y: h - r))
        // Concave: the arc's centre sits outside the body, at the corner the
        // curve is flaring into.
        path.addArc(
            center: CGPoint(x: w, y: h - r),
            radius: r,
            startAngle: .pi,
            endAngle: .pi / 2,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 0, y: h))
        path.addArc(
            center: CGPoint(x: 0, y: h - r),
            radius: r,
            startAngle: .pi / 2,
            endAngle: 0,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    /// How far a dock's content must stay clear of the bezel side, so it never
    /// lands under a flare.
    static func contentInsets(for edge: DockEdge) -> NSEdgeInsets {
        let r = inverseCornerRadius
        switch edge {
        case .top: return NSEdgeInsets(top: 0, left: r, bottom: 0, right: r)
        case .left, .right: return NSEdgeInsets(top: r, left: 0, bottom: r, right: 0)
        }
    }

    static func stripFrame(
        for edge: DockEdge,
        tabCount: Int,
        screenFrame: NSRect,
        menuBarHeight: CGFloat,
        auxLeft: NSRect?,
        auxRight: NSRect?
    ) -> NSRect {
        let length = stripLength(tabCount: tabCount)
        let breadth = stripBreadth()
        switch edge {
        case .top:
            let notch = notchRect(
                screenFrame: screenFrame,
                menuBarHeight: menuBarHeight,
                auxLeft: auxLeft,
                auxRight: auxRight
            )
            return NSRect(
                x: notch.midX - length / 2,
                y: notch.minY - breadth - topStripGap,
                width: length,
                height: breadth
            )
        case .left, .right:
            let x = edge == .left ? screenFrame.minX : screenFrame.maxX - breadth
            return NSRect(
                x: x,
                y: screenFrame.midY - length / 2,
                width: breadth,
                height: length
            )
        }
    }

    static func stripFrame(_ edge: DockEdge, tabCount: Int, on screen: NSScreen) -> NSRect {
        stripFrame(
            for: edge,
            tabCount: tabCount,
            screenFrame: screen.frame,
            menuBarHeight: menuBarHeight(of: screen),
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea
        )
    }

    // MARK: - Expanded

    static func expandedFrame(
        for edge: DockEdge,
        contentSize: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        menuBarHeight: CGFloat,
        auxLeft: NSRect?,
        auxRight: NSRect?
    ) -> NSRect {
        let width = min(contentSize.width, visibleFrame.width)
        let height = min(contentSize.height, visibleFrame.height)
        switch edge {
        case .top:
            let notch = notchRect(
                screenFrame: screenFrame,
                menuBarHeight: menuBarHeight,
                auxLeft: auxLeft,
                auxRight: auxRight
            )
            // Shares the notch's top edge so the panel reads as the notch
            // growing, not as a window appearing beneath it.
            var x = notch.midX - width / 2
            x = min(max(x, screenFrame.minX), screenFrame.maxX - width)
            return NSRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
        case .left, .right:
            let x = edge == .left ? screenFrame.minX : screenFrame.maxX - width
            var y = screenFrame.midY - height / 2
            y = min(max(y, visibleFrame.minY), visibleFrame.maxY - height)
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }

    static func expandedFrame(_ edge: DockEdge, contentSize: NSSize, on screen: NSScreen) -> NSRect {
        expandedFrame(
            for: edge,
            contentSize: contentSize,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            menuBarHeight: menuBarHeight(of: screen),
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea
        )
    }
}
