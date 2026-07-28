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

/// Where a ring button's hover bubble sits relative to its circle. Also
/// names the bubble edge (or corner, for diagonals) carrying the tail via
/// `opposite`.
enum RadialMenuLabelPlacement {
    case top
    case left
    case right
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// The facing edge — a bubble ABOVE the circle points its tail DOWN,
    /// a bubble to the TOP-RIGHT points its tail from its BOTTOM-LEFT corner.
    var opposite: RadialMenuLabelPlacement {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .left: return .right
        case .right: return .left
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

/// One button on the radial menu that opens around the floating bar / pet:
/// an image (SF Symbol or, for contextual entries, an app icon), a hover
/// label, and the action to run when picked. Labels avoid "translate"
/// wording deliberately — house copy rule.
struct RingItem {
    let label: String
    let image: NSImage
    let handler: () -> Void
    /// When non-empty, this button is a hover-expandable parent: hovering (or
    /// clicking) it reveals these buttons as a second-layer fan while the first
    /// ring stays. The parent's own `handler` is then unused.
    var subItems: [RingItem] = []

    /// Builds a ring item from an SF Symbol, applying the same fixed
    /// size/weight the ring has always rendered its glyphs at.
    static func symbol(_ name: String, label: String, handler: @escaping () -> Void) -> RingItem {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            ?? NSImage()
        return RingItem(label: label, image: img, handler: handler)
    }

    /// Builds a ring item from a bundled Phosphor icon (bold weight, rendered
    /// to a 40px template PNG in Resources/PhosphorIcons — see LICENSE.txt
    /// there). Template + 20pt logical size = tints and scales exactly like
    /// the SF Symbol items it replaced.
    static func phosphor(_ name: String, label: String, handler: @escaping () -> Void) -> RingItem {
        let img = Bundle.module.url(forResource: "\(name)-bold", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 20, height: 20)
        return RingItem(label: label, image: img, handler: handler)
    }
}

/// A time window for a chat summary — the second-layer ring buttons.
enum SummaryTimeRange: CaseIterable {
    case today, week, month

    var label: String {
        switch self {
        case .today: return "Today"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }

    /// Messages sent at or after this instant are included.
    func cutoff(now: Date = Date()) -> Date {
        switch self {
        case .today: return Calendar.current.startOfDay(for: now)
        case .week:  return now.addingTimeInterval(-7 * 24 * 3600)
        case .month: return now.addingTimeInterval(-30 * 24 * 3600)
        }
    }
}

struct RingSummarizeOption {
    let appLabel: String            // e.g. "KakaoTalk"
    let appIcon: NSImage
    /// Messenger flow: the ring expands into time-range subitems and calls
    /// this with the picked range. nil for browsers.
    var run: ((_ range: SummaryTimeRange) -> Void)? = nil
    /// Browser flow: a web page has no time axis, so the ring renders a
    /// single button that fires immediately. nil for messengers.
    var runDirect: (() -> Void)? = nil
    /// Generic "summarize from anywhere" flow (frontmost app isn't summarizable):
    /// the ring's second layer becomes an app picker — one button per available
    /// source (Kakao/Telegram/Browser), each firing its own `runDirect` or
    /// expanding into its own time-range third orbit (`run`).
    var appChoices: [RingSummarizeOption]? = nil
}

/// Builds the ring's Summarize item from a `RingSummarizeOption`, shared by
/// all three ring presenters (quick menu, pet, floating button). `dismiss`
/// is the presenter's own teardown, run before any action fires. Chat
/// sources expand into time ranges; browsers fire directly.
@MainActor
func summarizeRingItem(_ opt: RingSummarizeOption, dismiss: @escaping () -> Void) -> RingItem {
    func rangeItems(_ run: @escaping (_ range: SummaryTimeRange) -> Void) -> [RingItem] {
        SummaryTimeRange.allCases.map { range in
            RingItem(label: range.label, image: RingTextBadge.image(range.label)) {
                dismiss()
                run(range)
            }
        }
    }

    if let choices = opt.appChoices {
        let subItems: [RingItem] = choices.map { choice in
            if let run = choice.run {
                // Hovering the app choice opens its own (third) orbit of ranges.
                return RingItem(label: choice.appLabel, image: choice.appIcon, handler: {}, subItems: rangeItems(run))
            }
            return RingItem(label: choice.appLabel, image: choice.appIcon) {
                dismiss()
                choice.runDirect?()
            }
        }
        return RingItem(label: "", image: opt.appIcon, handler: {}, subItems: subItems)
    }
    if let direct = opt.runDirect {
        return RingItem(label: "", image: opt.appIcon) {
            dismiss()
            direct()
        }
    }
    if let run = opt.run {
        return RingItem(label: "", image: opt.appIcon, handler: {}, subItems: rangeItems(run))
    }
    return RingItem(label: "", image: opt.appIcon, handler: { dismiss() })
}

/// Renders a short word badge ("Today", "Week", "Month") as an `NSImage` for
/// the time-range ring buttons, which otherwise expect an SF Symbol image.
/// Auto-fits the font so the word fills the circle without clipping.
enum RingTextBadge {
    static func image(_ text: String) -> NSImage {
        let d = RadialMenuLayoutPolicy.buttonDiameter
        let size = NSSize(width: d, height: d)
        let maxWidth: CGFloat = d - 14
        var fontSize: CGFloat = d * 0.31
        var attrs: [NSAttributedString.Key: Any] = [:]
        var r = CGRect.zero
        repeat {
            attrs = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            r = (text as NSString).boundingRect(with: NSSize(width: 200, height: 40), options: [], attributes: attrs)
            fontSize -= 1
        } while r.width > maxWidth && fontSize > 8
        let img = NSImage(size: size)
        img.lockFocus()
        (text as NSString).draw(
            at: NSPoint(x: (size.width - r.width) / 2, y: (size.height - r.height) / 2),
            withAttributes: attrs
        )
        img.unlockFocus()
        // Template so the button's contentTintColor flips the word black/white
        // to contrast with the glass (same as the SF-symbol buttons).
        img.isTemplate = true
        return img
    }
}

