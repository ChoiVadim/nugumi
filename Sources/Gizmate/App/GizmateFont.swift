import AppKit
import CoreText

/// The Pixelify Sans face used by Gizmate's wordmark. The font ships in the
/// SwiftPM resource bundle, so it has to be registered with CoreText once per
/// process before `NSFont(name:)` can resolve it.
enum GizmateFont {
    private static let didRegisterPixelifySans: Bool = {
        guard let url = Bundle.module.url(
            forResource: "PixelifySans",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func pixelPrompt(size: CGFloat) -> NSFont {
        _ = didRegisterPixelifySans
        return NSFont(name: "PixelifySans-Regular_SemiBold", size: size)
            ?? NSFont(name: "Pixelify Sans", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }
}
