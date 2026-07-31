import Foundation

struct AskGizmateTurn: Codable, Equatable {
    let question: String
    let answer: String
}

/// Persists the Ask Gizmate dialog across app launches so follow-up questions
/// keep their context after a restart. The saved-at clock resets on every save,
/// so an actively used conversation never expires; after `maxAge` without a new
/// ask, the next launch starts fresh.
enum AskGizmateHistoryStore {
    static let maxAge: TimeInterval = 24 * 60 * 60
    // Pre-rename spellings on purpose: renaming these keys would drop the
    // conversation every existing user has in flight.
    private static let turnsKey = "askNugumiHistory"
    private static let savedAtKey = "askNugumiHistorySavedAt"

    static func load(defaults: UserDefaults = .standard, now: Date = Date()) -> [AskGizmateTurn] {
        let savedAt = defaults.double(forKey: savedAtKey)
        guard savedAt > 0,
              now.timeIntervalSince1970 - savedAt < maxAge,
              let data = defaults.data(forKey: turnsKey),
              let turns = try? JSONDecoder().decode([AskGizmateTurn].self, from: data)
        else {
            return []
        }
        return turns
    }

    static func save(_ turns: [AskGizmateTurn], defaults: UserDefaults = .standard, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(turns) else { return }
        defaults.set(data, forKey: turnsKey)
        defaults.set(now.timeIntervalSince1970, forKey: savedAtKey)
    }
}

enum AskGizmatePromptBuilder {
    static let maxHistoryTurns = 20

    static func appending(_ turn: AskGizmateTurn, to history: [AskGizmateTurn]) -> [AskGizmateTurn] {
        let updated = history + [turn]
        guard updated.count > maxHistoryTurns else { return updated }
        return Array(updated.suffix(maxHistoryTurns))
    }

    private static let systemPromptBase = """
You are Gizmate, a concise and helpful desktop assistant. Answer the user's question directly and usefully.

When the user attaches a screenshot, you can see what is currently on their screen and answer about it. When no screenshot is attached, answer from general knowledge.

Write the answer as plain text, not JSON. Markdown is welcome when structure genuinely helps: "-" bullets or numbered lists for steps, **bold** for the key term or the direct answer, a small table for comparisons. Keep it concise and scannable — plain prose for one-sentence answers, never headings.

When a screenshot is attached AND drawing on top of it explains better than words alone, append exactly one fenced block at the very end of the answer, after a blank line:

```annotations
[{"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05},
 {"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10},
 {"type":"arrow","fromX":0.42,"fromY":0.45,"toX":0.55,"toY":0.32},
 {"type":"label","x":0.42,"y":0.50,"text":"click here"}]
```

Annotation rules:
- The block contains ONLY a JSON array — double quotes, no comments, nothing after the closing fence. It is machine-read and never shown to the user; the answer text must stand on its own without it.
- Coordinates are normalized 0.0–1.0 over the screenshot: x left-to-right, y top-to-bottom.
- "ellipse" and "rect" take the CENTER ("cx", "cy") plus width/height fractions ("w", "h"). "arrow" goes from ("fromX", "fromY") to ("toX", "toY"). "label" anchors its "text" (five words or fewer) at ("x", "y").
- A few precise shapes beat many: circle one element, draw one arrow per direction or relationship, box one region. Never more than 12 shapes.
- If uncertain about a location, skip the shape and describe it in words instead.
- Your previous annotations are erased with every new answer. To keep pointing at something across a follow-up, include its shapes again.
- Never add the block when no screenshot is attached.

Do not click, automate, or claim you took an action.
"""

    /// Base prompt, plus the Gen Z styling suffix when the global toggle is on,
    /// plus the user's "About you" background when present.
    static func systemPrompt(genZ: Bool, aboutUser: String? = nil) -> String {
        let base = genZ ? systemPromptBase + "\n\n" + genZSuffix : systemPromptBase
        return UserAboutContext.appending(to: base, about: aboutUser)
    }

    /// Gen Z overlay for Ask answers. Ask replies in the question's own language
    /// (unknown at prompt-build time), so this stays language-agnostic and leans
    /// on the model's multilingual slang — and must not break the answer format.
    private static let genZSuffix = """
Gen Z mode is ON. Write the answer text the way a Gen Z native (born ~1997–2012) would actually text it — casual, all-lowercase, ironic and a little deadpan, using the native youth slang of whatever language you are answering in (never switch languages to do it). Keep it short. The #1 rule is restraint: at most 1–2 slang markers — piling it on is the dead giveaway of an adult faking it; when unsure, drop the slang. Write laughter as 💀 or 😭, never 😂. This restyles ONLY the answer wording — keep the annotations block format and its rules above exactly as specified.
"""

    static func prompt(question: String, hasImage: Bool) -> String {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard hasImage else {
            return cleanQuestion
        }

        return """
User question:
\(cleanQuestion)

Coordinate guide for annotations:
- All coordinates (`cx`/`cy`, `fromX`/`fromY`/`toX`/`toY`, `x`/`y`) are normalized from 0.0 to 1.0 over the attached screenshot. x is the horizontal fraction from the left edge; y is the vertical fraction from the top edge.
- Aim shapes at the geometric center of the target element's visible bounding box (button, icon, control, or input). Never anchor to the top-left of a text label — in a vertical list of buttons or menu items, a label's top-left sits inside the previous row.
- For small menu bar or status icons, aim at the icon glyph's visual center, not the surrounding hit area.
- Before choosing coordinates, identify the target's row/column context in `message` (for example: "the third item in the left sidebar, below New chat and above Artifacts") so you anchor to the correct sibling among visually similar elements.
"""
    }
}
