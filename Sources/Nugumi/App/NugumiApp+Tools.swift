import AppKit
import Foundation

extension NugumiApp {
    /// Runs one of the user's prompt tools (`PromptTool`) over the ring's armed
    /// selection. The quick menu arms its ring with no selection, so an empty
    /// `selection` means "read what's selected now" — the same arrangement the
    /// built-in ring actions use.
    @MainActor
    func runPromptTool(_ tool: PromptTool, selection: String) {
        guard tool.isUsable else { return }

        let armed = TextNormalizer.cleanedSelection(selection)
        if !armed.isEmpty {
            run(tool, on: armed, near: NSEvent.mouseLocation, selectionRect: nil)
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
        _ tool: PromptTool,
        on text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect?
    ) {
        switch tool.result {
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
        }
    }

    /// Clipboard tools have no panel and nothing to type back, so this is the
    /// one result mode with its own request. Shaped exactly like
    /// `runInstantTranslation`, but the answer lands on the pasteboard and the
    /// user is told via the shared toast.
    @MainActor
    private func runPromptToolToClipboard(
        _ tool: PromptTool,
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
