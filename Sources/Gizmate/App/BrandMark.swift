import AppKit

/// The menu bar mark, derived from the shipped brand artwork rather than drawn
/// by hand, so replacing `logo.png` updates the status item too.
///
/// A menu bar icon has to work on a light *and* a dark bar, which means it must
/// be a template image: AppKit throws the colours away and tints the alpha
/// channel to match the bar. The artwork is a dark body with a light plate and
/// two dark slots, so a naive silhouette would fill the slots in and lose the
/// face. `templateImage` keeps the body solid and punches the slots back out.
enum BrandMark {
    /// The artwork in full colour, for anywhere the brand should appear as a
    /// picture rather than a tinted glyph — alert icons, the window header.
    ///
    /// Loaded from resources rather than read back from `NSApp.applicationIconImage`,
    /// because that is the generic system placeholder in `swift run` builds, and
    /// AppKit happily renders the placeholder as a blue folder.
    static let appIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// The same artwork with its transparent margin cropped off. The shipped
    /// PNG keeps a wide margin because `Scripts/generate-icon.swift` builds the
    /// Dock `.icns` from it and macOS expects that padding on the icon grid —
    /// but next to a word at 30-odd points the margin just reads as a gap.
    static let trimmedIcon: NSImage? = {
        guard let source = appIcon,
              let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let (_, box) = maskBounds(from: rep),
              let cropped = rep.cgImage?.cropping(to: box) else { return appIcon }
        return NSImage(cgImage: cropped, size: box.size)
    }()

    /// Cached because building the mask walks the full 500×500 artwork.
    private static var cache: [CGFloat: NSImage] = [:]

    static func templateImage(height: CGFloat) -> NSImage? {
        if let hit = cache[height] { return hit }
        guard let image = buildTemplate(height: height) else { return nil }
        cache[height] = image
        return image
    }

    private static func buildTemplate(height: CGFloat) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "logo", withExtension: "png"),
              let source = NSImage(contentsOf: url),
              let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let mask = maskBounds(from: rep) else {
            return nil
        }

        let (opaque, box) = mask
        let scale: CGFloat = 2  // retina; the menu bar is never below 2x in practice
        let pixelHeight = max(1, Int((height * scale).rounded()))
        let pixelWidth = max(1, Int((height * scale * box.width / box.height).rounded()))

        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = out.bitmapData else {
            return nil
        }

        // Nearest-neighbour would alias the slots at 18pt, so sample a small box
        // per destination pixel and use its coverage as the alpha. That is a box
        // filter — cheap, and it keeps the two slots readable when the mark is
        // barely 20 pixels tall.
        let rowBytes = out.bytesPerRow
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let x0 = Int(box.minX) + x * Int(box.width) / pixelWidth
                let x1 = max(x0 + 1, Int(box.minX) + (x + 1) * Int(box.width) / pixelWidth)
                let y0 = Int(box.minY) + y * Int(box.height) / pixelHeight
                let y1 = max(y0 + 1, Int(box.minY) + (y + 1) * Int(box.height) / pixelHeight)

                var covered = 0, total = 0
                for sy in y0..<y1 {
                    for sx in x0..<x1 {
                        total += 1
                        if opaque[sy * rep.pixelsWide + sx] { covered += 1 }
                    }
                }
                let alpha = total == 0 ? 0 : UInt8(255 * covered / total)
                let offset = y * rowBytes + x * 4
                data[offset] = 0        // template images ignore colour…
                data[offset + 1] = 0
                data[offset + 2] = 0
                data[offset + 3] = alpha   // …and tint this
            }
        }

        let pointWidth = height * box.width / box.height
        out.size = NSSize(width: pointWidth, height: height)
        let image = NSImage(size: NSSize(width: pointWidth, height: height))
        image.addRepresentation(out)
        image.isTemplate = true
        return image
    }

    /// Returns a per-pixel "is part of the mark" mask plus the box that bounds
    /// it, both in artwork pixels indexed from the top-left like `colorAt`.
    private static func maskBounds(from rep: NSBitmapImageRep) -> ([Bool], NSRect)? {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 0, height > 0, let data = rep.bitmapData else { return nil }
        let samples = rep.samplesPerPixel
        guard samples >= 3 else { return nil }
        let rowBytes = rep.bytesPerRow

        var solid = [Bool](repeating: false, count: width * height)   // any artwork
        var bright = [Bool](repeating: false, count: width * height)  // the light plate
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * samples
                let alpha = samples >= 4 ? data[offset + 3] : 255
                guard alpha > 127 else { continue }
                let index = y * width + x
                solid[index] = true
                let luma = (Int(data[offset]) * 299 + Int(data[offset + 1]) * 587
                            + Int(data[offset + 2]) * 114) / 1000
                bright[index] = luma > 190
            }
        }

        // A slot is a dark pixel with plate on all four sides. Testing "enclosed"
        // rather than "inside the plate's bounding box" matters: the box corners
        // hold body pixels, and punching those would bite chunks out of the
        // silhouette exactly where the plate meets the body.
        var brightLeft = [Bool](repeating: false, count: width * height)
        var brightRight = [Bool](repeating: false, count: width * height)
        var brightUp = [Bool](repeating: false, count: width * height)
        var brightDown = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            var seen = false
            for x in 0..<width { brightLeft[y * width + x] = seen; seen = seen || bright[y * width + x] }
            seen = false
            for x in stride(from: width - 1, through: 0, by: -1) {
                brightRight[y * width + x] = seen; seen = seen || bright[y * width + x]
            }
        }
        for x in 0..<width {
            var seen = false
            for y in 0..<height { brightUp[y * width + x] = seen; seen = seen || bright[y * width + x] }
            seen = false
            for y in stride(from: height - 1, through: 0, by: -1) {
                brightDown[y * width + x] = seen; seen = seen || bright[y * width + x]
            }
        }

        var minX = width, minY = height, maxX = -1, maxY = -1
        var opaque = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard solid[index] else { continue }
                let enclosed = !bright[index]
                    && brightLeft[index] && brightRight[index]
                    && brightUp[index] && brightDown[index]
                guard !enclosed else { continue }
                opaque[index] = true
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (opaque, box)
    }
}
