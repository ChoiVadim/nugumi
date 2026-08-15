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

extension GizmateApp {
    @MainActor
    func toggleQuickMenuRing() {
        if let quickMenuButton {
            // Closing the ring fires onMenuClosed, which fades the button
            // away and clears the reference.
            quickMenuButton.closeMenu()
            return
        }
        // While the recorder is capturing, a mouse-button press is input for
        // the field, not a trigger.
        guard shortcutRecorderWindowController == nil else { return }

        // Same window arrangement as the selection bar: a real floating
        // button in its own panel BELOW the ring, centered on the cursor.
        // The collapse then plays over a persistent hub instead of piling
        // up inside the ring panel's own glass group.
        let cursor = NSEvent.mouseLocation
        let offsetX = 5 + AskGizmateFloatingTargetPresentationPolicy.buttonSize / 2
        let offsetY = AskGizmateFloatingTargetPresentationPolicy.buttonSize / 2 + 5
        let anchor = NSPoint(x: cursor.x - offsetX, y: cursor.y + offsetY)
        let button = FloatingTranslateButtonController(
            screenPoint: anchor,
            selectedText: "",
            initialMode: .selection,
            onTranslate: { [weak self] _ in
                self?.startSelectionTranslateOrReply(forcing: .translate)
            },
            onRewrite: { [weak self] _ in
                self?.startSelectedTextTranslationForReplacement()
            },
            onSmartReply: { [weak self] _ in
                self?.startSelectionTranslateOrReply(forcing: .smartReply)
            },
            onAsk: { [weak self] in
                self?.startAskGizmatePrompt()
            },
            onGenZ: { [weak self] _ in
                self?.startSelectedTextTranslationForReplacement(mode: .genZ)
            },
            onScreenshot: { [weak self] in
                self?.startScreenshotTranslation()
            },
            onLive: { [weak self] in
                self?.toggleLiveTranslation()
            },
            onDictate: { [weak self] in
                self?.toggleDictation()
            },
            onSaveNote: { [weak self] text, tag in
                self?.saveSelectionToNote(text, tag: tag)
            },
            noteTags: { [weak self] in self?.notesStore.tags ?? [] },
            summarizeOption: makeSummarizeOption(near: cursor, selectionRect: nil, panelSide: .right),
            // The quick menu arms no selection, so the empty string routes
            // `runTool` through its read-the-selection-now branch.
            onTool: { [weak self] tool, text in
                self?.runTool(tool, selection: text)
            }
        )
        button.onMenuClosed = { [weak self, weak button] in
            button?.fadeOutAndClose()
            self?.quickMenuButton = nil
        }
        quickMenuButton = button
        button.show()
        button.openMenu()
    }

    /// What `AskConversationStore` needs from the app, wired to the same
    /// helpers both submit paths already use.
    ///
    /// Internal rather than private, unlike everything else it reaches for:
    /// `GizmateApp.askConversation` builds the store with it, and that lives in
    /// `GizmateApp.swift`. The helpers stay private here, which is why the
    /// engine has to be assembled in this file rather than beside the store.
    @MainActor
    func makeAskEngine() -> AskEngine {
        AskEngine(
            capture: {
                let snapshot = Self.hideAppWindowsFromScreenCapture()
                defer { Self.restoreAppWindowSharing(snapshot) }
                return try await ScreenshotCapture.captureActiveScreen(
                    containing: NSEvent.mouseLocation
                )
            },
            ask: { [weak self] history, question, image, onPartial in
                guard let self else { throw CancellationError() }
                return try await self.askBackend.ask(
                    history: history,
                    question: question,
                    image: image,
                    thinkingLevel: self.askGizmateThinkingLevel,
                    onPartial: onPartial
                )
            },
            setupError: { [weak self] needsImage in
                guard let self else { return nil }
                let model = LLMModel.option(id: self.askGizmateModelID)
                // The vision requirement belongs to the message. Asked without
                // a picture, a text-only model is a perfectly good chat.
                if needsImage, !model.supportsImages {
                    return "Ask needs a vision model to look at your screen."
                }
                guard let setupError = self.askGizmateSetupErrorIfNeeded(for: model) else {
                    return nil
                }
                return Self.translationPanelErrorMessage(for: setupError)
            },
            showAnnotations: { [weak self] annotations, capture in
                self?.presentAskAnnotations(annotations, capture: capture)
            },
            clearAnnotations: { [weak self] in
                self?.closeAskAnnotationOverlay()
            },
            beginDrawing: { [weak self] in
                guard let self,
                      let capture = await self.captureScreenBeforeAskPromptTakesFocus()
                else { return nil }
                self.askDrawingOverlay?.close()
                self.askDrawingOverlay = AskDrawingOverlayController(
                    screenFrame: capture.screenFrame,
                    hint: "Draw on what you're asking about, then send"
                )
                return capture
            },
            endDrawing: { [weak self] in
                let strokes = self?.askDrawingOverlay?.strokes ?? []
                self?.closeAskDrawingOverlay()
                return strokes
            }
        )
    }

