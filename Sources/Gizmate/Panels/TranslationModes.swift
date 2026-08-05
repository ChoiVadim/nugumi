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

/// User-authored "About you" background appended to every system prompt so the
/// model picks meanings relevant to this user (e.g. "RLS" → Row-Level Security
/// for a developer, not Restless Legs Syndrome). Deliberately manual and
/// transparent — the user writes it in Settings; nothing is auto-learned.
enum UserAboutContext {
    static let maxLength = 1000
    static let defaultsKey = "aboutUserContext"

    static var text: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Appends the background section to a system prompt. Returns the prompt
    /// unchanged when the user wrote nothing, so empty stays zero-cost.
    static func appending(to prompt: String, about: String? = nil) -> String {
        let trimmed = (about ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        return prompt + """


        Background about the user, in their own words:
        \(String(trimmed.prefix(maxLength)))

        Use this background only to disambiguate terms and choose the meaning most relevant to this user. Do not change the output's tone, style, language, or format because of it unless it explicitly says to. Never mention this background in the output.
        """
    }
}

/// `Equatable` is spelled out because the enum carries an associated value now
/// (`.custom`) — Swift only synthesizes `==` for free on payload-free enums, and
/// several `mode == .selection` checks depend on it.
enum TranslationMode: Equatable {
    case selection
    case draftMessage
    case smartReply
    /// Restyles the user's own text into Gen Z slang and writes it back where
    /// they were typing — the same shape as `.draftMessage`, with its own
    /// prompt. Used to be a global toggle layered over every other mode; it is
    /// one built-in you aim now (`RingActionID.genZ`).
    case genZ
    /// Internal re-render of an existing `.selection` result: the user typed a
    /// "revise or ask a follow-up" instruction and we regenerate the answer in
    /// place. Never assigned to a floating surface — only the result panel.
    case revise
    /// Revise/follow-up for an outgoing message — both `.smartReply` (a drafted
    /// reply) and `.draftMessage` (a polished draft). Keeps composition (writing
    /// style/voice). Panel-only, never a floating surface.
    case reviseMessage
    /// Summarizes a chat transcript (see `ChatTranscript.format`) into a
    /// TL;DR + key points + action items. Read-only, no composition settings.
    /// Panel-only, never a floating surface.
    case summarizeChat
    /// Summarizes the web page open in the frontmost browser (text read off
    /// the AX tree — see `BrowserPageReader`). Same behavior contract as
    /// `.summarizeChat`: read-only, never persisted, panel-only.
    case summarizePage
    /// One of the user's own prompt tools (see `GizmateTool`), run over the
    /// selection. The tool carries its whole system prompt, so nothing about it
    /// is hardcoded here. Ring-only: never a floating-button default mode.
    case custom(GizmateTool)

    var usesCompositionSettings: Bool {
        switch self {
        case .revise, .summarizeChat, .summarizePage:
            return false
        case .reviseMessage:
            return true
        case .selection, .draftMessage, .smartReply, .genZ:
            // The four editable built-ins carry "Use my Voice" in their own
            // editor. Off means Rewrite and Reply render their style tokens
            // empty and Explain appends no style block — see
            // `builtInContextSections`. Gen Z takes only the glossary half of
            // it: the register is the whole point of that built-in, so the
            // writing style must not be spliced in to argue with it.
            return usesVoiceContext
        case .custom(let tool):
            // The user's own prompt is authoritative, so composition stays off
            // unless they ticked "Use my Voice" on this gizmo — layering the
            // writing style, cleanup, and glossary directives over "turn this
            // into JSON" would fight it.
            return tool.usesVoice
        }
    }

    /// Whether the panel's follow-up field revises *content* (`.revise`) rather
    /// than an outgoing message (`.reviseMessage`). A prompt tool's answer is
    /// content, so it takes the content path.
    var revisesAsContent: Bool {
        switch self {
        case .selection, .summarizeChat, .summarizePage, .custom:
            return true
        case .draftMessage, .smartReply, .genZ, .revise, .reviseMessage:
            return false
        }
    }

    var resultLabel: String? {
        switch self {
        case .selection, .draftMessage, .genZ, .revise:
            return nil
        case .smartReply, .reviseMessage:
            return "Reply"
        case .summarizeChat, .summarizePage:
            return "Summary"
        case .custom(let tool):
            return tool.name
        }
    }

    var loadingPlaceholder: String {
        switch self {
        case .smartReply:
            return "Thinking"
        case .draftMessage, .genZ:
            return "Rewriting"
        case .selection:
            return "Thinking"
        case .revise, .reviseMessage:
            return "Revising"
        case .summarizeChat, .summarizePage:
            return "Summarizing"
        case .custom:
            return "Thinking"
        }
    }

    /// Wraps the original text, the prior answer, and the user's instruction into
    /// the single `text` argument the existing one-shot `translate(...)` path
    /// carries — so revise reuses all four backends with no transport changes.
    static func composeReviseInput(source: String, previous: String, instruction: String) -> String {
        """
        Original text:
        \(source)

        Your previous response:
        \(previous)

        Revision request:
        \(instruction)
        """
    }

    // MARK: - Editable built-in prompts

