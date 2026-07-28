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

@MainActor
final class PetMascotView: NSView {
    enum State: Equatable {
        case idle
        case run
        case ready
        case thinking
        case talking
        case flying
    }

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragRequested: ((NSPoint) -> Void)?
    var allowsClickWhenNotReady = false

    private var state: State = .idle
    private var mode: TranslationMode = .selection
    private var emotion: AskGizmateEmotion = .neutral
    private var animationFrame = 0
    /// Writing register dressed onto the character: formal = top hat + mustache,
    /// casual = cap, polite = bare (no accessory).
    private var writingStyle: WritingStyle = .polite

    func setWritingStyle(_ style: WritingStyle) {
        guard writingStyle != style else { return }
        writingStyle = style
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Gizmate"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click always wins over single-click handling and short-
        // circuits drag detection — this is how Ask gets dismissed now.
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
            return
        }

        // With a drag handler installed, peek the first follow-up event to
        // decide: a movement before mouseUp means the user wants to drag,
        // an immediate mouseUp means it was a plain click.
        if let onDragRequested {
            let startLocation = NSEvent.mouseLocation
            while true {
                let next = NSApp.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else { return }
                if next.type == .leftMouseUp {
                    if state == .ready || allowsClickWhenNotReady {
                        onClick?()
                    }
                    return
                }
                // First .leftMouseDragged — hand off to the drag handler
                // using the location captured at mouseDown.
                NSCursor.closedHand.push()
                onDragRequested(startLocation)
                NSCursor.pop()
                return
            }
        }

