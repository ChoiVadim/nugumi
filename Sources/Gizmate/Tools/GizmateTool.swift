import AppKit
import Foundation
import GizmateToolAgentCore

/// How a tool does its work.
enum ToolKind: String, Codable, CaseIterable {
    /// One system prompt run over text by the current model. No code.
    case prompt
    /// A parameterized macOS action from a fixed catalog. No code, no runtime,
    /// no extra permissions beyond what Gizmate already holds — and instant,
    /// where the same job in Python costs a uv start plus an interpreter boot.
    case native
    /// A self-contained PEP 723 Python script run through `uv`.
    case python
    /// An instruction carried out by an agent that decides as it goes, writing
    /// and running Python until it has an answer. The only kind whose behavior
    /// is not fixed before it runs — which is the point, and the risk.
    case agent

    var displayName: String {
        switch self {
        case .prompt: return "Prompt"
        case .native: return "Action"
        case .python: return "Script"
        case .agent: return "Agent"
        }
    }
}

/// The macOS actions a `.native` tool can perform. A closed set on purpose: the
/// point of this kind is that nothing arbitrary executes.
enum NativeAction: String, Codable, CaseIterable {
    case openApp
    case openAppFullScreen
    case sendTextToApp
    case revealInFinder
    case openURL
    case runShortcut
    case saveToNote

    var displayName: String {
        switch self {
        case .openApp: return "Open app"
        case .openAppFullScreen: return "Open fullscreen"
        case .sendTextToApp: return "Send text to app"
        case .revealInFinder: return "Show in Finder"
        case .openURL: return "Open a link"
        case .runShortcut: return "Run a Shortcut"
        case .saveToNote: return "Save to notes"
        }
    }

    var explanation: String {
        switch self {
        case .openApp:
            return "Brings the app to the front, launching it if it isn't running."
        case .openAppFullScreen:
            return "Opens the app and puts its front window into full screen."
        case .sendTextToApp:
            return "Focuses the app and pastes the tool's input into it."
        case .revealInFinder:
            return "Opens a Finder window with the input files selected."
        case .openURL:
            return "Opens a link in your browser. Use {input} where the input goes."
        case .runShortcut:
            return "Runs one of your Shortcuts, handing it the input."
        case .saveToNote:
            return "Keeps the input as a new note in the Notes tab."
        }
    }

    /// What the tool's `target` field holds for this action, and how to label it.
    var targetLabel: String? {
        switch self {
        case .openApp, .openAppFullScreen, .sendTextToApp: return "App"
        case .openURL: return "Link"
        case .runShortcut: return "Shortcut name"
        case .revealInFinder, .saveToNote: return nil
        }
    }

    var targetPlaceholder: String {
        switch self {
        case .openApp, .openAppFullScreen, .sendTextToApp: return "Safari"
        case .openURL: return "https://www.google.com/search?q={input}"
        case .runShortcut: return "My Shortcut"
        case .revealInFinder, .saveToNote: return ""
        }
    }

    /// Whether the action consumes the tool's input at all.
    var usesInput: Bool {
        switch self {
        case .sendTextToApp, .revealInFinder, .openURL, .runShortcut, .saveToNote: return true
        case .openApp, .openAppFullScreen: return false
        }
    }
}

/// What the tool is handed when it runs.
enum ToolInput: String, Codable, CaseIterable {
    case selection
    /// Text the user types into the Ask capsule when the tool runs. The tool
    /// receives exactly what was typed and nothing else — the same one argument
    /// `selection` gives it, so nothing downstream has to know the difference.
    case ask
    /// The same one argument again, spoken instead of typed: the mic runs while
    /// the tool waits, and the tool is handed the transcript. Nothing
    /// downstream can tell it from a selection either.
    case dictation
    /// What Finder has selected, or what was copied out of it when Automation
    /// access was declined. One argument per file.
    case files
    /// A screen area the user drags out when the tool runs. The tool receives
    /// the path to the captured PNG.
    case screenshot
    /// The same capture, read by Vision. The tool receives the recognised text,
    /// so it looks exactly like `selection` to the script or prompt.
    case screenshotText
    /// The whole screen with the user's own red marks burned into it — Ask's
    /// drawing overlay without the prompt field. Draw, press Return, and the
    /// gizmo is handed the marked-up image.
    case drawnScreen
    case none

    var displayName: String {
        switch self {
        case .selection: return "Selected text"
        case .ask: return "Ask me"
        case .dictation: return "Spoken text"
        case .files: return "Selected files"
        case .screenshot: return "Screen area"
        case .screenshotText: return "Text on screen"
        case .drawnScreen: return "Screen you mark up"
        case .none: return "Nothing"
        }
    }

