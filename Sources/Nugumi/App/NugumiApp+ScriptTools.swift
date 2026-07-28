import AppKit
import Foundation
import NugumiToolAgentCore

extension NugumiApp {
    var uvIsReady: Bool { uvBootstrap.isReady }

    /// The editor's Install & test: fetch uv if it isn't here yet, then run the
    /// draft script once on whatever the user actually has selected or copied,
    /// and report the real outcome. No approval gate — the user is looking at the
    /// code they just wrote and pressed the button themselves.
    @MainActor
    func testScriptTool(
        _ tool: NugumiTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState {
        if !uvBootstrap.isReady {
            onOutput("Installing the uv runtime…\n")
            await uvBootstrap.install()
        }
        guard let uv = uvBootstrap.executable else {
            if case .failed(let detail) = uvBootstrap.status { return .failed(detail) }
            return .failed(ToolRunError.uvMissing.localizedDescription)
        }

        let context = ToolContext.current(selection: "")
        guard let arguments = context.arguments(for: tool.input) else {
            return .failed(
                (ToolRunError.noInput(tool.input).localizedDescription ?? "Nothing to work on.")
                + "\nThe test uses your real input, so give it something to chew on first."
            )
        }

        do {
            let result = try await ToolRunner.run(
                tool: tool,
                script: script,
                arguments: arguments,
                uv: uv,
                onOutput: onOutput
            )
            var lines: [String] = []
            if !result.stdout.isEmpty { lines.append(result.stdout) }
            if !result.stderr.isEmpty { lines.append(result.stderr) }
            if !result.producedFiles.isEmpty {
                lines.append("Produced:\n" + result.producedFiles.map(\.path).joined(separator: "\n"))
            }
            let report = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.isSuccess else {
                return .failed(report.isEmpty ? "Exited with code \(result.exitCode)." : report)
            }
            return .passed(report.isEmpty ? "Ran with no output. Exit code 0." : report)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The agent validates a Python candidate by running it, so uv has to be
    /// here before the build starts rather than at the tool's first use. Fetched
    /// on demand — a user who only ever asks for prompt tools never pays for it,
    /// but by the time the model has written a script it is too late to ask.
    @MainActor
    private func uvForBuilding(
        onPartial: @escaping @Sendable (String) -> Void
    ) async -> URL? {
        if let executable = uvBootstrap.executable { return executable }
        onPartial("Installing the Python runtime…")
        await uvBootstrap.install()
        return uvBootstrap.executable
    }

    /// Pi owns the whole build: it chooses prompt, native, or Python, submits a
    /// typed candidate, asks Gizmo to validate that kind, repairs failures, and
    /// finishes only the exact attested candidate.
    @MainActor
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            return .failure(setupError)
        }
        guard let uv = await uvForBuilding(onPartial: onPartial) else {
            return .failure(ToolRunError.uvMissing)
        }
        do {
            let generated = try await ToolAgentLiveBuilder.build(
                description: description,
                backend: currentBackend,
                thinkingLevel: textThinkingLevel,
                uv: uv,
                onStatus: onPartial,
                clarification: clarification,
                clarificationCancellation: clarificationCancellation
            )
            analyticsClient.track(.toolGenerated, properties: [
                "input": generated.tool.input.rawValue,
                "output": generated.tool.output.rawValue
            ])
            return .success(generated)
        } catch {
            return .failure(error)
        }
    }

    /// Pi amends the whole current tool, validates the replacement by kind, and
    /// returns only the exact attested candidate. The stored identity is retained.
    @MainActor
    func reviseScriptTool(
        tool: NugumiTool,
        script: String,
        instruction: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            return .failure(setupError)
        }
        guard let uv = await uvForBuilding(onPartial: onPartial) else {
            return .failure(ToolRunError.uvMissing)
        }
        do {
            return .success(try await ToolAgentLiveBuilder.revise(
                tool: tool,
                script: script,
                instruction: instruction,
                failure: nil,
                backend: currentBackend,
                thinkingLevel: textThinkingLevel,
                uv: uv,
                onStatus: onPartial,
                clarification: clarification,
                clarificationCancellation: clarificationCancellation
            ))
        } catch {
            return .failure(error)
        }
    }

