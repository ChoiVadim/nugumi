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
                    screenshot: shot
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

    @MainActor
    private func dispatch(
        _ tool: GizmateTool,
        selection: String,
        screenshot: ToolScreenshot?
    ) {
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
        selectionRect: NSRect?
    ) {
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
                restoresReadyOnUserDismiss: true
            )
        case .replace:
            lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            runInstantTranslation(
                text,
                language: draftTargetLanguage,
                near: screenPoint,
                mode: .custom(tool)
            )
        case .clipboard:
            runPromptToolToClipboard(tool, on: text, near: screenPoint)
        case .files, .notify:
            // Both are script-tool result modes. A prompt tool only ever produces
            // text, so the nearest honest behavior is to hand that text over.
            runPromptToolToClipboard(tool, on: text, near: screenPoint)
        }
    }

    /// Clipboard tools have no panel and nothing to type back, so this is the
    /// one result mode with its own request. Shaped exactly like
    /// `runInstantTranslation`, but the answer lands on the pasteboard and the
    /// user is told via the shared toast.
    @MainActor
    private func runPromptToolToClipboard(
        _ tool: GizmateTool,
        on text: String,
        near screenPoint: NSPoint
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
                    images: [],
                    to: language,
                    mode: mode,
                    appCategory: appCategory,
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cleaned, forType: .string)
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
                    ToastHUD.shared.show(text: "\(tool.name) — copied")
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
