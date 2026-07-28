#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: generate-dmg-background.swift <output.png>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let size = NSSize(width: 540, height: 380)

// Gizmate green, brightened so it reads on the dark gray gradient.
let accent = NSColor(srgbRed: 0.16, green: 0.64, blue: 0.58, alpha: 1.0)

let image = NSImage(size: size)
image.lockFocus()

let backgroundRect = NSRect(origin: .zero, size: size)

// Brand photo background: a soft green frosted-glass image, aspect-filled to the
// window. Located relative to this script so the build can regenerate without a
// path argument; falls back to a flat gradient if the asset is missing.
let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // Scripts/
    .deletingLastPathComponent()      // repo root
    .appendingPathComponent("Resources/dmg-bg-source.png")

if let photo = NSImage(contentsOf: sourceURL) {
    let scale = max(size.width / photo.size.width, size.height / photo.size.height)
    let w = photo.size.width * scale
    let h = photo.size.height * scale
    photo.draw(in: NSRect(x: backgroundRect.midX - w / 2, y: backgroundRect.midY - h / 2, width: w, height: h))

    // Dark scrim, heavier at the top, so white text reads over the bright frosted
    // area while the green still shows through at the bottom behind the steps.
    let scrim = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.52),
        NSColor.black.withAlphaComponent(0.30)
    ])!
    scrim.draw(in: backgroundRect, angle: 270)
} else {
    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.30, alpha: 1.0),
        NSColor(calibratedWhite: 0.22, alpha: 1.0)
    ])!
    gradient.draw(in: backgroundRect, angle: 270)
}

NSColor.white.withAlphaComponent(0.14).setStroke()
NSBezierPath(rect: NSRect(x: 0, y: size.height - 1, width: size.width, height: 1)).stroke()

// Centered single-line text helper (origin is bottom-left, AppKit style).
@discardableResult
func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat, tracking: CGFloat = 0) -> CGFloat {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if tracking != 0 { attrs[.kern] = tracking }
    let line = text as NSString
    let width = line.size(withAttributes: attrs).width
    line.draw(at: NSPoint(x: (size.width - width) / 2, y: y), withAttributes: attrs)
    return width
}

// Heading — a friendly hook rather than a flat "Install".
drawCentered(
    "Give Gizmate a home 😺",
    font: NSFont.systemFont(ofSize: 24, weight: .bold),
    color: NSColor.white.withAlphaComponent(0.95),
    y: 322
)

// Drag arrow between the app icon (x≈145) and the Applications alias (x≈395),
// at the icons' vertical centre.
let arrowFont = NSFont.systemFont(ofSize: 60, weight: .thin)
let arrowAttributes: [NSAttributedString.Key: Any] = [
    .font: arrowFont,
    .foregroundColor: accent.withAlphaComponent(0.85)
]
let arrow = "→" as NSString
let arrowSize = arrow.size(withAttributes: arrowAttributes)
arrow.draw(
    at: NSPoint(x: (size.width - arrowSize.width) / 2, y: 168),
    withAttributes: arrowAttributes
)

// Vertical three-step stepper along the bottom — explicit instructions, one per
// row. Numbered accent badges connected by a hairline; labels left-aligned, and
// the whole block centred horizontally on its widest row.
struct Step { let n: String; let label: String }
let steps = [
    Step(n: "1", label: "Drag Gizmate to Applications"),
    Step(n: "2", label: "Double-click Applications to open it"),
    Step(n: "3", label: "Find Gizmate and open it")
]

let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
let badgeFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
let badgeDiameter: CGFloat = 21
let badgeGap: CGFloat = 9         // badge → label
let rowSpacing: CGFloat = 32      // row → row (vertical)

func labelWidth(_ s: String) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: labelFont]).width
}

let blockWidth = badgeDiameter + badgeGap + (steps.map { labelWidth($0.label) }.max() ?? 0)
let leftX = (size.width - blockWidth) / 2

// Badge centre Y per row, top row highest (AppKit origin is bottom-left).
let topCenterY: CGFloat = 96
let centerYs = (0..<steps.count).map { topCenterY - CGFloat($0) * rowSpacing }

// Connector hairline through the badge centres.
accent.withAlphaComponent(0.35).setStroke()
let connector = NSBezierPath()
connector.lineWidth = 1.5
connector.move(to: NSPoint(x: leftX + badgeDiameter / 2, y: centerYs.first!))
connector.line(to: NSPoint(x: leftX + badgeDiameter / 2, y: centerYs.last!))
connector.stroke()

for (i, step) in steps.enumerated() {
    let centerY = centerYs[i]
    // Badge: filled accent circle with the step number.
    let badgeRect = NSRect(x: leftX, y: centerY - badgeDiameter / 2, width: badgeDiameter, height: badgeDiameter)
    accent.setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    let numAttrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.white]
    let num = step.n as NSString
    let numSize = num.size(withAttributes: numAttrs)
    num.draw(
        at: NSPoint(x: badgeRect.midX - numSize.width / 2, y: badgeRect.midY - numSize.height / 2),
        withAttributes: numAttrs
    )

    // Label, vertically centred against the badge.
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.white.withAlphaComponent(0.80)
    ]
    let label = step.label as NSString
    let labelSize = label.size(withAttributes: labelAttrs)
    label.draw(
        at: NSPoint(x: badgeRect.maxX + badgeGap, y: badgeRect.midY - labelSize.height / 2),
        withAttributes: labelAttrs
    )
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8))
    exit(1)
}

try png.write(to: outputURL)
print("Wrote \(outputURL.path)")