    /// Every other input is already sitting in the system when the ring opens.
    /// These two have to be taken, which is why they are resolved at run time
    /// rather than read off `ToolContext`'s snapshot.
    var needsCapture: Bool {
        self == .screenshot || self == .screenshotText
    }

    /// Same story as `needsCapture`, with a text field instead of a drag: the
    /// input doesn't exist until the tool runs and the user types it.
    var needsPrompt: Bool {
        self == .ask
    }

    /// And once more with the mic: same slot, same "doesn't exist until the tool
    /// runs", a REC pill instead of a field.
    var needsDictation: Bool {
        self == .dictation
    }

    /// Same slot again, with a canvas: the screen is captured, the user draws
    /// on it, and Return hands the result over. Deliberately not folded into
    /// `needsCapture` — that one drags out a region and returns immediately,
    /// this one waits on a keystroke.
    var needsDrawing: Bool {
        self == .drawnScreen
    }

    /// Whether what the gizmo is handed is a picture rather than text. The
    /// model has to be able to see, and the prompt paths have to carry the
    /// image rather than a path to it.
    var isImage: Bool {
        self == .screenshot || self == .drawnScreen
    }

    /// Whether building this tool's context should go looking for files. Gated
    /// because the lookup asks Finder over an Apple event, and a gizmo that
    /// never wanted files must not make the user answer for that.
    var needsFiles: Bool {
        self == .files
    }

    /// Gizmos that predate an input being retired keep working instead of
    /// disappearing: `ToolsStore` decodes each tool with `try?`, so one unknown
    /// string would delete a gizmo the user built. The clipboard inputs were
    /// text and a link, and selected text is the closest surviving thing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolInput(rawValue: raw) ?? .selection
    }
}

/// Where the tool's result goes.
enum ToolOutput: String, Codable, CaseIterable {
    /// The usual result panel, with the language selector and follow-up field.
    case panel
    /// Types the answer straight back over the selection, no panel.
    case replace
    /// Copies the answer to the clipboard and says so in a toast.
    case clipboard
    /// Whatever the script wrote is moved into the tool's output directory.
    case files
    /// Just a toast — for tools whose point is the side effect.
    case notify
    /// Keeps the answer as a new note, titled with the gizmo's name.
    case notes
    /// Reads the answer out loud. See `SpeechOut`.
    case speak
    /// The model draws over the screen instead of writing: the same shapes Ask
    /// renders, with no panel behind them.
    case annotate
    /// Not a result at all: the gizmo renders rows its script prints into an
    /// edge dock, and keeps doing so with no run to speak of.
    case surface

    var displayName: String {
        switch self {
        case .panel: return "Show panel"
        case .replace: return "Replace text"
        case .clipboard: return "Copy"
        case .files: return "Save files"
        case .notify: return "Notify"
        case .notes: return "Save to notes"
        case .speak: return "Read aloud"
        case .annotate: return "Draw on screen"
        case .surface: return "Screen edge"
        }
    }

    var explanation: String {
        switch self {
        case .panel:
            return "Opens the result panel, where you can revise the answer or copy it."
        case .replace:
            return "Types the answer over your selection, like Rewrite does."
        case .clipboard:
            return "Puts the answer on the clipboard without showing a panel."
        case .files:
            return "Moves whatever the script produced into the folder below."
        case .notify:
            return "Shows a short confirmation and nothing else."
        case .notes:
            return "Keeps the answer as a new note, ready to read in the Notes tab."
        case .speak:
            return "Says the answer out loud instead of showing it."
        case .annotate:
            return "Circles and points at things on your screen. Needs a gizmo that can see it."
        case .surface:
            return "Sits on a screen edge showing whatever the script lists, "
                + "with files you can drag straight into another app."
        }
    }
}

