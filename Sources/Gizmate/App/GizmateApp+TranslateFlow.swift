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
    func showTranslateButton(
        for selectedText: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right
    ) {
        translationPanelController?.close()
        translateButtonController?.close()
        petController?.clearReady()

        guard selectionDisplayMode != .off else {
            return
        }

        let primaryMode = floatingDefaultMode.translationMode
        let summarizeOption = makeSummarizeOption(near: screenPoint, selectionRect: selectionRect, panelSide: panelSide)

        if selectionDisplayMode == .pet {
            if petController == nil {
                petController = PetController(initialMode: primaryMode)
            }
            petController?.show()
            petController?.showReady(
                selectedText: selectedText,
                initialMode: primaryMode,
                onTranslate: { [weak self] text in
                    self?.translate(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true,
                        restoresReadyOnUserDismiss: true
                    )
                },
                onRewrite: { [weak self] text in
                    self?.rewriteSelectedDraftText(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true,
                        restoresReadyOnUserDismiss: true
                    )
                },
                onSmartReply: { [weak self] text in
                    self?.replyToSelection(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true,
                        restoresReadyOnUserDismiss: true
                    )
                },
                onAsk: { [weak self] in
                    self?.startAskGizmatePrompt()
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
                summarizeOption: summarizeOption,
                onTool: { [weak self] tool, text in
                    self?.runTool(tool, selection: text)
                }
            )
            return
        }

        let controller = FloatingTranslateButtonController(
            screenPoint: screenPoint,
            selectedText: selectedText,
            initialMode: primaryMode,
            onTranslate: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.translate(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    restoresReadyOnUserDismiss: true
                )
            },
            onRewrite: { [weak self] text in
                self?.rewriteSelectedDraftText(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    restoresReadyOnUserDismiss: true
                )
            },
            onSmartReply: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.replyToSelection(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    restoresReadyOnUserDismiss: true
                )
            },
            onAsk: { [weak self] in
                self?.startAskGizmatePrompt()
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
            summarizeOption: summarizeOption,
            onTool: { [weak self] tool, text in
                self?.runTool(tool, selection: text)
            }
        )

        translateButtonController = controller
        controller.show()
    }

    /// AX title of the frontmost app's focused window (best-effort; nil on
    /// any AX failure — the caller falls back to the most-recent chat).
    @MainActor
    func focusedWindowTitle(pid: pid_t) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let winEl = win, CFGetTypeID(winEl) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    /// Non-nil only when the frontmost app is a supported messenger
    /// (currently KakaoTalk) — drives the ring's contextual "Summarize"
    /// button in both `showTranslateButton` arming sites.
    @MainActor
    func rewriteSelectedDraftText(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false,
        restoresReadyOnUserDismiss: Bool = false
    ) {
        lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let cleanedDraft = TextNormalizer.cleanedDraftMessage(text)
        guard !cleanedDraft.isEmpty else {
            translateButtonController?.close()
            translateButtonController = nil
            petController?.clearReady()
            presentSelectionTranslationError("Select text first, then run Rewrite my text.")
            return
        }

        let language = draftTargetLanguage
        switch selectionReader.focusedElementEditability() {
        case .editable, .unknown:
            // .unknown inserts: in AX-broken apps (KakaoTalk) the blind
            // Cmd+V has always worked, and a panel here would regress them.
            runInstantTranslation(cleanedDraft, language: language, near: screenPoint)
        case .notEditable:
            translateButtonController?.close()
            translateButtonController = nil
            translate(
                cleanedDraft,
                near: screenPoint,
                targetLanguage: language,
                mode: .draftMessage,
                useCache: false,
                usageKind: .draftMessage,
                selectionRect: selectionRect,
                panelSide: panelSide,
                keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses,
                restoresReadyOnUserDismiss: restoresReadyOnUserDismiss,
                onReplace: { [weak self] translation in
                    self?.replaceCurrentSelection(with: translation)
                },
                replaceShortcutSourcePID: lastReplacementSourcePID
            )
        }
    }

    @MainActor
    func replyToSelection(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false,
        restoresReadyOnUserDismiss: Bool = false
    ) {
        // .unknown pastes blind, exactly like rewrite: broken-AX chat apps
        // (Telegram, KakaoTalk) route Cmd+V to their compose box regardless
        // of focus, and the result is in history either way. .notEditable
        // means AX is healthy and focus sits outside any field (the message
        // list) — hunt for the compose box; a window without one panels.
        let insertsDirectly: Bool
        switch selectionReader.focusedElementEditability() {
        case .editable, .unknown:
            insertsDirectly = true
        case .notEditable:
            insertsDirectly = selectionReader.focusEditableComposeField()
        }
        if insertsDirectly {
            lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            runInstantTranslation(text, language: draftTargetLanguage, near: screenPoint, mode: .smartReply)
            return
        }

        translate(
            text,
            near: screenPoint,
            targetLanguage: draftTargetLanguage,
            mode: .smartReply,
            useCache: false,
            usageKind: .smartReply,
            selectionRect: selectionRect,
            panelSide: panelSide,
            keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses,
            restoresReadyOnUserDismiss: restoresReadyOnUserDismiss
        )
    }

    @MainActor
    func translate(
        _ text: String,
        near screenPoint: NSPoint,
        targetLanguage explicitTargetLanguage: TranslationLanguage? = nil,
        mode: TranslationMode = .selection,
        useCache: Bool = true,
        usageKind: UsageStatsEventKind = .selection,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false,
        restoresReadyOnUserDismiss: Bool = false,
        onReplace: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil
    ) {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            handleTranslationFailure(setupError)
            return
        }

        let language = explicitTargetLanguage ?? targetLanguage
        let currentThinkingLevel = textThinkingLevel
        let currentAppCategory = AppCategoryClassifier.frontmostCategory()
        let currentComposition = compositionSettings(for: mode, appCategory: currentAppCategory)
        let anchor: TranslationPanelController.Anchor =
            selectionRect.map(TranslationPanelController.Anchor.selection)
                ?? .point(screenPoint, panelSide: panelSide)
        let controller = TranslationPanelController(
            anchor: anchor,
            sourceText: text,
            targetLanguage: language,
            resultLabel: mode.resultLabel,
            loadingPlaceholder: mode.loadingPlaceholder,
            showsSource: false,
            showsFollowUp: true,
            onTargetLanguageSelected: { [weak self] selectedLanguage in
                self?.retranslateCurrentPanel(
                    text,
                    targetLanguage: selectedLanguage,
                    mode: mode,
                    thinkingLevel: currentThinkingLevel,
                    appCategory: currentAppCategory,
                    composition: currentComposition,
                    useCache: useCache,
                    usageKind: usageKind
                )
            },
            onReplace: onReplace,
            onFollowUp: { [weak self] instruction in
                self?.reviseCurrentPanel(
                    instruction: instruction,
                    reviseMode: mode.revisesAsContent ? .revise : .reviseMessage,
                    usageKind: usageKind
                )
            },
            replaceShortcutSourcePID: replaceShortcutSourcePID,
            onClose: { [weak self] in
                self?.translationPanelController = nil
                self?.petController?.clearReady()
            }
        )
        translationPanelController?.close()
        translationPanelController = controller
        if restoresReadyOnUserDismiss {
            // The selection usually survives an Esc / ✕ / copy dismissal, so
            // re-arm the pet/button for it. If the dismissing click actually
            // killed the selection, the global mouse-up re-read finds nothing
            // and clears the ready state right back.
            controller.onUserDismiss = { [weak self] in
                self?.showTranslateButton(
                    for: text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            }
        }
        if keepPetReadyUntilPanelCloses {
            holdPetReadyUntilActivePanelCloses(mode: mode)
        }
        let requestID = controller.showLoading()
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: currentThinkingLevel,
            appCategory: currentAppCategory,
            composition: currentComposition,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    func compositionSettings(for mode: TranslationMode, appCategory: AppCategory) -> CompositionSettings? {
        guard mode.usesCompositionSettings else {
            // Translate/selection ignores writing style, cleanup, snippets, and
            // voice sample. The only composition input it honors is the global
            // Gen Z toggle, so synthesize a minimal carrier — and only when that
            // toggle is on, so default (off) behavior stays exactly as before.
            guard genZModeEnabled else { return nil }
            return CompositionSettings(style: .casual, cleanup: .none, snippets: [], genZ: true, voiceSample: nil)
        }
        let voiceSample = appCategory == .email
            ? emailVoiceSample.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let instruction = appCategory == .custom
            ? customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let resolvedStyle = writingStyle(for: appCategory)
        return CompositionSettings(
            style: resolvedStyle,
            cleanup: cleanupLevel,
            snippets: snippetsStore.usableSnippets(),
            // Gen Z is a casual-chat register. It clobbers email's formal
            // greeting + signature, and directly contradicts the formal
            // register's no-contractions / deferential rules — so never apply
            // it to email or to formal style.
            genZ: genZModeEnabled && appCategory != .email && resolvedStyle != .formal,
            voiceSample: voiceSample.isEmpty ? nil : voiceSample,
            customInstruction: instruction.isEmpty ? nil : instruction
        )
    }

    @MainActor
    private func holdPetReadyUntilActivePanelCloses(mode: TranslationMode) {
        guard selectionDisplayMode == .pet else {
            return
        }

        if petController == nil {
            petController = PetController(initialMode: mode)
        }
        petController?.show()
        petController?.holdReadyUntilPanelCloses(mode: mode)
    }

    @MainActor
    private func retranslateCurrentPanel(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        useCache: Bool,
        usageKind: UsageStatsEventKind
    ) {
        guard let controller = translationPanelController else {
            return
        }

        let requestID = controller.showLoading(targetLanguage: language)
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: thinkingLevel,
            appCategory: appCategory,
            composition: composition,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    /// Footer "Revise or ask a follow-up": regenerate the current selection
    /// result in place from the user's instruction. Reuses the existing
    /// `runTranslation` path via `TranslationMode.revise`, so all backends and
    /// streaming come for free. "Previous response" is the latest shown text, so
    /// chained revises ("now shorter") build on each other.
    @MainActor
    private func reviseCurrentPanel(
        instruction: String,
        reviseMode: TranslationMode = .revise,
        usageKind: UsageStatsEventKind = .selection
    ) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let controller = translationPanelController else {
            return
        }
        // Nothing to revise until the first answer has actually arrived.
        let previous = controller.displayedResultText
        guard !previous.isEmpty else { return }

        let composed = TranslationMode.composeReviseInput(
            source: controller.currentSourceText,
            previous: previous,
            instruction: trimmed
        )
        // Reply revises keep the writing style/voice; translate revises don't.
        let appCategory = AppCategoryClassifier.frontmostCategory()
        let composition = reviseMode.usesCompositionSettings
            ? compositionSettings(for: reviseMode, appCategory: appCategory)
            : nil
        let requestID = controller.showLoading(placeholder: reviseMode.loadingPlaceholder)
        runTranslation(
            composed,
            targetLanguage: controller.currentTargetLanguageValue,
            mode: reviseMode,
            thinkingLevel: textThinkingLevel,
            appCategory: appCategory,
            composition: composition,
            useCache: false,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID,
            recordsHistory: false
        )
    }

    @MainActor
    private func runTranslation(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        useCache: Bool,
        usageKind: UsageStatsEventKind,
        controller: TranslationPanelController,
        requestID: UUID,
        recordsHistory: Bool = true
    ) {
        if let busyError = translationErrorIfBootstrapBusy() {
            controller.showError(Self.translationPanelErrorMessage(for: busyError), requestID: requestID)
            return
        }

        let persistsHistory = recordsHistory && mode != .summarizeChat && mode != .summarizePage

        if useCache, let cachedTranslation = translationCache.translation(for: text, targetLanguage: language, thinkingLevel: thinkingLevel) {
            if persistsHistory {
                recordTranslation(source: text, result: cachedTranslation, kind: usageKind, targetLanguage: language)
            }
            analyticsClient.trackCompletedUsage(
                kind: usageKind,
                targetLanguageID: language.id,
                modelID: textModelID
            )
            controller.showTranslation(cachedTranslation, requestID: requestID, isFinal: true)
            return
        }

        let backend = currentBackend
        Task {
            do {
                let translated = try await backend.translate(
                    text,
                    images: [],
                    to: language,
                    mode: mode,
                    appCategory: appCategory,
                    composition: composition,
                    thinkingLevel: thinkingLevel
                ) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation, requestID: requestID)
                    }
                }
                await MainActor.run {
                    if useCache {
                        self.translationCache.store(translated, for: text, targetLanguage: language, thinkingLevel: thinkingLevel)
                    }
                    if persistsHistory {
                        self.recordTranslation(source: text, result: translated, kind: usageKind, targetLanguage: language)
                    }
                    self.analyticsClient.trackCompletedUsage(
                        kind: usageKind,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                    controller.showTranslation(translated, requestID: requestID, isFinal: true)
                }
            } catch {
                await MainActor.run {
                    if self.handleTranslationFailure(error, controller: controller) {
                        return
                    }
                    self.analyticsClient.track(.errorOccurred, properties: [
                        "error_type": Self.analyticsErrorType(error),
                        "error_context": "translation"
                    ])
                    controller.showError(Self.translationPanelErrorMessage(for: error), requestID: requestID)
                }
            }
        }
    }

    @MainActor
    @discardableResult
    func handleTranslationFailure(_ error: Error, controller: TranslationPanelController? = nil) -> Bool {
        guard let translationError = error as? TranslationError else { return false }
        switch translationError {
        case .serverUnavailable, .modelMissing, .signInRequired:
            controller?.close()
            bootstrap.refresh()
            presentMainWindow(section: .aiEngine)
            return true
        case .invalidAPIKey(let provider):
            controller?.close()
            switch provider {
            case .openAICodex: KeychainStore.setCodexCredentials(nil)
            case .anthropicClaudeCode: KeychainStore.setClaudeCodeCredentials(nil)
            default: KeychainStore.setAPIKey(nil, for: provider)
            }
            bootstrap.refresh()
            presentCredentialPrompt(for: provider) { _ in }
            return true
        case .ollama, .emptyResponse, .modelDownloading, .rateLimited, .outOfCredits, .cloudError:
            return false
        }
    }

    static func analyticsErrorType(_ error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .ollama: return "ollama"
            case .emptyResponse: return "empty_response"
            case .modelDownloading: return "model_downloading"
            case .serverUnavailable: return "server_unavailable"
            case .modelMissing: return "model_missing"
            case .signInRequired: return "sign_in_required"
            case .invalidAPIKey: return "invalid_api_key"
            case .rateLimited: return "rate_limited"
            case .outOfCredits: return "out_of_credits"
            case .cloudError: return "cloud_error"
            }
        }
        return String(describing: type(of: error))
    }

    static func translationPanelErrorMessage(for error: Error) -> String {
        guard let translationError = error as? TranslationError else {
            return "Could not translate this.\n\(error.localizedDescription)"
        }

        switch translationError {
        case .ollama(let message):
            return "Could not translate this.\n\(message)"
        case .emptyResponse:
            return "No translation came back. Try again."
        // Named for the translation panel, but Ask shows these too, so anything
        // describing the engine rather than the failed action says "model".
        case .modelDownloading(let detail):
            return "The model is still downloading.\n\(detail)"
        case .serverUnavailable:
            return "Ollama is not running."
        case .modelMissing:
            return "The model is not downloaded yet."
        case .signInRequired:
            return "Sign in to Ollama to use its hosted models."
        case .invalidAPIKey(let provider):
            return "\(provider.displayName) rejected the API key."
        case .rateLimited(let provider):
            return "\(provider.displayName) rate limit reached. Try again in a minute."
        case .outOfCredits(let provider):
            return "\(provider.displayName) is out of credits. Add funds, or switch to a free model."
        case .cloudError(let provider, let detail):
            return "\(provider.displayName): \(detail)"
        }
    }

    @MainActor
    func translationErrorIfBootstrapBusy(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        if case .working(let detail) = bootstrap.state.modelReady(for: modelID) {
            return .modelDownloading(detail)
        }
        return nil
    }

    @MainActor
    func translationErrorIfBootstrapNeedsSetup(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        let model = LLMModel.option(id: modelID)
        if let provider = model.cloudProvider {
            if case .needsAction = bootstrap.state.cloudKey(for: provider) {
                return .invalidAPIKey(provider)
            }
            return nil
        }

        if case .needsAction = bootstrap.state.ollamaInstalled {
            return .serverUnavailable
        }
        if case .needsAction = bootstrap.state.serverRunning {
            return .serverUnavailable
        }
        if case .needsAction = bootstrap.state.ollamaSignedIn,
           model.isCloud {
            return .signInRequired
        }
        if case .needsAction = bootstrap.state.modelReady(for: modelID) {
            return .modelMissing(modelID)
        }
        return nil
    }

}
