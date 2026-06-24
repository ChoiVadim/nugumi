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

let image = NSImage(size: size)
image.lockFocus()

let backgroundRect = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedWhite: 0.42, alpha: 1.0),
    NSColor(calibratedWhite: 0.34, alpha: 1.0)
])!
gradient.draw(in: backgroundRect, angle: 270)

let glassOverlay = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.12),
    NSColor.white.withAlphaComponent(0.03)
])!
glassOverlay.draw(in: backgroundRect.insetBy(dx: 1, dy: 1), angle: 90)

NSColor.white.withAlphaComponent(0.16).setStroke()
NSBezierPath(rect: NSRect(x: 0, y: size.height - 1, width: size.width, height: 1)).stroke()

// Centered single-line text helper (origin is bottom-left, AppKit style).
func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let line = text as NSString
    let width = line.size(withAttributes: attrs).width
    line.draw(at: NSPoint(x: (size.width - width) / 2, y: y), withAttributes: attrs)
}

// Step 1, stated plainly above the icons.
drawCentered(
    "Drag Nugumi to Applications",
    font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    color: NSColor.white.withAlphaComponent(0.92),
    y: 318
)

// Drag arrow between the app icon (x≈145) and the Applications alias (x≈395).
let arrowFont = NSFont.systemFont(ofSize: 64, weight: .thin)
let arrowAttributes: [NSAttributedString.Key: Any] = [
    .font: arrowFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.5)
]
let arrow = "→" as NSString
let arrowSize = arrow.size(withAttributes: arrowAttributes)
arrow.draw(
    at: NSPoint(x: (size.width - arrowSize.width) / 2, y: 164),
    withAttributes: arrowAttributes
)

// Step 2 — the part first-time users miss: nothing auto-launches after a
// drag-install, so spell out that they must open it from Applications.
drawCentered(
    "Then open Nugumi from your Applications folder",
    font: NSFont.systemFont(ofSize: 13, weight: .regular),
    color: NSColor.white.withAlphaComponent(0.62),
    y: 44
)

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