    private static let selectionTemplate = """
        Translate the user's text into plain, accessible {language} aimed at a curious ~12-year-old reader with no background in the field — accessible, but not babyish or condescending. The goal is to make the content understandable, not to produce a literal word-for-word rendering. This applies whether the source is already in {language}, in another language entirely, or a mix of both.

        Render any foreign-language parts into {language}, then simplify the whole result: break long sentences into shorter ones, replace jargon and rare or technical vocabulary with plain everyday words, unwind passive voice and nested clauses, and prefer concrete wording over abstract phrasing. Where a concept stays abstract after a plain-word swap, anchor it inline with a short concrete example or everyday analogy in parentheses or em-dashes — e.g. "a queue (like the line at a coffee shop — first in, first served)".

        Match output complexity to source complexity. If the source is already a casual, simple message — a chat line, a greeting, a short sentence with no jargon, a menu item, a button label — translate it plainly and stop. Do not force analogies, examples, or expansions onto content that is already simple. The simplification rules are for when there is something genuinely complex to make accessible; short, plain inputs get short, plain outputs. (A single standalone word or term that the user is looking up is the exception — see the Lookup case below.)

        Lookup case — if the source is a single word or a short standalone term (not a sentence, greeting, or casual phrase) and rendering it into {language} would leave it essentially unchanged — because it is already in {language}, or is a borrowed or technical term with no distinct {language} translation — then the user has selected it to understand what it means, not to translate it. Do not echo the word back unchanged. Instead, explain it in 1–2 short, plain {language} sentences: what it means in everyday words, and a quick concrete example if it helps. Keep it simple enough for a curious ~12-year-old. If the word has several common meanings, give the most everyday one first and you may note a field-specific sense in a few words. Do not add a dictionary header, the word itself as a title, pronunciation, or part-of-speech labels — just the plain explanation.

        Treat a single `\\n` as a wrapped line inside one paragraph — join it silently. Treat a blank line (`\\n\\n`) as a deliberate paragraph break that the user wants to keep — render it as a blank line in the output. Clean repeated spaces, OCR artifacts, and hyphenated line wraps. If the source has no paragraph breaks but is long or dense, split the output into readable paragraphs instead of returning one wall of text.

        Keep every fact, name, date, number, quotation, URL, proper noun, and the original paragraph/bullet/list structure exactly. Do not summarize, do not drop content, do not add new claims, opinions, or facts — examples and analogies must only illustrate what is already there, never extend it. If your output differs from a literal translation only by swapping a few synonyms (e.g. "specialized" → "special", "utilize" → "use") or replacing punctuation, you have not simplified — go further: add an illustrative example, restructure the sentence, or name the topic in plainer terms.

        Return only the {language} output. No preamble, no commentary, no quotes around the output. Never write a wrapper like "Here is the translation:" — output the text directly.
        """

    private static let draftMessageTemplate = """
        Translate the user's drafted outgoing message into natural {language}. Infer the user's actual intent, emotion, and social situation, then say it the way a native {language} speaker would send it in a chat or message. If the draft is already entirely in {language}, do not translate it; lightly rewrite/polish it only when needed so it sounds natural and sendable. If only part of the draft is in {language} and the rest is in one or more other languages, translate the foreign parts into {language} and weave everything into one cohesive, natural-sounding message — keep the {language} portions intact unless they need light polish to flow with the rest. Treat code-switching as the user reaching for words they didn't know in {language}, not as a stylistic choice to preserve.

        The selected Writing style is authoritative. The source draft tells you meaning, intent, emotion, and how direct the user wants to be, but it must not override the selected Writing style. When goals conflict, follow this priority: (1) meaning, (2) selected Writing style, (3) intended directness and emotional signal within that style, (4) cultural naturalness — idioms, honorifics, word order, (5) surface details to preserve verbatim — emojis, URLs, usernames, product names, numbers, line breaks, (6) literal wording (always lowest). If the draft is blunt, keep the result concise and direct, but still use the selected Writing style. Do not pad a curt one-liner into a long paragraph unless the meaning requires it. If the draft is awkward or phrased like a direct translation, smooth it while keeping the same intent. If the draft is a fragment, return a natural sendable fragment without inventing extra context.

        Emoji shorthand — replace `[X emoji]` patterns with the matching Unicode emoji (`[smile emoji]` → 😊, `[fire emoji]` → 🔥, `[thumbs up emoji]` → 👍, `[crying emoji]` → 😭). Pick the most common, neutral variant when several emojis fit the description. Only expand when the bracketed content reads as an emoji description — leave bracketed dates, citations, code, placeholders, and other non-emoji content untouched (e.g. `[2025-01-01]`, `[1]`, `[redacted]`, `[insert name]` stay as-is).

        Writing style — {writingStyle}{voice}{cleanup}{glossary}

        Return only the final {language} message, with no commentary, labels, alternatives, quotes, or explanations.
        """

    private static let smartReplyTemplate = """
        The user has selected text in another app. The text is either (a) a message they received — email, chat message, DM, comment, support ticket, or similar; or (b) a question they need to answer — a quiz item, exam question, multiple-choice question, or open question. Decide which it is from the text itself, then respond appropriately. Write your reply or answer in {language}, regardless of what language the source text is in.

        If it is a received message: write a natural, ready-to-send reply as if the user is sending it now. Match the intent, emotional signal, and approximate length of the original, but use the selected Writing style below for register and formality. Be concise. Don't restate or quote the original. Don't add greetings or sign-offs unless the original suggests them. Don't address the user — produce only the message body they would paste into the reply field.

        If it is a multiple-choice question: identify the correct option and respond with the option letter or number followed by the option text, then a brief one-sentence justification. Example: "B. Mitochondria — they generate most of the cell's ATP."

        If it is an open question: give a clear, direct answer. Keep it short unless the question demands depth.

        Writing style — {writingStyle}{voice}

        Cleanup — {cleanup}{glossary}

        Return only the reply or answer text. No commentary, no labels, no preface, no explanation of what you're doing, no quotes around the answer.
        """

    /// Deliberately short next to the other three: the substance is the
    /// `{genZ}` block, which is `GenZStyle`'s research for the writing language
    /// and would be ~60 lines of slang notes to scroll past in the editor.
    /// Every other built-in's writing-style layer is left out on purpose — Gen Z
    /// *is* a register, and splicing the user's own in would argue with it.
    private static let genZTemplate = """
        Rewrite the user's text in {language} the way a Gen Z native would text it. This is a restyle, not a response: keep their meaning, information, and intent exactly, and never answer, summarize, continue, or comment on the text.

        If the text is already in {language}, restyle it where it stands. If it is in another language, render it into {language} first, then restyle. Keep emojis, URLs, @usernames, numbers, and deliberate line breaks as written.

        {genZ}

        {glossary}

        Return only the rewritten {language} text. No commentary, no labels, no quotes, no alternatives.
        """

