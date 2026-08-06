import AppKit
import Foundation

/// How a ring button draws its glyph. Built-ins use the bundled Phosphor PNGs
/// where one exists and SF Symbols otherwise — see `RingItem.phosphor` /
/// `RingItem.symbol`, which own the actual sizing contract.
enum RingIconKind: Equatable {
    case phosphor(String)
    case symbol(String)
    /// Gizmate's own mark. `BrandMark.templateImage` already builds the one
    /// thing this needs — a silhouette with the two eye slots punched back out,
    /// so a plain alpha silhouette doesn't fill the face in — and caches it per
    /// height for the menu bar. Same artwork, same treatment, tinted like every
    /// other icon here.
    case brand
}

/// Stable identity of every built-in ring action.
///
/// Raw values are persisted inside the saved ring layout — **never rename one**.
/// Adding a case is safe: layouts saved by an older build simply won't carry it,
/// and the user can assign it from the Ring tab.
enum RingActionID: String, Codable, CaseIterable {
    case explain
    case rewrite
    case genZ
    case reply
    case ask
    case capture
    case summarize
    case dictate
    case live
    case saveNote

    /// Hover label in the live ring. Summarize is deliberately empty: its button
    /// wears the source app's own icon, which already names it.
    var label: String {
        switch self {
        case .explain:   return "Explain"
        case .rewrite:   return "Rewrite"
        case .genZ:      return "Gen Z"
        case .reply:     return "Reply"
        case .ask:       return "Ask"
        case .capture:   return "Capture"
        case .summarize: return ""
        case .dictate:   return "Dictate"
        case .live:      return "Live"
        case .saveNote:  return "Note"
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
        case .genZ:      return .symbol("flame")
        case .reply:     return .phosphor("arrow-bend-up-left")
        case .ask:       return .brand
        case .capture:   return .phosphor("scan")
        case .summarize: return .symbol("list.bullet.rectangle")
        case .dictate:   return .symbol("mic")
        case .live:      return .symbol("waveform")
        case .saveNote:  return .symbol("note.text.badge.plus")
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
        case .genZ:
            return "Rewrite your draft the way a Gen Z native would text it."
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
        case .saveNote:
            return "Keep the selected text as a note."
        }
    }

    /// The mode whose prompt this built-in owns, for the three that have an
    /// editable one.
    ///
    /// Summarize is deliberately absent even though it is prompt-driven: one
    /// button stands in front of two prompts (`.summarizeChat` for a transcript,
    /// `.summarizePage` for a web page), so a single text field could not
    /// honestly represent it.
    ///
    /// `default` rather than an exhaustive list on purpose — "this action has no
    /// editable prompt" is the safe answer for anything added later.
    var promptMode: TranslationMode? {
        switch self {
        case .explain: return .selection
        case .rewrite: return .draftMessage
        case .genZ:    return .genZ
        case .reply:   return .smartReply
        default:       return nil
        }
    }

    /// The global hotkey this built-in owns, so its editor can rebind it and
    /// switching the built-in off can free the key.
    ///
    /// Summarize has none on purpose: it only appears in a supported chat app or
    /// browser, so a global key that does nothing most of the time is a bug
    /// report waiting to happen.
    var shortcutAction: GlobalShortcutAction? {
        switch self {
        case .explain:   return .explainSelection
        case .rewrite:   return .translateSelection
        case .genZ:      return .genZSelection
        case .reply:     return .replyToSelection
        case .ask:       return .askGizmate
        case .capture:   return .screenshotArea
        case .dictate:   return .dictate
        case .live:      return .liveTranslation
        case .saveNote:  return .saveNote
        case .summarize: return nil
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
        case .brand:
            return BrandMark.templateImage(height: pointSize) ?? NSImage()
        }
    }
}
