import AppKit
import Foundation

/// How a ring button draws its glyph. Built-ins use the bundled Phosphor PNGs
/// where one exists and SF Symbols otherwise — see `RingItem.phosphor` /
/// `RingItem.symbol`, which own the actual sizing contract.
enum RingIconKind: Equatable {
    case phosphor(String)
    case symbol(String)
}

/// Stable identity of every built-in ring action.
///
/// Raw values are persisted inside the saved ring layout — **never rename one**.
/// Adding a case is safe: layouts saved by an older build simply won't carry it,
/// and the user can assign it from the Ring tab.
enum RingActionID: String, Codable, CaseIterable {
    case explain
    case rewrite
    case reply
    case ask
    case capture
    case summarize
    case dictate
    case live

    /// Hover label in the live ring. Summarize is deliberately empty: its button
    /// wears the source app's own icon, which already names it.
    var label: String {
        switch self {
        case .explain:   return "Explain"
        case .rewrite:   return "Rewrite"
        case .reply:     return "Reply"
        case .ask:       return "Ask"
        case .capture:   return "Capture"
        case .summarize: return ""
        case .dictate:   return "Dictate"
        case .live:      return "Live"
        }
    }

    /// Readable name for the Ring tab, which needs one for Summarize too.
    var displayName: String {
        self == .summarize ? "Summarize" : label
    }

    /// Glyph for the ring button and the settings diagram. Summarize's entry is
    /// settings-only: in the live ring its button carries the frontmost app's
    /// icon, supplied by `RingSummarizeOption`.
    var icon: RingIconKind {
        switch self {
        case .explain:   return .phosphor("magnifying-glass")
        case .rewrite:   return .phosphor("pencil-line")
        case .reply:     return .phosphor("arrow-bend-up-left")
        case .ask:       return .phosphor("question")
        case .capture:   return .phosphor("scan")
        case .summarize: return .symbol("list.bullet.rectangle")
        case .dictate:   return .symbol("mic")
        case .live:      return .symbol("waveform")
        }
    }

    /// One line for the slot picker, so a user who never memorized the ring can
    /// tell the actions apart.
    var summary: String {
        switch self {
        case .explain:
            return "Explain the selected text in plain language."
        case .rewrite:
            return "Rewrite your draft in the target language and your writing style."
        case .reply:
            return "Draft a reply to the selected message, or answer the question in it."
        case .ask:
            return "Open the Ask Gizmate prompt."
        case .capture:
            return "Pick a region of the screen and read the text in it."
        case .summarize:
            return "Summarize the current chat or web page. Shows up only in a supported app."
        case .dictate:
            return "Dictate text with your voice."
        case .live:
            return "Start live translation."
        }
    }
}

extension RingIconKind {
    /// Template image for this glyph at the ring's button size, or an SF Symbol
    /// at `pointSize` for the settings diagram. Mirrors the sizing that
    /// `RingItem.phosphor` / `RingItem.symbol` bake in.
    func image(pointSize: CGFloat = 20) -> NSImage {
        switch self {
        case .phosphor(let name):
            let image = Bundle.module.url(forResource: "\(name)-bold", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) } ?? NSImage()
            image.isTemplate = true
            image.size = NSSize(width: pointSize, height: pointSize)
            return image
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                ) ?? NSImage()
        }
    }
}