    /// Where Ask sits, if the user parked it on an edge.
    @MainActor
    private var askDockController: EdgeDockController? {
        guard let edge = dockStore.edge(of: ToolRef.builtIn(.ask).storageID) else { return nil }
        return dockControllers.first { $0.edge == edge }
    }

    @MainActor
    func startAskGizmatePrompt() {
        // Toggle: if any Ask Gizmate UI (prompt, loading, answer, or an
        // in-flight request) is already up, the shortcut dismisses it instead
        // of opening another one.
        let askUIOpen = isAskGizmateRunning || askPromptController != nil
        if askUIOpen {
            dismissAskGizmate()
            return
        }

        // Parked on an edge, the chat *is* Ask's surface, so the shortcut opens
        // it rather than a second place to type the same question into. Nothing
        // is captured on this path: the chat decides that per message, with its
        // camera at send and its pencil on press.
        if let dock = askDockController, dock.reveal(itemID: ToolRef.builtIn(.ask).storageID) {
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        // A `.ask` tool is waiting on the same capsule. Two of them on screen at
        // once is never what anyone meant by pressing the Ask shortcut.
        toolPromptController?.close()
        closeAskAnnotationOverlay()
        translationPanelController?.close()
        translationPanelController = nil

        let controller = AskPromptController(
            near: NSEvent.mouseLocation,
            onSubmit: { [weak self] prompt in
                self?.submitAskGizmatePrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.askPromptController = nil
                self.pendingAskGizmateCapture = nil
                self.closeAskDrawingOverlay()
                if self.isAskGizmateRunning {
                    self.cancelAskGizmateRequest()
                }
                // Escape / ✕ on the panel takes this path rather than
                // `dismissAskGizmate`, so it has to give focus back too.
                SelfActivationGuard.relinquish()
            }
        )
        askPromptController = controller
        // Capture before `show()`: activating Gizmate closes any menu the
        // user is asking about. The prompt appears one capture (~100 ms)
        // later, with the dropdown already safely in the pending shot.
        Task { @MainActor [weak self] in
            guard let self, self.askPromptController === controller else { return }
            self.pendingAskGizmateCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            guard self.askPromptController === controller else { return }
            controller.show()
            self.presentAskDrawingOverlay()
        }
    }

    /// Best-effort screen capture for `pendingAskGizmateCapture`. Returns nil
    /// on failure (e.g. missing screen-recording permission) so the submit
    /// path falls back to its own capture with full error reporting.
    @MainActor
    private func captureScreenBeforeAskPromptTakesFocus() async -> AskGizmateScreenCapture? {
        let sharingSnapshot = Self.hideAppWindowsFromScreenCapture()
        defer { Self.restoreAppWindowSharing(sharingSnapshot) }
        return try? await ScreenshotCapture.captureActiveScreen(containing: NSEvent.mouseLocation)
    }

    /// Shows the transparent drawing canvas over the screen that was just
    /// captured (falling back to the cursor's screen if capture failed).
    /// Clicks on it become strokes; the Ask pill never dismisses on outside
    /// clicks — only Esc or the shortcut toggle close it.
    @MainActor
    private func presentAskDrawingOverlay() {
        askDrawingOverlay?.close()
        askDrawingOverlay = nil
        let frame = pendingAskGizmateCapture?.screenFrame
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.frame
            ?? NSScreen.main?.frame
        guard let frame else { return }
        askDrawingOverlay = AskDrawingOverlayController(screenFrame: frame)
    }

    @MainActor
    private func closeAskDrawingOverlay() {
        askDrawingOverlay?.close()
        askDrawingOverlay = nil
    }

    @MainActor
    private func submitAskGizmatePrompt(_ prompt: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return }

        let model = LLMModel.option(id: askGizmateModelID)
        guard model.supportsImages else {
            askPromptController?.showError("Ask Gizmate needs a vision model.")
            return
        }

        if let setupError = askGizmateSetupErrorIfNeeded(for: model) {
            let message = Self.translationPanelErrorMessage(for: setupError)
            askPromptController?.showError(message)
            return
        }

        let requestID = UUID()
        askGizmateTask?.cancel()
        askGizmateRequestID = requestID
        isAskGizmateRunning = true
        askPromptController?.setLoading()

        // Hide the wide "Ask Gizmate" pill and surface the round loading bar
        // instead — a compact "in flight" indicator that never intercepts
        // clicks (`ignoresMouseEvents = true`). If the request fails,
        // `AskPromptController.showError` calls `panel.makeKeyAndOrderFront`
        // and the pill reappears with the error text.
        if let prompt = askPromptController {
            let pillCenter = prompt.panelCenter
            prompt.hidePanel()
            showAskFloatingLoadingBar(at: pillCenter)
        }

        let cursorLocation = NSEvent.mouseLocation
        let backend = askBackend
        // Prefer the capture taken when the prompt was summoned — it still
        // shows transient UI (open menus, popovers) that closed as soon as
        // the prompt took focus. Submit-time capture is the fallback.
        let preparedCapture = pendingAskGizmateCapture
        pendingAskGizmateCapture = nil
        // Strokes are consumed here: composited into the capture below, so
        // the on-screen canvas can come down before the request starts.
        let strokes = askDrawingOverlay?.strokes ?? []
        closeAskDrawingOverlay()
        let question = strokes.isEmpty
            ? cleanPrompt
            : cleanPrompt
                + "\n\n(The red marks on the screenshot are my annotations pointing at what I'm asking about.)"
        askGizmateTask = Task { [weak self] in
            do {
                let capture: AskGizmateScreenCapture
                if let preparedCapture {
                    capture = preparedCapture
                } else {
                    let sharingSnapshot = await MainActor.run {
                        Self.hideAppWindowsFromScreenCapture()
                    }
                    do {
                        capture = try await ScreenshotCapture.captureActiveScreen(containing: cursorLocation)
                    } catch {
                        await MainActor.run {
                            Self.restoreAppWindowSharing(sharingSnapshot)
                        }
                        throw error
                    }
                    await MainActor.run {
                        Self.restoreAppWindowSharing(sharingSnapshot)
                    }
                }
                try Task.checkCancellation()

                // Compositing decodes + re-encodes a ≤2048 px JPEG; keep it
                // off the main actor like the capture encode itself.
                let annotatedCapture = strokes.isEmpty
                    ? capture
                    : await Task.detached(priority: .userInitiated) {
                        capture.annotated(with: strokes)
                    }.value

                let shouldContinue = await MainActor.run {
                    self?.askGizmateRequestID == requestID
                }
                guard shouldContinue else { return }

                let history = await MainActor.run { self?.askHistory ?? [] }
                let currentThinkingLevel = await MainActor.run { self?.askGizmateThinkingLevel ?? .high }
                let response = try await backend.ask(
                    history: history,
                    question: question,
                    image: annotatedCapture.image,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                try Task.checkCancellation()

                await MainActor.run {
                    self?.presentAskGizmateResult(
                        response,
                        capture: annotatedCapture,
                        prompt: cleanPrompt,
                        requestID: requestID
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.clearAskGizmateRequestIfCurrent(requestID)
                }
            } catch {
                await MainActor.run {
                    self?.presentAskGizmateFailure(error, requestID: requestID)
                }
            }
        }
    }

    /// Follow-up from the floating answer panel's input field — the Ask
    /// analog of `reviseCurrentPanel`. Reuses the open panel (loading → new
    /// answer in place) and keeps the dialog context (`askHistory`) plus a
    /// fresh screen capture, so the conversation continues in place.
    @MainActor
    private func submitAskGizmateFollowUp(_ instruction: String) {
        let clean = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isAskGizmateRunning,
              let controller = translationPanelController else { return }

        let model = LLMModel.option(id: askGizmateModelID)
        guard model.supportsImages else {
            controller.showError("Ask Gizmate needs a vision model.")
            return
        }
        if let setupError = askGizmateSetupErrorIfNeeded(for: model) {
            controller.showError(Self.translationPanelErrorMessage(for: setupError))
            return
        }

        let requestID = UUID()
        askGizmateTask?.cancel()
        askGizmateRequestID = requestID
        isAskGizmateRunning = true
        let panelRequestID = controller.showLoading()

        let cursorLocation = NSEvent.mouseLocation
        let backend = askBackend
        askGizmateTask = Task { [weak self] in
            do {
                let sharingSnapshot = await MainActor.run { Self.hideAppWindowsFromScreenCapture() }
                let capture: AskGizmateScreenCapture
                do {
                    capture = try await ScreenshotCapture.captureActiveScreen(containing: cursorLocation)
                } catch {
                    await MainActor.run { Self.restoreAppWindowSharing(sharingSnapshot) }
                    throw error
                }
                await MainActor.run { Self.restoreAppWindowSharing(sharingSnapshot) }
                try Task.checkCancellation()

                let history = await MainActor.run { self?.askHistory ?? [] }
                let level = await MainActor.run { self?.askGizmateThinkingLevel ?? .high }
                let response = try await backend.ask(
                    history: history,
                    question: clean,
                    image: capture.image,
                    thinkingLevel: level
                ) { _ in }
                try Task.checkCancellation()

                await MainActor.run {
                    guard let self, self.askGizmateRequestID == requestID,
                          self.translationPanelController === controller else { return }
                    self.clearAskGizmateRequestIfCurrent(requestID)
                    self.recordAskTurn(question: clean, answer: response.message)
                    controller.showTranslation(response.message, requestID: panelRequestID, isFinal: true)
                    self.presentAskAnnotations(response.annotations, capture: capture)
                }
            } catch is CancellationError {
                await MainActor.run { self?.clearAskGizmateRequestIfCurrent(requestID) }
            } catch {
                await MainActor.run {
                    guard let self, self.askGizmateRequestID == requestID,
                          self.translationPanelController === controller else { return }
                    self.clearAskGizmateRequestIfCurrent(requestID)
                    controller.showError(error.localizedDescription, requestID: panelRequestID)
                }
            }
        }
    }

    @MainActor
    private func presentAskGizmateResult(
        _ response: AskGizmateResponse,
        capture: AskGizmateScreenCapture,
        prompt: String,
        requestID: UUID
    ) {
        guard askGizmateRequestID == requestID else { return }
        clearAskGizmateRequestIfCurrent(requestID)
        analyticsClient.track(.askScreenCompleted, properties: [
            "model_id": askGizmateModelID
        ])
        analyticsClient.trackFirstUsefulActionIfNeeded(
            sourceEvent: .askScreenCompleted,
            properties: ["model_id": askGizmateModelID]
        )
        recordAskTurn(question: prompt, answer: response.message)
        hideAskFloatingLoadingBar()
        askPromptController?.close()
        askPromptController = nil

        translationPanelController?.close()
        translationPanelController = nil

        let controller = TranslationPanelController(
            anchor: .point(NSEvent.mouseLocation, panelSide: .right),
            sourceText: prompt,
            targetLanguage: targetLanguage,
            resultLabel: "Answer",
            // Same layout as the translate/reply modal: no source box, plus a
            // follow-up field so the dialog can continue.
            showsSource: false,
            showsFollowUp: true,
            onFollowUp: { [weak self] instruction in
                self?.submitAskGizmateFollowUp(instruction)
            },
            // The answer is meant to be read — don't let a stray click dismiss it.
            dismissesOnOutsideClick: false,
            onClose: { [weak self] in
                guard let self else { return }
                if self.isAskGizmateRunning { self.cancelAskGizmateRequest() }
                self.translationPanelController = nil
                self.closeAskAnnotationOverlay()
            }
        )
        translationPanelController = controller
        let panelRequestID = controller.showLoading(targetLanguage: targetLanguage)
        controller.showTranslation(response.message, requestID: panelRequestID, isFinal: true)

        presentAskAnnotations(response.annotations, capture: capture)
    }

    /// Replace-on-every-answer semantics: new shapes redraw the layer, an
    /// empty list clears it.
    @MainActor
    private func presentAskAnnotations(
        _ annotations: [AskGizmateAnnotation],
        capture: AskGizmateScreenCapture
    ) {
        guard !annotations.isEmpty else {
            closeAskAnnotationOverlay()
            return
        }
        if let existing = askAnnotationOverlay, existing.screenFrame == capture.screenFrame {
            existing.show(annotations)
        } else {
            askAnnotationOverlay?.close()
            let overlay = AskAnnotationOverlayController(
                screenFrame: capture.screenFrame
            ) { [weak self] in
                self?.askAnnotationOverlay = nil
            }
            overlay.show(annotations)
            askAnnotationOverlay = overlay
        }
    }

    @MainActor
    private func closeAskAnnotationOverlay() {
        askAnnotationOverlay?.close()
        askAnnotationOverlay = nil
    }

    /// Brings up the round loading bubble centered on the pill's old
    /// position so the user sees that the question is in flight after the
    /// pill is hidden. The button is wired to no-op handlers — it exists
    /// purely as a visual indicator.
    @MainActor
    private func showAskFloatingLoadingBar(at pillCenter: NSPoint) {
        // The bar's init places the button at
        // `screenPoint + (5 + buttonSize/2, -buttonSize/2 - 5)` from its
        // anchor; reverse the math so its center lands on the pill's center.
        let offsetX = 5 + AskGizmateFloatingTargetPresentationPolicy.buttonSize / 2
        let offsetY = AskGizmateFloatingTargetPresentationPolicy.buttonSize / 2 + 5
        let anchor = NSPoint(x: pillCenter.x - offsetX, y: pillCenter.y + offsetY)

        let bar = FloatingTranslateButtonController(
            screenPoint: anchor,
            selectedText: "",
            initialMode: .selection,
            onTranslate: { _ in },
            onRewrite: { _ in },
            onSmartReply: { _ in },
            onAsk: {}
        )
        bar.show()
        bar.setLoading()
        askFloatingLoadingBar?.close()
        askFloatingLoadingBar = bar
    }

    @MainActor
    private func hideAskFloatingLoadingBar() {
        askFloatingLoadingBar?.close()
        askFloatingLoadingBar = nil
    }

    @MainActor
    private func presentAskGizmateFailure(_ error: Error, requestID: UUID) {
        guard askGizmateRequestID == requestID else { return }
        clearAskGizmateRequestIfCurrent(requestID)
        hideAskFloatingLoadingBar()

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            analyticsClient.track(.errorOccurred, properties: [
                "error_type": "screen_recording_permission_denied",
                "error_context": "ask_screen"
            ])
            askPromptController?.close()
            askPromptController = nil
            closeAskAnnotationOverlay()
            presentScreenshotTranslationError(screenshotError)
            return
        }

        let routed = handleTranslationFailure(error)
        if routed {
            askPromptController?.close()
            askPromptController = nil
            closeAskAnnotationOverlay()
            return
        }
        analyticsClient.track(.errorOccurred, properties: [
            "error_type": Self.analyticsErrorType(error),
            "error_context": "ask_screen"
        ])
        // `showError` on the hidden pill calls `makeKeyAndOrderFront`, so
        // the pill reappears at its original spot carrying the error text.
        askPromptController?.showError(error.localizedDescription)
    }

    @MainActor
    private func cancelAskGizmateRequest() {
        askGizmateTask?.cancel()
        askGizmateTask = nil
        askGizmateRequestID = nil
        isAskGizmateRunning = false
        hideAskFloatingLoadingBar()
    }

    /// Tears down every Ask Gizmate surface (prompt window, loading bar,
    /// in-flight request). Used by the Ask Gizmate shortcut toggle.
    @MainActor
    private func dismissAskGizmate() {
        if isAskGizmateRunning {
            cancelAskGizmateRequest()
        }
        pendingAskGizmateCapture = nil
        closeAskDrawingOverlay()
        askPromptController?.close()
        askPromptController = nil
        closeAskAnnotationOverlay()
        hideAskFloatingLoadingBar()
        // Nothing of ours needs focus now. Hand it back, or AppKit hands it to the
        // next window in line — which is the settings window if it's open, and it
        // gets raised in the process.
        SelfActivationGuard.relinquish()
    }

    @MainActor
    private func recordAskTurn(question: String, answer: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !trimmedAnswer.isEmpty else { return }
        askConversation.record(question: trimmedQuestion, answer: trimmedAnswer)
    }

    @MainActor
    func recordTranslation(
        source: String,
        result: String,
        kind: UsageStatsEventKind,
        targetLanguage: TranslationLanguage
    ) {
        usageStatsStore.recordUse(sourceText: source, resultText: result, kind: kind, targetLanguage: targetLanguage)
    }

    static func hideAppWindowsFromScreenCapture() -> [WindowSharingSnapshot] {
        let snapshots = NSApp.windows.map { window in
            WindowSharingSnapshot(window: window, sharingType: window.sharingType)
        }
        NSApp.windows.forEach { window in
            window.sharingType = .none
        }
        return snapshots
    }

    static func restoreAppWindowSharing(_ snapshots: [WindowSharingSnapshot]) {
        snapshots.forEach { snapshot in
            snapshot.window.sharingType = snapshot.sharingType
        }
    }

    @MainActor
    private func clearAskGizmateRequestIfCurrent(_ requestID: UUID) {
        guard askGizmateRequestID == requestID else { return }
        askGizmateTask = nil
        askGizmateRequestID = nil
        isAskGizmateRunning = false
    }

    @MainActor
    private func askGizmateSetupErrorIfNeeded(for model: LLMModel) -> TranslationError? {
        switch model.backend {
        case .ollama:
            return translationErrorIfBootstrapNeedsSetup(for: model.id)
        case .cloud(let provider):
            // Use the unified hasCredentials helper — for .openAICodex it
            // checks OAuth tokens via KeychainStore.codexCredentials(),
            // for API-key providers it checks the saved key. The previous
            // `apiKey(for:)` check was always nil for Codex even when the
            // user was signed in, killing requests pre-flight.
            return provider.hasCredentials ? nil : .invalidAPIKey(provider)
        }
    }
}