    /// The shipped prompt as an editable template. Tokens stand in for the
    /// values `systemPrompt` splices — a user override is plain text, so without
    /// them an edited Explain would stop targeting the writing language.
    ///
    /// nil for every mode that is not an editable built-in; those keep their
    /// interpolated form.
    var shippedPromptTemplate: String? {
        switch self {
        case .selection:    return Self.selectionTemplate
        case .draftMessage: return Self.draftMessageTemplate
        case .smartReply:   return Self.smartReplyTemplate
        case .genZ:         return Self.genZTemplate
        default:            return nil
        }
    }

    /// Prompt templates the user wrote, keyed by the built-in that owns them.
    /// Kept in sync by `GizmateApp` from `BuiltInOverridesStore` — the same
    /// arrangement as `AppCategoryClassifier.userOverrides`, and for the same
    /// reason: `systemPrompt` is called from four LLM clients, none of which
    /// should have to learn about built-in overrides to pass one through.
    static var promptOverrides: [RingActionID: String] = [:]

    /// Built-ins the user switched "Use my Voice" / "Use my notes" off for.
    /// Off-lists because both ship on: an untouched built-in is in neither.
    /// Kept current by `GizmateApp`, exactly like `promptOverrides`.
    static var voiceOffBuiltIns: Set<RingActionID> = []
    static var notesOffBuiltIns: Set<RingActionID> = []

    /// The built-in whose editor owns this mode's prompt, if any.
    private var owningBuiltIn: RingActionID? {
        RingActionID.allCases.first { $0.promptMode == self }
    }

    private var usesVoiceContext: Bool {
        guard let owningBuiltIn else { return false }
        return !Self.voiceOffBuiltIns.contains(owningBuiltIn)
    }

    private var usesNotesContext: Bool {
        guard let owningBuiltIn else { return false }
        return !Self.notesOffBuiltIns.contains(owningBuiltIn)
    }

