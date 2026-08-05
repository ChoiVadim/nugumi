import AppKit
import Foundation
import GizmateToolAgentCore

extension GizmateApp {
    var uvIsReady: Bool { uvBootstrap.isReady }

    /// The editor's Install & test: fetch uv if it isn't here yet, then run the
    /// draft script once on whatever the user actually has selected or copied,
    /// and report the real outcome. No approval gate — the user is looking at the
    /// code they just wrote and pressed the button themselves.
    @MainActor
    func testScriptTool(
        _ tool: GizmateTool,
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

        // An `.ask` tool has nothing to test until someone types its input, so
        // the test asks for it exactly as the real run would.
        var typed: String?
        if tool.input.needsPrompt {
            guard let answer = await promptForToolInput(tool) else {
                return .failed("Nothing was typed, so there was nothing to run on.")
            }
            typed = answer
        }
        if tool.input.needsDictation {
            guard let heard = await dictateToolInput() else {
                return .failed("Nothing was heard, so there was nothing to run on.")
            }
            typed = heard
        }

        // A capture tool has nothing to test until the user drags out an area,
        // so the test asks for one — the same drag the real run would.
        var screenshot: ToolScreenshot?
        if tool.input.needsCapture {
            do {
                screenshot = try await captureToolScreenshot(
                    readingText: tool.input == .screenshotText
                )
            } catch {
                guard !ScreenshotTranslationError.isCancellation(error) else {
                    return .failed("The capture was cancelled, so there was nothing to run on.")
                }
                return .failed(error.localizedDescription)
            }
        }
        defer {
            screenshot.map { try? FileManager.default.removeItem(at: $0.imageURL) }
        }

        let context = ToolContext.current(selection: typed ?? "", screenshot: screenshot, for: tool.input)
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
    /// typed candidate, asks Gizmate to validate that kind, repairs failures, and
    /// finishes only the exact attested candidate.
    ///
    /// Runs on the Ask model and its thinking level, not the text-actions one.
    /// Text actions are chosen for turning a sentence around quickly and
    /// cheaply; building a tool is a multi-turn session that writes code and
    /// has to read a stack trace and repair it, which is the same kind of work
    /// Ask is picked for. The readiness check below has to name that model too,
    /// or the build fails on a model nobody was going to use.
    @MainActor
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest = { _ in false }
    ) async -> Result<GeneratedTool, Error> {
        if let setupError = translationErrorIfBootstrapNeedsSetup(for: askGizmateModelID) {
            return .failure(setupError)
        }
        guard let uv = await uvForBuilding(onPartial: onPartial) else {
            return .failure(ToolRunError.uvMissing)
        }
        do {
            let generated = try await ToolAgentLiveBuilder.build(
                description: description,
                backend: askBackend,
                thinkingLevel: askGizmateThinkingLevel,
                uv: uv,
                onStatus: onPartial,
                clarification: clarification,
                clarificationCancellation: clarificationCancellation,
                secretRequest: secretRequest
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
        tool: GizmateTool,
        script: String,
        instruction: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest = { _ in false }
    ) async -> Result<GeneratedTool, Error> {
        if let setupError = translationErrorIfBootstrapNeedsSetup(for: askGizmateModelID) {
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
                backend: askBackend,
                thinkingLevel: askGizmateThinkingLevel,
                uv: uv,
                onStatus: onPartial,
                clarification: clarification,
                clarificationCancellation: clarificationCancellation,
                secretRequest: secretRequest
            ))
        } catch {
            return .failure(error)
        }
    }

