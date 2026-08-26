import AppKit
import Foundation

extension GizmateApp {
    /// Runs one of the user's tools. Script tools take their input from the
    /// context snapshot; prompt tools work on the ring's armed selection, and the
    /// quick menu arms its ring with no selection, so an empty `selection` means
    /// "read what's selected now" — the same arrangement the built-in ring
    /// actions use.
    @MainActor
    func runTool(_ tool: GizmateTool, selection: String) {
        guard tool.isUsable else { return }
        if tool.input.needsPrompt {
            askForToolInput(tool)
            return
        }
        if tool.input.needsDictation {
            dictateForToolInput(tool)
            return
        }
        if tool.input.needsDrawing {
            drawForToolInput(tool)
            return
        }
        guard tool.input.needsCapture else {
            dispatch(tool, selection: selection, screenshot: nil)
            return
        }
        // The drag has to happen before anything else can run, and it is the one
        // input the user can walk away from — a cancelled capture is a cancelled
        // tool, not an error worth a dialog.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let shot = try await self.captureToolScreenshot(
                    readingText: tool.input == .screenshotText
                )
                self.dispatch(
                    tool,
                    // From here on a capture tool looks like a selection tool:
                    // prompt and native paths take their one input as text.
                    selection: tool.input == .screenshotText
                        ? shot.text
                        : shot.imageURL.path,
                    screenshot: shot,
                    // `.screenshotText` asked for the words and gets only those.
                    // `.screenshot` asked for the picture, so the picture has to
                    // travel — a path is not an image input, it is a filename.
                    capture: tool.input == .screenshot
                        ? Self.captureForModel(shot)
                        : nil
                )
            } catch {
                guard !ScreenshotTranslationError.isCancellation(error) else { return }
                self.presentScreenshotTranslationError(error)
            }
        }
    }

    /// Runs a `.ask` tool on whatever the user types into the capsule.
    @MainActor
    func askForToolInput(_ tool: GizmateTool) {
        Task { @MainActor [weak self] in
            guard let self, let typed = await self.promptForToolInput(tool) else { return }
            self.dispatch(tool, selection: typed, screenshot: nil)
        }
    }

    /// Runs a `.dictation` tool on whatever the user says into the REC pill.
    @MainActor
    func dictateForToolInput(_ tool: GizmateTool) {
        Task { @MainActor [weak self] in
            guard let self, let heard = await self.dictateToolInput() else { return }
            self.dispatch(tool, selection: heard, screenshot: nil)
        }
    }

    /// Runs a `.drawnScreen` tool on the screen the user just marked up. Esc
    /// returns nil and cancels, like a walked-away capture or capsule.
    @MainActor
    func drawForToolInput(_ tool: GizmateTool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let capture = try await self.captureDrawnScreen() else { return }
                // Scripts and native actions have only ever taken a path; the
                // image itself rides along for the kinds with a model in them.
                let shot = try Self.writeDrawnScreenFile(capture)
                self.dispatch(
                    tool,
                    selection: shot.imageURL.path,
                    screenshot: shot,
                    capture: capture
                )
            } catch {
                guard !ScreenshotTranslationError.isCancellation(error) else { return }
                self.presentScreenshotTranslationError(error)
            }
        }
    }

    /// Borrows the Ask capsule for a `.ask` tool's one input, and returns what
    /// was typed. nil when the capsule was dismissed — an input the user walked
    /// away from is a cancelled tool, not an error worth a dialog, exactly as a
    /// cancelled screen capture is.
    @MainActor
    func promptForToolInput(_ tool: GizmateTool) async -> String? {
        toolPromptController?.close()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var resumed = false
            let finish: (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            let controller = AskPromptController(
                near: NSEvent.mouseLocation,
                placeholder: tool.name,
                onSubmit: { [weak self] typed in
                    // Answered before the capsule closes, because `close()` runs
                    // `onClose` synchronously — the other way round and the
                    // dismissal would resume with nil and eat the answer.
                    finish(typed)
                    self?.toolPromptController?.close()
                },
                onClose: { [weak self] in
                    self?.toolPromptController = nil
                    // The capsule holds focus, and a `.replace` tool has to type
                    // into the app the user came from.
                    SelfActivationGuard.relinquish()
                    finish(nil)
                }
            )
            toolPromptController = controller
            controller.show()
        }
    }

    /// `capture` carries what a path cannot: the image itself, for the kinds
    /// with a model that has to see it, and the screen rect a `.annotate`
    /// result needs to place its shapes on.
    @MainActor
    private func dispatch(
        _ tool: GizmateTool,
        selection: String,
        screenshot: ToolScreenshot?,
        capture: AskGizmateScreenCapture? = nil
    ) {
        // The one funnel every kind of gizmo passes through, whichever way it
        // was started — ring, hotkey, quick menu. Counted here rather than at
        // each `run*` so a new kind can't quietly stop being counted.
        usageStatsStore.recordGizmoRun(name: tool.name)

        switch tool.kind {
        case .python:
            runScriptTool(tool, selection: selection, screenshot: screenshot)
            return
        case .native:
            runNativeTool(tool, selection: selection)
            return
        case .agent:
            runAgentTool(tool, selection: selection, screenshot: screenshot)
            return
        case .prompt:
            break
        }

        // An image gizmo's "selection" is only a path — the model is meant to
        // look at the picture, so run it even though there is no text to work
        // on. Without this it would fall into the no-input error below.
        if tool.input.isImage {
            run(
                tool,
                on: capture == nil ? selection : "",
                near: NSEvent.mouseLocation,
                selectionRect: nil,
                capture: capture
            )
            return
        }

        // A no-input gizmo works over whatever context its prompt carries (the
        // user's notes, its own instruction) — falling through would read the
        // selection and refuse with "Select text first" for a tool that never
        // wanted one. Spelled `ToolInput.none`: a bare `.none` here is
        // `Optional.none` and matches nothing.
        if tool.input == ToolInput.none {
            run(tool, on: "", near: NSEvent.mouseLocation, selectionRect: nil)
            return
        }

        let armed = TextNormalizer.cleanedSelection(selection)
        if !armed.isEmpty {
            run(tool, on: armed, near: NSEvent.mouseLocation, selectionRect: nil)
            return
        }

        // A capture tool has no second source of input. Falling through to the
        // selection read would quietly run it on whatever text happens to be
        // highlighted, which is not what the user just dragged a box around.
        guard !tool.input.needsCapture else {
            presentSelectionTranslationError(
                ToolRunError.noInput(tool.input).localizedDescription
                    ?? "Nothing to work on.",
                title: tool.name
            )
            return
        }

        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionInteractively()
            return
        }
        // Same settle delay the other selection paths use: the ring click has to
        // land before the AX read, or the selection is still in flux.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] context in
                guard let self else { return }
                let text = TextNormalizer.cleanedSelection(context?.text ?? "")
                guard !text.isEmpty else {
                    self.presentSelectionTranslationError("Select text first, then run \(tool.name).")
                    return
                }
                self.run(
                    tool,
                    on: text,
                    near: NSEvent.mouseLocation,
                    selectionRect: context?.selectionRect
                )
            }
        }
    }

    /// Each result mode mirrors the built-in action it behaves like, down to the
    /// language it uses: `.panel` follows Explain (the reading language),
    /// `.replace` follows Rewrite (the writing language).
    @MainActor
    private func run(
        _ tool: GizmateTool,
        on text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        capture: AskGizmateScreenCapture? = nil
    ) {
        // A gizmo that looks at a picture is useless on a model that cannot see
        // one, and the failure is otherwise invisible: the image is dropped and
        // the model answers confidently about nothing.
        if capture != nil, !LLMModel.option(id: textModelID).supportsImages {
            presentSelectionTranslationError(
                "\(tool.name) looks at your screen, so it needs a model that can see images. "
                    + "Pick one in Settings.",
                title: tool.name
            )
            return
        }
        let images = capture.map { [$0.image] } ?? []

        switch tool.output {
        case .panel:
            translateButtonController?.close()
            translateButtonController = nil
            translate(
                text,
                near: screenPoint,
                mode: .custom(tool),
                // The translation cache keys on (text, language, thinking level)
                // and knows nothing about the mode, so caching a tool's answer
                // would serve it for a later plain Explain of the same text.
                useCache: false,
                usageKind: .selection,
                selectionRect: selectionRect,
                panelSide: panelSideForSelectionEnding(at: screenPoint),
                restoresReadyOnUserDismiss: true,
                images: images
            )
        case .replace:
            lastReplacementSourcePID = selectionSourcePID
            runInstantTranslation(
                text,
                language: draftTargetLanguage,
                near: screenPoint,
                mode: .custom(tool),
                images: images
            )
        case .clipboard, .files, .notify, .surface:
            // `.files`, `.notify` and `.surface` are script-tool result modes. A
            // prompt tool only ever produces text, so the nearest honest
            // behavior is to hand that text over.
            runPromptToolForText(tool, on: text, near: screenPoint, images: images) { answer in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
                ToastHUD.shared.show(text: "\(tool.name) — copied")
            }
        case .notes:
            runPromptToolForText(tool, on: text, near: screenPoint, images: images) { [weak self] answer in
                guard let self else { return }
                self.keepNote(answer, title: tool.name, tagID: self.gizmoNoteTagID)
            }
        case .speak:
            runPromptToolForText(tool, on: text, near: screenPoint, images: images) { answer in
                SpeechOut.speak(answer)
            }
        case .annotate:
            // Shapes are placed in fractions of a screen, so they need the rect
            // they were measured against. A gizmo that never captured one is
            // talking about the screen the user is looking at.
            let frame = capture?.screenFrame
                ?? NSScreen.screens.first { $0.frame.contains(screenPoint) }?.frame
                ?? NSScreen.main?.frame
                ?? .zero
            runPromptToolForText(tool, on: text, near: screenPoint, images: images) { [weak self] answer in
                self?.presentGizmoAnnotations(answer, screenFrame: frame, toolName: tool.name)
            }
        }
    }

    /// The result modes that have no panel and nothing to type back: the answer
    /// is fetched and handed to `deliver`. Shaped exactly like
    /// `runInstantTranslation`, minus the replacement.
    @MainActor
    private func runPromptToolForText(
        _ tool: GizmateTool,
        on text: String,
        near screenPoint: NSPoint,
        images: [ImageInput] = [],
        deliver: @escaping @MainActor (String) -> Void
    ) {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            handleTranslationFailure(setupError)
            return
        }
        if let busyError = translationErrorIfBootstrapBusy() {
            presentSelectionTranslationError(
                busyError.localizedDescription,
                title: "Translator is still downloading"
            )
            return
        }

        let mode = TranslationMode.custom(tool)
        let language = targetLanguage
        let thinkingLevel = textThinkingLevel
        let appCategory = AppCategoryClassifier.frontmostCategory()
        let composition = compositionSettings(for: mode, appCategory: appCategory)
        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        let client = currentBackend
        Task { [weak self] in
            do {
                let answer = try await client.translate(
                    text,
                    images: images,
                    to: language,
                    mode: mode,
                    composition: composition,
                    thinkingLevel: thinkingLevel
                ) { _ in }
                await MainActor.run {
                    guard let self else { return }
                    self.hideInstantTranslationLoading(loadingBar)
                    let cleaned = TextNormalizer.cleanedTranslation(answer)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError(
                            "The model returned nothing.",
                            title: tool.name
                        )
                        return
                    }
                    deliver(cleaned)
                    self.recordTranslation(
                        source: text,
                        result: cleaned,
                        kind: .selection,
                        targetLanguage: language
                    )
                    self.analyticsClient.trackCompletedUsage(
                        kind: .selection,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.hideInstantTranslationLoading(loadingBar)
                    guard !self.handleTranslationFailure(error) else { return }
                    self.analyticsClient.track(.errorOccurred, properties: [
                        "error_type": Self.analyticsErrorType(error),
                        "error_context": "prompt_tool_clipboard"
                    ])
                    self.presentSelectionTranslationError(
                        error.localizedDescription,
                        title: "\(tool.name) failed"
                    )
                }
            }
        }
    }
}