    /// The template actually used: the user's, or the shipped one. A blank
    /// override is a cleared field, not a request for an empty system prompt.
    var promptTemplate: String? {
        let userWritten = owningBuiltIn
            .flatMap { Self.promptOverrides[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let userWritten, !userWritten.isEmpty { return userWritten }
        return shippedPromptTemplate
    }

    /// Substitutes `{token}` placeholders in a single pass over the template.
    ///
    /// Single pass, not a `reduce` of `replacingOccurrences`, because the values
    /// being spliced in are user content: a glossary snippet or voice sample
    /// containing the literal text `{language}` would be rescanned and
    /// substituted by a later iteration. One pass means a value is never
    /// re-examined once written.
    ///
    /// An unknown token is left verbatim rather than erased, so a typo in a
    /// user's override shows up in the output instead of silently vanishing.
    static func renderPrompt(_ template: String, tokens: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[rest.startIndex..<open]
            rest = rest[rest.index(after: open)...]
            guard let close = rest.firstIndex(of: "}"),
                  let value = tokens[String(rest[rest.startIndex..<close])]
            else {
                result += "{"
                continue
            }
            result += value
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// Built per mode, not once globally: `.draftMessage` splices
    /// `cleanupSection(for:)`, which emits its own "Cleanup — " heading, while
    /// `.smartReply` has that heading written into the prompt and splices only
    /// `cleanup.promptDescription`. Same concept, different spelling — keeping
    /// the maps separate is what makes both byte-identical to what shipped.
    private func promptTokens(
        targetLanguage: TranslationLanguage,
        composition: CompositionSettings?
    ) -> [String: String] {
        var tokens: [String: String] = [
            "language": targetLanguage.promptName,
        ]
        switch self {
        case .genZ:
            // No `{writingStyle}` — see `genZTemplate`. The glossary half of
            // "Use my Voice" still applies: a name the user pinned stays spelled
            // the way they pinned it, slang or not.
            tokens["genZ"] = GenZStyle.promptSection(for: targetLanguage.id)
            tokens["glossary"] = Self.glossarySection(
                for: composition?.snippets ?? [],
                includeSnippets: true
            )
        case .draftMessage:
            tokens["writingStyle"] = composition?.writingStyleDirective(for: targetLanguage.id) ?? ""
            tokens["voice"] = Self.voiceSampleSection(for: composition?.voiceSample)
            tokens["cleanup"] = Self.cleanupSection(for: composition?.cleanup)
            tokens["glossary"] = Self.glossarySection(
                for: composition?.snippets ?? [],
                includeSnippets: true
            )
        case .smartReply:
            tokens["writingStyle"] = composition?.writingStyleDirective(for: targetLanguage.id) ?? ""
            tokens["voice"] = Self.voiceSampleSection(for: composition?.voiceSample)
            tokens["cleanup"] = composition?.cleanup.promptDescription ?? ""
            tokens["glossary"] = Self.glossarySection(
                for: composition?.snippets ?? [],
                includeSnippets: true
            )
        default:
            break
        }
        return tokens
    }


    /// The app the user is writing in reaches this only through the writing
    /// style it selected (`compositionSettings(for:appCategory:)`). It used to
    /// arrive a second time as an `{app}` prose hint too, which for three of the
    /// five categories said no more than "defer to the writing style".
    func systemPrompt(
        targetLanguage: TranslationLanguage,
        composition: CompositionSettings?
    ) -> String {
        // The four editable built-ins render from a template so a user's
        // override keeps the language and writing-style layers.
        if let template = promptTemplate {
            let rendered = TranslationMode.renderPrompt(
                template,
                tokens: promptTokens(
                    targetLanguage: targetLanguage,
                    composition: composition
                )
            )
            return UserAboutContext.appending(to: rendered + builtInContextSections(
                targetLanguage: targetLanguage,
                composition: composition
            ))
        }
        let base: String = switch self {
        case .selection, .draftMessage, .smartReply, .genZ:
            ""   // Rendered above from the template; unreachable.
        case .revise:
            """
            You are refining a response you previously gave the user. Their message has three labeled parts: the original text they were looking at, your previous response to it, and a revision request.

            Apply the revision request to your previous response. If the request asks you to change the response (shorter, simpler, more detail, different tone, etc.), produce the updated version. If it asks a follow-up question instead of an edit, answer it directly — your answer replaces the previous response.

            Write the result in \(targetLanguage.promptName), in the same plain, accessible style aimed at a curious ~12-year-old reader with no background in the field — accessible, but not babyish or condescending. Keep every fact, name, number, and quotation accurate; do not invent claims.

            Return only the updated response text. No preamble, no labels, no quotes, never a wrapper like "Here is the revised version:" — just the text.
            """
        case .reviseMessage:
            """
            You previously wrote a message for the user to send. Their input has three labeled parts: the original text (what they were working from — a message they received, a question, or their own rough draft), your previous message, and a revision request.

            Apply the revision request to your previous message. If it is an instruction (shorter, warmer, more formal, add a detail, fix something, etc.), produce the updated message. If it asks a follow-up question instead of an edit, answer it in the context of this message — your answer replaces the previous message.

            Write the result in \(targetLanguage.promptName), natural and ready to send, in the user's voice. Match the selected Writing style below. Don't restate or quote the original, don't add greetings or sign-offs unless warranted, and don't address the user — produce only the message body they would paste into the field.

            Writing style — \(composition?.writingStyleDirective(for: targetLanguage.id) ?? "")\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))

            Return only the updated message text. No preamble, no labels, no quotes, never a wrapper like "Here is the revised version:" — just the text.
            """
        case .summarizeChat:
            """
            You are given a chat transcript as "Sender: message" lines, oldest first. \
            Write a concise summary in \(targetLanguage.promptName): a one-line TL;DR, \
            then a short bulleted list of the key points and decisions, then any action \
            items or open questions addressed to the reader. Preserve names, dates, \
            numbers, and links exactly. Do not invent anything not in the transcript. \
            Return only the summary — no preamble, no quotes.
            """
        case .summarizePage:
            """
            You are given the text of a web page the user has open, extracted \
            top-to-bottom; the first line is the page title. It may contain stray \
            navigation labels, cookie banners, buttons, or ad text — ignore that \
            boilerplate and summarize the actual content. Write a concise summary \
            in \(targetLanguage.promptName): a one-line TL;DR, then a short \
            bulleted list of the key points, then any conclusions or next steps \
            the page offers the reader. Preserve names, dates, numbers, and links \
            exactly. Do not invent anything not on the page. Return only the \
            summary — no preamble, no quotes.
            """
        case .custom(let tool):
            TranslationMode.customPrompt(
                tool,
                targetLanguage: targetLanguage,
                composition: composition
            )
        }
        return UserAboutContext.appending(to: base)
    }

    /// A prompt tool's own instruction, plus a target-language line when the
    /// tool asked for one. Tools that transform rather than translate (text →
    /// JSON, pull out the dates) leave that off — a language instruction would
    /// corrupt their output.
    private static func customPrompt(
        _ tool: GizmateTool,
        targetLanguage: TranslationLanguage,
        composition: CompositionSettings?
    ) -> String {
        var body = tool.resolvingOption(tool.prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tool.appliesTargetLanguage {
            body += "\n\nWrite the output in \(targetLanguage.promptName)."
        }
        if tool.output == .annotate {
            body += Self.annotationContract
        }
        return body + contextSections(
            for: tool,
            targetLanguage: targetLanguage,
            composition: composition
        )
    }

    /// Appended to a gizmo whose result is `.annotate`. The shape vocabulary is
    /// Ask's — same decoder, same renderer — with one difference that follows
    /// from there being no panel: prose has nowhere to land, so the model is
    /// told its words have to live inside `label` shapes.
    private static let annotationContract = """


        Answer by drawing on the screenshot, not by writing. Return ONLY a fenced block, nothing before or after it:

        ```annotations
        [{"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05},
         {"type":"arrow","fromX":0.42,"fromY":0.45,"toX":0.55,"toY":0.32,"color":"red"},
         {"type":"label","x":0.55,"y":0.30,"text":"start here"}]
        ```

        - Coordinates are fractions of the screenshot, 0.0–1.0, x left-to-right and y TOP-to-bottom.
        - "ellipse" and "rect" take the CENTER ("cx", "cy") plus width/height fractions ("w", "h"). "arrow" goes from ("fromX", "fromY") to ("toX", "toY"). "label" anchors its "text" (five words or fewer) at ("x", "y").
        - Any shape may carry "color": one of "green", "red", "blue", "yellow", "orange", "purple", "pink", "cyan". Leave it out and the shape is green. Use it only when the colors mean different things — red for what is wrong and green for what to do, one color per step of an order — never as decoration.
        - There is no panel and no text answer — anything you need to say must be a "label" shape. A reply with no shapes shows the user nothing at all.
        - A few precise shapes beat many: circle one element, draw one arrow per direction, box one region. Never more than 12 shapes.
        """

    /// The context blocks a built-in's editor toggles bring in, for the parts
    /// its template does not already carry. Rewrite and Reply splice the Voice
    /// through `{writingStyle}` / `{cleanup}` / `{glossary}` — a nil
    /// composition is how "off" reaches them — so only Explain needs the block
    /// appended. Gen Z is left out of it: that built-in's template splices the
    /// only piece of the Voice it wants through `{glossary}`. No shipped
    /// template mentions notes, so those append for all four.
    private func builtInContextSections(
        targetLanguage: TranslationLanguage,
        composition: CompositionSettings?
    ) -> String {
        var sections = ""
        if self == .selection, usesVoiceContext, let composition {
            sections += "\n\nWriting style — "
                + composition.writingStyleDirective(for: targetLanguage.id)
                + Self.cleanupSection(for: composition.cleanup)
                + Self.glossarySection(for: composition.snippets, includeSnippets: true)
        }
        if usesNotesContext {
            sections = NotesContext.appending(to: sections)
        }
        return sections
    }

    /// The context blocks a user gizmo opted into: the user's Voice (register,
    /// cleanup, dictionary, snippets) and their ticked notes.
    ///
    /// Shared with `.agent` gizmos, which never pass through a `TranslationMode`
    /// at all — `AgentToolRunner` gets its instruction assembled by the caller
    /// and this is the one place that knows how the blocks are worded. Returns
    /// an empty string when both toggles are off, so a gizmo that wants neither
    /// sends byte-for-byte what it sent before this existed.
    static func contextSections(
        for tool: GizmateTool,
        targetLanguage: TranslationLanguage,
        composition: CompositionSettings?
    ) -> String {
        var sections = ""
        if tool.usesVoice, let composition {
            sections += "\n\nWriting style — "
                + composition.writingStyleDirective(for: targetLanguage.id)
                + cleanupSection(for: composition.cleanup)
                + glossarySection(for: composition.snippets, includeSnippets: true)
        }
        if tool.usesNotes {
            sections = NotesContext.appending(to: sections)
        }
        return sections
    }

    private static func glossarySection(for snippets: [Snippet], includeSnippets: Bool) -> String {
        let usable = snippets.filter(\.isUsable)
        guard !usable.isEmpty else { return "" }

        let expansions = includeSnippets ? usable.filter { $0.kind == .snippet } : []
        let dictionaryTerms = usable.filter { $0.kind == .dictionaryTerm }
        guard !expansions.isEmpty || !dictionaryTerms.isEmpty else { return "" }

        var sections: [String] = []
        sections.append(#"Glossary — apply these user-saved rules exactly when relevant."#)

        if !expansions.isEmpty {
            let lines = expansions.map { snippet -> String in
                let trigger = promptLine(snippet.trigger)
                let value = promptLine(snippet.value)
                return "- \"\(trigger)\" → \(value)"
            }
            sections.append("Snippets — expand BEFORE rewriting for tone/style. After expansion, treat the expanded text as canonical and do not paraphrase it:\n" + lines.joined(separator: "\n"))
        }

        if !dictionaryTerms.isEmpty {
            let lines = dictionaryTerms.map { "- \(promptLine($0.trigger))" }
            sections.append("Dictionary — preserve these terms verbatim. Never translate, paraphrase, or alter spelling/capitalization:\n" + lines.joined(separator: "\n"))
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    /// Cleanup/polish instruction block. Empty string for `.none` (and nil), so
    /// "no cleanup" injects no prompt at all and the writing style stays the only
    /// authority — cleanup is a polish axis, orthogonal to register.
    private static func cleanupSection(for level: CleanupLevel?) -> String {
        guard let level, level != .none else { return "" }
        return "\n\nCleanup — \(level.promptDescription)"
    }

    /// The user's email voice sample as a template block. Empty string when
    /// there's no sample (so callsites stay inline). `compositionSettings` only
    /// populates `voiceSample` for the email category, so this is a no-op
    /// everywhere else.
    ///
    /// Division of authority (resolves the sample-vs-Writing-style conflict):
    /// the sample owns STRUCTURE (that there's a greeting, a sign-off carrying the
    /// name, the rhythm) and overrides the draft prompt's chat-style brevity; the
    /// Writing style pill owns REGISTER (formality), overriding the sample's own
    /// formality line by line — so a casual register yields a casual greeting and
    /// sign-off even when the sample is written formally.
    private static func voiceSampleSection(for sample: String?) -> String {
        let trimmed = sample?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let instruction = "Voice sample — the example below is the user's own email template. Take its STRUCTURE from it: that the email opens with a greeting, closes with a sign-off carrying the user's name, plus its general rhythm and layout. This structure OVERRIDES any length-matching or brevity guidance above — always produce the full greeting + body + sign-off, even when the user's draft is a single short line or fragment; expand a terse draft into a complete email. The selected Writing style register, however, controls the FORMALITY of every line: render the greeting, body, and sign-off at that register even if the template itself is written more or less formally — e.g. if the register is casual, the greeting and sign-off become casual too, not the formal wording shown in the template. Write the body to convey the current draft's meaning; do not reuse the template's body text. Render everything in the target language. Reproduce the user's name in the signature exactly as written:"
        return "\n\n" + instruction + "\n" + trimmed
    }

    private static func promptLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum AppCategory: String, CaseIterable, Codable {
    case personalMessages
    case workMessages
    case email
    case other

    /// A raw value this build no longer knows decodes as `.other` rather than
    /// throwing. `CustomAppAssignment` is decoded as one array, so a single
    /// unknown category would otherwise take *every* per-app assignment down
    /// with it — which is exactly what retiring the `custom` category would
    /// have done to anyone who had used it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppCategory(rawValue: raw) ?? .other
    }

    var displayName: String {
        switch self {
        case .personalMessages: return "Personal messages"
        case .workMessages: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

}

enum WritingStyle: String, CaseIterable, Codable {
    case formal
    case polite
    case casual

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .polite: return "Polite"
        case .casual: return "Casual"
        }
    }

    /// Language-neutral description of the register. The per-language
    /// grammatical realization is appended by `promptDescription(for:)`.
    private var registerSummary: String {
        switch self {
        case .formal:
            return "highest formal register — the way you'd write to a senior client, superior, or in a business letter. No exclamation marks unless the source had them. This register overrides any informality implied by the app context."
        case .polite:
            return "polite, friendly register, the way you'd write to a colleague, acquaintance, or in a warm but professional message. This register overrides any informality implied by the app context. Never use the em dash (—), and don't substitute an en dash in its place; the long dash reads as AI writing and is out of place in a warm, conversational message. Use a comma, a period and a new sentence, or parentheses instead."
        case .casual:
            return "casual register, the way you'd write to a close friend. Lighter punctuation; periods optional at the ends of short messages. Conversational rhythm. Never use the em dash (—), and don't substitute an en dash in its place; the long dash reads as AI writing and clashes with a casual message. Use a comma, a period and a new sentence, or parentheses instead."
        }
    }

    /// Per-language grammatical realization of each register, keyed by
    /// `TranslationLanguage.id`. The output language is always known at
    /// prompt-build time, so only the matching language's rule is injected —
    /// keeping the prompt lean. Add a language = add one line per style; a
    /// language absent here falls back to `registerSummary` alone.
    private static let languageRules: [WritingStyle: [String: String]] = [
        .formal: [
            "en": "In English: NO contractions — write 'I am', 'cannot', 'I would', 'do not' in full. Complete, well-structured sentences. Open deferentially when it fits ('I hope you are well', 'Thank you for your message') and close formally ('Kind regards', 'Best regards', 'Sincerely'). Precise, slightly formal vocabulary (request, regarding, assistance, apologise, kindly, at your earliest convenience); soften requests fully ('Could you kindly...', 'I would be grateful if you could...', 'Would it be possible to...'). No slang, no abbreviations, no emoji, no exclamation marks. Professional and modern, never pompous or archaic. Example: 'can you send me the report?' → 'Could you kindly send me the report at your earliest convenience? I would be most grateful.'",
            "ko": "In Korean: use 합쇼체 (-습니다 / -십시오), never 해요체 and never 반말.",
            "ja": "In Japanese: use です/ます with deferential phrasing.",
            "ru": "In Russian: use Вы with full formal constructions.",
            "de": "In German: use Siezen (Sie/Ihnen) with formal salutations and closings; full sentences, no slangy contractions.",
            "fr": "In French: use vouvoiement (vous) with formal phrasing and closings (e.g. « Je vous prie d'agréer »).",
            "es": "In Spanish: use usted with deferential phrasing and complete sentences.",
            "zh-Hans": "In Chinese: use 您 with respectful set phrases (请, 麻烦您, 敬请) and no slang.",
        ],
        .polite: [
            "en": "In English: contractions are welcome (I'd, you're, can't, won't) — this is the warm, everyday professional register of a friendly email to a colleague. Complete but relaxed sentences. A light greeting ('Hi', 'Hope you're well') and a friendly sign-off ('Thanks so much', 'Best', 'Cheers') fit naturally. Plain, direct words (ask, about, help, sorry, sure) with lightly softened requests ('Could you...', 'Would you mind...', 'When you get a chance...'). At most one exclamation mark; the warmth comes from word choice, not punctuation. No slang and no texting abbreviations (no lmk/btw/tmrw). Example: 'can you send me the report?' → 'Hi! Could you send me the report when you get a chance? Thanks so much.'",
            "ko": "In Korean: use 해요체 (-아요 / -어요 / -해요), not 합쇼체 and not 반말.",
            "ja": "In Japanese: use です/ます in their everyday softer form.",
            "ru": "In Russian: use Вы with conversational warmth.",
            "de": "In German: use Sie in a warm, friendly tone — still Siezen, but conversational, not stiff.",
            "fr": "In French: use vous in a warm, friendly tone — polite but approachable.",
            "es": "In Spanish: use usted in a warm, friendly tone (or tú where the context is clearly informal).",
            "zh-Hans": "In Chinese: use 您 or 你 with a warm, polite tone and 请 where natural.",
        ],
        .casual: [
            "en": "In English: how you'd actually text a close friend. Heavy contractions and reductions (gonna, wanna, kinda, lemme, dunno, 'cause), short fragments and the odd run-on, blunt and direct ('sure', 'my bad', 'no worries', 'sounds good'). Everyday texting abbreviations are fine (lmk, btw, idk, tbh, rn, tmrw) but NOT loud Gen-Z slang — that's a separate mode. Keep natural casual capitalization (still capitalize names and sentence starts), light punctuation: periods optional on short messages, '...' and a single '!' fine. Drop formal greetings and sign-offs — 'hey' or nothing. Example: 'I will be unable to attend the meeting tomorrow, I apologize' → 'Hey, can't make the meeting tmrw, my bad'",
            "ko": "In Korean: use 반말 (-해, -야, -지), never 해요체 and never 합쇼체.",
            "ja": "In Japanese: use plain form (だ/する).",
            "ru": "In Russian: use ты-forms.",
            "de": "In German: use Duzen (du/dir) with relaxed phrasing and everyday contractions (geht's, hab's).",
            "fr": "In French: use tutoiement (tu) with relaxed everyday phrasing and common contractions (t'as, j'sais).",
            "es": "In Spanish: use tú (or vos where regionally natural), relaxed and conversational.",
            "zh-Hans": "In Chinese: use 你 with relaxed, conversational phrasing and everyday particles (啊, 吧, 呢).",
        ],
    ]

    /// Register description tailored to one target language: the neutral
    /// summary plus that language's specific rule when one exists.
    func promptDescription(for languageID: String) -> String {
        guard let rule = WritingStyle.languageRules[self]?[languageID] else {
            return registerSummary
        }
        return "\(registerSummary) \(rule)"
    }

    /// The style currently in effect for `category`, honoring the user's saved
    /// per-category choice and falling back to the category default.
    static func resolved(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return category.defaultWritingStyle
    }
}

extension AppCategory {
    /// Default register when the user hasn't picked one for this category.
    var defaultWritingStyle: WritingStyle {
        switch self {
        case .personalMessages: return .casual
        case .workMessages, .other: return .polite
        case .email: return .formal
        }
    }
}

enum CleanupLevel: String, CaseIterable, Codable {
    case none
    case light
    case medium
    case high

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var promptDescription: String {
        switch self {
        case .none:
            return "do not polish wording — preserve the source phrasing as faithfully as the target language allows."
        case .light:
            return "fix obvious typos, grammar errors, OCR/line-break artifacts. Do not rewrite for style."
        case .medium:
            return "edit lightly for clarity and flow — fix typos and awkward phrasing, but do not rephrase aggressively."
        case .high:
            return "polish thoroughly for brevity and clarity. Tighten verbose sentences, drop filler words, keep meaning intact."
        }
    }
}

/// The body of the Gen Z built-in's prompt (`TranslationMode.genZ`), spliced in
/// as its `{genZ}` token. The language-neutral `coreGuidance` always leads — its
/// load-bearing instruction is FULL transformation (rewrite the whole message in
/// slang, don't sprinkle one marker on formal text) — followed by one target
/// language's native-youth-slang block.
///
/// Synthesized from 2024–2026 per-language research. Slang churns fast, so each
/// block favors the durable signal (lowercase, dropped end-period, 💀/😭 over 😂,
/// tone) over fleeting vocabulary, and flags terms that already read as cringe.
enum GenZStyle {
    static let coreGuidance = """
        Gen Z mode is ON. Rewrite the message the way a Gen Z native (born ~1997–2012) would text it to a friend — casual digital register, not formal writing.
        CRITICAL — preserve the user's real meaning, intent, and information exactly. Change only the voice and styling, never what they are saying, and never invent new content.
        The #1 rule is to FULLY transform the message: rewrite the whole thing in slang, don't just sprinkle one marker on top of otherwise-formal text. Replace every formal/earnest word with its slang equivalent (impressed → lowkey obsessed, excellent → it ate / fire, very successful → so gonna cook / big W, talking about it → everyone's on it). Aim for 3+ slang markers per message. The failure mode to avoid is leaving formal phrasing untouched — if a sentence still reads corporate after you rewrite it, you under-did it.
        Default to all-lowercase. Drop the period at the end of a message (a trailing period reads cold or passive-aggressive). Keep it punchy.
        Tone skews ironic, deadpan, hyperbolic-for-jokes, and lightly self-deprecating — never earnest, peppy, or corporate.
        Use the target language's OWN native youth slang below — never translate English slang word-for-word into the target language.
        Still respect the selected register/honorific level (e.g. politeness or formality) while adding the Gen Z flavor.
        """

    static let languageGuidance: [String: String] = [
        "en": enGuide, "ru": ruGuide, "ko": koGuide, "ja": jaGuide,
        "zh-Hans": zhGuide, "es": esGuide, "fr": frGuide, "de": deGuide,
    ]

    /// Core rules plus the target language's specifics (core alone if the
    /// language has no dedicated block).
    static func promptSection(for languageID: String) -> String {
        guard let lang = languageGuidance[languageID] else { return coreGuidance }
        return "\(coreGuidance)\n\n\(lang)"
    }

    private static let enGuide = """
        English (US / global internet). All-lowercase; abbreviate freely: fr (for real), ngl, istg, idk, rn, tbh, lowkey/highkey, ong, deadass, iykyk, atp. Laughter is 💀 or 😭 or 'lmao' — never 😂 (a millennial tell).
        Current vocab: rizz (charm), no cap (no lie), it's giving X (gives off X), ate / understood the assignment (nailed it), cooked (doomed), mid (mediocre), crash out (lose it), delulu (delusional), bet (ok/deal), fire/bussin (great), 'that's so real' (agreement), aura (cool points).
        Cringe — avoid: skibidi, gyatt, sigma, Ohio, rizzler (Gen-Alpha brainrot); and millennial fossils: slay (overused), bae, on fleek, adulting, yas.
        Examples (note how every formal word gets swapped, not just one):
        - 'I'm really excited, this is going to be great' → 'ngl im so hyped this is gonna be fire fr'
        - 'Sorry, I can't make it tonight, I'm exhausted' → 'cant make it tn im so cooked 💀 sorry'
        - 'I was genuinely impressed by your presentation today. It was excellent, everyone was talking about it, and I think you're going to be very successful' → 'ngl your presentation today? it ate and left no crumbs fr 💀 no cap everyone was lowkey obsessed, you're so gonna cook, big W'
        """

    private static let ruGuide = """
        Russian. All-lowercase, no end-period, short fragments; heavy transliterated anglicisms. Laughter: ор / ору / орнул, ахах, пхпх — not 😂. Emoji sparse and ironic: 💀 🥲 🗿.
        Current vocab: база (facts/agreed), вайб (vibe), имба (op/awesome), рофл / рофлить (joke), окак (ironic 'oh wow'), чел (dude), го (let's go), жиза (relatable, postironic), делулу (delusional), скуф (unkempt older guy), слэй (nailed it).
        Tone: deadpan, postironic, understated. Don't overdo краш / кринж / чилить / флексить (now read slightly dated / adult).
        Examples:
        - 'Фильм очень понравился, советую посмотреть' → 'фильм имба реально советую'
        - 'Согласен, ты абсолютно прав' → 'база'
        """

    private static let koGuide = """
        Korean. Lean on 초성체: ㅋㅋㅋ (laugh; more ㅋ = funnier), ㅎㅎ (soft), ㅇㅇ (yes), ㄴㄴ (no), ㅇㅋ (ok), ㄱㄱ (go), ㄱㅅ (thanks), ㅈㅅ (sorry), ㄹㅇ (for real), ㅇㅈ (agreed), ㅁㅊ (omg). Cry with ㅠㅠ / ㅜㅜ. Clip words, drop spacing, use 음슴체 endings (먹음, 웃김, 가는중). Intensify with 개- / 존- / 핵- (개웃김, 존좋).
        Current vocab: 갓생 (grind-life), 찐 (genuine), 폼 미쳤다 (killing it), 현타 (reality crash), 꾸안꾸 (effortless style). Avoid dated: 어쩔티비, 존맛탱/JMT.
        Honorifics: if the input is 해요체, soften with ㅎㅎ / ~용 rather than dropping fully to 반말.
        Examples:
        - '오늘 정말 피곤해, 집에 가서 쉬고 싶어' → '오늘 진짜 개피곤 ㅠㅠ 집가서 눕고싶음'
        - '미안한데 약속에 좀 늦을 것 같아' → 'ㅈㅅㅈㅅ 나 좀 늦을듯 ㅠㅠ'
        """

    private static let jaGuide = """
        Japanese. Short fragments, タメ口, no 「。」 (reads cold). Drop particles (これヤバい). Laughter: 草 / w / wwww (more w = harder). 語尾: clip and stretch (しんど〜, きまず〜), nominalize with 〜み (つらみ, やばみ), 〜すぎ / 〜すぎる. Truncate: りょ→り (ok), とりま (anyway).
        Current vocab: それな (totally), ガチ / ガチで (for real), えぐい (insane), エモい (moving), ワンチャン (maybe), 知らんけど (…idk though — deadpan hedge), 神 (awesome), 推し. Avoid dead slang: ぴえん / ぱおん, マジ卍, あざまる, なう, タピる. Minimal emoji.
        Examples:
        - '今日は疲れたので早く寝ます' → '今日まじ疲れたわ〜もう寝る'
        - 'すごく助かりました、ありがとう' → 'まじ助かった〜ありがと🙏'
        """

    private static let zhGuide = """
        Simplified Chinese (Mainland). Lowercase pinyin-acronyms mixed with characters; repeat for emphasis. Laughter: 哈哈哈哈, 2333, xswl, 笑死 — not 😂.
        Current vocab: 那咋了 (so what / unbothered), emo了 (feeling down), 麻了 (numb / over it), 破防 (defenses broken / moved), 红温 (flushed with anger or embarrassment), 偷感 (acting low-key), 班味 (worn-down work vibe), 邪修 (unorthodox hack), 显眼包 (goofball), city不city (fancy?). Acronyms: yyds (GOAT), xswl (lmao), nbcs (nobody cares), awsl (so cute), u1s1 (real talk), dbq (sorry). Numbers: 666 (sick), 886 (bye), 555 (sob).
        Self-mocking 躺平 / 摆烂 tone. Avoid now-cringe: 绝绝子, 栓Q, overused yyds.
        Examples:
        - '这家餐厅真好吃，我很喜欢' → '这家真的绝了我爱住了哈哈哈哈'
        - '今天工作太累了，想休息' → '今天班味太重直接麻了 只想躺平'
        """

    private static let esGuide = """
        Spanish. Lowercase, drop opening ¿ ¡, no end-period, stretch vowels (siii, holaaa). Laughter: jajaja / jsjs / 💀 / 😭 — not 😂 or xD.
        Prefer PAN-HISPANIC terms (the user's region is usually unknown): cringe, random, crush, shippear, stalkear, mood, literal (intensifier), real / x2 (= same), mid, NPC, POV, red/green flag, modo X; peak term aura / farmear aura (clout). Regional — use only if signaled. Spain: tío/tía, en plan (filler), flipar, rayarse, mazo (= very). Mexico: neta, no manches, qué pedo, equis (= meh), alv. Argentina: che, boludo, re + adj, posta, de una (voseo: sos/tenés). Never mix regions — it reads instantly fake.
        Examples:
        - '¿Viste el video que te mandé? Es muy gracioso' → 'viste el video q te mande?? me morí 💀'
        - 'No quiero salir hoy, estoy muy cansado' → 'nah hoy no tengo ganas de salir estoy muerto'
        """

    private static let frGuide = """
        French. Default tu, never vous with peers (vous + slang = instant fake). All-lowercase; drop accents, apostrophes and the 'ne' (jai pas, jsp). Phonetic: c'est→c, j'ai→g, quoi→koi, t'inquiète→tkt, je sais pas→jsp, j'en peux plus→jpp, beaucoup→bcp. Laughter: mdr / ptdr / mdrrr and 💀 / 😭 — not 😂.
        Current vocab: wesh (yo), frérot / frr (bro), askip (apparently), c'est ouf / de ouf (insane), chelou (sketchy), relou (annoying), seum (bitter), bg (hot), validé (approved), banger, c'est carré (sorted), sah / wallah (i swear), jpp. Hyperbole for funny: 'je suis mort', 'ça m'a tué'. Avoid dated: swag, quoicoubeh, lol.
        Examples:
        - 'Tu es libre ce soir pour qu'on se voie ?' → 'wesh ça dit quoi tas dispo ce soir'
        - 'Je n'en peux plus, ce cours était trop long' → 'jpp ce cours ct giga long 💀'
        """

    private static let deGuide = """
        German. All-lowercase — drop even noun capitals (correct caps read old / try-hard). Default du. Drop the end-period (a lone 'Ok.' reads annoyed; 'ok' / 'kk' is fine). Laughter: 💀 / 😭, 'ich lieg', 'ich kann nicht' — not 😂.
        Current vocab: digga / diggah (bro, the #1 word), alter, bruda, wallah / ich schwör (i swear), lowkey, safe (definitely), mid, no cap, W / L (großes W, nimm das L), krass / geil (still live), 'das crazy', lost, cringe, random, aura. English verbs take German endings: gelikt, gecancelt, geghostet. Avoid corny / Jugendwort-bait: slay, lit, swag, yolo, smash, 'gönn dir', Ehrenmann. Do NOT generate Talahon or amk (slur / obscene).
        Examples:
        - 'Kannst du mir später beim Umzug helfen?' → 'digga hilfst du mir später beim umzug 🙏'
        - 'Der neue Film ist ziemlich mittelmäßig' → 'ngl der neue film war lowkey mid'
        """
}

enum AppCategoryClassifier {
    static let bundleIDMap: [String: AppCategory] = [
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "com.linkedin.LinkedIn": .workMessages,
        "com.apple.MobileSMS": .personalMessages,
        "com.apple.iChat": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.telegram.desktop": .personalMessages,
        "net.whatsapp.WhatsApp": .personalMessages,
        // KakaoTalk is deliberately NOT mapped: in Korea it is as much a work
        // channel as a personal one, and personalMessages defaults to casual
        // (반말) — too risky to assume. Unmapped → .other → polite (해요체),
        // safe in both directions. Users can assign it via custom app rules.
        "com.hnc.Discord": .personalMessages,
    ]

    /// User-added app→category assignments. Take precedence over `bundleIDMap`.
    /// Kept in sync by `GizmateApp` from persisted `CustomAppAssignment`s.
    static var userOverrides: [String: AppCategory] = [:]
    /// Built-in `bundleIDMap` apps the user removed — treated as unclassified.
    static var suppressedBuiltIns: Set<String> = []

    static func category(for bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        if let override = userOverrides[id] { return override }
        if suppressedBuiltIns.contains(id) { return .other }
        if let mapped = bundleIDMap[id] { return mapped }
        let lower = id.lowercased()
        if lower.contains("mail") || lower.contains("outlook") { return .email }
        if lower.contains("slack") || lower.contains("teams") { return .workMessages }
        return .other
    }

    /// Category of the current frontmost app, by bundle ID.
    static func frontmostCategory() -> AppCategory {
        category(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}

/// A user-added app→category assignment, persisted in UserDefaults.
struct CustomAppAssignment: Codable, Equatable {
    let bundleID: String
    let name: String
    let category: AppCategory
}