        guard state == .ready || allowsClickWhenNotReady else { return }
        onClick?()
    }

    func apply(state: State, mode: TranslationMode, emotion: AskGizmateEmotion = .neutral) {
        let didChange = self.state != state || self.mode != mode || self.emotion != emotion
        self.state = state
        self.mode = mode
        self.emotion = emotion
        toolTip = tooltip(for: state, mode: mode)
        if didChange {
            needsDisplay = true
        }
    }

    func advanceAnimationFrame() {
        animationFrame = (animationFrame + 1) % 240
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let rows = spriteRows()
        let cellSize: CGFloat = 2
        let maxColumns = rows.map(\.count).max() ?? 0
        let spriteSize = NSSize(width: CGFloat(maxColumns) * cellSize, height: CGFloat(rows.count) * cellSize)
        let spriteYOffset = spriteYOffset()
        let origin = NSPoint(
            x: floor((bounds.width - spriteSize.width) / 2),
            y: floor((bounds.height - spriteSize.height) / 2) + 1 + spriteYOffset
        )

        let accessory = styleAccessoryCells(rowCount: rows.count, faceOffset: currentFaceOffset())

        // Combined silhouette of body + accessory, used to stamp a thin dark rim
        // so the pale character stays legible on light backgrounds.
        var occupied = Set<MascotCell>()
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where color(for: pixel) != nil {
                occupied.insert(MascotCell(col: columnIndex, row: rowIndex))
            }
        }
        for cell in accessory.behind + accessory.front {
            occupied.insert(MascotCell(col: cell.col, row: cell.row))
        }

        drawPixelShadow(origin: origin)
        drawSpriteOutline(occupied, origin: origin, cellSize: cellSize, rowCount: rows.count)
        // z-order, back to front: tail, cap crown, body (ears), visor.
        drawPixelTail(origin: origin, cellSize: cellSize)
        drawAccessoryCells(accessory.behind, origin: origin, cellSize: cellSize, rowCount: rows.count)
        drawPixelRows(rows, origin: origin, cellSize: cellSize)
        drawAccessoryCells(accessory.front, origin: origin, cellSize: cellSize, rowCount: rows.count)
        if state == .ready {
            drawPixelActionBadge()
        }
        if state == .thinking {
            drawThinkingBadge()
        }
    }

    private struct MascotCell: Hashable { let col: Int; let row: Int }

    private func mascotCellRect(col: Int, row: Int, origin: NSPoint, cellSize: CGFloat, rowCount: Int) -> NSRect {
        NSRect(
            x: origin.x + CGFloat(col) * cellSize,
            y: origin.y + CGFloat(rowCount - row - 1) * cellSize,
            width: cellSize,
            height: cellSize
        )
    }

    /// One soft cell in every empty 4-neighbor of the silhouette → a 1-cell rim.
    /// A muted, semi-transparent slate (not hard black) so it reads as a gentle
    /// edge on light backgrounds without looking like a heavy outline.
    private func drawSpriteOutline(_ occupied: Set<MascotCell>, origin: NSPoint, cellSize: CGFloat, rowCount: Int) {
        NSColor(srgbRed: 0.40, green: 0.43, blue: 0.49, alpha: 0.6).setFill()
        for cell in occupied {
            let neighbors = [
                MascotCell(col: cell.col - 1, row: cell.row),
                MascotCell(col: cell.col + 1, row: cell.row),
                MascotCell(col: cell.col, row: cell.row - 1),
                MascotCell(col: cell.col, row: cell.row + 1),
            ]
            for n in neighbors where !occupied.contains(n) {
                NSBezierPath(rect: mascotCellRect(col: n.col, row: n.row, origin: origin, cellSize: cellSize, rowCount: rowCount)).fill()
            }
        }
    }

    /// Pixel cells for the current register's accessory, split by z-order.
    /// `behind` paints under the body sprite (so the ears stay in front of the
    /// cap's crown), `front` paints over it. `row` is measured from the sprite
    /// top (row 0); negative rows sit just above the head.
    private func styleAccessoryCells(
        rowCount: Int,
        faceOffset: Int
    ) -> (behind: [(col: Int, row: Int, color: NSColor)], front: [(col: Int, row: Int, color: NSColor)]) {
        switch writingStyle {
        case .polite:
            return ([], [])
        case .formal:
            let hat = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1)
            let band = NSColor(srgbRed: 0.55, green: 0.16, blue: 0.20, alpha: 1)
            var cells: [(col: Int, row: Int, color: NSColor)] = []
            // Top hat: wide brim, red hatband, narrow crown above. The hat is
            // fixed to the head; only the mustache tracks the face's idle drift.
            // The brim overlaps the head's top row so the hat sits flush — one
            // row higher leaves a 1px gap of background between hat and head.
            for c in 4...11 { cells.append((c, 2, hat)) }      // brim
            for c in 5...10 { cells.append((c, 1, band)) }     // hatband
            for c in 5...10 { cells.append((c, 0, hat)) }      // crown
            for c in 5...10 { cells.append((c, -1, hat)) }     // crown top
            // Tidy mustache centered under the nose, shifted with the face.
            for c in [5, 6, 8, 9] { cells.append((c + faceOffset, 8, hat)) }
            return ([], cells)
        case .casual:
            let cap = NSColor(srgbRed: 0.20, green: 0.52, blue: 0.50, alpha: 1)
            let capDark = NSColor(srgbRed: 0.13, green: 0.40, blue: 0.39, alpha: 1)
            // Baseball cap: rounded crown sitting up-right, a flat visor
            // jutting left. The crown goes BEHIND the body so the ears poke
            // out in front of it; the visor stays on top, sticking out over
            // the left ear.
            var crown: [(col: Int, row: Int, color: NSColor)] = []
            for c in 6...10 { crown.append((c, 0, cap)) }      // crown top
            for c in 5...11 { crown.append((c, 1, cap)) }      // crown
            for c in 5...12 { crown.append((c, 2, cap)) }      // crown base (right side)
            // Two-row visor angled down-left: light top surface continuous
            // with the crown, dark underside shifted one cell out — reads as
            // a proper peak instead of a dark blob.
            var visor: [(col: Int, row: Int, color: NSColor)] = []
            for c in 1...4 { visor.append((c, 2, cap)) }       // top surface
            for c in 0...3 { visor.append((c, 3, capDark)) }   // underside / tip
            return (crown, visor)
        }
    }

    private func drawAccessoryCells(_ cells: [(col: Int, row: Int, color: NSColor)], origin: NSPoint, cellSize: CGFloat, rowCount: Int) {
        for cell in cells {
            cell.color.setFill()
            NSBezierPath(rect: mascotCellRect(col: cell.col, row: cell.row, origin: origin, cellSize: cellSize, rowCount: rowCount)).fill()
        }
    }

    private func spriteYOffset() -> CGFloat {
        switch state {
        case .idle:
            return animationFrame % 90 >= 72 ? 0.5 : 0
        case .run:
            return (animationFrame / 4) % 2 == 0 ? 1 : 0
        case .ready:
            return animationFrame % 64 < 8 ? 0.75 : 0
        case .thinking:
            let phase = animationFrame % 32
            if phase < 8 { return 0 }
            if phase < 16 { return 0.5 }
            if phase < 24 { return 1 }
            return 0.5
        case .talking:
            // Body holds still — only the mouth (sprite swap) and tail
            // (drawPixelTail) animate while answering.
            return 0
        case .flying:
            // Rapid wobble — sells the "thrown" feeling. Two pixels of
            // amplitude, ~3-frame period (~100ms at 30fps).
            return CGFloat((animationFrame / 3) % 3) - 1
        }
    }

    private func idleFaceOffset() -> Int {
        switch (animationFrame / 32) % 4 {
        case 1:
            return -1
        case 3:
            return 1
        default:
            return 0
        }
    }

    /// Horizontal drift of the face this frame — the mustache rides along so it
    /// stays under the nose. Only the neutral idle animation shifts the face.
    private func currentFaceOffset() -> Int {
        state == .idle && emotion == .neutral ? idleFaceOffset() : 0
    }

    private func spriteRows() -> [String] {
        switch state {
        case .idle:
            if emotion != .neutral {
                return emotionSpriteRows(emotion)
            }
            return spriteRows(faceOffset: idleFaceOffset(), noseWidth: 1)
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "...WW......WWW..",
                    "................"
                ]
            } else {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "..WWW......WW...",
                    "................"
                ]
            }
        case .ready:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .thinking:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .talking:
            // Eyes, nose, ears, body — frozen. Identical to a calm idle pose
            // (faceOffset=0, neutral). Only the mouth (this row swap) and the
            // tail (drawPixelTail) move while the answer is shown.
            let mouthOpen = (animationFrame / 10) % 2 == 1
            return mouthOpen ? talkingSpriteRows() : spriteRows(faceOffset: 0, noseWidth: 1)
        case .flying:
            return flyingSpriteRows()
        }
    }

    private func flyingSpriteRows() -> [String] {
        // Shocked-in-flight expression: wide 3-pixel eyes, plain nose, no
        // mouth. The bigger eyes carry the "thrown!" feeling on their own.
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            "WWWKKKWWWWKKKWWW",
            "WWWKKKWWWWKKKWWW",
            "GWWWWWWPWWWWWWWG",
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func talkingSpriteRows() -> [String] {
        // Neutral centered head with a single-pixel mouth at row 8, col 9 —
        // diagonally below-right of the nose (col 7), with col 8 as a 1-pixel
        // horizontal gap. Reads as a small mouth, not a nose drip.
        var rows = spriteRows(faceOffset: 0, noseWidth: 1)
        var chars = Array(rows[8])
        if chars.count > 9 {
            chars[9] = "K"
            rows[8] = String(chars)
        }
        return rows
    }

    private func emotionSpriteRows(_ emotion: AskGizmateEmotion) -> [String] {
        switch emotion {
        case .neutral:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .happy:
            return spriteRows(
                eyeRow: "WWWKWWWWWWKWWWWW",
                noseRow: "GWWWWWPPWWWWWWWG"
            )
        case .surprised:
            return spriteRows(
                eyeRow: "WWWWKKWWWWKKWWWW",
                noseRow: "GWWWWWKKWWWWWWWG"
            )
        case .confused:
            return spriteRows(
                eyeRow: "WWWKKWWWWWKWWWWW",
                noseRow: "GWWWWWWPWWWWWWWG"
            )
        case .concerned:
            return spriteRows(
                eyeRow: "WWWWKWWWWWWKWWWW",
                noseRow: "GWWWWKKWWWWWWWWG"
            )
        }
    }

    private func spriteRows(eyeRow: String, noseRow: String) -> [String] {
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            eyeRow,
            eyeRow,
            noseRow,
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func spriteRows(faceOffset: Int, noseWidth: Int) -> [String] {
        let eyeRow: String
        let noseRow: String
        switch faceOffset {
        case ..<0:
            eyeRow = "WWWKKWWWWKKWWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWPWWWWWWWWG" : "GWWWWWPPWWWWWWWG"
        case 1...:
            eyeRow = "WWWWWKKWWWWKKWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWWPWWWWWWG" : "GWWWWWWPPWWWWWWG"
        default:
            eyeRow = "WWWWKKWWWWKKWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWPWWWWWWWG" : "GWWWWWPPWWWWWWG."
        }

        return spriteRows(eyeRow: eyeRow, noseRow: noseRow)
    }

    private func drawPixelRows(_ rows: [String], origin: NSPoint, cellSize: CGFloat) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() {
                guard let color = color(for: pixel) else { continue }
                color.setFill()
                let rect = NSRect(
                    x: origin.x + CGFloat(columnIndex) * cellSize,
                    y: origin.y + CGFloat(rows.count - rowIndex - 1) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    private func drawPixelTail(origin: NSPoint, cellSize: CGFloat) {
        let cells: [(Int, Int)]
        switch state {
        case .idle:
            switch (animationFrame / 24) % 3 {
            case 0:
                cells = [(7, 9), (7, 10), (8, 11), (9, 12), (10, 12)]
            case 1:
                cells = [(7, 9), (8, 10), (8, 11), (8, 12), (9, 12)]
            default:
                cells = [(7, 9), (8, 10), (7, 11), (6, 12), (5, 12)]
            }
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                cells = [(7, 9), (7, 10), (8, 11), (10, 12), (11, 12)]
            } else {
                cells = [(8, 9), (8, 10), (7, 11), (5, 12), (4, 12)]
            }
        case .ready, .thinking, .talking:
            switch (animationFrame / 16) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (8, 11), (9, 12), (10, 12)]
            default:
                cells = [(7, 9), (7, 10), (8, 11), (8, 12), (9, 12)]
            }
        case .flying:
            // Tail flails fast — switches every 3 frames (~100ms) between
            // hard-left and hard-right wags.
            switch (animationFrame / 3) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (9, 11), (10, 12), (11, 12)]
            default:
                cells = [(7, 9), (6, 10), (5, 11), (4, 12), (3, 12)]
            }
        }

        let tailColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.90, alpha: 1.0)
        let tailShade = NSColor(srgbRed: 0.68, green: 0.72, blue: 0.73, alpha: 1.0)
        for (index, cell) in cells.enumerated() {
            (index == cells.count - 1 ? tailShade : tailColor).setFill()
            let rect = NSRect(
                x: origin.x + CGFloat(cell.0) * cellSize,
                y: origin.y + CGFloat(cell.1) * cellSize,
                width: cellSize,
                height: cellSize
            )
            NSBezierPath(rect: rect).fill()
        }
    }

    private func drawPixelShadow(origin: NSPoint) {
        NSColor(calibratedWhite: 0.0, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: origin.x + 4, y: origin.y - 1, width: 22, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: origin.x + 8, y: origin.y - 3, width: 14, height: 2)).fill()
    }

    private func drawPixelActionBadge() {
        switch mode {
        case .selection, .revise, .reviseMessage, .summarizeChat, .summarizePage, .custom:
            drawTranslateBadge()
        case .draftMessage:
            drawRewriteBadge()
        case .smartReply:
            drawReplyBadge()
        }
    }

    private func badgeOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        NSPoint(x: bounds.width - width, y: bounds.height - height)
    }

    private func drawTranslateBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 19, height: 14), size: NSSize(width: 19, height: 14))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let borderColor = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        borderColor.setFill()
        shape.fill()

        let inner = frame.insetBy(dx: 1.5, dy: 1.5)
        let leftRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.52, height: inner.height)
        let rightRect = NSRect(x: leftRect.maxX, y: inner.minY, width: inner.maxX - leftRect.maxX, height: inner.height)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(srgbRed: 0.02, green: 0.55, blue: 0.76, alpha: 1.0).setFill()
        NSBezierPath(rect: leftRect).fill()
        NSColor(srgbRed: 0.80, green: 0.86, blue: 0.87, alpha: 1.0).setFill()
        NSBezierPath(rect: rightRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawBadgeText("A", color: .white, fontSize: 8.5, in: NSRect(x: inner.minX - 0.5, y: inner.minY + 0.5, width: leftRect.width, height: inner.height))
        drawBadgeText("文", color: NSColor(srgbRed: 0.19, green: 0.34, blue: 0.39, alpha: 1.0), fontSize: 8, in: NSRect(x: rightRect.minX - 0.5, y: rightRect.minY + 0.5, width: rightRect.width + 1, height: rightRect.height))
    }

    private func drawRewriteBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 18, height: 15), size: NSSize(width: 18, height: 15))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let inner = frame.insetBy(dx: 1.7, dy: 1.7)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
        drawBadgeText("✎", color: NSColor(srgbRed: 0.14, green: 0.18, blue: 0.20, alpha: 1.0), fontSize: 10.5, in: NSRect(x: inner.minX, y: inner.minY + 0.5, width: inner.width, height: inner.height))
    }

    private func drawReplyBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0).setFill()
        for x in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawThinkingBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        // Animated dots: cycle one bright dot at a time
        let activeDot = (animationFrame / 8) % 3
        for (index, x) in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5].enumerated() {
            let isActive = index == activeDot
            let color = isActive
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0)
                : NSColor(srgbRed: 0.55, green: 0.57, blue: 0.58, alpha: 1.0)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawBadgeText(_ text: String, color: NSColor, fontSize: CGFloat, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func color(for pixel: Character) -> NSColor? {
        switch pixel {
        case "W":
            return NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
        case "G":
            return NSColor(srgbRed: 0.70, green: 0.75, blue: 0.76, alpha: 1)
        case "K":
            return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        case "P":
            return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.65, alpha: 1)
        case "B":
            return NSColor(srgbRed: 0.97, green: 0.96, blue: 0.86, alpha: 1)
        case "D":
            return NSColor(srgbRed: 0.08, green: 0.16, blue: 0.20, alpha: 1)
        default:
            return nil
        }
    }

    private func tooltip(for state: State, mode: TranslationMode) -> String {
        switch state {
        case .idle, .run:
            return "Gizmate pet"
        case .ready:
            return "Choose an action"
        case .thinking:
            return "Thinking…"
        case .talking:
            return "Double-click to close"
        case .flying:
            return "Weeee!"
        }
    }
}

extension PetMascotView {
    /// The mascot rendered into a standalone image — the app's mark on
    /// surfaces that can't host a live view (menu bar, floating button).
    @MainActor
    static func markImage(height: CGFloat, mode: TranslationMode = .selection) -> NSImage? {
        let renderSize = NSSize(width: 42, height: 34)
        let mascot = PetMascotView(frame: NSRect(origin: .zero, size: renderSize))
        mascot.wantsLayer = false  // draw straight via draw(_:) so off-window cacheDisplay is reliable
        mascot.apply(state: .idle, mode: mode)
        guard let rep = mascot.bitmapImageRepForCachingDisplay(in: mascot.bounds) else {
            return nil
        }
        mascot.cacheDisplay(in: mascot.bounds, to: rep)

        let image = NSImage(size: NSSize(width: renderSize.width * height / renderSize.height, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}

