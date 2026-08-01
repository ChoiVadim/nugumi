import AppKit
import Foundation

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

    var displayName: String {
        switch self {
        case .openApp: return "Open app"
        case .openAppFullScreen: return "Open fullscreen"
        case .sendTextToApp: return "Send text to app"
        case .revealInFinder: return "Show in Finder"
        case .openURL: return "Open a link"
        case .runShortcut: return "Run a Shortcut"
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
        }
    }

    /// What the tool's `target` field holds for this action, and how to label it.
    var targetLabel: String? {
        switch self {
        case .openApp, .openAppFullScreen, .sendTextToApp: return "App"
        case .openURL: return "Link"
        case .runShortcut: return "Shortcut name"
        case .revealInFinder: return nil
        }
    }

    var targetPlaceholder: String {
        switch self {
        case .openApp, .openAppFullScreen, .sendTextToApp: return "Safari"
        case .openURL: return "https://www.google.com/search?q={input}"
        case .runShortcut: return "My Shortcut"
        case .revealInFinder: return ""
        }
    }

    /// Whether the action consumes the tool's input at all.
    var usesInput: Bool {
        switch self {
        case .sendTextToApp, .revealInFinder, .openURL, .runShortcut: return true
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
    case clipboardText
    case clipboardURL
    case files
    /// A screen area the user drags out when the tool runs. The tool receives
    /// the path to the captured PNG.
    case screenshot
    /// The same capture, read by Vision. The tool receives the recognised text,
    /// so it looks exactly like `selection` to the script or prompt.
    case screenshotText
    case none

    var displayName: String {
        switch self {
        case .selection: return "Selected text"
        case .ask: return "Ask me"
        case .clipboardText: return "Clipboard text"
        case .clipboardURL: return "Copied link"
        case .files: return "Copied files"
        case .screenshot: return "Screen area"
        case .screenshotText: return "Text on screen"
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

    var displayName: String {
        switch self {
        case .panel: return "Show panel"
        case .replace: return "Replace text"
        case .clipboard: return "Copy"
        case .files: return "Save files"
        case .notify: return "Notify"
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

    // MARK: .agent
    /// How many scripts a `.agent` tool may run before it has to answer. The
    /// only bound on a tool whose behavior nobody can read in advance, so it is
    /// part of what the user approves.
    var maxSteps: Int
    /// The plain-language request the tool was generated from. Kept so a saved
    /// tool can still be regenerated or repaired later, and empty for a tool the
    /// user wrote by hand.
    var brief: String

    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        symbolName: String = ToolIcons.fallback,
        kind: ToolKind = .prompt,
        input: ToolInput = .selection,
        output: ToolOutput = .panel,
        prompt: String = "",
        appliesTargetLanguage: Bool = true,
        nativeAction: NativeAction = .openApp,
        target: String = "",
        outputDirectory: String? = nil,
        timeoutSeconds: Int = 120,
        declaresNetwork: Bool = false,
        secretNames: [String] = [],
        maxSteps: Int = 8,
        brief: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.kind = kind
        self.input = input
        self.output = output
        self.prompt = prompt
        self.appliesTargetLanguage = appliesTargetLanguage

        self.nativeAction = nativeAction

        self.target = target
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.declaresNetwork = declaresNetwork
        self.secretNames = secretNames
        self.maxSteps = maxSteps

        self.brief = brief
        self.createdAt = createdAt
    }

    /// A prompt tool needs a prompt; a script tool's script lives on disk, so the
    /// store checks that separately via `isRunnable(script:)`.
    var isUsable: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
        case id, name, symbolName, kind, input, output
        case prompt, appliesTargetLanguage
        case nativeAction, target
        case outputDirectory, timeoutSeconds, declaresNetwork, secretNames, brief
        case maxSteps
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
        maxSteps = max(1, min(24, try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8))
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