    /// Pi receives the exact failed-test report and may repair the complete tool,
    /// not only Python source. Its replacement must pass the normal agent gate.
    @MainActor
    func repairScriptTool(
        tool: GizmateTool,
        script: String,
        failure: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void,
        secretRequest: @escaping ToolAgentLiveBuilder.SecretRequest = { _ in false }
    ) async -> Result<GeneratedTool, Error> {
        if let setupError = translationErrorIfBootstrapNeedsSetup(for: askGizmateModelID) {
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
                backend: askBackend,
                thinkingLevel: askGizmateThinkingLevel,
                uv: uv,
                onStatus: onPartial,
                clarification: clarification,
                clarificationCancellation: clarificationCancellation,
                secretRequest: secretRequest
            )
            return .success(fixed)
        } catch {
            return .failure(error)
        }
    }

    /// Runs a `.native` tool. No approval gate and no runtime: the action comes
    /// from a closed catalog, so there is no arbitrary code to review.
    @MainActor
    func runNativeTool(_ tool: GizmateTool, selection: String) {
        let context = ToolContext.current(selection: selection, for: tool.input)
        // Captured strongly: a `.saveToNote` run that outlives the app delegate
        // must still land the note, and the store is what owns it.
        let notes = notesStore
        Task { @MainActor [weak self] in
            do {
                let result = try await NativeToolRunner.run(tool, context: context, notes: notes)
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
                case .notes where result.text != nil:
                    self.keepNote(result.text ?? "", title: tool.name, tagID: self.gizmoNoteTagID)
                case .speak where result.text != nil:
                    SpeechOut.speak(result.text ?? "")
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
    func runScriptTool(
        _ tool: GizmateTool,
        selection: String,
        screenshot: ToolScreenshot? = nil
    ) {
        guard let uv = uvBootstrap.executable else {
            presentSelectionTranslationError(
                ToolRunError.uvMissing.localizedDescription,
                title: tool.name
            )
            presentMainWindow(section: .home)
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

        let context = ToolContext.current(selection: selection, screenshot: screenshot, for: tool.input)
        guard let arguments = context.arguments(for: tool.input) else {
            screenshot.map { try? FileManager.default.removeItem(at: $0.imageURL) }
            presentSelectionTranslationError(
                ToolRunError.noInput(tool.input).localizedDescription ?? "Nothing to work on.",
                title: tool.name
            )
            return
        }

        // The capture is this run's own file. Whatever happens to it — approved,
        // refused, run, failed — it goes away with the run.
        let temporaryFiles = screenshot.map { [$0.imageURL] } ?? []
        let hash = toolsStore.approvalHash(for: tool)
        guard ToolApprovals.isApproved(tool.id, hash: hash)
            || presentScriptApproval(tool, script: script, hash: hash) else {
            temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        execute(
            tool,
            script: script,
            arguments: arguments,
            uv: uv,
            temporaryFiles: temporaryFiles
        )
    }

    /// Runs a `.agent` tool. Same three gates as a script tool — uv, an input,
    /// an approval — but the approval is of a very different thing, so it has its
    /// own dialog.
    @MainActor
    func runAgentTool(
        _ tool: GizmateTool,
        selection: String,
        screenshot: ToolScreenshot? = nil
    ) {
        guard let uv = uvBootstrap.executable else {
            presentSelectionTranslationError(
                ToolRunError.uvMissing.localizedDescription,
                title: tool.name
            )
            presentMainWindow(section: .home)
            return
        }
        if let setupError = translationErrorIfBootstrapNeedsSetup(for: askGizmateModelID) {
            handleTranslationFailure(setupError)
            return
        }

        let context = ToolContext.current(selection: selection, screenshot: screenshot, for: tool.input)
        guard let arguments = context.arguments(for: tool.input) else {
            screenshot.map { try? FileManager.default.removeItem(at: $0.imageURL) }
            presentSelectionTranslationError(
                ToolRunError.noInput(tool.input).localizedDescription ?? "Nothing to work on.",
                title: tool.name
            )
            return
        }

        let temporaryFiles = screenshot.map { [$0.imageURL] } ?? []
        let hash = toolsStore.approvalHash(for: tool)
        guard ToolApprovals.isApproved(tool.id, hash: hash)
            || presentAgentApproval(tool, hash: hash) else {
            temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }

        // Context is folded into the instruction *after* the approval gate, so
        // the hash the user approved stays the hash of what they read. An agent
        // gizmo never passes through a `TranslationMode`, so this is where the
        // blocks the prompt path gets from `systemPrompt` are attached instead.
        var contextualized = tool
        // Resolved before the context blocks are appended, so `{option}` in the
        // user's own instruction is filled in and `{option}` inside a context
        // block — which is not a template — is left alone.
        contextualized.prompt = tool.resolvingOption(tool.prompt)
        contextualized.prompt += TranslationMode.contextSections(
            for: tool,
            targetLanguage: targetLanguage,
            composition: compositionSettings(
                for: .custom(tool),
                appCategory: AppCategoryClassifier.frontmostCategory()
            )
        )

        // A "files" input hands over several paths; the agent gets them one per
        // line, which is what a Python script it writes will split on anyway.
        let input = arguments.joined(separator: "\n")
        // An agent asked to look at a screen used to get only the path to it and
        // a Python interpreter, so it could crop the picture but never see it.
        // The path still goes over in `input` — a script it writes needs one —
        // and now the picture goes to its model too.
        let images = tool.input.isImage
            ? screenshot.flatMap(Self.imageInput(for:)).map { [$0] } ?? []
            : []
        if !images.isEmpty, !LLMModel.option(id: askGizmateModelID).supportsImages {
            presentSelectionTranslationError(
                "\(tool.name) looks at your screen, so it needs a model that can see images. "
                    + "Pick one in Settings.",
                title: tool.name
            )
            temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let loadingBar = showInstantTranslationLoading(near: screenPoint)
        let backend = askBackend
        let thinkingLevel = askGizmateThinkingLevel

        Task { @MainActor [weak self] in
            defer {
                self?.hideInstantTranslationLoading(loadingBar)
                temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            do {
                let answer = try await AgentToolRunner.run(
                    tool: contextualized,
                    input: input,
                    images: images,
                    backend: backend,
                    thinkingLevel: thinkingLevel,
                    uv: uv
                )
                guard let self else { return }
                self.deliver(
                    ToolRunResult(exitCode: 0, stdout: answer, stderr: "", producedFiles: []),
                    for: tool,
                    near: screenPoint
                )
            } catch {
                self?.presentToolFailure(tool, detail: error.localizedDescription)
            }
        }
    }

    /// The agent tool's review gate. Deliberately unlike the script one: there is
    /// no code to show, because none exists yet, and offering a "Show code"
    /// button would imply a review that cannot happen. What the user is agreeing
    /// to is the instruction, the step budget and the keys — which is exactly
    /// what `ToolsStore.approvalHash(for:)` covers, so changing any of them asks
    /// again.
    @MainActor
    private func presentAgentApproval(_ tool: GizmateTool, hash: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Run “\(tool.name)” for the first time?"
        alert.informativeText = [
            tool.brief.isEmpty ? nil : tool.brief,
            "This tool writes and runs its own code, deciding as it goes. Nobody has "
                + "read that code, because it doesn't exist until the tool runs.",
            tool.secretNames.isEmpty
                ? nil
                : "Reads your secrets: \(tool.secretNames.sorted().joined(separator: ", "))",
            "Steps: max \(tool.maxSteps)  ·  Stops after \(tool.timeoutSeconds)s",
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        ToolApprovals.approve(tool.id, hash: hash)
        return true
    }

    /// The review gate. Shown before a script's first run and again whenever its
    /// code changes, because approval is of a specific script, not of a name.
    ///
    /// - Returns: whether the user approved. The sheet is modal, so the caller
    ///   gets the answer in line and can clean up after a refusal.
    @MainActor
    private func presentScriptApproval(
        _ tool: GizmateTool,
        script: String,
        hash: String?
    ) -> Bool {
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
            "It runs code on your Mac with your access — Gizmate doesn't restrict what it can do.",
            // Its own line rather than appended to the row below: handing a
            // script a key is the one thing here the user might refuse over, and
            // it should not be the fourth item in a run-on sentence.
            tool.secretNames.isEmpty
                ? nil
                : "Reads your secrets: \(tool.secretNames.sorted().joined(separator: ", "))",
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
            guard Self.presentCode(script, name: tool.name) else { return false }
        default:
            return false
        }
        ToolApprovals.approve(tool.id, hash: hash)
        return true
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
        _ tool: GizmateTool,
        script: String,
        arguments: [String],
        uv: URL,
        /// Deleted once the run is over, whatever its outcome. A screen capture
        /// belongs to the run that asked for it.
        temporaryFiles: [URL] = []
    ) {
        let screenPoint = NSEvent.mouseLocation
        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        Task { @MainActor [weak self] in
            defer {
                self?.hideInstantTranslationLoading(loadingBar)
                temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            }
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
    private func deliver(_ result: ToolRunResult, for tool: GizmateTool, near screenPoint: NSPoint) {
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
        case .notes:
            let text = result.text
            guard !text.isEmpty else {
                ToastHUD.shared.show(text: "\(tool.name) — no output")
                return
            }
            // Titled with the gizmo rather than the answer's first line: a list
            // of notes all called "Summary" is unreadable, "Summarize page" is not.
            keepNote(text, title: tool.name, tagID: gizmoNoteTagID)
        case .speak:
            let text = result.text
            guard !text.isEmpty else {
                ToastHUD.shared.show(text: "\(tool.name) — no output")
                return
            }
            SpeechOut.speak(text)
        case .annotate:
            // A script or agent never captured a screen of its own, so the
            // shapes land on the one the user is looking at.
            let frame = NSScreen.screens.first { $0.frame.contains(screenPoint) }?.frame
                ?? NSScreen.main?.frame
                ?? .zero
            presentGizmoAnnotations(result.text, screenFrame: frame, toolName: tool.name)
        case .surface:
            // A surface has no result to deliver; its rows are already on the
            // edge, so toasting the run itself would report an answer that is
            // not one. But this run is very likely the one that just approved
            // the script — `SurfaceRefresh.outcome` cannot run an unapproved
            // surface at all, so "run it once from the ring, or test it from
            // its editor in Home" (its own failure message) is the only route
            // in, and the hover trigger that runs it from here on has nowhere
            // to put a "this worked" message. This toast is that
            // confirmation, and it names whatever is still missing — an edge
            // — since "it worked" is not true yet for a gizmo nothing will
            // ever open. Points at Edges, not Home: edge placement is Edges'
            // screen now (Task 3), and sending someone to Home to do a thing
            // Home no longer does is the exact failure the navigation
            // restructure exists to remove.
            let placed = dockStore.edge(of: ToolRef.generated(tool.id).storageID) != nil
            ToastHUD.shared.show(
                text: placed
                    ? "\(tool.name) — ready on its edge"
                    : "\(tool.name) — approved. Pick an edge for it in Edges."
            )
        }
    }

    @MainActor
    private func presentToolFailure(_ tool: GizmateTool, detail: String) {
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