/// A user-authored ring action.
///
/// Deliberately one flat struct with a `kind` rather than an enum carrying
/// per-kind payloads: the generator has to emit this as JSON, and a flat schema
/// is far easier for a model to produce and for the format to grow. Fields that
/// don't apply to a kind are simply ignored — `prompt` for `.python`,
/// `timeoutSeconds` for `.prompt`.
///
/// A `.python` tool's script is NOT in here; it lives beside `tool.json` as
/// `main.py` (see `ToolsStore`), so it stays readable and editable as a file.
struct GizmateTool: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// SF Symbol from `ToolIcons.curated`. Built-in ring actions keep their
    /// bundled Phosphor glyphs; user tools draw from SF Symbols.
    var symbolName: String
    var kind: ToolKind
    var input: ToolInput
    var output: ToolOutput
    /// Variants this gizmo offers. In the Ring its button expands into one
    /// circle per option — the same second layer Summarize's time ranges use.
    /// The label IS the value: "720p" is both what the button says and what the
    /// gizmo is handed. Empty for a gizmo that does one thing.
    var options: [String]
    /// Which option this run picked. Deliberately absent from `CodingKeys`: it
    /// belongs to a run, not to the saved gizmo. A gizmo that remembered the
    /// last button pressed would be a setting nobody asked for.
    var chosenOption: String?

    // MARK: .prompt
    var prompt: String
    /// Appends "Write the output in <target language>." to the prompt. Right for
    /// rewriting and explaining; wrong for language-agnostic transforms (text →
    /// JSON, extract the dates), where a language instruction corrupts the output.
    var appliesTargetLanguage: Bool

    // MARK: .native
    var nativeAction: NativeAction
    /// The action's one parameter: an app name, a link template, or a Shortcut
    /// name. Empty for actions that don't take one.
    var target: String

    // MARK: .python
    /// Where `.files` output lands, as a tilde path. nil keeps it in the run's
    /// temp directory (useful while testing).
    var outputDirectory: String?
    var timeoutSeconds: Int
    /// The script says it needs network access. Shown to the user as a heads-up,
    /// NOT enforced — see `ToolRunner`'s note on the security posture.
    var declaresNetwork: Bool
    /// Which of the user's stored secrets this tool is handed, as environment
    /// variables. Declared rather than ambient: a tool that never says it wants
    /// `OPENAI_API_KEY` never sees it, so one leaky script is not every key.
    /// Part of the approval hash — see `ToolsStore.scriptHash(for:)`.
    var secretNames: [String]
    /// What a `.surface` gizmo draws. nil for every other result.
    var layout: ToolAgentLayoutV1?
    /// How often a `.surface` gizmo re-runs while its panel is on screen, in
    /// seconds. nil is the default and means what surfaces have always done:
    /// one refresh per reveal. Set by the builder only for gizmos whose data
    /// goes stale on its own (a system monitor, a download queue) — a folder
    /// listing has no business re-running on a clock. The host clamps it and
    /// never refreshes an unrevealed panel, so this is a cadence, not a
    /// background poller.
    var refreshSeconds: Int?

    // MARK: .agent
    /// How many scripts a `.agent` tool may run before it has to answer. The
    /// only bound on a tool whose behavior nobody can read in advance, so it is
    /// part of what the user approves.
    var maxSteps: Int
    /// The plain-language request the tool was generated from. Kept so a saved
    /// tool can still be regenerated or repaired later, and empty for a tool the
    /// user wrote by hand.
    var brief: String

    // MARK: Context
    //
    // Both default to off. `.native` ignores both: a macOS action has nothing
    // to hand context to.

    /// Hands the gizmo the user's Voice settings — writing register,
    /// level, dictionary and snippets. Off by default because a gizmo's own
    /// prompt is authoritative: layering a register directive over "turn this
    /// into JSON" corrupts the output rather than styling it. `.prompt` and
    /// `.agent` only; a script has no model to style.
    var usesVoice: Bool
    /// Hands the gizmo the notes ticked in the Notes tab (see `NotesContext`):
    /// as prompt text for `.prompt` and `.agent`, as the JSON file named in
    /// `GIZMO_NOTES_FILE` for `.python`.
    var usesNotes: Bool

    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        symbolName: String = ToolIcons.fallback,
        kind: ToolKind = .prompt,
        input: ToolInput = .selection,
        output: ToolOutput = .panel,
        options: [String] = [],
        prompt: String = "",
        appliesTargetLanguage: Bool = true,
        nativeAction: NativeAction = .openApp,
        target: String = "",
        outputDirectory: String? = nil,
        timeoutSeconds: Int = 120,
        declaresNetwork: Bool = false,
        secretNames: [String] = [],
        layout: ToolAgentLayoutV1? = nil,
        refreshSeconds: Int? = nil,
        maxSteps: Int = 8,
        brief: String = "",
        usesVoice: Bool = false,
        usesNotes: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.kind = kind
        self.input = input
        self.output = output
        self.options = Self.sanitizedOptions(options)
        self.prompt = prompt
        self.appliesTargetLanguage = appliesTargetLanguage

        self.nativeAction = nativeAction

        self.target = target
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.declaresNetwork = declaresNetwork
        self.secretNames = secretNames
        self.layout = layout
        self.refreshSeconds = refreshSeconds.map(Self.clampedRefreshSeconds)
        self.maxSteps = maxSteps

        self.brief = brief
        self.usesVoice = usesVoice
        self.usesNotes = usesNotes
        self.createdAt = createdAt
    }

    /// A prompt tool needs a prompt; a script tool's script lives on disk, so the
    /// store checks that separately via `isRunnable(script:)`.
    var isUsable: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A surface with nothing to draw is worse than one the dock never
        // offers: it would dock cleanly and then sit empty forever.
        if output == .surface, layout == nil { return false }
        switch kind {
        // An agent tool is its instruction: there is nothing else to run.
        case .prompt, .agent:
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .native:
            guard nativeAction.targetLabel != nil else { return true }
            return !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .python:
            return true
        }
    }

    /// The saved symbol, or the fallback when a name no longer resolves on this OS.
    var resolvedSymbolName: String {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
            ? symbolName
            : ToolIcons.fallback
    }

    /// Expanded `outputDirectory`, or nil to leave results in the run directory.
    var resolvedOutputDirectory: URL? {
        guard let outputDirectory, !outputDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
    }

    // Lenient decoding, same reasoning as `Snippet`: a field added in a later
    // version must not throw away every tool the user already saved.
    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, kind, input, output, options
        case prompt, appliesTargetLanguage
        case nativeAction, target
        case outputDirectory, timeoutSeconds, declaresNetwork, secretNames, brief
        case layout
        case refreshSeconds
        case maxSteps
        case usesVoice, usesNotes
        case createdAt
    }

    /// `output` was called `result` in the first prompt-tools release. Kept in its
    /// own key set so the encoder stays synthesized — a `CodingKeys` case with no
    /// matching property blocks `Encodable` synthesis.
    private enum LegacyCodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? ToolIcons.fallback
        kind = try c.decodeIfPresent(ToolKind.self, forKey: .kind) ?? .prompt
        input = try c.decodeIfPresent(ToolInput.self, forKey: .input) ?? .selection
        let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self)
        output = try c.decodeIfPresent(ToolOutput.self, forKey: .output)
            ?? legacy?.decodeIfPresent(ToolOutput.self, forKey: .result)
            ?? .panel
        options = Self.sanitizedOptions(
            try c.decodeIfPresent([String].self, forKey: .options) ?? []
        )
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        appliesTargetLanguage = try c.decodeIfPresent(Bool.self, forKey: .appliesTargetLanguage) ?? true
        nativeAction = try c.decodeIfPresent(NativeAction.self, forKey: .nativeAction) ?? .openApp
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 120
        declaresNetwork = try c.decodeIfPresent(Bool.self, forKey: .declaresNetwork) ?? false
        // Filtered on the way in, not just on the way out: a manifest is a file
        // on disk and `ToolSecrets` resolves these straight into a path.
        secretNames = (try c.decodeIfPresent([String].self, forKey: .secretNames) ?? [])
            .filter(ToolSecrets.isValidName)
        // Lenient for the same reason the rest of this initialiser is: a
        // layout written by a newer build must cost the user this gizmo's
        // surface, not the gizmo.
        layout = try? c.decodeIfPresent(ToolAgentLayoutV1.self, forKey: .layout)
        refreshSeconds = (try? c.decodeIfPresent(Int.self, forKey: .refreshSeconds))
            .flatMap { $0 }.map(Self.clampedRefreshSeconds)
        maxSteps = max(1, min(24, try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8))
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        // Absent in every gizmo saved before this existed, and false is what
        // those gizmos have always behaved like.
        usesVoice = try c.decodeIfPresent(Bool.self, forKey: .usesVoice) ?? false
        usesNotes = try c.decodeIfPresent(Bool.self, forKey: .usesNotes) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The option in force for this run: what the Ring picked, or the first one
    /// for a run started from a hotkey or the quick menu, which never offered a
    /// choice. nil for a gizmo with no options.
    var activeOption: String? { chosenOption ?? options.first }

    /// `template` with `{option}` filled in. A gizmo with no options gets its
    /// template back untouched, so an author who typed `{option}` by mistake
    /// sees the literal rather than an empty hole.
    func resolvingOption(_ template: String) -> String {
        guard let activeOption else { return template }
        return template.replacingOccurrences(of: "{option}", with: activeOption)
    }

    /// Trimmed, de-duplicated and capped at five — more than that stops fanning
    /// cleanly at the outer orbit. Fewer than two is dropped entirely: a
    /// one-circle sub-orbit is a worse button than the one it replaced. The
    /// 64-byte ceiling mirrors the builder protocol's own bound: a gizmo the
    /// store accepts but `ToolAgentInstalledToolV1` rejects would throw on the
    /// way into an edit session, so the user asks to rename a gizmo and gets an
    /// error instead. Written as a literal rather than imported, because the
    /// app's data model does not depend on the builder protocol.
    static func sanitizedOptions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        let cleaned = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.utf8.count <= 64 && seen.insert($0).inserted }
            .prefix(5)
        return cleaned.count < 2 ? [] : Array(cleaned)
    }

    /// The host's bounds on a surface cadence. Every tick spawns a `uv` +
    /// Python process, so nothing faster than every second no matter what the
    /// builder wrote — and since the loop awaits the run before sleeping, the
    /// real floor is the script's own duration anyway. Above an hour the field
    /// is indistinguishable from "once per reveal", which nil already means.
    static func clampedRefreshSeconds(_ value: Int) -> Int {
        max(1, min(3600, value))
    }
}