    /// Pi receives the exact failed-test report and may repair the complete tool,
    /// not only Python source. Its replacement must pass the normal agent gate.
    @MainActor
    func repairScriptTool(
        tool: NugumiTool,
        script: String,
        failure: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            return .failure(setupError)
        }
        guard let uv = await uvForBuilding(onPartial: onPartial) else {
            return .failure(ToolRunError.uvMissing)
        }
        do {
            let fixed = try await ToolAgentLiveBuilder.revise(
                tool: tool,
                script: script,
                instruction: "Repair this tool without changing its intended behavior.",
                failure: failure,
                backend: currentBackend,
                thinkingLevel: textThinkingLevel,
                uv: uv,
                onStatus: onPartial,
                clarification: clarification,
                clarificationCancellation: clarificationCancellation
            )
            return .success(fixed)
        } catch {
            return .failure(error)
        }
    }

    /// Runs a `.native` tool. No approval gate and no runtime: the action comes
    /// from a closed catalog, so there is no arbitrary code to review.
    @MainActor
    func runNativeTool(_ tool: NugumiTool, selection: String) {
        let context = ToolContext.current(selection: selection)
        Task { @MainActor [weak self] in
            do {
                let result = try await NativeToolRunner.run(tool, context: context)
                guard let self else { return }
                switch tool.output {
                case .clipboard where result.text != nil:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text ?? "", forType: .string)
                    ToastHUD.shared.show(text: "\(tool.name) — copied")
                case .replace where result.text != nil:
                    self.lastReplacementSourcePID = NSWorkspace.shared
                        .frontmostApplication?.processIdentifier
                    self.replaceCurrentSelection(with: result.text ?? "")
                default:
                    ToastHUD.shared.show(text: result.message)
                }
            } catch {
                self?.presentSelectionTranslationError(
                    error.localizedDescription,
                    title: tool.name
                )
            }
        }
    }

    /// Runs a `.python` tool. Three gates before anything executes: uv has to be
    /// installed, the context has to satisfy the tool's declared input, and the
    /// user has to have approved this exact script.
    @MainActor
    func runScriptTool(_ tool: NugumiTool, selection: String) {
        guard let uv = uvBootstrap.executable else {
            presentSelectionTranslationError(
                ToolRunError.uvMissing.localizedDescription,
                title: tool.name
            )
            presentMainWindow(section: .ring)
            return
        }
        guard let script = toolsStore.script(for: tool.id),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            presentSelectionTranslationError(
                ToolRunError.scriptMissing.localizedDescription,
                title: tool.name
            )
            return
        }

        let context = ToolContext.current(selection: selection)
        guard let arguments = context.arguments(for: tool.input) else {
            presentSelectionTranslationError(
                ToolRunError.noInput(tool.input).localizedDescription ?? "Nothing to work on.",
                title: tool.name
            )
            return
        }

        let hash = toolsStore.scriptHash(for: tool.id)
        guard ToolApprovals.isApproved(tool.id, hash: hash) else {
            presentScriptApproval(tool, script: script, hash: hash) { [weak self] in
                self?.execute(tool, script: script, arguments: arguments, uv: uv)
            }
            return
        }
        execute(tool, script: script, arguments: arguments, uv: uv)
    }

    /// The review gate. Shown before a script's first run and again whenever its
    /// code changes, because approval is of a specific script, not of a name.
    @MainActor
    private func presentScriptApproval(
        _ tool: NugumiTool,
        script: String,
        hash: String?,
        onApprove: @escaping () -> Void
    ) {
        // Reached only when nobody has run this exact script yet — a tool saved
        // without testing, or one whose file changed on disk. The normal path
        // (generate → Install & test → Save) approves itself and never lands here.
        //
        // Leads with what the tool says it does rather than the source: a wall of
        // Python is not something anyone reads in a modal, and burying the one
        // sentence that matters under it makes the dialog worse than useless.
        // "Show code" is there for when it does matter.
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Run “\(tool.name)” for the first time?"
        alert.informativeText = [
            tool.brief.isEmpty ? nil : tool.brief,
            "It runs code on your Mac with your access — Gizmo doesn't restrict what it can do.",
            "Network: \(tool.declaresNetwork ? "yes" : "not declared")  ·  "
                + "Saves to: \(tool.resolvedOutputDirectory?.lastPathComponent ?? "a temporary folder")  ·  "
                + "Stops after \(tool.timeoutSeconds)s",
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Show code")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertThirdButtonReturn:
            guard Self.presentCode(script, name: tool.name) else { return }
        default:
            return
        }
        ToolApprovals.approve(tool.id, hash: hash)
        onApprove()
    }

    /// The source, for the one person in ten who wants it. Returns whether they
    /// still want to run after reading.
    private static func presentCode(_ script: String, name: String) -> Bool {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
        textView.string = script
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = name
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func execute(
        _ tool: NugumiTool,
        script: String,
        arguments: [String],
        uv: URL
    ) {
        let screenPoint = NSEvent.mouseLocation
        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        Task { @MainActor [weak self] in
            defer { self?.hideInstantTranslationLoading(loadingBar) }
            do {
                let result = try await ToolRunner.run(
                    tool: tool,
                    script: script,
                    arguments: arguments,
                    uv: uv
                )
                guard let self else { return }
                guard result.isSuccess else {
                    self.presentToolFailure(tool, detail: result.stderr.isEmpty
                        ? "The script exited with code \(result.exitCode)."
                        : result.stderr)
                    return
                }
                self.deliver(result, for: tool, near: screenPoint)
            } catch {
                self?.presentToolFailure(tool, detail: error.localizedDescription)
            }
        }
    }

    /// Routes a finished run by the tool's declared output.
    @MainActor
    private func deliver(_ result: ToolRunResult, for tool: NugumiTool, near screenPoint: NSPoint) {
        switch tool.output {
        case .files:
            guard let first = result.producedFiles.first else {
                ToastHUD.shared.show(text: "\(tool.name) — nothing produced")
                return
            }
            let count = result.producedFiles.count
            ToastHUD.shared.show(
                text: count == 1
                    ? "\(tool.name) — \(first.lastPathComponent)"
                    : "\(tool.name) — \(count) files"
            )
            NSWorkspace.shared.activateFileViewerSelecting(result.producedFiles)
        case .clipboard:
            let text = result.text
            guard !text.isEmpty else {
                ToastHUD.shared.show(text: "\(tool.name) — no output")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ToastHUD.shared.show(text: "\(tool.name) — copied")
        case .replace:
            let text = result.text
            guard !text.isEmpty else {
                ToastHUD.shared.show(text: "\(tool.name) — no output")
                return
            }
            lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            replaceCurrentSelection(with: text)
        case .panel:
            let text = result.text
            guard !text.isEmpty else {
                ToastHUD.shared.show(text: "\(tool.name) — no output")
                return
            }
            presentSelectionTranslationError(text, title: tool.name)
        case .notify:
            let text = result.text
            ToastHUD.shared.show(
                text: text.isEmpty ? "\(tool.name) — done" : "\(tool.name) — \(text.prefix(60))"
            )
        }
    }

    @MainActor
    private func presentToolFailure(_ tool: NugumiTool, detail: String) {
        analyticsClient.track(.errorOccurred, properties: [
            "error_type": "script_tool",
            "error_context": "tool_run"
        ])
        // Scripts fail with tracebacks; the last lines carry the actual cause.
        let tail = detail
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(8)
            .joined(separator: "\n")
        presentSelectionTranslationError(
            tail.isEmpty ? "The tool failed with no output." : tail,
            title: "\(tool.name) failed"
        )
    }
}
