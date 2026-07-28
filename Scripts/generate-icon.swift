#!/usr/bin/env swift

import AppKit
import Foundation

// Builds Resources/AppIcon.icns from the shipped brand artwork at
// Sources/Gizmate/Resources/logo.png, so the Dock icon and the in-app brand
// icon can never drift apart.
//
// The mark is free-form rather than sitting on a tile: the artwork is a dark
// object with its own silhouette, and the dark rounded-square backdrop the
// previous pixel-mascot icon used would swallow it.
//
// Usage: swift Scripts/generate-icon.swift Resources/AppIcon.icns

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon.swift <output.icns>\n".utf8))
    exit(2)
}

let outputICNS = URL(fileURLWithPath: arguments[1])
let scriptDir = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
let root = scriptDir.deletingLastPathComponent()
let sourceArt = root.appendingPathComponent("Sources/Gizmate/Resources/logo.png")
let workDir = root.appendingPathComponent(".build/icon-stage")
let iconset = workDir.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: workDir)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let art = NSImage(contentsOf: sourceArt),
      let tiff = art.tiffRepresentation,
      let artRep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("Could not read brand artwork at \(sourceArt.path)\n".utf8))
    exit(1)
}

/// Bounding box of everything that is not fully transparent, in image pixels.
/// The source render is not centred in its own canvas, so drawing it as-is
/// would leave the icon visibly off-centre in the Dock.
func opaqueBounds(of rep: NSBitmapImageRep) -> NSRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.02 else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let contentBox = opaqueBounds(of: artRep)
print("Artwork content box: \(Int(contentBox.width))×\(Int(contentBox.height)) "
      + "in \(artRep.pixelsWide)×\(artRep.pixelsHigh)")

// `colorAt` indexes from the top-left, AppKit draws from the bottom-left.
let flippedContentBox = NSRect(
    x: contentBox.minX,
    y: CGFloat(artRep.pixelsHigh) - contentBox.maxY,
    width: contentBox.width,
    height: contentBox.height
)

struct Variant {
    let pixels: Int
    let filename: String
}

let variants: [Variant] = [
    .init(pixels: 16,   filename: "icon_16x16.png"),
    .init(pixels: 32,   filename: "icon_16x16@2x.png"),
    .init(pixels: 32,   filename: "icon_32x32.png"),
    .init(pixels: 64,   filename: "icon_32x32@2x.png"),
    .init(pixels: 128,  filename: "icon_128x128.png"),
    .init(pixels: 256,  filename: "icon_128x128@2x.png"),
    .init(pixels: 256,  filename: "icon_256x256.png"),
    .init(pixels: 512,  filename: "icon_256x256@2x.png"),
    .init(pixels: 512,  filename: "icon_512x512.png"),
    .init(pixels: 1024, filename: "icon_512x512@2x.png")
]

/// Fraction of the tile the mark spans. Apple's icon grid leaves a margin, and
/// filling the square edge to edge makes an icon look oversized next to its
/// neighbours in the Dock.
let contentScale: CGFloat = 0.86

func renderIcon(pixels size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap"])
    }
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(size) * contentScale
    let aspect = flippedContentBox.width / flippedContentBox.height
    let drawSize = aspect >= 1
        ? NSSize(width: side, height: side / aspect)
        : NSSize(width: side * aspect, height: side)
    let destination = NSRect(
        x: (CGFloat(size) - drawSize.width) / 2,
        y: (CGFloat(size) - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )

    art.draw(
        in: destination,
        from: flippedContentBox,
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )

    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url)
}

for variant in variants {
    let image = try renderIcon(pixels: variant.pixels)
    let url = iconset.appendingPathComponent(variant.filename)
    try writePNG(image, to: url)
    print("Wrote \(variant.filename) (\(variant.pixels)px)")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", outputICNS.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (status \(process.terminationStatus))\n".utf8))
    exit(process.terminationStatus)
}
print("Built \(outputICNS.path)")
