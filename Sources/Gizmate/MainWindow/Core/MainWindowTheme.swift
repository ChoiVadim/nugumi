import AppKit
import SwiftUI

// MARK: - Theme

/// Flow-inspired flat, opaque palette. Deliberately NOT the frosted GlassHostView
/// look used by the small panels — the main window is a calm cream + white sheet.
enum FlowTheme {
    /// The single accent. Monochrome on purpose: the palette carries hierarchy
    /// through lightness alone, so nothing competes with the content. Light
    /// rather than dark because `accent` is used as foreground text on the dark
    /// sheet.
    ///
    /// Use it for **text, icons and hairlines only** — never as a large fill
    /// under white text. A light accent behind white text has no contrast left;
    /// raised surfaces belong to the elevation ladder below.
    static let accent = Color(white: 0.788)
    static let accentSoft = Color.white.opacity(0.18)
    /// Brighter accent for the sign-in HUDs, which sit on a darker scrim than
    /// the main sheet and need more separation.
    static let accentBright = Color(white: 0.910)

    /// Two backgrounds only: translucent liquid glass everywhere (clear, shows the
    /// window's NSVisualEffectView), and an opaque near-black settings container.
    static let glass = Color.clear
    static let card = Color.white.opacity(0.06)          // translucent gray settings panel

    /// Text is white throughout.
    static let ink = Color.white
    static let inkSecondary = Color(white: 0.74)
    static let inkTertiary = Color(white: 0.55)

    static let hairline = Color.white.opacity(0.10)
    static let subtleFill = Color.white.opacity(0.08)

    /// The one break in a monochrome palette, and it earns it: red is the only
    /// colour a control can wear that means "this deletes something" without a
    /// word of copy. Light rather than saturated for the same reason `accent`
    /// is — it has to stay legible as text on the dark sheet. The palette's
    /// "Status/error" row in `DESIGN.md` §2 is this value; anything destructive
    /// takes it from here rather than mint its own red.
    static let danger = Color(red: 1.0, green: 0.549, blue: 0.549)  // #FF8C8C

    // MARK: Elevation
    //
    // Depth comes from stacked translucent sheets over one backdrop, the way
    // Apple's materials work — never from opaque grey. Each step adds a thin
    // veil, so the blur underneath keeps showing through and neighbouring
    // layers read as height rather than as different paint. Two rules keep it
    // honest: things content sits *inside* go down (`recess`), things that sit
    // *on top* go up (`raised`), and white text stays legible on every step
    // because no step is ever light enough to compete with it.

    /// Recessed well: segmented-control tracks, input fields, anything the eye
    /// should read as carved into the surface.
    static let recess = Color.black.opacity(0.18)
    /// What "this one is selected" looks like: a well sunk *below* the surface,
    /// not a chip lifted above it. Deeper than `recess` because it has to read
    /// against the sidebar's own material rather than against a lit track.
    /// The sidebar's current row. Deliberately faint, and lighter rather than
    /// darker: the label already carries the selection in weight and in ink, so
    /// the fill only has to say "this group", not shout it. A well of black
    /// punched into the panel, plus a hairline around it, was reading as a
    /// pressed button on a screen where nothing else is pressed.
    static let selected = Color.white.opacity(0.055)
    /// One step above the surface: the selected chip in a track, a hovered row.
    static let raised = Color.white.opacity(0.14)
    /// Top of the ladder: the primary action in a section.
    static let raisedStrong = Color.white.opacity(0.20)
    /// Hairline along a raised edge — brighter than `hairline` so the lit top
    /// edge of a chip separates it from the layer beneath.
    static let edge = Color.white.opacity(0.22)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension Font {
    /// Pixelify wordmark. Reuse GizmateFont's resolved NSFont (which registers the
    /// bundled Pixelify and falls back safely), then bridge to SwiftUI via CoreText
    /// so the custom family resolves reliably under `swift run` and in the app.
    static func gizmatePixel(_ size: CGFloat) -> Font {
        let nsFont = GizmateFont.pixelPrompt(size: size)
        return Font(CTFontCreateWithName(nsFont.fontName as CFString, size, nil))
    }
}

/// Forces subtle, auto-hiding overlay scrollers even when macOS is set to
/// "always show scroll bars". Drop inside a ScrollView's content so it can reach
/// the backing `NSScrollView` via `enclosingScrollView`.
struct ScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView) }
    }

    private static func apply(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
    }
}

/// SwiftUI bridge to `NSVisualEffectView` so a container can use a real system
/// material (the same dark translucent look as the status-bar dropdown menu)
/// instead of a flat translucent fill.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
