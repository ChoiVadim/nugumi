import AppKit
import ApplicationServices
import Foundation

enum NativeToolError: LocalizedError {
    case missingTarget(NativeAction)
    case appNotFound(String)
    case noWindow(String)
    case badURL(String)
    case shortcutFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTarget(let action):
            return "This tool needs a \(action.targetLabel?.lowercased() ?? "target")."
        case .appNotFound(let name):
            return "Couldn't find an app called “\(name)”."
        case .noWindow(let name):
            return "\(name) didn't open a window to put into full screen."
        case .badURL(let raw):
            return "That isn't a link Gizmate can open: \(raw)"
        case .shortcutFailed(let detail):
            return detail.isEmpty ? "The Shortcut failed." : detail
        }
    }
}

/// Runs the fixed catalog of macOS actions behind `ToolKind.native`.
///
/// Everything here is either an AppKit call or one short-lived system binary, so
/// an action lands in milliseconds where the same job as a Python script costs a
/// uv start plus an interpreter boot. It also needs no permission Gizmate doesn't
/// already hold: pasting reuses `PasteboardTextInserter`, which rides the same
/// Accessibility grant the selection reader asks for at launch.
@MainActor
enum NativeToolRunner {
    /// What the action produced, if anything, for `ToolOutput` routing.
    struct Result {
        var message: String
        var text: String?
        var files: [URL] = []
    }

    /// - Parameter notes: the store `.saveToNote` writes into. Passed rather
    ///   than reached for globally so the action stays in this catalog with the
    ///   rest of them instead of being special-cased at the call site.
    static func run(
        _ tool: GizmateTool,
        context: ToolContext,
        notes: NotesStore
    ) async throws -> Result {
        // `{option}` is resolved here, once, so every action below sees a
        // finished target — `openURL` percent-encodes only the `{input}` it
        // substitutes afterwards, and `runShortcut` never substitutes at all.
        let target = tool.resolvingOption(tool.target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tool.nativeAction.targetLabel != nil, target.isEmpty {
            throw NativeToolError.missingTarget(tool.nativeAction)
        }
        let arguments = context.arguments(for: tool.input) ?? []

        switch tool.nativeAction {
        case .openApp:
            let app = try await activate(target)
            return Result(message: "Opened \(app)")

        case .openAppFullScreen:
            let app = try await activate(target)
            try await enterFullScreen(app: app)
            return Result(message: "\(app) — full screen")

        case .sendTextToApp:
            guard let text = arguments.first, !text.isEmpty else {
                throw ToolRunError.noInput(tool.input)
            }
            let app = try await activate(target)
            // Give the app a beat to take focus before the paste lands; the
            // keystroke goes to whatever is frontmost at that instant.
            try? await Task.sleep(nanoseconds: 600_000_000)
            PasteboardTextInserter.replaceCurrentSelection(with: text)
            return Result(message: "Sent to \(app)")

        case .revealInFinder:
            guard !context.files.isEmpty else {
                throw ToolRunError.noInput(.files)
            }
            NSWorkspace.shared.activateFileViewerSelecting(context.files)
            return Result(
                message: "Showing \(context.files.count) in Finder",
                text: nil,
                files: context.files
            )

        case .openURL:
            let filled = substitute(arguments.first ?? "", into: target)
            guard let url = URL(string: filled), url.scheme != nil else {
                throw NativeToolError.badURL(filled)
            }
            NSWorkspace.shared.open(url)
            return Result(message: "Opened \(url.host() ?? filled)")

        case .runShortcut:
            let output = try await runShortcut(named: target, input: arguments.first)
            return Result(
                message: output.isEmpty ? "Ran \(target)" : "\(target) — done",
                text: output.isEmpty ? nil : output
            )

        case .saveToNote:
            guard let text = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                throw ToolRunError.noInput(tool.input)
            }
            // No title: the user is mid-flow in another app and has nothing to
            // type one into. `Note.displayTitle` stands the first line up as one,
            // and the Notes tab is where a real title gets added if it's wanted.
            // Filed under the fixed "Other" tag, or untagged once the user has
            // deleted it — a gizmo runs unattended and has nobody to ask.
            notes.add(text: text, tagID: notes.tag(NoteTag.otherID)?.id)
            // No `text` on the way out: saving is the whole point of the action,
            // so every output mode collapses to the toast rather than pasting
            // the note back over the selection it came from.
            return Result(message: "Saved to notes")
        }
    }

    // MARK: - Apps

    /// Launches or focuses the app and returns its display name. `open -a` does
    /// the name resolution (fuzzy matching, `.app` suffixes, bundle ids) that no
    /// single NSWorkspace call covers, and costs a few tens of milliseconds.
    @discardableResult
    private static func activate(_ nameOrBundleID: String) async throws -> String {
        if nameOrBundleID.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: nameOrBundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return url.deletingPathExtension().lastPathComponent
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", nameOrBundleID]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw NativeToolError.appNotFound(nameOrBundleID)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeToolError.appNotFound(nameOrBundleID)
        }
        return nameOrBundleID
    }

    /// Sets `AXFullScreen` on the app's front window, polling briefly because a
    /// just-launched app has no window yet.
    private static func enterFullScreen(app name: String) async throws {
        for _ in 0..<20 {
            if let running = runningApplication(named: name),
               let window = frontWindow(of: running.processIdentifier) {
                AXUIElementSetAttributeValue(
                    window,
                    "AXFullScreen" as CFString,
                    kCFBooleanTrue
                )
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NativeToolError.noWindow(name)
    }

    private static func runningApplication(named name: String) -> NSRunningApplication? {
        let wanted = name.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == wanted
                || $0.bundleIdentifier?.lowercased() == wanted
        }
    }

    private static func frontWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() {
            return (window as! AXUIElement)
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement], let first = list.first
        else { return nil }
        return first
    }

    // MARK: - Shortcuts

    /// `shortcuts run <name> [-i file] [-o file]`. Text input goes through a temp
    /// file because the CLI takes a path, not stdin.
    private static func runShortcut(named name: String, input: String?) async throws -> String {
        let scratch = try GizmatePaths.makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var arguments = ["run", name]
        if let input, !input.isEmpty {
            let inputURL = scratch.appending(path: "input.txt", directoryHint: .notDirectory)
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
            arguments += ["--input-path", inputURL.path]
        }
        let outputURL = scratch.appending(path: "output", directoryHint: .notDirectory)
        arguments += ["--output-path", outputURL.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw NativeToolError.shortcutFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NativeToolError.shortcutFailed(detail)
        }
        return (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Templates

    /// Replaces `{input}` in a link template, percent-encoding the value so a
    /// search query with spaces still produces a valid URL.
    private static func substitute(_ value: String, into template: String) -> String {
        guard template.contains("{input}") else { return template }
        let encoded = value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? value
        return template.replacingOccurrences(of: "{input}", with: encoded)
    }
}
