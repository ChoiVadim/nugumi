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

@main
@MainActor
final class NugumiApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mouseMonitor: Any?
    private var keyboardMonitor: Any?
    private var lastLeftMouseDownLocation: NSPoint?
    /// Pasteboard changeCount at the start of the current selection gesture.
    /// If it advances before the clipboard fallback runs, the frontmost app
    /// copied on its own (copy-on-select TUIs, click-to-copy sites) — that
    /// copy is the selection and must survive on the clipboard.
    private var lastMouseDownPasteboardChangeCount: Int?
    private var lastMouseDownDragPasteboardChangeCount: Int?
    private var lastMouseDownWindowNumber: Int?
    private var lastMouseDownWindowBounds: CGRect?
    /// Per-bundle count of consecutive selection-gesture attempts that returned
    /// no readable text. Apps like KakaoTalk expose neither AX text attributes
    /// nor a working Cmd+C path, so the floating bar silently never appears —
    /// this counter lets us surface a one-time hint pointing users at
    /// Screenshot Translation instead.
    private var unreadableSelectionFailureCounts: [String: Int] = [:]
    private static let unreadableSelectionFailureThreshold = 3
    private static let unreadableSelectionHintShownDefaultsKey = "unreadableSelectionHintShownBundles"
    private let selectionReader = SelectionReader()
    private let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    private var currentBackend: any LLMBackend {
        backend(for: textModelID)
    }
    private var askBackend: any LLMBackend {
        backend(for: askNugumiModelID)
    }

    private func backend(for modelID: String) -> any LLMBackend {
        let model = LLMModel.option(id: modelID)
        switch model.backend {
        case .ollama:
            return OllamaClient(baseURL: ollamaBaseURL, model: model.apiModelID)
        case .cloud(let provider):
            switch provider {
            case .openAICodex:
                return OpenAICodexClient(apiModelID: model.apiModelID)
            case .anthropicClaudeCode:
                return ClaudeCodeClient(model: model.apiModelID)
            case .openAI, .anthropic, .gemini, .openRouter:
                let key = KeychainStore.apiKey(for: provider) ?? ""
                return OpenAIChatClient(provider: provider, apiKey: key, model: model.apiModelID)
            }
        }
    }

    private var translateButtonController: FloatingTranslateButtonController?
    private var floatingLoadingBar: FloatingTranslateButtonController?
    /// Click-through layer with the model's explanation shapes; replaced on
    /// every Ask answer, torn down with the answer UI.
    private var askAnnotationOverlay: AskAnnotationOverlayController?
    /// Round loading bubble shown in place of the Ask Nugumi pill while a
    /// question is in flight. Unlike the pill, it has no outside-click
    /// monitors, so clicking elsewhere can't dismiss the in-flight request.
    private var askFloatingLoadingBar: FloatingTranslateButtonController?
    private var petController: PetController?
    private var translationPanelController: TranslationPanelController?
    private var askPromptController: AskPromptController?
    private var askNugumiTask: Task<Void, Never>?
    private var askNugumiRequestID: UUID?
    private var askHistory: [AskNugumiTurn] = AskNugumiHistoryStore.load()
    /// Screen capture taken the moment Ask Nugumi is summoned, before the
    /// prompt steals focus. Activating Nugumi deactivates the frontmost app,
    /// which instantly closes its open menus/popovers, so a submit-time
    /// capture can never see them. Consumed by `submitAskNugumiPrompt`.
    private var pendingAskNugumiCapture: AskNugumiScreenCapture?
    /// Draw-anywhere canvas over the captured screen; alive while the Ask
    /// prompt is open, consumed (strokes → image) at submit.
    private var askDrawingOverlay: AskDrawingOverlayController?
    private var isScreenshotTranslationRunning = false
    private var isAskNugumiRunning = false
    /// True while a cloud sign-in flow (ChatGPT or Claude) is on screen.
    /// Suspends the mouse/Cmd+A selection auto-readers so they don't fire
    /// synthetic ⌘+C at the sign-in page on every click — which makes macOS beep
    /// when there's nothing to copy. Set around the login alerts' `present()`.
    private var isCloudSignInActive = false
    private var screenshotDragStartLocation: NSPoint?
    private var screenshotDragEndLocation: NSPoint?
    private var screenshotPanelSide: TranslationPanelController.Side?
    private var screenshotDragTracker: ScreenshotDragTracker?
    private var globalHotKeys: [GlobalHotKey] = []
    private lazy var liveTranslationController: LiveTranslationController = {
        let controller = LiveTranslationController()
        controller.onMissingAPIKey = { [weak self] in self?.presentLiveTranslationAPIKeyAlert() }
        controller.onMicrophonePermissionDenied = { [weak self] in self?.presentMicrophonePermissionAlert() }
        // Captions follow the target language: forward changes (the main window
        // writes targetLanguageID to UserDefaults) into a running session.
        // `updateTargetLanguage` no-ops unless a session is active, so this is
        // cheap, and the observer is installed lazily on first use so users who
        // never open live captions pay nothing.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self, weak controller] _ in
            Task { @MainActor in
                guard let self, let controller else { return }
                controller.updateTargetLanguage(self.targetLanguage)
            }
        }
        return controller
    }()
    private lazy var dictationController: DictationController = {
        let controller = DictationController()
        controller.onMissingAPIKey = { [weak self] in self?.presentLiveTranslationAPIKeyAlert(feature: "Dictation") }
        controller.onMicrophonePermissionDenied = { [weak self] in self?.presentMicrophonePermissionAlert() }
        return controller
    }()
    private var modifierDetectors: [DoubleModifierPressDetector] = []
    private var mouseButtonMonitors: [MouseButtonShortcutMonitor] = []
    private var quickMenuRing: RadialActionMenuController?
    private var shortcutRecorderWindowController: ShortcutRecorderWindowController?
    private var lastReplacementSourcePID: pid_t?
    private var translationCache = TranslationCache()
    private let usageStatsStore = UsageStatsStore()
    private let analyticsClient = AnalyticsClient()
    private let snippetsStore = SnippetsStore()
    private let translationHistoryStore = TranslationHistoryStore()
    private lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        models: LLMModel.ollamaModels
    )
    private var snippetsWindowController: SnippetsWindowController?
    private var mainWindowController: MainWindowController?
    /// Ollama model whose pull the user kicked off from the AI Engine setup card.
    /// When it finishes we promote it to the everyday-text default once, mirroring
    /// the retired onboarding window's `onOllamaReady` behavior.
    private var pendingOllamaAutoSelectID: String?
    private var accessibilityTrustTimer: Timer?
    private var screenRecordingTrustTimer: Timer?

    private struct WindowSharingSnapshot {
        let window: NSWindow
        let sharingType: NSWindow.SharingType
    }
    private var onboardingWindowController: OnboardingWindowController?
    private var lastObservedModelReadyState: [String: BootstrapStepStatus] = [:]
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()
    /// Set by Sparkle's gentle-reminder path when a *scheduled* background check
    /// finds an update. Drives the sidebar badge + menu-bar item instead of the
    /// modal. nil = no pending update. Cleared once the user acts on it.
    private var availableUpdate: SUAppcastItem?
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
    private var targetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "targetLanguageID") ?? TranslationLanguage.defaultLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "targetLanguageID")
        }
    }
    private var draftTargetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "draftTargetLanguageID") ?? TranslationLanguage.defaultDraftLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "draftTargetLanguageID")
        }
    }
    /// The single "other" language the "Toggle writing language" shortcut flips
    /// to. The toggle swaps this with `draftTargetLanguage`, so the configured
    /// pair is always {writing language, alternate} — the writing language side
    /// is the live target, only this one is user-selectable.
    private var writingToggleAlternate: TranslationLanguage {
        get {
            if let id = UserDefaults.standard.string(forKey: "writingToggleAlternateID") {
                return TranslationLanguage.language(id: id)
            }
            // Migrate from the legacy A/B pair: carry over whichever language
            // isn't the active writing language so existing setups are preserved.
            let current = draftTargetLanguage
            let legacyA = UserDefaults.standard.string(forKey: "writingToggleLanguageAID")
                .map { TranslationLanguage.language(id: $0) }
            let legacyB = UserDefaults.standard.string(forKey: "writingToggleLanguageBID")
                .map { TranslationLanguage.language(id: $0) }
            if let a = legacyA, a.id != current.id { return a }
            if let b = legacyB, b.id != current.id { return b }
            return TranslationLanguage.defaultLanguage.id == current.id
                ? TranslationLanguage.defaultDraftLanguage
                : TranslationLanguage.defaultLanguage
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "writingToggleAlternateID")
        }
    }
    private var floatingDefaultMode: FloatingButtonDefaultMode {
        get {
            FloatingButtonDefaultMode.storedMode(
                rawValue: UserDefaults.standard.string(forKey: "floatingButtonDefaultMode")
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "floatingButtonDefaultMode")
        }
    }
    private var selectionDisplayMode: SelectionDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "selectionDisplayMode") ?? SelectionDisplayMode.floatingBar.rawValue
            return SelectionDisplayMode(rawValue: raw) ?? .floatingBar
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectionDisplayMode")
        }
    }
    private var legacySelectedModelID: String? {
        UserDefaults.standard.string(forKey: "selectedOllamaModel")
    }
    private var textModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.defaultsKey)
                ?? ModelUseScope.textActions.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.textActions.defaultsKey)
        }
    }
    private var askNugumiModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.askNugumi.defaultsKey)
                ?? ModelUseScope.askNugumi.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.askNugumi.defaultsKey)
        }
    }
    private func modelID(for scope: ModelUseScope) -> String {
        switch scope {
        case .textActions:
            return textModelID
        case .askNugumi:
            return askNugumiModelID
        }
    }
    private func setModelID(_ modelID: String, for scope: ModelUseScope) {
        switch scope {
        case .textActions:
            textModelID = modelID
        case .askNugumi:
            askNugumiModelID = modelID
        }
    }
    private var legacyThinkingRawValue: String? {
        UserDefaults.standard.string(forKey: "thinkingLevel")
    }
    private var textThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.textActions.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.textActions.thinkingDefaultsKey)
        }
    }
    private var askNugumiThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.askNugumi.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.askNugumi.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.askNugumi.thinkingDefaultsKey)
        }
    }
    private func thinkingLevel(for scope: ModelUseScope) -> ThinkingLevel {
        switch scope {
        case .textActions:
            return textThinkingLevel
        case .askNugumi:
            return askNugumiThinkingLevel
        }
    }
    private func setThinkingLevel(_ level: ThinkingLevel, for scope: ModelUseScope) {
        switch scope {
        case .textActions:
            textThinkingLevel = level
        case .askNugumi:
            askNugumiThinkingLevel = level
        }
    }
    private var cleanupLevel: CleanupLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "cleanupLevel") ?? CleanupLevel.light.rawValue
            return CleanupLevel(rawValue: raw) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupLevel")
        }
    }

    /// Global Gen Z styling toggle. Off by default; injected into compose
    /// prompts via `CompositionSettings.genZ`.
    private var genZModeEnabled: Bool {
        get { GenZStyle.isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: GenZStyle.defaultsKey) }
    }

    /// The user's email voice sample — a typical email they write, used as a
    /// style reference for the `email` category only. Empty by default. Treated
    /// as personal content (like Snippets), so it survives a settings reset.
    private var emailVoiceSample: String {
        get { UserDefaults.standard.string(forKey: "voiceSample.email") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSample.email") }
    }

    /// Free-text instruction for the `custom` style. Personal content (like the
    /// email voice sample and Snippets), so it survives a settings reset.
    private var customStyleInstruction: String {
        get { UserDefaults.standard.string(forKey: "customStyleInstructionV1") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "customStyleInstructionV1") }
    }

    private var invisibilityModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: InvisibilityState.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: InvisibilityState.defaultsKey) }
    }

    private func writingStyle(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return Self.defaultStyle(for: category)
    }

    private func setWritingStyle(_ style: WritingStyle, for category: AppCategory) {
        UserDefaults.standard.set(style.rawValue, forKey: "writingStyle.\(category.rawValue)")
    }

    private static func defaultStyle(for category: AppCategory) -> WritingStyle {
        category.defaultWritingStyle
    }

    // MARK: - Custom app → category assignments

    private static let customAppAssignmentsKey = "customAppAssignmentsV1"
    private static let suppressedBuiltInAppsKey = "suppressedBuiltInAppsV1"

    func customAppAssignments() -> [CustomAppAssignment] {
        guard let data = UserDefaults.standard.data(forKey: Self.customAppAssignmentsKey),
              let list = try? JSONDecoder().decode([CustomAppAssignment].self, from: data)
        else { return [] }
        return list
    }

    private func saveCustomAppAssignments(_ list: [CustomAppAssignment]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.customAppAssignmentsKey)
        }
        syncAppClassifierOverrides()
    }

    func suppressedBuiltInApps() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.suppressedBuiltInAppsKey) ?? [])
    }

    private func saveSuppressedBuiltInApps(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.suppressedBuiltInAppsKey)
        syncAppClassifierOverrides()
    }

    /// Push persisted assignments into the classifier's static lookup so the live
    /// rewrite path (`AppCategoryClassifier.category(for:)`) honors them.
    func syncAppClassifierOverrides() {
        var overrides: [String: AppCategory] = [:]
        for assignment in customAppAssignments() {
            overrides[assignment.bundleID] = assignment.category
        }
        AppCategoryClassifier.userOverrides = overrides
        AppCategoryClassifier.suppressedBuiltIns = suppressedBuiltInApps()
    }

    func addCustomApp(bundleID: String, name: String, category: AppCategory) {
        var list = customAppAssignments().filter { $0.bundleID != bundleID }
        list.append(CustomAppAssignment(bundleID: bundleID, name: name, category: category))
        saveCustomAppAssignments(list)
        // If the user re-adds a previously-removed built-in, un-suppress it.
        if AppCategoryClassifier.bundleIDMap[bundleID] != nil {
            var suppressed = suppressedBuiltInApps()
            suppressed.remove(bundleID)
            saveSuppressedBuiltInApps(suppressed)
        }
    }

    /// Removes an app from its category. Built-in mapped apps are suppressed (so they
    /// stop auto-classifying); user-added apps are deleted outright.
    func removeApp(bundleID: String) {
        if customAppAssignments().contains(where: { $0.bundleID == bundleID }) {
            saveCustomAppAssignments(customAppAssignments().filter { $0.bundleID != bundleID })
        }
        if AppCategoryClassifier.bundleIDMap[bundleID] != nil {
            var suppressed = suppressedBuiltInApps()
            suppressed.insert(bundleID)
            saveSuppressedBuiltInApps(suppressed)
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = NugumiApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: Streaming-jitter repro (NUGUMI_STREAM_DEBUG=1) — delete when solved.
    private var fakeStreamTimer: Timer?
    private func runFakeStreamRepro() {
        let controller = TranslationPanelController(
            anchor: .point(NSPoint(x: 500, y: 700), panelSide: .right),
            sourceText: "debug",
            targetLanguage: targetLanguage,
            resultLabel: "Summary",
            loadingPlaceholder: "Summarizing",
            showsSource: false,
            showsFollowUp: true,
            dismissesOnOutsideClick: false
        )
        translationPanelController?.close()
        translationPanelController = controller
        let requestID = controller.showLoading()
        var emitted = ""
        var i = 0
        fakeStreamTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            guard i < 220 else {
                t.invalidate()
                controller.showTranslation(emitted, requestID: requestID, isFinal: true)
                return
            }
            let word = i % 9 == 4 ? "**слово\(i)**" : "слово\(i)"
            if i % 34 == 33 { emitted += "\n\n" }
            else if i % 13 == 12 { emitted += "\n- " }
            else if !emitted.isEmpty { emitted += " " }
            emitted += word
            controller.showTranslation(emitted, requestID: requestID)
            i += 1
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nugumi is a dark-only design (white ink on dark glass everywhere). Pin
        // the whole app to dark so windows/panels render correctly even when macOS
        // is in light mode — otherwise the system serves a light material and the
        // white text on the floating Ask Nugumi panels becomes invisible. This is
        // the single source of truth; the per-window .darkAqua pins are redundant.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Developer switch: NUGUMI_FIRST_RUN=1 clears the first-run flags so
        // the full install experience (intro video → permissions → feature
        // tour → engine choice → main window) replays on this launch. TCC
        // permissions can't be revoked from here — use `tccutil reset` for
        // full fidelity.
        if ProcessInfo.processInfo.environment["NUGUMI_FIRST_RUN"] == "1" {
            for key in [
                OnboardingModel.featureTourCompletedKey,
                OnboardingModel.introPlayedKey,
                "mainWindowAutoShownV1",
                "permissionsOnboarding.screenCaptureRequested",
                "didSetDefaultLoginItemV1",
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // Developer switch: NUGUMI_STREAM_DEBUG=1 opens a result panel on
        // launch and streams fake markdown chunks into it, logging per-render
        // geometry — repro harness for streaming-jitter debugging.
        if TranslationContentView.streamDebug {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runFakeStreamRepro()
            }
        }
        // AX default messaging timeout is 6s. Parameterized calls (e.g.
        // kAXBoundsForRangeParameterizedAttribute) can stall the main thread
        // when an unsupported app responds slowly. Cap it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
        setupStatusItem()
        installMainMenu()
        statusItem?.isVisible = !invisibilityModeEnabled
        InvisibilityState.applyToAllOpenWindows()
        requestAccessibilityPermissionIfNeeded()
        requestScreenRecordingPermissionIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.presentPermissionsWindowIfNeeded()
        }
        startMouseMonitor()
        startKeyboardMonitor()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        syncAppClassifierOverrides()
        setupBootstrap()
        // Refresh the API-key providers' + Claude Code model catalogs and the
        // ChatGPT/Codex catalog (best-effort, cached). Codex previously only
        // refreshed on fresh login, so an existing session never saw catalog
        // changes until re-login — mirror the cloud refresh at every launch.
        Task.detached { await CloudModelDiscovery.refreshAll() }
        Task.detached { await CodexModelDiscovery.refreshFromAPI() }
        _ = updaterController
        analyticsClient.trackInstallIfNeeded()
        analyticsClient.track(.appLaunched, properties: permissionStatusProperties(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingTrusted: CGPreflightScreenCaptureAccess()
        ))
        reconcilePermissionAnalyticsAtLaunch()
        enableLaunchAtLoginByDefaultIfNeeded()
        showMainWindowOnFirstRunIfNeeded()
    }

    /// First launch from the app bundle registers Nugumi as a login item so the
    /// user never has to re-open it from Applications. One-time and flag-guarded,
    /// so a later manual toggle-off in Settings sticks (we never re-enable).
    @MainActor
    private func enableLaunchAtLoginByDefaultIfNeeded() {
        guard isRunningFromAppBundle else { return }
        let key = "didSetDefaultLoginItemV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LaunchAtLogin.set(true)
    }

    /// Opens the main window once after install so users discover it. While the
    /// onboarding window is up this defers WITHOUT consuming the flag — the
    /// onboarding close handler calls it again, so the main window appears only
    /// after the tour, never side by side with it.
    @MainActor
    private func showMainWindowOnFirstRunIfNeeded() {
        let key = "mainWindowAutoShownV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self,
                  self.onboardingWindowController == nil
            else { return }
            UserDefaults.standard.set(true, forKey: key)
            // Fresh installs have no model ready yet — land on setup directly.
            let section: MainWindowSection? = self.bootstrap.isReady(for: self.textModelID) ? nil : .aiEngine
            self.presentMainWindow(section: section)
        }
    }

    private func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
        GlobalShortcutStore.shortcut(for: action)
    }

    private func setupGlobalHotKeys() {
        globalHotKeys.forEach { $0.unregister() }
        globalHotKeys.removeAll()
        modifierDetectors.forEach { $0.stop() }
        modifierDetectors.removeAll()
        mouseButtonMonitors.forEach { $0.stop() }
        mouseButtonMonitors.removeAll()

        let bindings: [(GlobalShortcutAction, @MainActor () -> Void)] = [
            (.screenshotArea, { [weak self] in self?.startScreenshotTranslation() }),
            (.translateSelection, { [weak self] in self?.startSelectedTextTranslationForReplacement() }),
            (.translateOrReply, { [weak self] in self?.startSelectionTranslateOrReply() }),
            (.toggleInvisibility, { [weak self] in self?.toggleInvisibilityMode() }),
            (.askNugumi, { [weak self] in self?.startAskNugumiPrompt() }),
            (.toggleWritingLanguage, { [weak self] in self?.toggleWritingLanguageAction() }),
            (.liveTranslation, { [weak self] in self?.toggleLiveTranslation() }),
            (.quickMenu, { [weak self] in self?.toggleQuickMenuRing() })
        ]

        for (action, handler) in bindings {
            let shortcut = shortcut(for: action)
            switch shortcut.kind {
            case .combo:
                let hotKey = GlobalHotKey(
                    definition: GlobalHotKeyDefinition(action: action, shortcut: shortcut),
                    onPressed: handler
                )
                globalHotKeys.append(hotKey)
                hotKey.register()
            case .doubleTap:
                let detector = DoubleModifierPressDetector(
                    modifier: shortcut.modifiers,
                    onDetected: handler
                )
                modifierDetectors.append(detector)
                detector.start()
            case .mouseButton:
                let monitor = MouseButtonShortcutMonitor(
                    buttonNumber: Int(shortcut.keyCode),
                    onPressed: handler
                )
                mouseButtonMonitors.append(monitor)
                monitor.start()
            }
        }

        // Always-on ⌃⌥A alias for Ask Nugumi, in addition to its configurable
        // (default double-tap ⌃) shortcut above. Fixed id avoids colliding with
        // the action ids 1...7.
        let askNugumiAlias = GlobalHotKey(
            definition: GlobalHotKeyDefinition(id: 100, shortcut: GlobalShortcutAction.askNugumiAlias),
            onPressed: { [weak self] in self?.startAskNugumiPrompt() }
        )
        globalHotKeys.append(askNugumiAlias)
        askNugumiAlias.register()
    }

    /// The quick-menu shortcut (default Mouse 3): opens the same action ring
    /// the floating button shows, but centered on the cursor and with no
    /// selection required. Items that do need text (Explain / Rewrite) reuse
    /// the selection-grabbing shortcut handlers, which fetch whatever is
    /// selected at click time via AX/⌘C and show a hint if nothing is.
    @MainActor
    private func toggleQuickMenuRing() {
        if let quickMenuRing {
            quickMenuRing.close()
            self.quickMenuRing = nil
            return
        }
        // While the recorder is capturing, a mouse-button press is input for
        // the field, not a trigger.
        guard shortcutRecorderWindowController == nil else { return }

        let anchor = NSEvent.mouseLocation
        var items: [RingItem] = [
            .phosphor("magnifying-glass", label: "Explain") { [weak self] in
                self?.quickMenuRing = nil
                self?.startSelectionTranslateOrReply(forcing: .translate)
            },
            .phosphor("pencil-line", label: "Rewrite") { [weak self] in
                self?.quickMenuRing = nil
                self?.startSelectedTextTranslationForReplacement()
            },
            .phosphor("arrow-bend-up-left", label: "Reply") { [weak self] in
                self?.quickMenuRing = nil
                self?.startSelectionTranslateOrReply(forcing: .smartReply)
            },
            .phosphor("question", label: "Ask") { [weak self] in
                self?.quickMenuRing = nil
                self?.startAskNugumiPrompt()
            },
            .phosphor("scan", label: "Capture") { [weak self] in
                self?.quickMenuRing = nil
                self?.startScreenshotTranslation()
            },
            // SF Symbols until waveform/mic Phosphor PNGs are bundled.
            .symbol("mic", label: "Dictate") { [weak self] in
                self?.quickMenuRing = nil
                self?.toggleDictation()
            },
            .symbol("waveform", label: "Live") { [weak self] in
                self?.quickMenuRing = nil
                self?.toggleLiveTranslation()
            },
        ]
        if let opt = makeSummarizeOption(near: anchor, selectionRect: nil, panelSide: .right) {
            items.insert(summarizeRingItem(opt, dismiss: { [weak self] in
                self?.quickMenuRing = nil
            }), at: 5)
        }
        let ring = RadialActionMenuController(
            centeredOn: anchor,
            ignoring: nil,
            items: items,
            showsCenterClose: true,
            onDismiss: { [weak self] in
                self?.quickMenuRing = nil
            }
        )
        quickMenuRing = ring
        ring.show()
    }

    @MainActor
    private func startAskNugumiPrompt() {
        // Toggle: if any Ask Nugumi UI (prompt, loading, answer, or an
        // in-flight request) is already up, the shortcut dismisses it instead
        // of opening another one.
        let askUIOpen = isAskNugumiRunning
            || askPromptController != nil
            || petController?.isPromptVisible == true
        if askUIOpen {
            dismissAskNugumi()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        closeAskAnnotationOverlay()
        translationPanelController?.close()
        translationPanelController = nil

        if selectionDisplayMode == .pet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
                self.presentPetAskPrompt()
                self.presentAskDrawingOverlay()
            }
            return
        }

        let controller = AskPromptController(
            near: NSEvent.mouseLocation,
            onSubmit: { [weak self] prompt in
                self?.submitAskNugumiPrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.askPromptController = nil
                self.pendingAskNugumiCapture = nil
                self.closeAskDrawingOverlay()
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
        )
        askPromptController = controller
        // Capture before `show()`: activating Nugumi closes any menu the
        // user is asking about. The prompt appears one capture (~100 ms)
        // later, with the dropdown already safely in the pending shot.
        Task { @MainActor [weak self] in
            guard let self, self.askPromptController === controller else { return }
            self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            guard self.askPromptController === controller else { return }
            controller.show()
            self.presentAskDrawingOverlay()
        }
    }

    /// Best-effort screen capture for `pendingAskNugumiCapture`. Returns nil
    /// on failure (e.g. missing screen-recording permission) so the submit
    /// path falls back to its own capture with full error reporting.
    @MainActor
    private func captureScreenBeforeAskPromptTakesFocus() async -> AskNugumiScreenCapture? {
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
        let frame = pendingAskNugumiCapture?.screenFrame
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
    private func submitAskNugumiPrompt(_ prompt: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return }

        let model = LLMModel.option(id: askNugumiModelID)
        guard model.supportsImages else {
            askPromptController?.showError("Ask Nugumi needs a vision model.")
            petController?.showPromptError("Needs a vision model.")
            return
        }

        if let setupError = askNugumiSetupErrorIfNeeded(for: model) {
            let message = Self.translationPanelErrorMessage(for: setupError)
            askPromptController?.showError(message)
            petController?.showPromptError(message)
            return
        }

        let requestID = UUID()
        askNugumiTask?.cancel()
        askNugumiRequestID = requestID
        isAskNugumiRunning = true
        askPromptController?.setLoading()
        if petController?.isPromptVisible == true {
            petController?.setPromptLoading()
        }

        // Hide the wide "Ask Nugumi" pill and surface the round loading bar
        // instead — a compact "in flight" indicator that never intercepts
        // clicks (`ignoresMouseEvents = true`). If the request fails,
        // `AskPromptController.showError` calls `panel.makeKeyAndOrderFront`
        // and the pill reappears with the error text.
        if selectionDisplayMode != .pet, let prompt = askPromptController {
            let pillCenter = prompt.panelCenter
            prompt.hidePanel()
            showAskFloatingLoadingBar(at: pillCenter)
        }

        let cursorLocation = NSEvent.mouseLocation
        let backend = askBackend
        // Prefer the capture taken when the prompt was summoned — it still
        // shows transient UI (open menus, popovers) that closed as soon as
        // the prompt took focus. Submit-time capture is the fallback.
        let preparedCapture = pendingAskNugumiCapture
        pendingAskNugumiCapture = nil
        // Strokes are consumed here: composited into the capture below, so
        // the on-screen canvas can come down before the request starts.
        let strokes = askDrawingOverlay?.strokes ?? []
        closeAskDrawingOverlay()
        let question = strokes.isEmpty
            ? cleanPrompt
            : cleanPrompt
                + "\n\n(The red marks on the screenshot are my annotations pointing at what I'm asking about.)"
        askNugumiTask = Task { [weak self] in
            do {
                let capture: AskNugumiScreenCapture
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

                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self, self.askNugumiRequestID == requestID else {
                        return false
                    }
                    self.petController?.showThinking()
                    return true
                }
                guard shouldContinue else { return }

                let history = await MainActor.run { self?.askHistory ?? [] }
                let currentThinkingLevel = await MainActor.run { self?.askNugumiThinkingLevel ?? .high }
                let response = try await backend.ask(
                    history: history,
                    question: question,
                    image: annotatedCapture.image,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                try Task.checkCancellation()

                await MainActor.run {
                    self?.presentAskNugumiResult(
                        response,
                        capture: annotatedCapture,
                        prompt: cleanPrompt,
                        requestID: requestID
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.clearAskNugumiRequestIfCurrent(requestID)
                }
            } catch {
                await MainActor.run {
                    self?.presentAskNugumiFailure(error, requestID: requestID)
                }
            }
        }
    }

    /// Follow-up from the floating answer panel's input field — the Ask
    /// analog of `reviseCurrentPanel`. Reuses the open panel (loading → new
    /// answer in place) and keeps the dialog context (`askHistory`) plus a
    /// fresh screen capture, so it continues the conversation just like pet
    /// mode's "continue" does.
    @MainActor
    private func submitAskNugumiFollowUp(_ instruction: String) {
        let clean = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isAskNugumiRunning,
              let controller = translationPanelController else { return }

        let model = LLMModel.option(id: askNugumiModelID)
        guard model.supportsImages else {
            controller.showError("Ask Nugumi needs a vision model.")
            return
        }
        if let setupError = askNugumiSetupErrorIfNeeded(for: model) {
            controller.showError(Self.translationPanelErrorMessage(for: setupError))
            return
        }

        let requestID = UUID()
        askNugumiTask?.cancel()
        askNugumiRequestID = requestID
        isAskNugumiRunning = true
        let panelRequestID = controller.showLoading()

        let cursorLocation = NSEvent.mouseLocation
        let backend = askBackend
        askNugumiTask = Task { [weak self] in
            do {
                let sharingSnapshot = await MainActor.run { Self.hideAppWindowsFromScreenCapture() }
                let capture: AskNugumiScreenCapture
                do {
                    capture = try await ScreenshotCapture.captureActiveScreen(containing: cursorLocation)
                } catch {
                    await MainActor.run { Self.restoreAppWindowSharing(sharingSnapshot) }
                    throw error
                }
                await MainActor.run { Self.restoreAppWindowSharing(sharingSnapshot) }
                try Task.checkCancellation()

                let history = await MainActor.run { self?.askHistory ?? [] }
                let level = await MainActor.run { self?.askNugumiThinkingLevel ?? .high }
                let response = try await backend.ask(
                    history: history,
                    question: clean,
                    image: capture.image,
                    thinkingLevel: level
                ) { _ in }
                try Task.checkCancellation()

                await MainActor.run {
                    guard let self, self.askNugumiRequestID == requestID,
                          self.translationPanelController === controller else { return }
                    self.clearAskNugumiRequestIfCurrent(requestID)
                    self.recordAskTurn(question: clean, answer: response.message)
                    controller.showTranslation(response.message, requestID: panelRequestID, isFinal: true)
                    self.presentAskAnnotations(response.annotations, capture: capture)
                }
            } catch is CancellationError {
                await MainActor.run { self?.clearAskNugumiRequestIfCurrent(requestID) }
            } catch {
                await MainActor.run {
                    guard let self, self.askNugumiRequestID == requestID,
                          self.translationPanelController === controller else { return }
                    self.clearAskNugumiRequestIfCurrent(requestID)
                    controller.showError(error.localizedDescription, requestID: panelRequestID)
                }
            }
        }
    }

    @MainActor
    private func presentAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture,
        prompt: String,
        requestID: UUID
    ) {
        guard askNugumiRequestID == requestID else { return }
        clearAskNugumiRequestIfCurrent(requestID)
        analyticsClient.track(.askScreenCompleted, properties: [
            "model_id": askNugumiModelID
        ])
        analyticsClient.trackFirstUsefulActionIfNeeded(
            sourceEvent: .askScreenCompleted,
            properties: ["model_id": askNugumiModelID]
        )
        recordAskTurn(question: prompt, answer: response.message)
        hideAskFloatingLoadingBar()
        askPromptController?.close()
        askPromptController = nil

        translationPanelController?.close()
        translationPanelController = nil

        if selectionDisplayMode == .pet {
            presentPetAskNugumiResult(response, capture: capture)
            return
        }

        petController?.clearPrompt()
        let controller = TranslationPanelController(
            anchor: .point(NSEvent.mouseLocation, panelSide: .right),
            sourceText: prompt,
            targetLanguage: targetLanguage,
            resultLabel: "Answer",
            // Same layout as the translate/reply modal: no source box, plus a
            // follow-up field so the dialog can continue like it does in pet mode.
            showsSource: false,
            showsFollowUp: true,
            onFollowUp: { [weak self] instruction in
                self?.submitAskNugumiFollowUp(instruction)
            },
            // The answer is meant to be read — don't let a stray click dismiss it.
            dismissesOnOutsideClick: false,
            onClose: { [weak self] in
                guard let self else { return }
                if self.isAskNugumiRunning { self.cancelAskNugumiRequest() }
                self.translationPanelController = nil
                self.closeAskAnnotationOverlay()
                self.petController?.clearReady()
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
        _ annotations: [AskNugumiAnnotation],
        capture: AskNugumiScreenCapture
    ) {
        guard !annotations.isEmpty else {
            closeAskAnnotationOverlay()
            return
        }
        if let existing = askAnnotationOverlay, existing.screenFrame == capture.screenFrame {
            existing.show(annotations)
        } else {
            askAnnotationOverlay?.close()
            let overlay = AskAnnotationOverlayController(screenFrame: capture.screenFrame)
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
        let offsetX = 5 + AskNugumiFloatingTargetPresentationPolicy.buttonSize / 2
        let offsetY = AskNugumiFloatingTargetPresentationPolicy.buttonSize / 2 + 5
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
    private func presentPetAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture
    ) {
        if petController == nil {
            petController = PetController(initialMode: .selection)
        }

        guard let petController else { return }
        // The pet's own answer-dismiss gesture (click/double-click/Escape)
        // has no other route to the app delegate — see
        // `PetController.onAnswerDismissedByUser`.
        petController.onAnswerDismissedByUser = { [weak self] in
            self?.closeAskAnnotationOverlay()
        }
        // The pixel-font bubble can't render rich text — resolve markdown to
        // plain text so list markers survive and `**`/`|` never leak raw.
        petController.showAnswer(
            TranslationContentView.flattenedMarkdown(response.message),
            emotion: nil
        )
        presentAskAnnotations(response.annotations, capture: capture)
    }

    @MainActor
    private func presentAskNugumiFailure(_ error: Error, requestID: UUID) {
        guard askNugumiRequestID == requestID else { return }
        clearAskNugumiRequestIfCurrent(requestID)
        hideAskFloatingLoadingBar()

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            analyticsClient.track(.errorOccurred, properties: [
                "error_type": "screen_recording_permission_denied",
                "error_context": "ask_screen"
            ])
            askPromptController?.close()
            askPromptController = nil
            petController?.clearPrompt()
            closeAskAnnotationOverlay()
            presentScreenshotTranslationError(screenshotError)
            return
        }

        let routed = handleTranslationFailure(error)
        if routed {
            askPromptController?.close()
            askPromptController = nil
            petController?.clearPrompt()
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
        petController?.showPromptError(error.localizedDescription)
    }

    @MainActor
    private func cancelAskNugumiRequest() {
        askNugumiTask?.cancel()
        askNugumiTask = nil
        askNugumiRequestID = nil
        isAskNugumiRunning = false
        petController?.clearThinking()
        petController?.clearPrompt()
        hideAskFloatingLoadingBar()
    }

    /// Opens the pet prompt input wired to Ask Nugumi. Reused for the initial
    /// shortcut-triggered prompt and for the answer bubble's "continue" button —
    /// `askHistory` persists across launches (see `AskNugumiHistoryStore`) so
    /// follow-ups keep context.
    @MainActor
    private func presentPetAskPrompt() {
        if petController == nil {
            petController = PetController(initialMode: .draftMessage)
        }
        petController?.onContinue = { [weak self] in
            self?.continueAskNugumiDialog()
        }
        petController?.showPrompt(
            onSubmit: { [weak self] prompt in
                self?.submitAskNugumiPrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.pendingAskNugumiCapture = nil
                self.closeAskDrawingOverlay()
                self.closeAskAnnotationOverlay()
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
        )
    }

    /// "Continue dialog" affordance on the answer bubble: re-open the prompt
    /// for a follow-up question in the same conversation.
    @MainActor
    private func continueAskNugumiDialog() {
        guard !isAskNugumiRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            self.presentPetAskPrompt()
            self.presentAskDrawingOverlay()
        }
    }

    /// Tears down every Ask Nugumi surface (pet prompt/answer, standalone
    /// prompt window, in-flight request). Used by the Ask Nugumi shortcut toggle.
    @MainActor
    private func dismissAskNugumi() {
        if isAskNugumiRunning {
            cancelAskNugumiRequest()
        }
        pendingAskNugumiCapture = nil
        closeAskDrawingOverlay()
        askPromptController?.close()
        askPromptController = nil
        petController?.clearPrompt()
        closeAskAnnotationOverlay()
        hideAskFloatingLoadingBar()
    }

    @MainActor
    private func recordAskTurn(question: String, answer: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !trimmedAnswer.isEmpty else { return }
        let turn = AskNugumiTurn(question: trimmedQuestion, answer: trimmedAnswer)
        askHistory = AskNugumiPromptBuilder.appending(turn, to: askHistory)
        AskNugumiHistoryStore.save(askHistory)
        translationHistoryStore.recordAsk(question: trimmedQuestion, answer: trimmedAnswer)
    }

    @MainActor
    private func recordTranslation(
        source: String,
        result: String,
        kind: UsageStatsEventKind,
        targetLanguage: TranslationLanguage
    ) {
        usageStatsStore.recordUse(sourceText: source, resultText: result, kind: kind, targetLanguage: targetLanguage)
        translationHistoryStore.record(sourceText: source, resultText: result, kind: kind, targetLanguage: targetLanguage)
    }

    private static func hideAppWindowsFromScreenCapture() -> [WindowSharingSnapshot] {
        let snapshots = NSApp.windows.map { window in
            WindowSharingSnapshot(window: window, sharingType: window.sharingType)
        }
        NSApp.windows.forEach { window in
            window.sharingType = .none
        }
        return snapshots
    }

    private static func restoreAppWindowSharing(_ snapshots: [WindowSharingSnapshot]) {
        snapshots.forEach { snapshot in
            snapshot.window.sharingType = snapshot.sharingType
        }
    }

    @MainActor
    private func clearAskNugumiRequestIfCurrent(_ requestID: UUID) {
        guard askNugumiRequestID == requestID else { return }
        askNugumiTask = nil
        askNugumiRequestID = nil
        isAskNugumiRunning = false
        petController?.clearThinking()
    }

    @MainActor
    private func askNugumiSetupErrorIfNeeded(for model: LLMModel) -> TranslationError? {
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

    @objc private func toggleInvisibilityMode() {
        let now = !invisibilityModeEnabled
        invisibilityModeEnabled = now
        statusItem?.isVisible = !now
        InvisibilityState.applyToAllOpenWindows()
        updateMenuState()
        if now && !UserDefaults.standard.bool(forKey: InvisibilityState.firstRunShownKey) {
            showInvisibilityFirstRunDialog()
            UserDefaults.standard.set(true, forKey: InvisibilityState.firstRunShownKey)
        }
    }

    private func showInvisibilityFirstRunDialog() {
        let chord = shortcut(for: .toggleInvisibility).displayString
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: "Invisibility mode is on",
            message: "Nugumi is now hidden from screenshots and screen sharing, and the menu-bar icon is gone. Press \(chord) anywhere to bring it back.",
            primaryButtonTitle: "Got it"
        ).showModal()
    }

    /// Flips the writing (draft) language with the configured alternate, swapping
    /// the two so the pair {writing language, alternate} is preserved each toggle.
    @objc private func toggleWritingLanguageAction() {
        let previous = draftTargetLanguage
        let next = writingToggleAlternate
        draftTargetLanguage = next
        writingToggleAlternate = previous
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
        LanguageToggleHUD.shared.show(text: "Writing in \(next.displayName)")
    }

    @MainActor
    @objc private func toggleLiveTranslationFromMenu() {
        toggleLiveTranslation()
    }

    /// Live translation runs exclusively on OpenAI's realtime model, so it is
    /// gated on an OpenAI API key regardless of which provider the rest of the
    /// app uses. A missing/empty key surfaces `presentLiveTranslationAPIKeyAlert`
    /// via the controller's `onMissingAPIKey` hook before any capture starts.
    @MainActor
    private func toggleLiveTranslation() {
        liveTranslationController.toggle(
            apiKey: KeychainStore.apiKey(for: .openAI),
            targetLanguage: targetLanguage
        )
    }

    /// Dictation shares live translation's OpenAI realtime dependency (and
    /// its key gate + mic-permission alerts).
    @MainActor
    private func toggleDictation() {
        dictationController.toggle(apiKey: KeychainStore.apiKey(for: .openAI))
    }

    @MainActor
    private func presentLiveTranslationAPIKeyAlert(feature: String = "Live translation") {
        NSApp.activate(ignoringOtherApps: true)
        let response = NugumiAlertController(
            title: "OpenAI API key required",
            message: "\(feature) runs on OpenAI's realtime model. Add an OpenAI API key under AI Engine → API key models, then try again.",
            primaryButtonTitle: "Open AI Engine",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else { return }
        presentMainWindow(section: .aiEngine)
    }

    @MainActor
    private func presentMicrophonePermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let response = NugumiAlertController(
            title: "Microphone access needed",
            message: "Live captions listen to your microphone. Allow access under System Settings → Privacy & Security → Microphone, then start again.",
            primaryButtonTitle: "Open Settings",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    private func setupBootstrap() {
        wireBootstrap()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            // While onboarding is up, don't stack the main window on top of
            // it — the onboarding close handler opens it (on AI Engine when
            // no model is ready) via showMainWindowOnFirstRunIfNeeded.
            guard self.onboardingWindowController == nil else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentMainWindow(section: .aiEngine)
            }
        }
    }

    private func wireBootstrap() {
        bootstrap.onChange = { [weak self] state in
            self?.handleBootstrapStateChange(state)
        }
        bootstrap.refresh()
    }

    @MainActor
    private func onModelSelectionChanged(for scope: ModelUseScope) {
        bootstrap.refresh()
        guard scope == .textActions else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentMainWindow(section: .aiEngine)
            }
        }
    }

    @MainActor
    private func handleBootstrapStateChange(_ state: BootstrapState) {
        let currentID = textModelID
        let previous = lastObservedModelReadyState[currentID] ?? .unknown
        let current = state.modelReady(for: currentID)
        if case .working = previous, case .ok = current {
            postTranslatorReadyNotification()
        }
        // Any model that just became ready can satisfy an engine preset —
        // e.g. a slot stuck on a broken factory default heals the moment
        // gpt-oss:20b / Gemma finishes installing (or is discovered already
        // installed on first refresh).
        let anyBecameReady = ModelReadyTransition.anyBecameReady(
            previous: lastObservedModelReadyState, current: state.modelReady)
        lastObservedModelReadyState = ModelReadyTransition.merge(
            into: lastObservedModelReadyState, current: state.modelReady)
        // A pull the user started from the AI Engine setup card just finished —
        // promote it to the everyday-text default, once. Runs before the
        // preset so an explicit pull wins the text slot.
        if let pendingID = pendingOllamaAutoSelectID,
           case .ok = state.modelReady(for: pendingID) {
            pendingOllamaAutoSelectID = nil
            applyModelSelection(pendingID, for: .textActions)
        }
        if anyBecameReady {
            applyEnginePreset(.ollama)
        }
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    @MainActor
    private func postTranslatorReadyNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.deliverTranslatorReadyNotification()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Self.deliverTranslatorReadyNotification()
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated private static func deliverTranslatorReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Nugumi is ready"
        content.body = "The translator finished downloading. Press your shortcut or select text to start."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "nugumi.translator.ready.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Launching the app again from /Applications while it's already running
    /// lands here (macOS sends a reopen event to the running instance). With
    /// the menu bar icon hidden this is the only way back into the app, so
    /// always surface a window: onboarding if the tour is still up, otherwise
    /// the main window.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Ignore the reopen our own panels trigger when they activate the app to
        // take focus — only a genuine Dock/Finder relaunch should surface a window.
        if SelfActivationGuard.isSuppressing { return false }
        if let onboardingWindowController {
            onboardingWindowController.presentAndActivate()
        } else {
            presentMainWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        petController?.close()
        modifierDetectors.forEach { $0.stop() }
        modifierDetectors.removeAll()
        globalHotKeys.forEach { $0.unregister() }
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
        screenRecordingTrustTimer?.invalidate()
        screenRecordingTrustTimer = nil
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.length = 24
        if let button = statusItem.button {
            button.title = ""
            button.image = makeStatusBarIcon(for: floatingDefaultMode)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Nugumi"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.statusItem = statusItem
    }

    @MainActor
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isContextClick, let button = statusItem?.button {
            let menu = makeStatusBarMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else {
            openMainWindow()
        }
    }

    @MainActor
    private func makeStatusBarMenu() -> NSMenu {
        let menu = NSMenu()

        if isRunningFromAppBundle {
            let updates: NSMenuItem
            if let version = availableUpdate?.displayVersionString {
                updates = NSMenuItem(title: "Install update \(version)...", action: #selector(checkForUpdates), keyEquivalent: "")
                updates.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update available")
            } else {
                updates = NSMenuItem(title: "Check for updates...", action: #selector(checkForUpdates), keyEquivalent: "")
            }
            updates.target = self
            menu.addItem(updates)
        }
        let contact = NSMenuItem(title: "Contact me...", action: #selector(contactSupport), keyEquivalent: "")
        contact.target = self
        menu.addItem(contact)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nugumi", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// The Nugumi pixel character with no background, rendered in its own colours
    /// (so the eyes and nose stay visible — a template would flatten it to a blob).
    private func makeStatusBarIcon(for mode: FloatingButtonDefaultMode) -> NSImage {
        PetMascotView.markImage(height: 20, mode: mode.translationMode) ?? NSApp.applicationIconImage
    }

    private func refreshStatusBarIcon() {
        statusItem?.button?.image = makeStatusBarIcon(for: floatingDefaultMode)
    }

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            if event.type == .leftMouseDown {
                self.lastLeftMouseDownLocation = mouseLocation
                self.lastMouseDownPasteboardChangeCount = NSPasteboard.general.changeCount
                self.lastMouseDownDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
                self.lastMouseDownWindowNumber = event.windowNumber
                self.lastMouseDownWindowBounds = Self.windowBounds(forWindowNumber: event.windowNumber)
                if self.isScreenshotTranslationRunning {
                    self.screenshotDragStartLocation = mouseLocation
                    self.screenshotDragEndLocation = nil
                    return
                }
                // This click is already dropping any live selection in the
                // target app — dismiss the selection UI now instead of after
                // the mouse-up read (80ms gate + AX + up to 0.5s clipboard
                // poll). If this same gesture makes a new selection, the
                // mouse-up pipeline re-shows it.
                if let controller = self.translationPanelController,
                   controller.isVisible,
                   controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
                    return
                }
                self.translateButtonController?.close()
                self.translateButtonController = nil
                self.petController?.clearReady()
                return
            }

            if event.type == .leftMouseDragged {
                if self.isScreenshotTranslationRunning {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            if self.isScreenshotTranslationRunning {
                if event.type == .leftMouseUp {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            self.handleMouseUp(event)
        }
    }

    private func startKeyboardMonitor() {
        // Global, listen-only — Cmd+A still propagates to the focused app so
        // its native select-all fires. We just want to know when it happened
        // so we can read the resulting selection and show the translate UI.
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command, event.keyCode == UInt16(kVK_ANSI_A) else {
                return
            }
            self.handleSelectAll()
        }
    }

    private func handleSelectAll() {
        guard selectionDisplayMode != .off else { return }
        guard accessibilityIsTrusted() else { return }
        guard !isCloudSignInActive else { return }

        // Cmd+A inside Nugumi's own panels means "select the prompt input",
        // not "translate everything" — drop those events.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        if frontmostBundleID == Bundle.main.bundleIdentifier {
            return
        }
        let frontmostAppName = frontmostApp?.localizedName ?? frontmostBundleID ?? "this app"
        let pasteboardBaseline = NSPasteboard.general.changeCount

        // The target app updates its AX selection state after macOS dispatches
        // the Cmd+A keystroke. Mirror the mouse-up gating delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            // ⌘A in Finder selects files, not text — a synthesized ⌘C would
            // copy the files themselves. AX-only read there (silent, no-op).
            // Same for open/save panels in any app: ⌘A selects file rows.
            let allowsClipboard = frontmostBundleID != "com.apple.finder"
                && !self.selectionReader.isInsideOpenSavePanel()
            let preferClipboard = allowsClipboard
                && !self.selectionReader.isLikelyEditableElementAtMouseLocation()
            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: allowsClipboard,
                pasteboardBaseline: pasteboardBaseline
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    self.noteUnreadableSelection(
                        bundleID: frontmostBundleID,
                        appName: frontmostAppName
                    )
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                self.clearUnreadableSelectionCounter(bundleID: frontmostBundleID)

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                let anchor = self.selectAllAnchorPoint(from: selection.selectionRect)
                self.showTranslateButton(
                    for: cleanedSelection,
                    near: anchor,
                    selectionRect: selection.selectionRect,
                    panelSide: .right
                )
            }
        }
    }

    private func selectAllAnchorPoint(from rect: NSRect?) -> NSPoint {
        // Cmd+A has no mouse-based anchor. Prefer the bottom-right corner of
        // the reported selection rect; fall back to current pointer position.
        if let rect, rect.width > 0, rect.height > 0 {
            return NSPoint(x: rect.maxX, y: rect.minY)
        }
        return NSEvent.mouseLocation
    }

    @MainActor
    private func applySelectionDisplayMode() {
        switch selectionDisplayMode {
        case .floatingBar:
            petController?.close()
            petController = nil
        case .off:
            petController?.close()
            petController = nil
            translateButtonController?.close()
            translateButtonController = nil
        case .pet:
            translateButtonController?.close()
            translateButtonController = nil
            if petController == nil {
                petController = PetController(initialMode: floatingDefaultMode.translationMode)
            }
            petController?.show()
        }

        updateMenuState()
    }

    private var lastAccessibilitySelectionPromptAt: Date?

    private func handleMouseUp(_ event: NSEvent) {
        guard accessibilityIsTrusted() else {
            // Reading the highlighted text needs Accessibility, so without it a
            // drag-select would silently do nothing. When the user clearly made
            // a selection gesture, surface the permission request — throttled so
            // we never spam System Settings on repeated drags / stray gestures.
            if selectionDisplayMode != .off,
               isLikelySelectionGesture(event, upLocation: NSEvent.mouseLocation),
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                let now = Date()
                if lastAccessibilitySelectionPromptAt.map({ now.timeIntervalSince($0) > 15 }) ?? true {
                    lastAccessibilitySelectionPromptAt = now
                    requestAccessibilityPermissionInteractively()
                }
            }
            return
        }

        // A cloud sign-in panel (ChatGPT/Claude) is up. Clicking around its page
        // would otherwise post a synthetic ⌘+C on every mouse-up (clipboard
        // fallback) and beep when there's no selection. Skip until sign-in ends.
        if isCloudSignInActive {
            return
        }

        // The shortcut recorder is up. Any synthesized ⌘+C we'd post during
        // the clipboard fallback below would land in Nugumi (now frontmost)
        // and the recorder field would capture it as the user's shortcut —
        // see KeyboardShortcutPoster.postCommandShortcut. Hard-skip while the
        // recorder is open.
        if shortcutRecorderWindowController != nil {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if let controller = translationPanelController,
           controller.isVisible,
           controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
            return
        }

        // Capture the frontmost app at gesture time, not at completion time —
        // the user may have switched apps during the 80ms+AX-read window, and
        // we want to attribute the unreadable-selection signal to the app
        // where the drag actually happened.
        let isSelectionGesture = isLikelySelectionGesture(event, upLocation: mouseLocation)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        let frontmostAppName = frontmostApp?.localizedName ?? frontmostBundleID ?? "this app"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            // The async window is long enough for the user to have brought
            // Nugumi to the front (e.g. opened the menu to set a shortcut).
            // Re-check before posting any synthetic keystrokes.
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                return
            }
            if self.shortcutRecorderWindowController != nil {
                return
            }
            // A drag in Finder (desktop included) is a marquee selecting
            // files, not text. Never synthesize ⌘C there: with nothing
            // selected Finder beeps, and with icons selected it clobbers the
            // clipboard with the files and "translates" their names.
            // Open/save panels in ANY app are the same file-browsing surface
            // (double-clicking a folder to enter it counts as a selection
            // gesture and would beep on every navigation).
            let allowsClipboard = frontmostBundleID != "com.apple.finder"
                && !self.selectionReader.isInsideOpenSavePanel()
            let preferClipboard = allowsClipboard
                && self.shouldAttemptClipboardSelectionFallback(for: event, upLocation: mouseLocation)

            // Clipboard fallback after a failed AX read covers apps that
            // expose a text-area-ish AX role (so `preferClipboard` is false)
            // but don't actually publish `kAXSelectedTextAttribute` —
            // KakaoTalk chat bubbles being the canonical example. Only allow
            // it when the user clearly meant to select something; otherwise
            // a stray click would synthesize Cmd+C for nothing.
            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: isSelectionGesture && allowsClipboard,
                pasteboardBaseline: self.lastMouseDownPasteboardChangeCount
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    // Don't count Finder marquee drags as "app blocks text
                    // access" — they never had text to begin with.
                    if isSelectionGesture && allowsClipboard {
                        self.noteUnreadableSelection(
                            bundleID: frontmostBundleID,
                            appName: frontmostAppName
                        )
                    }
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                // The app exposed *some* selection text — even if we end up
                // discarding it as not meaningful below, that's a "user
                // selected garbage" case, not an "app blocks access" case.
                if isSelectionGesture {
                    self.clearUnreadableSelectionCounter(bundleID: frontmostBundleID)
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                self.showTranslateButton(
                    for: cleanedSelection,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation)
                )
            }
        }
    }

    private func panelSideForSelectionEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        panelSideForDrag(from: lastLeftMouseDownLocation, to: mouseLocation)
    }

    private func panelSideForScreenshotEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        screenshotPanelSide ?? panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    private func panelSideForDrag(from startLocation: NSPoint?, to endLocation: NSPoint) -> TranslationPanelController.Side {
        guard let startLocation else { return .right }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        // Need a meaningful horizontal drag — vertical or tiny drags
        // give no reliable direction signal, so default to .right.
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return .right }
        return dx > 0 ? .right : .left
    }

    private func updateScreenshotDrag(to mouseLocation: NSPoint) {
        screenshotDragEndLocation = mouseLocation
        screenshotPanelSide = panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    @MainActor
    private func startScreenshotDragTracking() {
        resetScreenshotDragTracking()
        let tracker = ScreenshotDragTracker { [weak self] startLocation, endLocation, panelSide in
            guard let self else { return }
            if let startLocation {
                self.screenshotDragStartLocation = startLocation
            }
            if let endLocation {
                self.screenshotDragEndLocation = endLocation
            }
            if let panelSide {
                self.screenshotPanelSide = panelSide
            }
        }
        screenshotDragTracker = tracker
        tracker.enable()
    }

    @MainActor
    private func resetScreenshotDragTracking() {
        screenshotDragTracker?.disable()
        screenshotDragTracker = nil
        screenshotDragStartLocation = nil
        screenshotDragEndLocation = nil
        screenshotPanelSide = nil
    }

    private func shouldAttemptClipboardSelectionFallback(for event: NSEvent, upLocation: NSPoint) -> Bool {
        guard isLikelySelectionGesture(event, upLocation: upLocation) else {
            return false
        }

        return !selectionReader.isLikelyEditableElementAtMouseLocation()
    }

    /// Drag OR double-click. Double-click selects a word in text but
    /// *activates* rows/folders/chats elsewhere, and in AX-opaque apps
    /// (KakaoTalk) there is no pre-flight signal to tell the cases apart —
    /// so a navigation double-click there beeps via the synthesized ⌘C.
    /// Vadim accepted that trade-off on 2026-07-16 (reversing the
    /// 2026-07-03 drag-only decision) so double-click word lookup works
    /// in AX-opaque apps again.
    private func isLikelySelectionGesture(_ event: NSEvent, upLocation: NSPoint) -> Bool {
        guard event.type == .leftMouseUp else {
            return false
        }

        if event.clickCount >= 2 {
            return true
        }

        return isDragSelectionGesture(event, upLocation: upLocation)
    }

    /// A real drag: ≥15pt of travel with no refuting signal (drag-and-drop
    /// session, window move/resize).
    /// `upLocation` must be the pointer position captured AT the mouse-up
    /// event. This runs again inside the 80ms-delayed read, and reading
    /// `NSEvent.mouseLocation` there instead measured wherever the cursor
    /// had flicked to after the click — a stationary double-click followed
    /// by a quick mouse move read as a ≥15pt "drag" and beeped via the
    /// clipboard fallback's ⌘C.
    private func isDragSelectionGesture(_ event: NSEvent, upLocation: NSPoint) -> Bool {
        guard event.type == .leftMouseUp else {
            return false
        }

        guard let downLocation = lastLeftMouseDownLocation else {
            return false
        }

        // A real drag-and-drop session (files, photos, dragged text) always
        // writes to the drag pasteboard when the session starts; a
        // drag-to-select never does. Dropping a photo into a browser input
        // used to read as a selection drag here, and the clipboard fallback's
        // synthesized ⌘C then beeped with nothing to copy.
        if let baseline = lastMouseDownDragPasteboardChangeCount,
           NSPasteboard(name: .drag).changeCount != baseline {
            return false
        }

        // Moving or resizing a window travels ≥15pt too, but never selects
        // text — the synthesized ⌘C after dropping a window beeped just like
        // the drag-and-drop case. During a genuine text-selection drag the
        // window under the gesture keeps its frame; if it moved or resized,
        // this was window manipulation.
        if let windowNumber = lastMouseDownWindowNumber,
           let startBounds = lastMouseDownWindowBounds,
           Self.windowBounds(forWindowNumber: windowNumber) != startBounds {
            return false
        }

        let distance = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
        return distance >= 15
    }

    /// Frame of any on-screen window (any app) by window number, in CG
    /// screen coordinates. Bounds are readable without Screen Recording
    /// permission — only window *names* are gated.
    private static func windowBounds(forWindowNumber windowNumber: Int) -> CGRect? {
        guard let windowID = CGWindowID(exactly: windowNumber), windowID > 0 else {
            return nil
        }
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let boundsDict = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }
        return bounds
    }

    private func clearUnreadableSelectionCounter(bundleID: String?) {
        guard let bundleID else { return }
        unreadableSelectionFailureCounts[bundleID] = 0
    }

    private func noteUnreadableSelection(bundleID: String?, appName: String) {
        guard selectionDisplayMode != .off else { return }
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        // UNUserNotificationCenter.current() aborts in non-bundle contexts
        // (`swift run`). Skipping here also avoids polluting the persistent
        // "already shown" set with bundles seen only during dev, which would
        // suppress the hint forever in the user-facing .app build.
        guard isRunningFromAppBundle else { return }

        let next = (unreadableSelectionFailureCounts[bundleID] ?? 0) + 1
        unreadableSelectionFailureCounts[bundleID] = next

        guard next >= Self.unreadableSelectionFailureThreshold else { return }

        let defaults = UserDefaults.standard
        let key = Self.unreadableSelectionHintShownDefaultsKey
        var shown = Set(defaults.stringArray(forKey: key) ?? [])
        guard !shown.contains(bundleID) else { return }
        shown.insert(bundleID)
        defaults.set(Array(shown).sorted(), forKey: key)

        Self.deliverUnreadableSelectionHint(appName: appName)
    }

    nonisolated private static func deliverUnreadableSelectionHint(appName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Nugumi can't read text in \(appName)"
            content.body = "This app doesn't expose its selection to other apps. Try Screenshot Translation instead."
            let request = UNNotificationRequest(
                identifier: "nugumi.selection.unreadable.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    @MainActor
    private func showTranslateButton(
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
                    self?.startAskNugumiPrompt()
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
                summarizeOption: summarizeOption
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
                self?.startAskNugumiPrompt()
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
            summarizeOption: summarizeOption
        )

        translateButtonController = controller
        controller.show()
    }

    /// AX title of the frontmost app's focused window (best-effort; nil on
    /// any AX failure — the caller falls back to the most-recent chat).
    @MainActor
    private func focusedWindowTitle(pid: pid_t) -> String? {
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
    private func makeSummarizeOption(
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) -> RingSummarizeOption? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Browsers: summarize the open page. No time-range sub-ring — a page
        // has no time axis, so the button fires immediately.
        if BrowserPageReader.isBrowser(app.bundleIdentifier) {
            let pid = app.processIdentifier
            let pageTitle = focusedWindowTitle(pid: pid)
            let icon = app.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
            return RingSummarizeOption(
                appLabel: app.localizedName ?? "browser",
                appIcon: icon,
                runDirect: { [weak self] in
                    self?.runPageSummary(
                        pid: pid,
                        pageTitle: pageTitle,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide
                    )
                }
            )
        }
        guard let open = ChatArchiveFactory.archive(forFrontmostBundleID: app.bundleIdentifier) else {
            // Frontmost isn't a summarizable app — offer an app picker so a
            // summary can be started from anywhere.
            let choices = summarizeAppChoices(near: screenPoint, selectionRect: selectionRect, panelSide: panelSide)
            guard !choices.isEmpty else { return nil }
            let icon = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Summarize") ?? NSImage()
            return RingSummarizeOption(appLabel: "Summarize", appIcon: icon, appChoices: choices)
        }
        let title = focusedWindowTitle(pid: app.processIdentifier)
        let icon = app.icon ?? NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil) ?? NSImage()
        let label = app.localizedName ?? "chat"
        // Warm the cached KakaoTalk userId recovery now, off the click path, so
        // the first summary isn't blocked on the multi-second SHA-512 search.
        if app.bundleIdentifier == "com.kakao.KakaoTalkMac" {
            Task.detached(priority: .utility) { KakaoArchive.prewarmUserId() }
        }
        // Telegram's window title is the account name and its chat DB has no
        // reliable open-chat pointer, so read the open chat off the screen
        // (OCR the header) at summary time. Other messengers use the AX title.
        let ocrProvider: (() async -> [String])? =
            app.bundleIdentifier == TelegramChatDetector.bundleID
            ? { await TelegramChatDetector.openChatTitleCandidates() }
            : nil
        return RingSummarizeOption(appLabel: label, appIcon: icon, run: { [weak self] range in
            self?.runChatSummary(
                open: open,
                windowTitle: title,
                ocrProvider: ocrProvider,
                range: range,
                near: screenPoint,
                selectionRect: selectionRect,
                panelSide: panelSide
            )
        })
    }

    /// Summarize sources for the "from anywhere" picker. Messengers read their
    /// local DB regardless of whether they're running; the browser entry needs a
    /// running browser. Each fires directly — most-recent chat over the last
    /// week for messengers, the page for a browser — since there's no open-chat
    /// context and (for browsers) no time axis.
    @MainActor
    private func summarizeAppChoices(
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) -> [RingSummarizeOption] {
        var choices: [RingSummarizeOption] = []
        let ws = NSWorkspace.shared
        for (bundleID, label) in [("com.kakao.KakaoTalkMac", "KakaoTalk"), (TelegramChatDetector.bundleID, "Telegram")] {
            guard let open = ChatArchiveFactory.archive(forFrontmostBundleID: bundleID),
                  let appURL = ws.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            if bundleID == "com.kakao.KakaoTalkMac" {
                Task.detached(priority: .utility) { KakaoArchive.prewarmUserId() }
            }
            let icon = ws.icon(forFile: appURL.path)
            choices.append(RingSummarizeOption(appLabel: label, appIcon: icon, run: { [weak self] range in
                self?.runChatSummary(
                    open: open, windowTitle: nil, ocrProvider: nil, range: range,
                    near: screenPoint, selectionRect: selectionRect, panelSide: panelSide
                )
            }))
        }
        if let browser = ws.runningApplications.first(where: {
            BrowserPageReader.isBrowser($0.bundleIdentifier) && !$0.isTerminated
        }) {
            let pid = browser.processIdentifier
            let icon = browser.icon ?? (NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage())
            choices.append(RingSummarizeOption(appLabel: browser.localizedName ?? "Browser", appIcon: icon, runDirect: { [weak self] in
                self?.runPageSummary(
                    pid: pid, pageTitle: nil,
                    near: screenPoint, selectionRect: selectionRect, panelSide: panelSide
                )
            }))
        }
        return choices
    }

    /// Opens the chat archive, matches the frontmost chat by window title
    /// (falling back to the most-recently active chat), keeps the messages
    /// within the chosen time `range`, and panels the summary through the
    /// existing `translate(...)` path with `.summarizeChat`. Never crashes — any
    /// `ChatArchiveError` (or other failure) is surfaced via
    /// `presentChatSummaryError`.
    ///
    /// `open()` (ioreg + PBKDF2 + SQLCipher's own KDF) and the SQL reads can
    /// take several hundred ms to ~1s on a real KakaoTalk DB, so that whole
    /// local pipeline runs off the main thread in a detached task. Only the
    /// consent alert, `translate(...)`, and error presentation stay on the
    /// main actor.
    @MainActor
    private func runChatSummary(
        open: @escaping () throws -> ChatArchive,
        windowTitle: String?,
        ocrProvider: (() async -> [String])? = nil,
        range: SummaryTimeRange,
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) {
        let cutoff = range.cutoff()
        Task { [weak self] in
            guard let self else { return }
            do {
                // Read the on-screen chat (Telegram) before the DB work; empty
                // for messengers that don't need it (Kakao uses the AX title).
                let ocrCandidates = await ocrProvider?() ?? []
                let transcript = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    let archive = try open()
                    let (chat, _) = try archive.chat(forWindowTitle: windowTitle, ocrCandidates: ocrCandidates)
                    // Pull a generous recent window, then keep only the chosen
                    // time range; the token-budget trim caps the final output.
                    let recent = try archive.messages(chatID: chat.id, limit: 3000)
                    let inRange = recent.filter { $0.date >= cutoff }
                    guard !inRange.isEmpty else { throw ChatArchiveError.emptyChat }
                    return ChatTranscript.format(inRange, maxMessages: inRange.count, tokenBudget: 12_000)
                }.value

                // Nothing leaves the device only when running a genuinely local
                // Ollama model — an Ollama-hosted cloud model (e.g.
                // gpt-oss:120b-cloud) still routes through OllamaClient but
                // executes on Ollama's cloud infra, so it needs the gate too.
                let runsTrulyLocally = (self.currentBackend is OllamaClient) && !LLMModel.option(id: self.textModelID).isCloud
                if !runsTrulyLocally, !SummaryConsent.accepted {
                    guard self.presentSummaryCloudConsentAlert() else { return }
                    SummaryConsent.accepted = true
                }

                // The summary is a terminal action, not tied to the armed
                // selection — dismiss the floating bar/pet as the panel opens
                // instead of keeping it "ready" behind the Summary window.
                self.translateButtonController?.close()
                self.translateButtonController = nil
                self.petController?.clearReady()
                self.translate(
                    transcript,
                    near: screenPoint,
                    mode: .summarizeChat,
                    useCache: false,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    keepPetReadyUntilPanelCloses: false,
                    restoresReadyOnUserDismiss: false
                )
            } catch {
                self.presentChatSummaryError(error)
            }
        }
    }

    /// Browser twin of `runChatSummary`: reads the frontmost page's text off
    /// the AX tree (blocking mach IPC — runs in a detached task), then panels
    /// the summary through the existing `translate(...)` path with
    /// `.summarizePage`. Same cloud-consent gate and error surface as chats.
    @MainActor
    private func runPageSummary(
        pid: pid_t,
        pageTitle: String?,
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try BrowserPageReader.pageText(pid: pid)
                }.value
                let page = pageTitle.map { "\($0)\n\n\(text)" } ?? text

                let runsTrulyLocally = (self.currentBackend is OllamaClient) && !LLMModel.option(id: self.textModelID).isCloud
                if !runsTrulyLocally, !SummaryConsent.accepted {
                    guard self.presentSummaryCloudConsentAlert(forPage: true) else { return }
                    SummaryConsent.accepted = true
                }

                self.translateButtonController?.close()
                self.translateButtonController = nil
                self.petController?.clearReady()
                self.translate(
                    page,
                    near: screenPoint,
                    mode: .summarizePage,
                    useCache: false,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    keepPetReadyUntilPanelCloses: false,
                    restoresReadyOnUserDismiss: false
                )
            } catch {
                self.presentChatSummaryError(error, title: "Couldn't summarize the page")
            }
        }
    }

    /// One-time modal consent gate shown before the first cloud-backend chat
    /// summary. Returns `true` if the user chose to continue (caller
    /// proceeds and persists the choice); `false` means abort — the caller
    /// must not run the summary. Blocking `runModal()` on the main thread
    /// mirrors the existing `contactSupport()` alert pattern.
    @MainActor
    private func presentSummaryCloudConsentAlert(forPage: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = forPage ? "Send this page to your AI provider?" : "Send this chat to your AI provider?"
        alert.informativeText = forPage
            ? "The page contents will be sent to your selected AI provider to generate this summary."
            : "Chat contents — including messages from other people — will be sent to your selected AI provider to generate this summary."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Surfaces a chat-summary failure. `handleTranslationFailure` only
    /// recognizes `TranslationError` (it's the setup/auth-recovery path for
    /// the translation backends), so a `ChatArchiveError` here falls through
    /// to the same plain-message alert the rest of the app already uses for
    /// "nothing to act on" failures (`presentSelectionTranslationError`).
    @MainActor
    private func presentChatSummaryError(_ error: Error, title: String = "Couldn't summarize chat") {
        let message = (error as? ChatArchiveError)?.description
            ?? (error as? BrowserPageReader.PageError)?.description
            ?? error.localizedDescription
        presentSelectionTranslationError(message, title: title)
    }

    @MainActor
    private func rewriteSelectedDraftText(
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
    private func replyToSelection(
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
    private func translate(
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
                    reviseMode: (mode == .selection || mode == .summarizeChat || mode == .summarizePage) ? .revise : .reviseMessage,
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
    private func compositionSettings(for mode: TranslationMode, appCategory: AppCategory) -> CompositionSettings? {
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
    private func handleTranslationFailure(_ error: Error, controller: TranslationPanelController? = nil) -> Bool {
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

    private static func analyticsErrorType(_ error: Error) -> String {
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

    private static func translationPanelErrorMessage(for error: Error) -> String {
        guard let translationError = error as? TranslationError else {
            return "Could not translate this.\n\(error.localizedDescription)"
        }

        switch translationError {
        case .ollama(let message):
            return "Could not translate this.\n\(message)"
        case .emptyResponse:
            return "No translation came back. Try again."
        case .modelDownloading(let detail):
            return "Translator is still downloading.\n\(detail)"
        case .serverUnavailable:
            return "Ollama is not running."
        case .modelMissing:
            return "Translator is not downloaded yet."
        case .signInRequired:
            return "Sign in to Ollama to use the online translator."
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
    private func translationErrorIfBootstrapBusy(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        if case .working(let detail) = bootstrap.state.modelReady(for: modelID) {
            return .modelDownloading(detail)
        }
        return nil
    }

    @MainActor
    private func translationErrorIfBootstrapNeedsSetup(for modelID: String? = nil) -> TranslationError? {
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

    @MainActor
    private func requestAccessibilityPermissionIfNeeded() {
        // prompt:false silently registers Nugumi in System Settings → Privacy &
        // Security → Accessibility (so the TCC entry exists and the user can find
        // the toggle), without surfacing macOS's stock "would like to control this
        // computer using accessibility features" dialog. The friendlier prompt
        // lives in OnboardingWindowController.
        let probe = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(probe) else {
            return
        }
        startAccessibilityTrustWatcher()
    }

    private func accessibilityIsTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Point-of-use Accessibility request (selection / reply shortcuts). The
    /// launch-time `requestAccessibilityPermissionIfNeeded` (prompt:false)
    /// already registers Nugumi in the Accessibility list — and macOS only ever
    /// shows its native prompt:true dialog while the app is ABSENT from that
    /// list, so prompt:true here is a permanent silent no-op. Open the
    /// Accessibility pane directly instead: it's the only reliably-visible
    /// "grant me access" UI we can surface at point of use.
    @MainActor
    private func requestAccessibilityPermissionInteractively() {
        // Re-probe (prompt:false) so the Nugumi row exists even right after a
        // tccutil reset, then jump straight to the toggle.
        let probe = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(probe)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startAccessibilityTrustWatcher()
    }

    private func startAccessibilityTrustWatcher() {
        guard accessibilityTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.accessibilityIsTrusted() {
                    timer.invalidate()
                    self.accessibilityTrustTimer = nil
                    self.trackPermissionGranted(.accessibility)
                    self.updateMenuState()
                    self.presentPermissionsWindowIfNeeded()
                }
            }
        }
        accessibilityTrustTimer = timer
    }

    private func requestScreenRecordingPermissionIfNeeded() {
        // No CGRequestScreenCaptureAccess() at launch — that triggers Apple's
        // stock "would like to record this screen" dialog, which we replace
        // with our own row in OnboardingWindowController. The actual TCC
        // registration happens lazily when the user clicks "Open settings" in
        // that window, or on the first screenshot attempt.
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }
        startScreenRecordingTrustWatcher()
    }

    private func startScreenRecordingTrustWatcher() {
        guard screenRecordingTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if CGPreflightScreenCaptureAccess() {
                    timer.invalidate()
                    self.screenRecordingTrustTimer = nil
                    self.trackPermissionGranted(.screenRecording)
                    self.updateMenuState()
                    self.presentPermissionsWindowIfNeeded()
                }
            }
        }
        screenRecordingTrustTimer = timer
    }

    private func presentPermissionsWindowIfNeeded() {
        presentPermissionsWindow(force: false)
    }

    private func presentPermissionsWindow(force: Bool, replay: Bool = false) {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()
        guard force
            || !(axTrusted && scrTrusted)
            || !OnboardingWindowController.hasCompletedFeatureTour
            // Initial setup unfinished (the post-Screen-Recording restart
            // lands here): reopen onboarding so the engine choice still
            // happens.
            || !OnboardingModel.mainWindowEverAutoShown
            || OnboardingModel.devPageOverride != nil
        else { return }
        if let onboardingWindowController {
            onboardingWindowController.presentAndActivate()
            return
        }

        if !OnboardingWindowController.hasCompletedFeatureTour {
            analyticsClient.trackOnboardingStartedIfNeeded(properties: permissionStatusProperties(
                accessibilityTrusted: axTrusted,
                screenRecordingTrusted: scrTrusted
            ))
        }
        if !(axTrusted && scrTrusted) {
            analyticsClient.trackPermissionsPromptedIfNeeded(properties: permissionStatusProperties(
                accessibilityTrusted: axTrusted,
                screenRecordingTrusted: scrTrusted
            ))
        }
        let controller = OnboardingWindowController(
            mode: replay ? .replay : (force ? .review : .firstRun),
            onPickEngine: { [weak self] choice in
                guard let self else { return }
                self.presentMainWindow(section: .aiEngine)
                self.mainWindowController?.bridge.engineSetupFocus = choice
            },
            onTourFinished: { [weak self] skipped in
                self?.analyticsClient.trackOnboardingCompletedIfNeeded(skipped: skipped)
            }
        ) { [weak self] in
            guard let self else { return }
            let closedForSystemDialog = self.onboardingWindowController?.closedForSystemDialog ?? false
            self.onboardingWindowController = nil
            // Onboarding is really over (not just hidden for a macOS
            // permission dialog) — now the main window may take the stage.
            if !closedForSystemDialog {
                self.showMainWindowOnFirstRunIfNeeded()
            }
        }
        onboardingWindowController = controller
        controller.presentAndActivate()
    }

    private func trackPermissionGranted(_ permission: PermissionKind, source: String = "watcher") {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()
        var properties = permissionStatusProperties(
            accessibilityTrusted: axTrusted,
            screenRecordingTrusted: scrTrusted
        )
        properties["permission"] = permission.analyticsValue
        properties["source"] = source
        analyticsClient.trackPermissionGrantedIfNeeded(
            permission: permission.analyticsValue,
            properties: properties
        )
        if axTrusted && scrTrusted {
            analyticsClient.trackPermissionsCompletedIfNeeded(properties: properties)
        }
    }

    /// Granting Screen Recording force-relaunches the app, killing the trust
    /// watchers before they can report. Recover at launch: any permission
    /// that is granted but was never tracked gets its one-shot event here.
    private func reconcilePermissionAnalyticsAtLaunch() {
        if AXIsProcessTrusted() {
            trackPermissionGranted(.accessibility, source: "launch")
        }
        if CGPreflightScreenCaptureAccess() {
            trackPermissionGranted(.screenRecording, source: "launch")
        }
    }

    private func permissionStatusProperties(accessibilityTrusted: Bool, screenRecordingTrusted: Bool) -> [String: String] {
        [
            "accessibility_status": accessibilityTrusted ? "granted" : "missing",
            "screen_recording_status": screenRecordingTrusted ? "granted" : "missing"
        ]
    }

    private func updateMenuState() {
        guard let menu = statusItem?.menu else {
            return
        }

        let trusted = accessibilityIsTrusted()
        menu.item(withTag: MenuItemTag.permissionNotice.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.accessibilitySettings.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.permissionSeparator.rawValue)?.isHidden = trusted

        let bootstrapReady = bootstrap.isReady(for: textModelID)
        menu.item(withTag: MenuItemTag.bootstrapNotice.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.bootstrapAction.rawValue)?.title = bootstrapReady
            ? "Setup..."
            : "Open setup..."
        menu.item(withTag: MenuItemTag.bootstrapSeparator.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.checkForUpdates.rawValue)?.isHidden = !isRunningFromAppBundle
        if let translateSelectionItem = menu.item(withTag: MenuItemTag.translateSelection.rawValue) {
            translateSelectionItem.title = "Rewrite my text in \(draftTargetLanguage.displayName)..."
            applyShortcut(for: .translateSelection, to: translateSelectionItem)
            translateSelectionItem.isEnabled = trusted
        }
        if let screenshotItem = menu.item(withTag: MenuItemTag.screenshotArea.rawValue) {
            let idleTitle: String
            switch floatingDefaultMode {
            case .translate:
                idleTitle = "Translate screen area to \(targetLanguage.displayName)..."
            case .smartReply:
                idleTitle = "Reply to screen area in \(draftTargetLanguage.displayName)..."
            }
            screenshotItem.title = isScreenshotTranslationRunning
                ? "Selecting screen area..."
                : idleTitle
            applyShortcut(for: .screenshotArea, to: screenshotItem)
            screenshotItem.isEnabled = !isScreenshotTranslationRunning
        }
        if let selectionItem = menu.item(withTag: MenuItemTag.translateOrReplySelection.rawValue) {
            switch floatingDefaultMode {
            case .translate:
                selectionItem.title = "Translate selected text to \(targetLanguage.displayName)..."
            case .smartReply:
                selectionItem.title = "Reply to selected text in \(draftTargetLanguage.displayName)..."
            }
            applyShortcut(for: .translateOrReply, to: selectionItem)
            selectionItem.isEnabled = trusted
        }

        if let invisibilityItem = menu.item(withTag: MenuItemTag.invisibilityMode.rawValue) {
            invisibilityItem.state = invisibilityModeEnabled ? .on : .off
            let chord = shortcut(for: .toggleInvisibility)
            invisibilityItem.keyEquivalent = chord.menuKeyEquivalent
            invisibilityItem.keyEquivalentModifierMask = chord.keyEquivalentModifierMask
        }
    }

    private func applyShortcut(for action: GlobalShortcutAction, to item: NSMenuItem) {
        let shortcut = shortcut(for: action)
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    @objc private func openOnboardingWindow() {
        presentMainWindow(section: .aiEngine)
    }

    @MainActor
    @objc private func openPermissionsOnboardingWindow() {
        presentPermissionsWindow(force: true)
    }

    @MainActor
    @objc private func openSnippetsWindow() {
        if let snippetsWindowController {
            snippetsWindowController.presentAndFocus()
            return
        }
        let controller = SnippetsWindowController(store: snippetsStore) { [weak self] in
            self?.snippetsWindowController = nil
        }
        snippetsWindowController = controller
        controller.presentAndFocus()
    }

    @MainActor
    @objc private func openMainWindow() {
        presentMainWindow()
    }

    /// Opens (or focuses) the main window, optionally jumping to a section. This
    /// is also the entry point for "setup" — the AI Engine section now hosts the
    /// full backend setup flow that used to live in a standalone window.
    @MainActor
    private func presentMainWindow(section: MainWindowSection? = nil) {
        let controller: MainWindowController
        if let mainWindowController {
            controller = mainWindowController
        } else {
            controller = MainWindowController(host: self) { [weak self] in
                self?.mainWindowController = nil
            }
            mainWindowController = controller
        }
        // Programmatic jumps to AI Engine always mean "set up a provider" —
        // land on the Providers tab. Sidebar clicks keep the Models tab.
        if section == .aiEngine {
            controller.bridge.aiEngineTab = 1
        }
        controller.presentAndFocus(section: section)
    }

    @MainActor
    @objc private func translateScreenshotAreaFromMenu() {
        startScreenshotTranslation()
    }

    @MainActor
    @objc private func translateSelectedTextFromMenu() {
        startSelectedTextTranslationForReplacement()
    }

    @objc private func translateOrReplySelectionFromMenu() {
        startSelectionTranslateOrReply()
    }

    @objc private func contactSupport() {
        let metadata = supportMetadata()
        let subject = "Nugumi bug or request"
        let body = """
        Hey Vadim,

        <tell me about your bug or request>

        --

        \(metadata)
        """

        var components = URLComponents(string: "https://mail.google.com/mail/")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: "tsoivadim97@gmail.com"),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        if let url = components.url, NSWorkspace.shared.open(url) {
            return
        }

        let errorAlert = NSAlert()
        errorAlert.messageText = "Could not open Gmail"
        errorAlert.informativeText = "Please email Vadim directly at tsoivadim97@gmail.com."
        errorAlert.alertStyle = .warning
        errorAlert.runModal()
    }

    private func supportMetadata() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = nativeArchitecture
        let screenCount = NSScreen.screens.count

        return """
        App: Nugumi \(version)
        Build: \(build)
        macOS: \(osVersion)
        Mac: \(hardwareModel()) (\(architecture))
        Number of screens: \(screenCount)
        Triggered from: menu bar
        """
    }

    private var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown Mac"
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown Mac"
        }

        return String(cString: buffer)
    }

    /// `forcedMode` pins the branch regardless of the user's default-mode
    /// setting — the quick-menu ring has explicit Explain and Reply items,
    /// while the ⌃⌥T shortcut (nil) keeps following `floatingDefaultMode`.
    @MainActor
    private func startSelectionTranslateOrReply(forcing forcedMode: FloatingButtonDefaultMode? = nil) {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionInteractively()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()

        let mode = forcedMode ?? floatingDefaultMode

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                let shortcutDisplay = self.shortcut(for: .translateOrReply).displayString

                guard let selection else {
                    self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                let panelSide = self.panelSideForSelectionEnding(at: mouseLocation)

                switch mode {
                case .smartReply:
                    let cleaned = TextNormalizer.cleanedSelection(selection.text)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                        return
                    }
                    self.replyToSelection(
                        cleaned,
                        near: mouseLocation,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide,
                        restoresReadyOnUserDismiss: true
                    )
                case .translate:
                    let cleaned = TextNormalizer.cleanedSelection(selection.text)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                        return
                    }
                    self.translate(
                        cleaned,
                        near: mouseLocation,
                        mode: .selection,
                        usageKind: .selection,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide,
                        restoresReadyOnUserDismiss: true
                    )
                }
            }
        }
    }

    @MainActor
    private func startSelectedTextTranslationForReplacement() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionInteractively()
            return
        }


        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                guard let selection else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let cleanedDraft = TextNormalizer.cleanedDraftMessage(selection.text)
                guard !cleanedDraft.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                self.rewriteSelectedDraftText(
                    cleanedDraft,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation),
                    keepPetReadyUntilPanelCloses: true,
                    restoresReadyOnUserDismiss: true
                )
            }
        }
    }

    @MainActor
    private func runInstantTranslation(
        _ text: String,
        language: TranslationLanguage,
        near screenPoint: NSPoint,
        mode: TranslationMode = .draftMessage
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

        let currentThinkingLevel = textThinkingLevel
        let currentAppCategory = AppCategoryClassifier.frontmostCategory()
        let currentComposition = compositionSettings(for: mode, appCategory: currentAppCategory)
        let usageKind: UsageStatsEventKind = mode == .smartReply ? .smartReply : .draftMessage

        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        let client = currentBackend
        Task { [weak self] in
            do {
                let translated = try await client.translate(
                    text,
                    images: [],
                    to: language,
                    mode: mode,
                    appCategory: currentAppCategory,
                    composition: currentComposition,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                await MainActor.run {
                    guard let self else { return }
                    self.recordTranslation(source: text, result: translated, kind: usageKind, targetLanguage: language)
                    self.analyticsClient.trackCompletedUsage(
                        kind: usageKind,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                    self.hideInstantTranslationLoading(loadingBar)
                    self.replaceCurrentSelection(with: translated)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.hideInstantTranslationLoading(loadingBar)
                    let routedToOnboarding = self.handleTranslationFailure(error)
                    if !routedToOnboarding {
                        self.analyticsClient.track(.errorOccurred, properties: [
                            "error_type": Self.analyticsErrorType(error),
                            "error_context": mode == .smartReply ? "instant_reply" : "instant_rewrite"
                        ])
                        self.presentSelectionTranslationError(
                            error.localizedDescription,
                            title: "Translation failed"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func showInstantTranslationLoading(near screenPoint: NSPoint) -> FloatingTranslateButtonController? {
        switch selectionDisplayMode {
        case .pet:
            if petController == nil {
                petController = PetController(initialMode: .draftMessage)
            }
            petController?.showThinking()
            return nil
        case .floatingBar:
            // Reuse the bar that's already on screen so it morphs in place
            // instead of flickering — its panel stays at the same origin.
            let bar: FloatingTranslateButtonController
            if let existing = translateButtonController {
                bar = existing
                translateButtonController = nil
            } else {
                bar = FloatingTranslateButtonController(
                    screenPoint: screenPoint,
                    selectedText: "",
                    initialMode: .selection,
                    onTranslate: { _ in },
                    onRewrite: { _ in },
                    onSmartReply: { _ in },
                    onAsk: {}
                )
                bar.show()
            }
            bar.setLoading()
            floatingLoadingBar?.close()
            floatingLoadingBar = bar
            return bar
        case .off:
            return nil
        }
    }

    @MainActor
    private func hideInstantTranslationLoading(_ loadingBar: FloatingTranslateButtonController?) {
        petController?.clearThinking()
        guard let loadingBar else { return }
        loadingBar.close()
        if floatingLoadingBar === loadingBar {
            floatingLoadingBar = nil
        }
    }

    @MainActor
    private func replaceCurrentSelection(with translation: String) {
        let cleanTranslation = TextNormalizer.cleanedTranslation(translation)
        guard !cleanTranslation.isEmpty else {
            return
        }

        let sourcePID = lastReplacementSourcePID
        lastReplacementSourcePID = nil

        // Tear down panel + interceptors first so they can't intercept the
        // synthesized Cmd+V or leave the source app's text view in a stale
        // resign-key state.
        translationPanelController?.close()
        translationPanelController = nil

        let performPaste: @MainActor () -> Void = { [weak self] in
            PasteboardTextInserter.replaceCurrentSelection(with: cleanTranslation)
            self?.usageStatsStore.recordReplacement(text: cleanTranslation)
        }

        if let pid = sourcePID, let runningApp = NSRunningApplication(processIdentifier: pid) {
            // Always reactivate source — even if frontmost == source — because
            // some apps (notably Electron-based ones) drop their text view's
            // selection when their window briefly resigned key while the panel
            // was up.
            runningApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                performPaste()
            }
        } else {
            performPaste()
        }
    }

    @MainActor
    private func startScreenshotTranslation() {
        guard !isScreenshotTranslationRunning else {
            return
        }

        isScreenshotTranslationRunning = true
        startScreenshotDragTracking()
        updateMenuState()
        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()
        translationPanelController?.close()
        translationPanelController = nil

        Task { [weak self] in
            do {
                // Nugumi's own UI must never end up in the OCR shot — the
                // annotation layer is deliberately screenshot-capturable now,
                // and its text labels would pollute recognition. sharingType
                // only affects captures, so nothing visibly changes on screen.
                let sharingSnapshot = await MainActor.run {
                    Self.hideAppWindowsFromScreenCapture()
                }
                let screenshotURL: URL
                do {
                    screenshotURL = try await ScreenshotCapture.captureInteractiveArea()
                } catch {
                    await MainActor.run {
                        Self.restoreAppWindowSharing(sharingSnapshot)
                    }
                    throw error
                }
                await MainActor.run {
                    Self.restoreAppWindowSharing(sharingSnapshot)
                }
                defer {
                    try? FileManager.default.removeItem(at: screenshotURL)
                }

                let recognizedText = try await ImageTextRecognizer.recognizeText(in: screenshotURL)
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.updateMenuState()

                    let sourceText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !TextNormalizer.cleanedSelection(sourceText).isEmpty else {
                        self.resetScreenshotDragTracking()
                        self.presentScreenshotTranslationError(ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let panelSide = self.panelSideForScreenshotEnding(at: mouseLocation)
                    self.resetScreenshotDragTracking()
                    let mode = self.floatingDefaultMode.translationMode
                    let usageKind: UsageStatsEventKind
                    let language: TranslationLanguage
                    switch mode {
                    case .smartReply:
                        usageKind = .smartReply
                        language = self.draftTargetLanguage
                    case .selection, .draftMessage, .revise, .reviseMessage, .summarizeChat, .summarizePage:
                        usageKind = .screenArea
                        language = self.targetLanguage
                    }
                    self.translate(
                        sourceText,
                        near: mouseLocation,
                        targetLanguage: language,
                        mode: mode,
                        useCache: mode == .selection,
                        usageKind: usageKind,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.resetScreenshotDragTracking()
                    self.updateMenuState()
                    guard !ScreenshotTranslationError.isCancellation(error) else {
                        return
                    }
                    self.presentScreenshotTranslationError(error)
                }
            }
        }
    }

    /// Relaunch Nugumi reliably without depending on macOS's TCC "Quit &
    /// Reopen" — that path is flaky for LSUIElement agent apps (it quits but
    /// doesn't reopen) and gets confused when more than one copy of
    /// com.nugumi.app is registered. Detach a helper that waits for us to fully
    /// exit, then reopens our exact bundle. Falls back to a plain quit in dev
    /// (`swift run`), where there is no .app to reopen.
    @MainActor
    private func relaunchApp() {
        guard isRunningFromAppBundle else {
            NSApp.terminate(nil)
            return
        }
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @MainActor
    private func presentScreenshotTranslationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            // First time: surface macOS's native Screen Recording prompt — this
            // call also registers Nugumi in the Privacy list. It's a no-op once
            // the user has answered, so only then fall back to the guide-to-
            // Settings alert. Shared flag keeps this in sync with onboarding.
            let requestedKey = "permissionsOnboarding.screenCaptureRequested"
            if !CGPreflightScreenCaptureAccess(),
               !UserDefaults.standard.bool(forKey: requestedKey) {
                UserDefaults.standard.set(true, forKey: requestedKey)
                _ = CGRequestScreenCaptureAccess()
                startScreenRecordingTrustWatcher()
                return
            }
            let response = NugumiAlertController(
                title: "Screen recording required",
                message: screenshotError.localizedDescription,
                primaryButtonTitle: "Open settings",
                secondaryButtonTitle: "Quit & Reopen"
            ).showModal()
            switch response {
            case .alertFirstButtonReturn:
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            case .alertSecondButtonReturn:
                relaunchApp()
            default:
                break
            }
            return
        }

        _ = NugumiAlertController(
            title: "Screenshot translation failed",
            message: error.localizedDescription,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    private func presentSelectionTranslationError(_ message: String, title: String = "No text selected") {
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: title,
            message: message,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    private func presentCredentialPrompt(for provider: CloudProvider, onSave: @escaping (Bool) -> Void) {
        switch provider {
        case .openAICodex:
            Task { @MainActor in
                self.isCloudSignInActive = true
                let outcome = await CodexLoginAlert.present()
                self.isCloudSignInActive = false
                switch outcome {
                case .success:
                    self.bootstrap.refresh()
                    self.applyEnginePreset(.cloud(.openAICodex), force: true)
                    onSave(true)
                case .cancelled:
                    onSave(false)
                case .failed(let message):
                    self.presentSelectionTranslationError(message, title: "ChatGPT sign-in failed")
                    onSave(false)
                }
            }
        case .anthropicClaudeCode:
            Task { @MainActor in
                self.isCloudSignInActive = true
                let outcome = await ClaudeCodeLoginAlert.present()
                self.isCloudSignInActive = false
                switch outcome {
                case .success:
                    self.bootstrap.refresh()
                    self.applyEnginePreset(.cloud(.anthropicClaudeCode), force: true)
                    onSave(true)
                case .cancelled:
                    onSave(false)
                case .failed(let message):
                    self.presentSelectionTranslationError(message, title: "Claude sign-in failed")
                    onSave(false)
                }
            }
        default:
            presentAPIKeySheet(for: provider, onSave: onSave)
        }
    }

    /// "Sign out" / "Remove key" on a provider card. Confirms, wipes the
    /// credentials, then re-points any model slot that just went dead at a
    /// still-connected engine so the app never sits on a broken selection.
    @MainActor
    private func disconnectCloudProvider(_ provider: CloudProvider) {
        NSApp.activate(ignoringOtherApps: true)
        let isOAuth = provider.usesOAuth
        let response = NugumiAlertController(
            title: isOAuth ? "Sign out of \(provider.displayName)?" : "Remove \(provider.displayName) API key?",
            message: isOAuth
                ? "Nugumi will forget this account. Models from \(provider.displayName) stop working until you sign in again."
                : "The key is deleted from this Mac. Models from \(provider.displayName) stop working until you add a key again.",
            primaryButtonTitle: isOAuth ? "Sign out" : "Remove key",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else { return }

        switch provider {
        case .openAICodex: KeychainStore.setCodexCredentials(nil)
        case .anthropicClaudeCode: KeychainStore.setClaudeCodeCredentials(nil)
        default: KeychainStore.setAPIKey(nil, for: provider)
        }
        bootstrap.refresh()
        healModelSlots()
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    /// Walks the engines in rough popularity order and lets each one's preset
    /// claim any broken slot (`applyEnginePreset` never touches a working
    /// selection, so the first still-connected engine wins).
    @MainActor
    private func healModelSlots() {
        let engines: [EngineModelPreset] = [
            .cloud(.openAICodex), .cloud(.anthropicClaudeCode), .ollama,
            .cloud(.openAI), .cloud(.anthropic), .cloud(.gemini)
        ]
        for engine in engines {
            applyEnginePreset(engine)
        }
    }

    @MainActor
    func runCloudTest(for provider: CloudProvider) async -> CloudTestResult {
        let model: LLMModel
        let client: any LLMBackend
        switch provider {
        case .openAICodex:
            guard let m = LLMModel.codexModels.first else {
                return .failure("No Codex models known yet - sign in first.")
            }
            guard provider.hasCredentials else {
                return .failure("Not signed in to ChatGPT.")
            }
            model = m
            client = OpenAICodexClient(apiModelID: m.apiModelID)
        case .anthropicClaudeCode:
            guard let m = LLMModel.cloudModels(for: provider).first else {
                return .failure("No model registered for \(provider.displayName).")
            }
            guard provider.hasCredentials else {
                return .failure("Not signed in to Claude.")
            }
            model = m
            client = ClaudeCodeClient(model: m.apiModelID)
        case .openAI, .anthropic, .gemini, .openRouter:
            // Merged list, not the static curated one: if the provider has
            // retired the first curated model, the picker hides it — the
            // connectivity test must not keep hitting that dead id.
            let models = LLMModel.cloudModels(for: provider)
            // OpenRouter: prefer a `:free` model so the test verifies the key on
            // a credit-less account — paid models 402 ("Payment Required") with
            // no balance, which looks like a broken key but isn't.
            let chosen = provider == .openRouter
                ? (models.first(where: { $0.id.hasSuffix(":free") }) ?? models.first)
                : models.first
            guard let m = chosen else {
                return .failure("No model registered for \(provider.displayName).")
            }
            guard let apiKey = KeychainStore.apiKey(for: provider), !apiKey.isEmpty else {
                return .failure("No API key saved.")
            }
            model = m
            client = OpenAIChatClient(provider: provider, apiKey: apiKey, model: m.apiModelID)
        }
        do {
            let translated = try await client.translate(
                "Hello, this is a test sentence.",
                images: [],
                to: targetLanguage,
                mode: .selection,
                appCategory: .other,
                composition: nil,
                thinkingLevel: textThinkingLevel,
                onPartial: { _ in }
            )
            let preview = String(translated.prefix(160))
            return .success(preview: "Model: \(model.shortName)\n\n\(preview)")
        } catch let error as TranslationError where error.provesCredentialsValid {
            // 402 / 429 mean the key authenticated — the provider is connected,
            // the request just can't run right now. Report "key valid", not a
            // broken-key ✕.
            let reason: String
            switch error {
            case .outOfCredits:
                reason = "you're out of credits. Add funds to run paid models (free models are rate-limited)."
            case .rateLimited:
                reason = "the model is rate-limited right now. Wait a minute, or add credits for a paid model."
            default:
                reason = "the request couldn't run, but the key authenticated."
            }
            return .info("Key is valid - \(reason)")
        } catch let error as TranslationError {
            return .failure(error.errorDescription ?? "Unknown error.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    @MainActor
    private func applyModelSelection(_ modelID: String, for scope: ModelUseScope) {
        setModelID(modelID, for: scope)
        analyticsClient.track(.modelChanged, properties: [
            "model_id": modelID,
            "model_scope": scope.rawValue,
            "source": "user"
        ])
        translationCache = TranslationCache()
        onModelSelectionChanged(for: scope)
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    /// An engine just connected: point each scope at the engine's preset
    /// model. A slot is only touched when its current model is broken (its
    /// provider has no credentials / the local model isn't installed) or is
    /// still the untouched factory default — a working user choice is never
    /// replaced. The preset itself must be usable right now, so a half-set-up
    /// engine never grabs a slot.
    @MainActor
    /// `force` = the user just connected this engine (entered a key / signed in),
    /// so snap every slot to its models even if the current pick still works.
    /// Healing flows (`healModelSlots`, Ollama auto-install) leave it false so a
    /// working selection is never stolen out from under the user.
    private func applyEnginePreset(_ engine: EngineModelPreset, force: Bool = false) {
        var applied = false
        for scope in ModelUseScope.allCases {
            guard let presetID = engine.modelID(for: scope),
                  presetID != modelID(for: scope),
                  isModelUsableNow(presetID)
            else { continue }
            if !force {
                let untouchedDefault = UserDefaults.standard.string(forKey: scope.defaultsKey) == nil
                guard untouchedDefault || !isModelUsableNow(modelID(for: scope)) else { continue }
            }
            setModelID(presetID, for: scope)
            analyticsClient.track(.modelChanged, properties: [
                "model_id": presetID,
                "model_scope": scope.rawValue,
                "source": "preset"
            ])
            applied = true
        }
        guard applied else { return }
        translationCache = TranslationCache()
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    /// True when the model can serve a request right now: its cloud provider
    /// has credentials, or the local model is installed and the server runs.
    private func isModelUsableNow(_ modelID: String) -> Bool {
        let model = LLMModel.option(id: modelID)
        if let provider = model.cloudProvider {
            return provider.hasCredentials
        }
        return bootstrap.isReady(for: modelID)
    }

    @MainActor
    private func presentAPIKeySheet(for provider: CloudProvider, onSave: @escaping (Bool) -> Void) {
        Task { @MainActor in
            // Suppress the selection auto-readers while the panel is up and the
            // user is on the provider's site copying their key (same beep fix as
            // the sign-in flows).
            self.isCloudSignInActive = true
            let outcome = await CloudAPIKeyAlert.present(provider: provider)
            self.isCloudSignInActive = false
            switch outcome {
            case .saved:
                self.bootstrap.refresh()
                self.applyEnginePreset(.cloud(provider), force: true)
                onSave(true)
            case .savedUnverified(let detail):
                self.bootstrap.refresh()
                self.applyEnginePreset(.cloud(provider), force: true)
                self.presentSelectionTranslationError(
                    "Couldn't reach \(provider.displayName) to verify the key (\(detail)). Saved it locally.",
                    title: "Key saved without verification"
                )
                onSave(true)
            case .cancelled:
                onSave(false)
            }
        }
    }

    @MainActor
    private func presentShortcutRecorder(for action: GlobalShortcutAction) {
        // Suspend every double-tap detector so the recorder owns flagsChanged
        // events while the panel is up; otherwise the very modifier the user
        // is trying to bind would also fire its currently-bound action.
        modifierDetectors.forEach { $0.isEnabled = false }
        shortcutRecorderWindowController?.close()
        let controller = ShortcutRecorderWindowController(
            action: action,
            currentShortcut: shortcut(for: action),
            onShortcut: { [weak self] shortcut in
                let didSet = self?.setKeyboardShortcut(shortcut, for: action) ?? false
                self?.mainWindowController?.bridge.refreshFromHost()
                return didSet
            },
            onClose: { [weak self] in
                self?.modifierDetectors.forEach { $0.isEnabled = true }
                self?.shortcutRecorderWindowController = nil
            }
        )
        shortcutRecorderWindowController = controller
        controller.present()
    }

    @MainActor
    private func setKeyboardShortcut(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) -> Bool {
        // Reserve the always-on Ask Nugumi alias so no action can shadow it.
        if shortcut == GlobalShortcutAction.askNugumiAlias {
            return false
        }
        for otherAction in GlobalShortcutAction.allCases where otherAction != action {
            if self.shortcut(for: otherAction) == shortcut {
                return false
            }
        }

        GlobalShortcutStore.set(shortcut, for: action)
        setupGlobalHotKeys()
        updateMenuState()
        return true
    }

    @MainActor
    @objc private func resetKeyboardShortcuts() {
        GlobalShortcutStore.resetToDefaults()
        setupGlobalHotKeys()
        updateMenuState()
    }

    @MainActor
    @objc private func resetSettings() {
        let response = NugumiAlertController(
            title: "Reset settings?",
            message: "This restores languages, per-app modes, main mode, display, output, AI mode, live captions, and keyboard shortcuts. Snippets, dictionary, saved API keys, your email voice sample, and usage stats stay unchanged.",
            primaryButtonTitle: "Reset",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        resetSettingsToDefaults()
    }

    @MainActor
    private func resetSettingsToDefaults() {
        let previousTextModelID = textModelID
        let previousAskModelID = askNugumiModelID
        let defaults = UserDefaults.standard
        [
            "targetLanguageID",
            "draftTargetLanguageID",
            "writingToggleAlternateID",
            "writingToggleLanguageAID",        // legacy quick-switch A/B pair
            "writingToggleLanguageBID",
            "floatingButtonDefaultMode",
            "selectionDisplayMode",
            "liveTranslationSource",            // live captions: audio source + show-original
            "liveTranslationShowSource",
            "customAppAssignmentsV1",           // per-app modes (re-synced below)
            "suppressedBuiltInAppsV1",
            ModelUseScope.textActions.defaultsKey,
            ModelUseScope.askNugumi.defaultsKey,
            ModelUseScope.textActions.thinkingDefaultsKey,
            ModelUseScope.askNugumi.thinkingDefaultsKey,
            "selectedOllamaModel",
            "thinkingLevel",
            "cleanupLevel",
            "genZMode",
            "replacementMode",
            InvisibilityState.defaultsKey,
            InvisibilityState.firstRunShownKey,
            usageStatsExpandedKey
        ].forEach { defaults.removeObject(forKey: $0) }

        for category in AppCategory.allCases {
            defaults.removeObject(forKey: "writingStyle.\(category.rawValue)")
        }
        syncAppClassifierOverrides()   // clear the static per-app overrides cache live

        GlobalShortcutStore.resetToDefaults(defaults: defaults)
        shortcutRecorderWindowController?.close()
        translationCache = TranslationCache()
        translationPanelController?.close()
        translationPanelController = nil
        petController?.setActionMode(floatingDefaultMode.translationMode)
        refreshStatusBarIcon()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        statusItem?.isVisible = true
        InvisibilityState.applyToAllOpenWindows()

        if textModelID != previousTextModelID {
            onModelSelectionChanged(for: .textActions)
        }
        if askNugumiModelID != previousAskModelID {
            onModelSelectionChanged(for: .askNugumi)
        }

        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Builds the application's main menu. An accessory (LSUIElement) app gets no
    /// menu bar by default, so the standard text-editing key equivalents
    /// (⌘C / ⌘V / ⌘X / ⌘A / ⌘Z) never reach the focused text field — they are
    /// delivered through the Edit menu. The menu surfaces only while Nugumi is the
    /// active app. ⌘Q is deliberately bound to "Close Window" rather than Quit:
    /// Nugumi lives in the menu bar, so closing the window must not kill it — users
    /// quit via the status-bar "Quit Nugumi" item.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // The first submenu is always treated as the application menu; the system
        // substitutes the app name for its title.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Nugumi",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        // ⌘Q closes the front window (routed through the responder chain) instead
        // of terminating — the accessory app keeps running in the menu bar.
        appMenu.addItem(withTitle: "Close Window",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")

        // Edit menu — actions target nil so they dispatch down the responder chain
        // to the first-responder text view, enabling copy/paste/etc. everywhere.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(nil)
    }

    /// Record (or clear) a pending update and refresh every surface that shows
    /// it — the sidebar badge (via notification) and the next menu rebuild.
    @MainActor
    private func setAvailableUpdate(_ update: SUAppcastItem?) {
        availableUpdate = update
        NotificationCenter.default.post(name: .updateAvailabilityChanged, object: nil)
    }
}

extension NugumiApp: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/ChoiVadim/nugumi/main/appcast.xml"
    }
}

extension NugumiApp: SPUStandardUserDriverDelegate {
    // Opt into gentle reminders: scheduled checks surface our own badge instead
    // of Sparkle's modal. User-initiated "Check for updates..." is unaffected.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Sparkle is *not* showing it (gentle path) → light up our own badge.
        guard !handleShowingUpdate else { return }
        MainActor.assumeIsolated { setAvailableUpdate(update) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setAvailableUpdate(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setAvailableUpdate(nil) }
    }
}

enum ScreenshotTranslationError: LocalizedError {
    case captureCancelled
    case captureFailed(Int32)
    case captureFailedDetail(String)
    case noTextRecognized
    case screenRecordingPermissionDenied

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            "Screenshot selection was cancelled."
        case .captureFailed(let status):
            "Screenshot capture failed with exit code \(status)."
        case .captureFailedDetail(let message):
            "Screenshot capture failed: \(message)"
        case .noTextRecognized:
            "No readable text was found in the selected area."
        case .screenRecordingPermissionDenied:
            "Nugumi needs Screen Recording permission to capture screenshots. Open settings to enable it, then choose Quit & Reopen to apply the change."
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        guard let screenshotError = error as? ScreenshotTranslationError else {
            return false
        }

        if case .captureCancelled = screenshotError {
            return true
        }
        return false
    }
}

struct AskNugumiScreenCapture {
    let image: ImageInput
    let imagePixelSize: CGSize
    // AppKit global coordinates in points.
    let screenFrame: CGRect
    let visibleFrame: CGRect
}

extension AskNugumiScreenCapture {
    /// Burns user-drawn strokes (AppKit global screen points) into the
    /// screenshot as red marks so the vision model can see what the user is
    /// pointing at. Best-effort: any decode/encode failure returns `self`
    /// unannotated — the request is never blocked on annotation.
    func annotated(with strokes: [[NSPoint]]) -> AskNugumiScreenCapture {
        guard strokes.contains(where: { $0.count > 1 }),
              screenFrame.width > 0, screenFrame.height > 0,
              let cgImage = NSBitmapImageRep(data: image.data)?.cgImage
        else { return self }

        let width = cgImage.width
        let height = cgImage.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return self }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // AppKit global coordinates and CGContext both use a bottom-left
        // origin, so the mapping is pure scale + offset — no y flip.
        let scaleX = CGFloat(width) / screenFrame.width
        let scaleY = CGFloat(height) / screenFrame.height
        context.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1))
        // 4 pt on screen scaled to image pixels, floored so marks stay
        // visible on screenshots downscaled to the 2048 px vision edge.
        context.setLineWidth(max(3, 4 * scaleX))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes where stroke.count > 1 {
            let mapped = stroke.map { point in
                CGPoint(
                    x: (point.x - screenFrame.minX) * scaleX,
                    y: (point.y - screenFrame.minY) * scaleY
                )
            }
            let path = CGMutablePath()
            path.move(to: mapped[0])
            for point in mapped.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.strokePath()
        }

        guard let composited = context.makeImage() else { return self }
        let bitmap = NSBitmapImageRep(cgImage: composited)
        let jpegProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
        guard let jpeg = bitmap.representation(using: .jpeg, properties: jpegProps)
        else { return self }

        return AskNugumiScreenCapture(
            image: ImageInput(data: jpeg, mediaType: "image/jpeg"),
            imagePixelSize: imagePixelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }
}

enum ScreenshotCapture {
    @MainActor
    static func captureActiveScreen(containing point: NSPoint = NSEvent.mouseLocation) async throws -> AskNugumiScreenCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotTranslationError.screenRecordingPermissionDenied
        }

        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            throw ScreenshotTranslationError.captureFailedDetail("No screen is available.")
        }

        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
        }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let imagePayload = try await Task.detached(priority: .userInitiated) {
            guard let captured = CGDisplayCreateImage(screenID) else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
            }

            // Retina/5K screenshots as lossless PNG routinely exceed the
            // 5 MB cloud-backend limit. Cloud vision models (OpenAI 4o/4.1,
            // etc.) fit images to 2048² before tiling, so downscaling here
            // is lossless w.r.t. the model and JPEG keeps payload small.
            let cgImage = ScreenshotCapture.downscaledForVision(captured)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let jpegProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
            let encoded: (data: Data, mediaType: String)
            if let jpeg = bitmap.representation(using: .jpeg, properties: jpegProps) {
                encoded = (jpeg, "image/jpeg")
            } else if let png = bitmap.representation(using: .png, properties: [:]) {
                encoded = (png, "image/png")
            } else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not encode the active screen.")
            }

            return (
                image: ImageInput(data: encoded.data, mediaType: encoded.mediaType),
                pixelSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
        }.value

        return AskNugumiScreenCapture(
            image: imagePayload.image,
            imagePixelSize: imagePayload.pixelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }

    // Matches the tile boundary cloud vision models snap to; sending larger
    // is bandwidth waste plus risks tripping client-side size guards.
    private static let visionMaxEdge: CGFloat = 2048

    fileprivate static func downscaledForVision(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > visionMaxEdge else { return image }
        let scale = visionMaxEdge / longest
        let targetWidth = Int((width * scale).rounded())
        let targetHeight = Int((height * scale).rounded())
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    static func captureInteractiveArea() async throws -> URL {
        // Permission is requested once at launch (requestScreenRecordingPermissionIfNeeded),
        // which is what registers Nugumi in System Settings. Calling CGRequestScreenCaptureAccess
        // here would stack Apple's system prompt on top of our NugumiAlertController.
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotTranslationError.screenRecordingPermissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nugumi-screenshot-\(UUID().uuidString)")
                    .appendingPathExtension("png")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", outputURL.path]
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fileExists = FileManager.default.fileExists(atPath: outputURL.path)

                    if !fileExists {
                        // If `screencapture` produced no file and the system
                        // says the app isn't trusted for screen capture, the
                        // failure is almost certainly a permission denial —
                        // independent of how Apple phrased the stderr message.
                        let permissionDenied = !CGPreflightScreenCaptureAccess()
                            || stderrText.localizedCaseInsensitiveContains("could not create image")
                        if stderrText.isEmpty && !permissionDenied {
                            continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        } else if permissionDenied {
                            continuation.resume(throwing: ScreenshotTranslationError.screenRecordingPermissionDenied)
                        } else {
                            continuation.resume(throwing: ScreenshotTranslationError.captureFailedDetail(stderrText))
                        }
                        return
                    }

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: ScreenshotTranslationError.captureFailed(process.terminationStatus))
                        return
                    }

                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                          let fileSize = attributes[.size] as? NSNumber,
                          fileSize.intValue > 0
                    else {
                        continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        return
                    }

                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}

enum ImageTextRecognizer {
    private struct RecognizedLine {
        let text: String
        let boundingBox: CGRect
    }

    static func recognizeText(in imageURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true

                    let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
                    if !supportedLanguages.isEmpty {
                        request.recognitionLanguages = supportedLanguages
                    }

                    let handler = VNImageRequestHandler(url: imageURL, options: [:])
                    try handler.perform([request])

                    let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }

                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            return nil
                        }

                        return RecognizedLine(text: text, boundingBox: observation.boundingBox)
                    }

                    let rowTolerance: CGFloat = 0.025
                    let orderedLines = lines.sorted { lhs, rhs in
                        let lhsMidY = lhs.boundingBox.midY
                        let rhsMidY = rhs.boundingBox.midY

                        if abs(lhsMidY - rhsMidY) <= rowTolerance {
                            return lhs.boundingBox.minX < rhs.boundingBox.minX
                        }

                        return lhsMidY > rhsMidY
                    }

                    let recognizedText = Self.joinedTextPreservingParagraphs(
                        from: orderedLines,
                        rowTolerance: rowTolerance
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !recognizedText.isEmpty else {
                        continuation.resume(throwing: ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    continuation.resume(returning: recognizedText)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Joins OCR lines using their geometry. Same-row lines join with a space.
    /// Stacked lines use `\n` for ordinary line wraps and `\n\n` when the
    /// vertical gap between them is meaningfully larger than the median line
    /// height — that gap corresponds to a deliberate paragraph break in the
    /// source. Without this signal the downstream LLM cannot distinguish a
    /// word-wrap from a paragraph boundary and collapses everything into one
    /// block.
    private static func joinedTextPreservingParagraphs(
        from lines: [RecognizedLine],
        rowTolerance: CGFloat
    ) -> String {
        guard let first = lines.first else { return "" }
        guard lines.count > 1 else { return first.text }

        let heights = lines.map(\.boundingBox.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let paragraphGapThreshold = max(medianHeight * 0.65, 0.005)

        var result = first.text
        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let current = lines[index]
            let sameRow = abs(previous.boundingBox.midY - current.boundingBox.midY) <= rowTolerance
            if sameRow {
                result += " " + current.text
                continue
            }

            let gap = previous.boundingBox.minY - current.boundingBox.maxY
            let separator = gap > paragraphGapThreshold ? "\n\n" : "\n"
            result += separator + current.text
        }
        return result
    }
}

final class ScreenshotDragTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startLocation: NSPoint?
    private var lastLocation: NSPoint?
    private var currentPanelSide: TranslationPanelController.Side?
    private let onUpdate: @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void

    init(onUpdate: @escaping @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void) {
        self.onUpdate = onUpdate
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let tracker = Unmanaged<ScreenshotDragTracker>.fromOpaque(userInfo).takeUnretainedValue()
                tracker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        startLocation = nil
        lastLocation = nil
        currentPanelSide = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            startLocation = location
            lastLocation = location
            currentPanelSide = nil
            notify(startLocation: location, endLocation: nil, panelSide: nil)
        case .leftMouseDragged, .leftMouseUp:
            let referenceLocation = startLocation ?? lastLocation
            if let panelSide = Self.meaningfulPanelSideForDrag(from: referenceLocation, to: location) {
                currentPanelSide = panelSide
            }
            notify(startLocation: startLocation, endLocation: location, panelSide: currentPanelSide)
            lastLocation = location
            if type == .leftMouseUp {
                startLocation = nil
                lastLocation = nil
            }
        default:
            break
        }
    }

    private func notify(
        startLocation: NSPoint?,
        endLocation: NSPoint?,
        panelSide: TranslationPanelController.Side?
    ) {
        Task { @MainActor in
            onUpdate(startLocation, endLocation, panelSide)
        }
    }

    private static func meaningfulPanelSideForDrag(
        from startLocation: NSPoint?,
        to endLocation: NSPoint
    ) -> TranslationPanelController.Side? {
        guard let startLocation else { return nil }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return nil }
        return dx > 0 ? .right : .left
    }

    deinit {
        disable()
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum NugumiFont {
    private static let didRegisterPixelifySans: Bool = {
        guard let url = Bundle.module.url(
            forResource: "PixelifySans",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func pixelPrompt(size: CGFloat) -> NSFont {
        _ = didRegisterPixelifySans
        return NSFont(name: "PixelifySans-Regular_SemiBold", size: size)
            ?? NSFont(name: "Pixelify Sans", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }
}

private final class PetPromptBubbleView: NSView {
    var isError = false {
        didSet { needsDisplay = true }
    }
    var bubbleFrame: NSRect = .zero {
        didSet { needsDisplay = true }
    }

    /// When set, the bubble becomes a drag handle: clicks on the bubble
    /// background (areas not covered by text or buttons) start a drag that
    /// the closure handles. The closure receives the initial screen-space
    /// mouse location captured at mouseDown so the drag anchor is precise.
    /// Text selection and button clicks still work because their views sit
    /// above this view in z-order and AppKit asks them first.
    var onDragRequested: ((NSPoint) -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Opt-in: stay click-through (current behavior) unless a drag handler
        // is wired in.
        guard onDragRequested != nil else { return nil }
        return bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onDragRequested != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onDragRequested else {
            super.mouseDown(with: event)
            return
        }
        let startLocation = NSEvent.mouseLocation
        NSCursor.closedHand.push()
        onDragRequested(startLocation)
        NSCursor.pop()
    }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let unit: CGFloat = 3
        let drawingFrame = bubbleFrame == .zero ? bounds : bubbleFrame
        let bubbleRect = NSRect(
            x: drawingFrame.minX + 5 * unit,
            y: drawingFrame.minY + 3 * unit,
            width: floor((drawingFrame.width - 10 * unit) / unit) * unit,
            height: floor((drawingFrame.height - 7 * unit) / unit) * unit
        )

        let shadow = NSColor(calibratedWhite: 0.0, alpha: 0.22)
        let fill = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.91, alpha: 1.0)
        let highlight = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        let border = isError
            ? NSColor(srgbRed: 0.93, green: 0.23, blue: 0.23, alpha: 1.0)
            : NSColor(srgbRed: 0.42, green: 0.47, blue: 0.47, alpha: 1.0)
        let borderDark = isError
            ? NSColor(srgbRed: 0.54, green: 0.08, blue: 0.08, alpha: 1.0)
            : NSColor(srgbRed: 0.22, green: 0.27, blue: 0.28, alpha: 1.0)

        drawPixelBubbleBody(in: bubbleRect.offsetBy(dx: unit, dy: -unit), unit: unit, color: shadow)
        let tailAnchor = bubbleRect.minX + 4 * unit
        drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: shadow, offset: NSPoint(x: unit, y: -unit))
        drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: borderDark)
        drawPixelBubbleBody(in: bubbleRect, unit: unit, color: borderDark)
        drawPixelBubbleBody(in: bubbleRect.insetBy(dx: unit, dy: unit), unit: unit, color: border)
        drawPixelBubbleBody(in: bubbleRect.insetBy(dx: unit * 2, dy: unit * 2), unit: unit, color: fill)

        drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: fill, offset: NSPoint(x: unit * 2, y: unit * 2))

        highlight.setFill()
        NSBezierPath(rect: NSRect(
            x: bubbleRect.minX + 4 * unit,
            y: bubbleRect.maxY - 4 * unit,
            width: bubbleRect.width - 8 * unit,
            height: unit
        )).fill()
    }

    private func drawPixelBubbleBody(in rect: NSRect, unit: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(rect: NSRect(
            x: rect.minX + unit,
            y: rect.minY,
            width: rect.width - unit * 2,
            height: rect.height
        )).fill()
        NSBezierPath(rect: NSRect(
            x: rect.minX,
            y: rect.minY + unit,
            width: rect.width,
            height: rect.height - unit * 2
        )).fill()
    }

    private func drawPixelTail(anchor: CGFloat, baseY: CGFloat, unit: CGFloat, color: NSColor, offset: NSPoint = .zero) {
        color.setFill()
        let cells: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 7),
            (1, -1, 5),
            (2, -2, 3),
            (3, -3, 1)
        ]
        for (x, y, width) in cells {
            NSBezierPath(rect: NSRect(
                x: anchor + offset.x + x * unit,
                y: baseY + offset.y + y * unit,
                width: width * unit,
                height: unit
            )).fill()
        }
    }
}

@MainActor
final class PetController: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let containerView: NSView
    private let promptPanel: NSPanel
    private let promptContainerView: NSView
    private let petView: PetMascotView
    private let appIconView: NSImageView
    private let promptBubbleView: PetPromptBubbleView
    private let promptTextField: AskPromptTextField
    private let answerScrollView: NSScrollView
    private let answerTextView: NSTextView
    private let continueButton = NSButton()
    private var workspaceObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private var throwTimer: Timer?
    private var throwVelocity: NSPoint = .zero
    private var onAsk: (() -> Void)?
    private var radialMenu: RadialActionMenuController?
    private var selectedText: String?
    private var onTranslate: ((String) -> Void)?
    private var onRewrite: ((String) -> Void)?
    private var onSmartReply: ((String) -> Void)?
    private var onScreenshot: (() -> Void)?
    private var onLive: (() -> Void)?
    private var onDictate: (() -> Void)?
    private var summarizeOption: RingSummarizeOption?
    private var onPromptSubmit: ((String) -> Void)?
    private var onPromptClose: (() -> Void)?
    var onContinue: (() -> Void)?
    /// Fires when the user dismisses an open ANSWER bubble themselves (click
    /// on the pet, double-click, or Escape) — `onPromptClose` is nilled out
    /// by `showAnswer`, so this is the only signal the app delegate gets for
    /// that gesture. Used to tear down UI the delegate layered on top of the
    /// answer (e.g. the Ask annotation overlay), which PetController has no
    /// reference to itself.
    var onAnswerDismissedByUser: (() -> Void)?
    private var currentMode: TranslationMode
    private var isReadyLockedUntilPanelCloses = false
    private var isThinking = false
    private var isPromptOpen = false
    private var isPromptLoading = false
    private var isAnswerOpen = false
    /// Catches Esc while the answer bubble (or the loading state) is up.
    /// The prompt text field handles Esc itself while typing, but it is
    /// hidden/disabled in those two states, so without this monitor Esc
    /// has no responder and the bubble can only be closed with the mouse.
    private var escapeKeyMonitor: Any?
    private var promptBuffer = ""
    private var currentPromptInputLayout = AskNugumiPromptInputMetrics.layout(forContentHeight: 0)
    private var currentAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0)
    private var pointingTarget: NSPoint?
    private var pointingReturnTimer: Timer?
    private var lastCursorLocation = NSEvent.mouseLocation
    private var lastCursorMovementDate = Date.distantPast
    private var cursorOffset = PetController.defaultCursorOffset
    /// Exponentially-smoothed per-frame cursor velocity. The trailing side
    /// commits off this smoothed vector instead of per-frame movement, so
    /// sub-pixel tremor and tiny zig-zags can't flip the pet left/right every
    /// tick. Reset implicitly via decay when the cursor stops.
    private var smoothedCursorVelocity: NSPoint = .zero
    private var isReadyState: Bool {
        selectedText != nil || isReadyLockedUntilPanelCloses
    }

    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let appIconSize = NSSize(width: 13, height: 13)
    private static let panelPadding: CGFloat = 6
    private static let panelSize = NSSize(
        width: mascotSize.width + panelPadding * 2,
        height: mascotSize.height + panelPadding * 2
    )
    private static let answerFontSize: CGFloat = 14
    private static let edgeMargin: CGFloat = 6
    private static let pointingArrivalThreshold: CGFloat = 8
    private static let textMovementUserInfoKey = "NSTextMovement"
    private static let promptPlaceholder = "Hey, need me?"
    private static let defaultCursorOffset = NSPoint(
        x: 12 - panelPadding,
        y: -mascotSize.height - 8 - panelPadding
    )

    var isPromptVisible: Bool {
        isPromptOpen || isPromptLoading || isAnswerOpen
    }

    var isPromptComposingVisible: Bool {
        isPromptOpen || isPromptLoading
    }

    init(initialMode: TranslationMode) {
        currentMode = initialMode
        let origin = PetController.originNearCursor(
            for: NSEvent.mouseLocation,
            size: Self.panelSize,
            offset: cursorOffset
        )
        panel = PetPanel(
            contentRect: NSRect(origin: origin, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        containerView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let initialPromptInputLayout = AskNugumiPromptInputMetrics.layout(forContentHeight: 0)
        promptPanel = PetPanel(
            contentRect: NSRect(origin: origin, size: initialPromptInputLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        promptContainerView = NSView(frame: NSRect(origin: .zero, size: initialPromptInputLayout.panelSize))
        petView = PetMascotView(frame: NSRect(
            origin: .zero,
            size: Self.panelSize
        ))
        appIconView = NSImageView(frame: NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        ))
        promptBubbleView = PetPromptBubbleView(frame: initialPromptInputLayout.bubbleFrame)
        promptTextField = AskPromptTextField(frame: initialPromptInputLayout.textFrame)
        let initialAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0)
        answerScrollView = NSScrollView(frame: initialAnswerLayout.viewportFrame)
        answerTextView = NSTextView(frame: NSRect(
            origin: .zero,
            size: initialAnswerLayout.viewportFrame.size
        ))

        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        promptPanel.level = .floating
        promptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: promptPanel)
        promptPanel.isReleasedWhenClosed = false
        promptPanel.isOpaque = false
        promptPanel.backgroundColor = .clear
        promptPanel.hasShadow = false
        promptPanel.hidesOnDeactivate = false
        promptPanel.ignoresMouseEvents = false

        containerView.autoresizingMask = [.width, .height]
        promptContainerView.autoresizingMask = [.width, .height]
        petView.wantsLayer = true
        petView.layer?.shadowColor = NSColor.black.cgColor
        petView.layer?.shadowOpacity = 0.32
        petView.layer?.shadowRadius = 3
        petView.layer?.shadowOffset = .zero
        petView.layer?.masksToBounds = false
        containerView.addSubview(petView)

        appIconView.imageScaling = .scaleProportionallyDown
        appIconView.isHidden = true
        containerView.addSubview(appIconView)

        promptBubbleView.alphaValue = 0
        promptBubbleView.isHidden = true
        promptContainerView.addSubview(promptBubbleView)

        promptBubbleView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }

        promptTextField.delegate = self
        promptTextField.onEscape = { [weak self] in
            self?.closePromptFromUser()
        }
        promptTextField.font = NugumiFont.pixelPrompt(size: 16)
        promptTextField.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        promptTextField.isBordered = false
        promptTextField.isBezeled = false
        promptTextField.drawsBackground = false
        promptTextField.backgroundColor = .clear
        promptTextField.focusRingType = .none
        promptTextField.isEditable = false
        promptTextField.isSelectable = false
        configurePromptTextFieldForInput()
        promptTextField.alphaValue = 0
        promptTextField.isHidden = true
        setPromptPlaceholder(Self.promptPlaceholder)
        promptContainerView.addSubview(promptTextField)

        answerTextView.font = NugumiFont.pixelPrompt(size: Self.answerFontSize)
        answerTextView.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        answerTextView.drawsBackground = false
        answerTextView.backgroundColor = .clear
        answerTextView.isEditable = false
        answerTextView.isSelectable = true
        answerTextView.isRichText = false
        answerTextView.importsGraphics = false
        answerTextView.isHorizontallyResizable = false
        answerTextView.isVerticallyResizable = true
        answerTextView.textContainerInset = .zero
        answerTextView.textContainer?.lineFragmentPadding = 0
        answerTextView.textContainer?.widthTracksTextView = true
        answerTextView.textContainer?.heightTracksTextView = false

        answerScrollView.borderType = .noBorder
        answerScrollView.drawsBackground = false
        answerScrollView.hasHorizontalScroller = false
        answerScrollView.hasVerticalScroller = false
        answerScrollView.autohidesScrollers = true
        answerScrollView.scrollerStyle = .overlay
        answerScrollView.alphaValue = 0
        answerScrollView.isHidden = true
        answerScrollView.documentView = answerTextView
        promptContainerView.addSubview(answerScrollView)

        // "Continue dialog" affordance, bottom-right of the answer bubble.
        continueButton.isBordered = false
        continueButton.bezelStyle = .regularSquare
        continueButton.imagePosition = .imageOnly
        continueButton.image = NSImage(
            systemSymbolName: "arrowshape.turn.up.left.circle.fill",
            accessibilityDescription: "Continue conversation"
        )
        continueButton.contentTintColor = .nugumiAccent
        continueButton.toolTip = "Continue the conversation"
        continueButton.target = self
        continueButton.action = #selector(continueButtonTapped)
        continueButton.isHidden = true
        continueButton.alphaValue = 0
        promptContainerView.addSubview(continueButton)

        panel.contentView = containerView
        promptPanel.contentView = promptContainerView
        petView.onClick = { [weak self] in
            guard let self else { return }
            if self.isPromptVisible || self.onPromptClose != nil {
                self.closePromptFromUser()
                return
            }
            self.toggleRadialMenu()
        }

        refreshStyleBadge()
        subscribeToFrontmostAppChanges()
        installEscapeKeyMonitor()
    }

    private func installEscapeKeyMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == UInt16(kVK_Escape),
                  self.isAnswerOpen || self.isPromptLoading
            else {
                return event
            }
            self.closePromptFromUser()
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    private func subscribeToFrontmostAppChanges() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStyleBadge()
            }
        }
    }

    /// Dresses the pet in the writing register Nugumi will use for the frontmost app
    /// (formal = hat + mustache, casual = cap, polite = bare). Uses the app-based
    /// category only — deliberately not the AppleScript URL read — so passively
    /// switching apps never triggers an Automation prompt. The legacy corner badge
    /// view stays hidden.
    private func refreshStyleBadge() {
        appIconView.isHidden = true
        guard let runningApp = NSWorkspace.shared.frontmostApplication,
              runningApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return // keep the last register while Nugumi itself is frontmost
        }
        let category = AppCategoryClassifier.category(for: runningApp.bundleIdentifier)
        petView.setWritingStyle(WritingStyle.resolved(for: category))
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startTracking()
    }

    func close() {
        radialMenu?.close()
        radialMenu = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        removeEscapeKeyMonitor()
        clearPrompt(animate: false)
        clearReady()
        trackingTimer?.invalidate()
        trackingTimer = nil
        cancelPointingAnimation()
        panel.close()
        promptPanel.close()
    }

    func showPrompt(
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        radialMenu?.close()
        radialMenu = nil
        cancelPointingAnimation()
        selectedText = nil
        self.onTranslate = nil
        self.onRewrite = nil
        self.onSmartReply = nil
        self.onAsk = nil
        summarizeOption = nil
        onPromptSubmit = onSubmit
        onPromptClose = onClose
        currentMode = .draftMessage
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        appIconView.isHidden = true
        petView.apply(state: .idle, mode: currentMode)

        promptBuffer = ""
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        renderPromptText()
        promptBubbleView.isError = false
        setPromptPlaceholder(Self.promptPlaceholder)
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        focusPromptField()
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    func focusPrompt() {
        guard isPromptOpen else { return }
        promptPanel.orderFrontRegardless()
    }

    func setPromptLoading() {
        guard isPromptOpen else {
            showThinking()
            return
        }

        isPromptOpen = false
        isPromptLoading = true
        isAnswerOpen = false
        isThinking = true
        promptTextField.isEnabled = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        petView.apply(state: .thinking, mode: currentMode)
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginPetThrowDrag(initialMouseLocation: startLocation)
        }
        let targetFrame = panel.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            promptPanel.animator().setFrame(targetFrame, display: true)
            promptPanel.animator().alphaValue = 0
            promptBubbleView.animator().alphaValue = 0
            promptTextField.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPromptLoading else { return }
                self.promptBubbleView.isHidden = true
                self.promptTextField.isHidden = true
                self.promptPanel.orderOut(nil)
                self.promptPanel.alphaValue = 1
            }
        }
    }

    func showPromptError(_ message: String) {
        guard isPromptVisible || onPromptSubmit != nil else { return }

        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        isThinking = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        promptBubbleView.isError = true
        setPromptPlaceholder(message)
        petView.apply(state: .idle, mode: currentMode)
        refreshPromptInputLayout()
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        focusPrompt()
        focusPromptField()
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    func clearPrompt() {
        clearPrompt(animate: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        submitPrompt()
    }

    /// Shift+Enter inserts a line break instead of submitting. AppKit binds
    /// Enter to `insertNewline:` and dispatches it through this delegate
    /// callback before ending editing — checking the current event's modifier
    /// lets us swap the behavior at the point of interception.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === promptTextField,
              commandSelector == #selector(NSResponder.insertNewline(_:)),
              NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        else {
            return false
        }
        textView.insertNewlineIgnoringFieldEditor(self)
        return true
    }

    func showAnswer(_ message: String, emotion: AskNugumiEmotion?) {
        radialMenu?.close()
        radialMenu = nil
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return }

        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        onPromptSubmit = nil
        onPromptClose = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = true
        promptBuffer = ""

        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        appIconView.isHidden = true
        promptBubbleView.isError = false
        configureAnswerTextView(with: cleanMessage)

        let presentation = promptPresentationAnchoredToPet(
            size: currentAnswerLayout.panelSize,
            bubbleFrame: currentAnswerLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        panel.orderFrontRegardless()
        petView.apply(state: .talking, mode: currentMode, emotion: .neutral)
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    private func submitPrompt() {
        guard isPromptOpen, promptTextField.isEnabled else { return }
        let text = promptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            renderPromptText()
            return
        }
        onPromptSubmit?(text)
    }

    private func closePromptFromUser() {
        guard isPromptVisible else { return }
        let onClose = onPromptClose
        let wasAnswerOpen = isAnswerOpen
        clearPrompt(animate: true)
        onClose?()
        if wasAnswerOpen {
            onAnswerDismissedByUser?()
        }
    }

    private func clearPrompt(animate: Bool) {
        guard isPromptVisible || onPromptSubmit != nil || onPromptClose != nil else { return }
        stopThrow()
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = false
        onPromptSubmit = nil
        onPromptClose = nil
        promptBuffer = ""
        renderPromptText()
        promptTextField.isEnabled = true
        promptBubbleView.isError = false
        setPromptPlaceholder(Self.promptPlaceholder)
        hidePromptViews()
        promptPanel.orderOut(nil)
        promptPanel.alphaValue = 1
        // Drag + double-click are only active while Ask is visible. Drop the
        // callbacks so the pet goes back to its plain click-to-act behavior
        // when the user is just hovering it on idle.
        petView.onDoubleClick = nil
        petView.onDragRequested = nil
        if !isThinking {
            panel.ignoresMouseEvents = true
            petView.allowsClickWhenNotReady = false
            petView.apply(state: .idle, mode: currentMode, emotion: .neutral)
            refreshStyleBadge()
        }
    }

    private func showPromptViews() {
        layoutPromptSubviews()
        promptBubbleView.isHidden = false
        promptBubbleView.alphaValue = 1
        if isAnswerOpen {
            promptTextField.alphaValue = 0
            promptTextField.isHidden = true
            answerScrollView.isHidden = false
            answerScrollView.alphaValue = 1
            continueButton.isHidden = (onContinue == nil)
            continueButton.alphaValue = (onContinue == nil) ? 0 : 1
        } else {
            answerScrollView.alphaValue = 0
            answerScrollView.isHidden = true
            promptTextField.isHidden = false
            promptTextField.alphaValue = 1
            continueButton.isHidden = true
            continueButton.alphaValue = 0
        }
    }

    private func hidePromptViews() {
        promptBubbleView.alphaValue = 0
        promptTextField.alphaValue = 0
        answerScrollView.alphaValue = 0
        promptBubbleView.isHidden = true
        promptTextField.isHidden = true
        answerScrollView.isHidden = true
        continueButton.isHidden = true
        continueButton.alphaValue = 0
    }

    @objc private func continueButtonTapped() {
        onContinue?()
    }

    private func configurePromptTextFieldForInput() {
        promptTextField.font = NugumiFont.pixelPrompt(size: AskNugumiPromptInputMetrics.fontSize)
        promptTextField.usesSingleLineMode = false
        promptTextField.maximumNumberOfLines = 0
        promptTextField.cell?.wraps = true
        promptTextField.cell?.isScrollable = false
        promptTextField.cell?.lineBreakMode = .byWordWrapping
        promptTextField.isEditable = true
        promptTextField.isSelectable = true
    }

    private func configureAnswerTextView(with message: String) {
        let contentHeight = answerContentHeight(for: message)
        currentAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: contentHeight)
        let layout = currentAnswerLayout
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: Self.answerFontSize),
            .foregroundColor: NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]
        answerTextView.textStorage?.setAttributedString(NSAttributedString(
            string: message,
            attributes: attributes
        ))
        answerTextView.font = NugumiFont.pixelPrompt(size: Self.answerFontSize)
        answerTextView.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        // Only carve out a lane for the overlay scroller when it's actually
        // shown. The text view stays full-width (so the clip view fills the
        // bubble); the container wraps ~14px short so glyphs never sit under
        // the scrollbar, with no wasted space when there's no scroll.
        let scrollerGutter: CGFloat = layout.needsScroll ? 14 : 0
        answerTextView.textContainer?.widthTracksTextView = false
        answerTextView.textContainer?.containerSize = NSSize(
            width: layout.viewportFrame.width - scrollerGutter,
            height: .greatestFiniteMagnitude
        )
        answerTextView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: layout.viewportFrame.width,
                height: layout.documentHeight
            )
        )
        answerScrollView.hasVerticalScroller = layout.needsScroll
        answerScrollView.autohidesScrollers = !layout.needsScroll
        answerTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func answerContentHeight(for message: String) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: Self.answerFontSize),
            .paragraphStyle: paragraphStyle
        ]
        let boundingRect = (message as NSString).boundingRect(
            with: NSSize(
                width: AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0).viewportFrame.width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(boundingRect.height) + 4
    }

    private func setPromptPlaceholder(_ text: String) {
        promptTextField.placeholderString = text
        promptTextField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: promptBubbleView.isError
                    ? NSColor(srgbRed: 0.78, green: 0.18, blue: 0.18, alpha: 0.78)
                    : NSColor(srgbRed: 0.27, green: 0.31, blue: 0.33, alpha: 0.62),
                .font: promptTextField.font ?? NugumiFont.pixelPrompt(size: 16)
            ]
        )
    }

    private func renderPromptText() {
        promptTextField.stringValue = promptBuffer
        refreshPromptInputLayout()
    }

    private func refreshPromptInputLayout() {
        currentPromptInputLayout = AskNugumiPromptInputMetrics.layout(
            forContentHeight: promptInputContentHeight(for: promptBuffer)
        )
        guard isPromptOpen, !isAnswerOpen else { return }
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        layoutPromptSubviews()
    }

    private func promptInputContentHeight(for text: String) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: AskNugumiPromptInputMetrics.fontSize),
            .paragraphStyle: paragraphStyle
        ]
        let measurementSize = NSSize(
            width: AskNugumiPromptInputMetrics.textMeasurementWidth,
            height: .greatestFiniteMagnitude
        )
        let measure: (String) -> CGFloat = { sample in
            (sample as NSString).boundingRect(
                with: measurementSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            ).height
        }
        // Floor the bubble height at the placeholder's measured height so the
        // dialog never shrinks below the "empty state" size when a single
        // short word is typed. Lets the bubble still grow for longer input.
        // Measure the placeholder actually on screen, not the default one —
        // showPromptError swaps in the (often longer) error message.
        let placeholder = promptTextField.placeholderString ?? Self.promptPlaceholder
        let rawHeight = text.isEmpty ? measure(placeholder) : max(measure(text), measure(placeholder))
        return ceil(rawHeight) + AskNugumiPromptInputMetrics.textMeasurementBottomInset
    }

    /// Give the prompt's native NSTextField keyboard focus so the blinking
    /// caret appears. The panel becomes key without activating Nugumi
    /// (`.nonactivatingPanel` on promptPanel) — other apps stay active and
    /// keep receiving keystrokes when the user clicks back into them.
    private func focusPromptField() {
        promptPanel.makeKeyAndOrderFront(nil)
        promptPanel.makeFirstResponder(promptTextField)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as AnyObject) === promptTextField else { return }
        promptBuffer = promptTextField.stringValue
        if !promptBuffer.isEmpty {
            promptBubbleView.isError = false
            setPromptPlaceholder(Self.promptPlaceholder)
        }
        refreshPromptInputLayout()
    }

    private func textMovement(from notification: Notification) -> Int? {
        notification.userInfo?[Self.textMovementUserInfoKey] as? Int
    }

    private func promptPresentationAnchoredToPet(
        size: NSSize,
        bubbleFrame: NSRect
    ) -> (promptFrame: NSRect, petOrigin: NSPoint) {
        let referencePoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let presentation = AskNugumiPetBubblePresentationMetrics.presentation(
            petOrigin: panel.frame.origin,
            petSize: Self.panelSize,
            promptSize: size,
            bubbleFrame: bubbleFrame,
            visibleFrame: visibleFrame,
            edgeMargin: Self.edgeMargin
        )

        return (presentation.promptFrame, presentation.petOrigin)
    }

    private func layoutPromptSubviews() {
        petView.frame = NSRect(origin: .zero, size: Self.panelSize)
        appIconView.frame = NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        )
        if isAnswerOpen {
            promptBubbleView.frame = NSRect(origin: .zero, size: currentAnswerLayout.panelSize)
            promptBubbleView.bubbleFrame = currentAnswerLayout.bubbleFrame
            answerScrollView.frame = currentAnswerLayout.viewportFrame
            // The visible bubble border sits 15px in from the sides (5*unit)
            // and 9px up from the bottom (3*unit). Add the SAME gap past each
            // so the button is equidistant from the right and bottom edges.
            let bubble = currentAnswerLayout.bubbleFrame
            let buttonSize: CGFloat = 16
            let sideBorder: CGFloat = 15
            let bottomBorder: CGFloat = 9
            let gap: CGFloat = 8
            continueButton.frame = NSRect(
                x: bubble.maxX - sideBorder - gap - buttonSize,
                y: bubble.minY + bottomBorder + gap,
                width: buttonSize,
                height: buttonSize
            )
        } else {
            promptBubbleView.frame = NSRect(origin: .zero, size: currentPromptInputLayout.panelSize)
            promptBubbleView.bubbleFrame = currentPromptInputLayout.bubbleFrame
            promptTextField.frame = currentPromptInputLayout.textFrame
        }
    }

    func showReady(
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void,
        onAsk: @escaping () -> Void,
        onScreenshot: @escaping () -> Void = {},
        onLive: @escaping () -> Void = {},
        onDictate: @escaping () -> Void = {},
        summarizeOption: RingSummarizeOption? = nil
    ) {
        // Don't yank the pet back to "ready" while Ask is open (input, loading,
        // or answer) — a casual selection in another app should leave the
        // in-progress dialog alone instead of tearing it down.
        guard !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: isThinking,
            isPromptVisible: isPromptVisible
        ) else {
            return
        }
        // A stale ring can still reference the previous selection's closures
        // if a new one arrives while it's open — tear it down before rearming.
        radialMenu?.close()
        radialMenu = nil
        clearPrompt(animate: true)
        cancelPointingAnimation()
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.onAsk = onAsk
        self.onScreenshot = onScreenshot
        self.onLive = onLive
        self.onDictate = onDictate
        self.summarizeOption = summarizeOption
        currentMode = initialMode
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = false
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
        show()
    }

    func holdReadyUntilPanelCloses(mode: TranslationMode? = nil) {
        radialMenu?.close()
        radialMenu = nil
        cancelPointingAnimation()
        if let mode {
            currentMode = mode
        }
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        isReadyLockedUntilPanelCloses = true
        panel.ignoresMouseEvents = true
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
    }

    func clearReady() {
        guard !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: isThinking,
            isPromptVisible: isPromptVisible
        ) else { return }
        radialMenu?.close()
        radialMenu = nil
        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = true
        petView.apply(state: .idle, mode: currentMode)
        refreshStyleBadge()
    }

    func showThinking() {
        radialMenu?.close()
        radialMenu = nil
        if isPromptOpen {
            clearPrompt(animate: false)
        }
        cancelPointingAnimation()
        isThinking = true
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = !isPromptLoading
        petView.allowsClickWhenNotReady = isPromptLoading
        appIconView.isHidden = true
        petView.apply(state: .thinking, mode: currentMode)
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginPetThrowDrag(initialMouseLocation: startLocation)
        }
        show()
    }

    func clearThinking() {
        isThinking = false
        isPromptLoading = false
        stopThrow()
        panel.ignoresMouseEvents = true
        petView.allowsClickWhenNotReady = false
        petView.onDragRequested = nil
        petView.apply(state: .idle, mode: currentMode)
        refreshStyleBadge()
    }

    private func cancelPointingAnimation() {
        pointingReturnTimer?.invalidate()
        pointingReturnTimer = nil
        pointingTarget = nil
    }

    func setActionMode(_ mode: TranslationMode) {
        currentMode = mode
        guard !isPromptVisible else { return }
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
        refreshStyleBadge()
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func updateTracking() {
        guard panel.isVisible else { return }

        petView.advanceAnimationFrame()
        if let pointingTarget {
            let targetOrigin = Self.originNearPoint(pointingTarget, size: Self.panelSize)
            let currentOrigin = panel.frame.origin
            let dx = targetOrigin.x - currentOrigin.x
            let dy = targetOrigin.y - currentOrigin.y
            let nextOrigin = NSPoint(
                x: currentOrigin.x + dx * 0.18,
                y: currentOrigin.y + dy * 0.18
            )
            panel.setFrameOrigin(nextOrigin)
            let distance = hypot(dx, dy)
            let didArrive = distance <= Self.pointingArrivalThreshold
            petView.apply(state: didArrive ? .ready : .run, mode: currentMode)
            return
        }
        guard selectedText == nil, !isReadyLockedUntilPanelCloses, !isThinking, !isPromptVisible else {
            return
        }

        let cursorLocation = NSEvent.mouseLocation
        let frameDelta = NSPoint(
            x: cursorLocation.x - lastCursorLocation.x,
            y: cursorLocation.y - lastCursorLocation.y
        )
        lastCursorLocation = cursorLocation
        let frameMagnitude = hypot(frameDelta.x, frameDelta.y)
        if frameMagnitude > 0.75 {
            lastCursorMovementDate = Date()
        }

        // Low-pass filter on cursor velocity — used ONLY by the shy-step
        // evasion below, not for the side flip. The side commitment uses raw
        // instantaneous frame velocity so only a true flick (high peak speed
        // in a single tick) flips the pet.
        let alpha: CGFloat = 0.08
        smoothedCursorVelocity = NSPoint(
            x: alpha * frameDelta.x + (1 - alpha) * smoothedCursorVelocity.x,
            y: alpha * frameDelta.y + (1 - alpha) * smoothedCursorVelocity.y
        )

        // Side only flips on a real flick — a sharp single-frame jerk above
        // this threshold. ~50pt/frame at 30Hz ≈ 1500pt/sec, which is a hard
        // wrist-snap, not normal cursor travel. Slow or sustained movement
        // keeps the current side no matter how long it lasts — only a sudden
        // burst earns a new side.
        let flickThreshold: CGFloat = 50
        if frameMagnitude >= flickThreshold {
            let candidate = Self.trailingOffset(
                forMovement: frameDelta,
                size: Self.panelSize,
                currentOffset: cursorOffset
            )
            if candidate != cursorOffset {
                cursorOffset = candidate
            }
        }

        // Shy-step displacement: for sub-threshold motion (jitter / small
        // moves that don't earn a side flip), nudge the pet a little further
        // along its current trailing direction whenever the cursor is closing
        // the gap on it. Net effect is "pet steps away" instead of "pet sits
        // still". The nudge decays with the EMA when the cursor stops.
        let evasion: NSPoint = {
            let petDistance = hypot(cursorOffset.x, cursorOffset.y)
            guard petDistance > 0 else { return .zero }
            let petDirX = cursorOffset.x / petDistance
            let petDirY = cursorOffset.y / petDistance
            // Projected velocity along the pet's direction. > 0 means the
            // cursor is moving toward where the pet currently sits.
            let velocityTowardPet =
                smoothedCursorVelocity.x * petDirX
                + smoothedCursorVelocity.y * petDirY
            guard velocityTowardPet > 0 else { return .zero }
            let evasionGain: CGFloat = 4.0
            let maxEvasion: CGFloat = 14.0
            let magnitude = min(velocityTowardPet * evasionGain, maxEvasion)
            return NSPoint(x: petDirX * magnitude, y: petDirY * magnitude)
        }()

        let effectiveOffset = NSPoint(
            x: cursorOffset.x + evasion.x,
            y: cursorOffset.y + evasion.y
        )
        let targetOrigin = Self.originNearCursor(
            for: cursorLocation,
            size: Self.panelSize,
            offset: effectiveOffset
        )
        let currentOrigin = panel.frame.origin
        let dx = targetOrigin.x - currentOrigin.x
        let dy = targetOrigin.y - currentOrigin.y
        let nextOrigin = NSPoint(
            x: currentOrigin.x + dx * 0.22,
            y: currentOrigin.y + dy * 0.22
        )
        panel.setFrameOrigin(nextOrigin)
        let cursorMovedRecently = Date().timeIntervalSince(lastCursorMovementDate) < 0.16
        petView.apply(state: cursorMovedRecently ? .run : .idle, mode: currentMode)
    }

    private func toggleRadialMenu() {
        if let radialMenu {
            radialMenu.close()
            self.radialMenu = nil
            return
        }
        // Same gate the old direct invocation had: the ring only makes sense
        // while a selection is armed.
        guard selectedText != nil, !isReadyLockedUntilPanelCloses else { return }
        var items: [RingItem] = [
            .phosphor("magnifying-glass", label: "Explain") { [weak self] in
                guard let self, let t = self.selectedText else { return }
                self.radialMenu = nil
                self.onTranslate?(t)
            },
            .phosphor("pencil-line", label: "Rewrite") { [weak self] in
                guard let self, let t = self.selectedText else { return }
                self.radialMenu = nil
                self.onRewrite?(t)
            },
            .phosphor("arrow-bend-up-left", label: "Reply") { [weak self] in
                guard let self, let t = self.selectedText else { return }
                self.radialMenu = nil
                self.onSmartReply?(t)
            },
            .phosphor("question", label: "Ask") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onAsk?()
            },
            .phosphor("scan", label: "Capture") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onScreenshot?()
            },
            .symbol("mic", label: "Dictate") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onDictate?()
            },
            .symbol("waveform", label: "Live") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onLive?()
            },
        ]
        if let opt = summarizeOption {
            items.insert(summarizeRingItem(opt, dismiss: { [weak self] in
                self?.radialMenu = nil
            }), at: 5)
        }
        let menu = RadialActionMenuController(
            centeredOn: petCenterInScreen(),
            ignoring: panel,
            items: items,
            onDismiss: { [weak self] in
                self?.radialMenu = nil
            }
        )
        radialMenu = menu
        menu.show()
    }

    private func petCenterInScreen() -> NSPoint {
        let frameInWindow = petView.convert(petView.bounds, to: nil)
        let screenRect = panel.convertToScreen(frameInWindow)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }

    private static func originNearCursor(for cursor: NSPoint, size: NSSize, offset: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)

        if origin.y < visibleFrame.minY + edgeMargin {
            origin.y = cursor.y + 12
        }
        if origin.y + size.height > visibleFrame.maxY - edgeMargin {
            origin.y = cursor.y - size.height - 8
        }
        if origin.x < visibleFrame.minX + edgeMargin {
            origin.x = cursor.x + 12
        }
        if origin.x + size.width > visibleFrame.maxX - edgeMargin {
            origin.x = cursor.x - size.width - 12
        }

        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func originNearPoint(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin),
            y: min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        )
    }

    private static func trailingOffset(
        forMovement movement: NSPoint,
        size: NSSize,
        currentOffset: NSPoint? = nil
    ) -> NSPoint {
        // Axis-bias hysteresis: if the pet is already committed horizontally
        // (left/right of cursor), require the vertical component to be
        // noticeably larger than the horizontal before flipping to a vertical
        // side — and vice-versa. Without this, diagonal motion where |dx|≈|dy|
        // would oscillate between horizontal and vertical sides.
        let axisBias: CGFloat = 1.9
        let currentIsHorizontal: Bool? = currentOffset.flatMap { offset in
            if offset.x == 12 || offset.x == -size.width - 12 {
                return true
            }
            if offset.y == 12 || offset.y == -size.height - 8 {
                return false
            }
            return nil
        }

        let pickHorizontal: Bool
        switch currentIsHorizontal {
        case .some(true):
            pickHorizontal = abs(movement.x) * axisBias >= abs(movement.y)
        case .some(false):
            pickHorizontal = abs(movement.x) >= abs(movement.y) * axisBias
        case .none:
            pickHorizontal = abs(movement.x) >= abs(movement.y)
        }

        if pickHorizontal {
            let xOffset = movement.x > 0 ? -size.width - 12 : 12
            return NSPoint(x: xOffset, y: -size.height / 2)
        }

        let yOffset = movement.y > 0 ? -size.height - 8 : 12
        return NSPoint(x: -size.width / 2, y: yOffset)
    }

    /// Drag the dialog bubble — and the pet with it — by tracking mouse
    /// movement until the user releases the button. Runs a synchronous event
    /// loop because that's the Cocoa-blessed way to handle window drag from a
    /// view's mouseDown. Annotation coordinates remain fixed to their screen
    /// positions so they anchor to whatever on-screen objects the answer
    /// describes, allowing the user to drag the bubble to a readable spot
    /// without losing visual reference. The caller supplies the initial
    /// screen-space mouse location captured at mouseDown so drag-vs-click
    /// detection upstream doesn't shift the anchor.
    private func beginBubbleDrag(initialMouseLocation: NSPoint) {
        let initialPetOrigin = panel.frame.origin
        let initialPromptOrigin = promptPanel.frame.origin

        while true {
            let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
            guard let event else { break }
            if event.type == .leftMouseUp { break }

            let current = NSEvent.mouseLocation
            let dx = current.x - initialMouseLocation.x
            let dy = current.y - initialMouseLocation.y

            panel.setFrameOrigin(NSPoint(x: initialPetOrigin.x + dx, y: initialPetOrigin.y + dy))
            promptPanel.setFrameOrigin(NSPoint(x: initialPromptOrigin.x + dx, y: initialPromptOrigin.y + dy))
        }
    }

    // MARK: Throw physics (thinking-state drag)

    private static let throwVelocityFrameRate: TimeInterval = 1.0 / 60.0
    private static let throwSampleWindow: TimeInterval = 0.1   // last 100ms of motion → release velocity
    private static let throwBounceDamping: CGFloat = 0.65       // wall-bounce energy retained
    private static let throwFriction: CGFloat = 0.98             // per-frame velocity decay
    private static let throwReleaseThreshold: CGFloat = 2        // pts/frame below which release is just a drag, not a throw
    private static let throwStopThreshold: CGFloat = 0.4         // pts/frame below which the throw stops

    /// During thinking, drag works like the bubble drag (pet + prompt panel
    /// move together) but also samples the last 100ms of cursor motion. On
    /// release, if the user was moving fast enough, hand off to the throw
    /// simulator so the pet flies and bounces off screen edges.
    private func beginPetThrowDrag(initialMouseLocation: NSPoint) {
        stopThrow()   // a fresh grab cancels any in-flight throw

        let initialPetOrigin = panel.frame.origin
        let initialPromptOrigin = promptPanel.frame.origin
        var samples: [(time: Date, point: NSPoint)] = [(Date(), initialMouseLocation)]

        while true {
            let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
            guard let event else { break }

            let now = NSEvent.mouseLocation
            let cutoff = Date(timeIntervalSinceNow: -Self.throwSampleWindow)
            samples.removeAll { $0.time < cutoff }
            samples.append((Date(), now))

            if event.type == .leftMouseUp { break }

            let dx = now.x - initialMouseLocation.x
            let dy = now.y - initialMouseLocation.y
            panel.setFrameOrigin(NSPoint(x: initialPetOrigin.x + dx, y: initialPetOrigin.y + dy))
            promptPanel.setFrameOrigin(NSPoint(x: initialPromptOrigin.x + dx, y: initialPromptOrigin.y + dy))
        }

        guard let first = samples.first, let last = samples.last else { return }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0.001 else { return }
        let vxPerSec = (last.point.x - first.point.x) / CGFloat(dt)
        let vyPerSec = (last.point.y - first.point.y) / CGFloat(dt)
        let perFrame = NSPoint(
            x: vxPerSec * CGFloat(Self.throwVelocityFrameRate),
            y: vyPerSec * CGFloat(Self.throwVelocityFrameRate)
        )
        guard hypot(perFrame.x, perFrame.y) > Self.throwReleaseThreshold else { return }
        startThrowSimulation(initialVelocity: perFrame)
    }

    private func startThrowSimulation(initialVelocity: NSPoint) {
        throwTimer?.invalidate()
        throwVelocity = initialVelocity
        petView.apply(state: .flying, mode: currentMode)
        let timer = Timer(timeInterval: Self.throwVelocityFrameRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepThrow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        throwTimer = timer
    }

    private func stepThrow() {
        let petOrigin = panel.frame.origin
        let promptOrigin = promptPanel.frame.origin
        let petSize = panel.frame.size
        var newOrigin = NSPoint(x: petOrigin.x + throwVelocity.x, y: petOrigin.y + throwVelocity.y)

        let referencePoint = NSPoint(x: petOrigin.x + petSize.width / 2, y: petOrigin.y + petSize.height / 2)
        let screen = NSScreen.visibleFrame(containing: referencePoint)
        let bounce = Self.throwBounceDamping

        if newOrigin.x < screen.minX {
            newOrigin.x = screen.minX
            throwVelocity.x = -throwVelocity.x * bounce
        } else if newOrigin.x + petSize.width > screen.maxX {
            newOrigin.x = screen.maxX - petSize.width
            throwVelocity.x = -throwVelocity.x * bounce
        }
        if newOrigin.y < screen.minY {
            newOrigin.y = screen.minY
            throwVelocity.y = -throwVelocity.y * bounce
        } else if newOrigin.y + petSize.height > screen.maxY {
            newOrigin.y = screen.maxY - petSize.height
            throwVelocity.y = -throwVelocity.y * bounce
        }

        let dx = newOrigin.x - petOrigin.x
        let dy = newOrigin.y - petOrigin.y
        panel.setFrameOrigin(newOrigin)
        promptPanel.setFrameOrigin(NSPoint(x: promptOrigin.x + dx, y: promptOrigin.y + dy))

        throwVelocity.x *= Self.throwFriction
        throwVelocity.y *= Self.throwFriction

        if hypot(throwVelocity.x, throwVelocity.y) < Self.throwStopThreshold {
            stopThrow()
        }
    }

    private func stopThrow() {
        let wasFlying = throwTimer != nil
        throwTimer?.invalidate()
        throwTimer = nil
        throwVelocity = .zero
        // Snap the pet back to the state it was already in (thinking, if
        // throw was triggered from there). Skip if no throw was running to
        // avoid clobbering whatever state the caller is mid-setting.
        if wasFlying, isThinking {
            petView.apply(state: .thinking, mode: currentMode)
        }
    }
}

@MainActor
final class PetMascotView: NSView {
    enum State: Equatable {
        case idle
        case run
        case ready
        case thinking
        case talking
        case flying
    }

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragRequested: ((NSPoint) -> Void)?
    var allowsClickWhenNotReady = false

    private var state: State = .idle
    private var mode: TranslationMode = .selection
    private var emotion: AskNugumiEmotion = .neutral
    private var animationFrame = 0
    /// Writing register dressed onto the character: formal = top hat + mustache,
    /// casual = cap, polite = bare (no accessory).
    private var writingStyle: WritingStyle = .polite

    func setWritingStyle(_ style: WritingStyle) {
        guard writingStyle != style else { return }
        writingStyle = style
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Nugumi"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click always wins over single-click handling and short-
        // circuits drag detection — this is how Ask gets dismissed now.
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
            return
        }

        // With a drag handler installed, peek the first follow-up event to
        // decide: a movement before mouseUp means the user wants to drag,
        // an immediate mouseUp means it was a plain click.
        if let onDragRequested {
            let startLocation = NSEvent.mouseLocation
            while true {
                let next = NSApp.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else { return }
                if next.type == .leftMouseUp {
                    if state == .ready || allowsClickWhenNotReady {
                        onClick?()
                    }
                    return
                }
                // First .leftMouseDragged — hand off to the drag handler
                // using the location captured at mouseDown.
                NSCursor.closedHand.push()
                onDragRequested(startLocation)
                NSCursor.pop()
                return
            }
        }

        guard state == .ready || allowsClickWhenNotReady else { return }
        onClick?()
    }

    func apply(state: State, mode: TranslationMode, emotion: AskNugumiEmotion = .neutral) {
        let didChange = self.state != state || self.mode != mode || self.emotion != emotion
        self.state = state
        self.mode = mode
        self.emotion = emotion
        toolTip = tooltip(for: state, mode: mode)
        if didChange {
            needsDisplay = true
        }
    }

    func advanceAnimationFrame() {
        animationFrame = (animationFrame + 1) % 240
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let rows = spriteRows()
        let cellSize: CGFloat = 2
        let maxColumns = rows.map(\.count).max() ?? 0
        let spriteSize = NSSize(width: CGFloat(maxColumns) * cellSize, height: CGFloat(rows.count) * cellSize)
        let spriteYOffset = spriteYOffset()
        let origin = NSPoint(
            x: floor((bounds.width - spriteSize.width) / 2),
            y: floor((bounds.height - spriteSize.height) / 2) + 1 + spriteYOffset
        )

        let accessory = styleAccessoryCells(rowCount: rows.count, faceOffset: currentFaceOffset())

        // Combined silhouette of body + accessory, used to stamp a thin dark rim
        // so the pale character stays legible on light backgrounds.
        var occupied = Set<MascotCell>()
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where color(for: pixel) != nil {
                occupied.insert(MascotCell(col: columnIndex, row: rowIndex))
            }
        }
        for cell in accessory.behind + accessory.front {
            occupied.insert(MascotCell(col: cell.col, row: cell.row))
        }

        drawPixelShadow(origin: origin)
        drawSpriteOutline(occupied, origin: origin, cellSize: cellSize, rowCount: rows.count)
        // z-order, back to front: tail, cap crown, body (ears), visor.
        drawPixelTail(origin: origin, cellSize: cellSize)
        drawAccessoryCells(accessory.behind, origin: origin, cellSize: cellSize, rowCount: rows.count)
        drawPixelRows(rows, origin: origin, cellSize: cellSize)
        drawAccessoryCells(accessory.front, origin: origin, cellSize: cellSize, rowCount: rows.count)
        if state == .ready {
            drawPixelActionBadge()
        }
        if state == .thinking {
            drawThinkingBadge()
        }
    }

    private struct MascotCell: Hashable { let col: Int; let row: Int }

    private func mascotCellRect(col: Int, row: Int, origin: NSPoint, cellSize: CGFloat, rowCount: Int) -> NSRect {
        NSRect(
            x: origin.x + CGFloat(col) * cellSize,
            y: origin.y + CGFloat(rowCount - row - 1) * cellSize,
            width: cellSize,
            height: cellSize
        )
    }

    /// One soft cell in every empty 4-neighbor of the silhouette → a 1-cell rim.
    /// A muted, semi-transparent slate (not hard black) so it reads as a gentle
    /// edge on light backgrounds without looking like a heavy outline.
    private func drawSpriteOutline(_ occupied: Set<MascotCell>, origin: NSPoint, cellSize: CGFloat, rowCount: Int) {
        NSColor(srgbRed: 0.40, green: 0.43, blue: 0.49, alpha: 0.6).setFill()
        for cell in occupied {
            let neighbors = [
                MascotCell(col: cell.col - 1, row: cell.row),
                MascotCell(col: cell.col + 1, row: cell.row),
                MascotCell(col: cell.col, row: cell.row - 1),
                MascotCell(col: cell.col, row: cell.row + 1),
            ]
            for n in neighbors where !occupied.contains(n) {
                NSBezierPath(rect: mascotCellRect(col: n.col, row: n.row, origin: origin, cellSize: cellSize, rowCount: rowCount)).fill()
            }
        }
    }

    /// Pixel cells for the current register's accessory, split by z-order.
    /// `behind` paints under the body sprite (so the ears stay in front of the
    /// cap's crown), `front` paints over it. `row` is measured from the sprite
    /// top (row 0); negative rows sit just above the head.
    private func styleAccessoryCells(
        rowCount: Int,
        faceOffset: Int
    ) -> (behind: [(col: Int, row: Int, color: NSColor)], front: [(col: Int, row: Int, color: NSColor)]) {
        switch writingStyle {
        case .polite:
            return ([], [])
        case .formal:
            let hat = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1)
            let band = NSColor(srgbRed: 0.55, green: 0.16, blue: 0.20, alpha: 1)
            var cells: [(col: Int, row: Int, color: NSColor)] = []
            // Top hat: wide brim, red hatband, narrow crown above. The hat is
            // fixed to the head; only the mustache tracks the face's idle drift.
            // The brim overlaps the head's top row so the hat sits flush — one
            // row higher leaves a 1px gap of background between hat and head.
            for c in 4...11 { cells.append((c, 2, hat)) }      // brim
            for c in 5...10 { cells.append((c, 1, band)) }     // hatband
            for c in 5...10 { cells.append((c, 0, hat)) }      // crown
            for c in 5...10 { cells.append((c, -1, hat)) }     // crown top
            // Tidy mustache centered under the nose, shifted with the face.
            for c in [5, 6, 8, 9] { cells.append((c + faceOffset, 8, hat)) }
            return ([], cells)
        case .casual:
            let cap = NSColor(srgbRed: 0.20, green: 0.52, blue: 0.50, alpha: 1)
            let capDark = NSColor(srgbRed: 0.13, green: 0.40, blue: 0.39, alpha: 1)
            // Baseball cap: rounded crown sitting up-right, a flat visor
            // jutting left. The crown goes BEHIND the body so the ears poke
            // out in front of it; the visor stays on top, sticking out over
            // the left ear.
            var crown: [(col: Int, row: Int, color: NSColor)] = []
            for c in 6...10 { crown.append((c, 0, cap)) }      // crown top
            for c in 5...11 { crown.append((c, 1, cap)) }      // crown
            for c in 5...12 { crown.append((c, 2, cap)) }      // crown base (right side)
            // Two-row visor angled down-left: light top surface continuous
            // with the crown, dark underside shifted one cell out — reads as
            // a proper peak instead of a dark blob.
            var visor: [(col: Int, row: Int, color: NSColor)] = []
            for c in 1...4 { visor.append((c, 2, cap)) }       // top surface
            for c in 0...3 { visor.append((c, 3, capDark)) }   // underside / tip
            return (crown, visor)
        }
    }

    private func drawAccessoryCells(_ cells: [(col: Int, row: Int, color: NSColor)], origin: NSPoint, cellSize: CGFloat, rowCount: Int) {
        for cell in cells {
            cell.color.setFill()
            NSBezierPath(rect: mascotCellRect(col: cell.col, row: cell.row, origin: origin, cellSize: cellSize, rowCount: rowCount)).fill()
        }
    }

    private func spriteYOffset() -> CGFloat {
        switch state {
        case .idle:
            return animationFrame % 90 >= 72 ? 0.5 : 0
        case .run:
            return (animationFrame / 4) % 2 == 0 ? 1 : 0
        case .ready:
            return animationFrame % 64 < 8 ? 0.75 : 0
        case .thinking:
            let phase = animationFrame % 32
            if phase < 8 { return 0 }
            if phase < 16 { return 0.5 }
            if phase < 24 { return 1 }
            return 0.5
        case .talking:
            // Body holds still — only the mouth (sprite swap) and tail
            // (drawPixelTail) animate while answering.
            return 0
        case .flying:
            // Rapid wobble — sells the "thrown" feeling. Two pixels of
            // amplitude, ~3-frame period (~100ms at 30fps).
            return CGFloat((animationFrame / 3) % 3) - 1
        }
    }

    private func idleFaceOffset() -> Int {
        switch (animationFrame / 32) % 4 {
        case 1:
            return -1
        case 3:
            return 1
        default:
            return 0
        }
    }

    /// Horizontal drift of the face this frame — the mustache rides along so it
    /// stays under the nose. Only the neutral idle animation shifts the face.
    private func currentFaceOffset() -> Int {
        state == .idle && emotion == .neutral ? idleFaceOffset() : 0
    }

    private func spriteRows() -> [String] {
        switch state {
        case .idle:
            if emotion != .neutral {
                return emotionSpriteRows(emotion)
            }
            return spriteRows(faceOffset: idleFaceOffset(), noseWidth: 1)
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "...WW......WWW..",
                    "................"
                ]
            } else {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "..WWW......WW...",
                    "................"
                ]
            }
        case .ready:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .thinking:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .talking:
            // Eyes, nose, ears, body — frozen. Identical to a calm idle pose
            // (faceOffset=0, neutral). Only the mouth (this row swap) and the
            // tail (drawPixelTail) move while the answer is shown.
            let mouthOpen = (animationFrame / 10) % 2 == 1
            return mouthOpen ? talkingSpriteRows() : spriteRows(faceOffset: 0, noseWidth: 1)
        case .flying:
            return flyingSpriteRows()
        }
    }

    private func flyingSpriteRows() -> [String] {
        // Shocked-in-flight expression: wide 3-pixel eyes, plain nose, no
        // mouth. The bigger eyes carry the "thrown!" feeling on their own.
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            "WWWKKKWWWWKKKWWW",
            "WWWKKKWWWWKKKWWW",
            "GWWWWWWPWWWWWWWG",
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func talkingSpriteRows() -> [String] {
        // Neutral centered head with a single-pixel mouth at row 8, col 9 —
        // diagonally below-right of the nose (col 7), with col 8 as a 1-pixel
        // horizontal gap. Reads as a small mouth, not a nose drip.
        var rows = spriteRows(faceOffset: 0, noseWidth: 1)
        var chars = Array(rows[8])
        if chars.count > 9 {
            chars[9] = "K"
            rows[8] = String(chars)
        }
        return rows
    }

    private func emotionSpriteRows(_ emotion: AskNugumiEmotion) -> [String] {
        switch emotion {
        case .neutral:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .happy:
            return spriteRows(
                eyeRow: "WWWKWWWWWWKWWWWW",
                noseRow: "GWWWWWPPWWWWWWWG"
            )
        case .surprised:
            return spriteRows(
                eyeRow: "WWWWKKWWWWKKWWWW",
                noseRow: "GWWWWWKKWWWWWWWG"
            )
        case .confused:
            return spriteRows(
                eyeRow: "WWWKKWWWWWKWWWWW",
                noseRow: "GWWWWWWPWWWWWWWG"
            )
        case .concerned:
            return spriteRows(
                eyeRow: "WWWWKWWWWWWKWWWW",
                noseRow: "GWWWWKKWWWWWWWWG"
            )
        }
    }

    private func spriteRows(eyeRow: String, noseRow: String) -> [String] {
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            eyeRow,
            eyeRow,
            noseRow,
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func spriteRows(faceOffset: Int, noseWidth: Int) -> [String] {
        let eyeRow: String
        let noseRow: String
        switch faceOffset {
        case ..<0:
            eyeRow = "WWWKKWWWWKKWWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWPWWWWWWWWG" : "GWWWWWPPWWWWWWWG"
        case 1...:
            eyeRow = "WWWWWKKWWWWKKWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWWPWWWWWWG" : "GWWWWWWPPWWWWWWG"
        default:
            eyeRow = "WWWWKKWWWWKKWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWPWWWWWWWG" : "GWWWWWPPWWWWWWG."
        }

        return spriteRows(eyeRow: eyeRow, noseRow: noseRow)
    }

    private func drawPixelRows(_ rows: [String], origin: NSPoint, cellSize: CGFloat) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() {
                guard let color = color(for: pixel) else { continue }
                color.setFill()
                let rect = NSRect(
                    x: origin.x + CGFloat(columnIndex) * cellSize,
                    y: origin.y + CGFloat(rows.count - rowIndex - 1) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    private func drawPixelTail(origin: NSPoint, cellSize: CGFloat) {
        let cells: [(Int, Int)]
        switch state {
        case .idle:
            switch (animationFrame / 24) % 3 {
            case 0:
                cells = [(7, 9), (7, 10), (8, 11), (9, 12), (10, 12)]
            case 1:
                cells = [(7, 9), (8, 10), (8, 11), (8, 12), (9, 12)]
            default:
                cells = [(7, 9), (8, 10), (7, 11), (6, 12), (5, 12)]
            }
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                cells = [(7, 9), (7, 10), (8, 11), (10, 12), (11, 12)]
            } else {
                cells = [(8, 9), (8, 10), (7, 11), (5, 12), (4, 12)]
            }
        case .ready, .thinking, .talking:
            switch (animationFrame / 16) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (8, 11), (9, 12), (10, 12)]
            default:
                cells = [(7, 9), (7, 10), (8, 11), (8, 12), (9, 12)]
            }
        case .flying:
            // Tail flails fast — switches every 3 frames (~100ms) between
            // hard-left and hard-right wags.
            switch (animationFrame / 3) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (9, 11), (10, 12), (11, 12)]
            default:
                cells = [(7, 9), (6, 10), (5, 11), (4, 12), (3, 12)]
            }
        }

        let tailColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.90, alpha: 1.0)
        let tailShade = NSColor(srgbRed: 0.68, green: 0.72, blue: 0.73, alpha: 1.0)
        for (index, cell) in cells.enumerated() {
            (index == cells.count - 1 ? tailShade : tailColor).setFill()
            let rect = NSRect(
                x: origin.x + CGFloat(cell.0) * cellSize,
                y: origin.y + CGFloat(cell.1) * cellSize,
                width: cellSize,
                height: cellSize
            )
            NSBezierPath(rect: rect).fill()
        }
    }

    private func drawPixelShadow(origin: NSPoint) {
        NSColor(calibratedWhite: 0.0, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: origin.x + 4, y: origin.y - 1, width: 22, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: origin.x + 8, y: origin.y - 3, width: 14, height: 2)).fill()
    }

    private func drawPixelActionBadge() {
        switch mode {
        case .selection, .revise, .reviseMessage, .summarizeChat, .summarizePage:
            drawTranslateBadge()
        case .draftMessage:
            drawRewriteBadge()
        case .smartReply:
            drawReplyBadge()
        }
    }

    private func badgeOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        NSPoint(x: bounds.width - width, y: bounds.height - height)
    }

    private func drawTranslateBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 19, height: 14), size: NSSize(width: 19, height: 14))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let borderColor = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        borderColor.setFill()
        shape.fill()

        let inner = frame.insetBy(dx: 1.5, dy: 1.5)
        let leftRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.52, height: inner.height)
        let rightRect = NSRect(x: leftRect.maxX, y: inner.minY, width: inner.maxX - leftRect.maxX, height: inner.height)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(srgbRed: 0.02, green: 0.55, blue: 0.76, alpha: 1.0).setFill()
        NSBezierPath(rect: leftRect).fill()
        NSColor(srgbRed: 0.80, green: 0.86, blue: 0.87, alpha: 1.0).setFill()
        NSBezierPath(rect: rightRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawBadgeText("A", color: .white, fontSize: 8.5, in: NSRect(x: inner.minX - 0.5, y: inner.minY + 0.5, width: leftRect.width, height: inner.height))
        drawBadgeText("文", color: NSColor(srgbRed: 0.19, green: 0.34, blue: 0.39, alpha: 1.0), fontSize: 8, in: NSRect(x: rightRect.minX - 0.5, y: rightRect.minY + 0.5, width: rightRect.width + 1, height: rightRect.height))
    }

    private func drawRewriteBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 18, height: 15), size: NSSize(width: 18, height: 15))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let inner = frame.insetBy(dx: 1.7, dy: 1.7)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
        drawBadgeText("✎", color: NSColor(srgbRed: 0.14, green: 0.18, blue: 0.20, alpha: 1.0), fontSize: 10.5, in: NSRect(x: inner.minX, y: inner.minY + 0.5, width: inner.width, height: inner.height))
    }

    private func drawReplyBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0).setFill()
        for x in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawThinkingBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        // Animated dots: cycle one bright dot at a time
        let activeDot = (animationFrame / 8) % 3
        for (index, x) in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5].enumerated() {
            let isActive = index == activeDot
            let color = isActive
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0)
                : NSColor(srgbRed: 0.55, green: 0.57, blue: 0.58, alpha: 1.0)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawBadgeText(_ text: String, color: NSColor, fontSize: CGFloat, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func color(for pixel: Character) -> NSColor? {
        switch pixel {
        case "W":
            return NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
        case "G":
            return NSColor(srgbRed: 0.70, green: 0.75, blue: 0.76, alpha: 1)
        case "K":
            return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        case "P":
            return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.65, alpha: 1)
        case "B":
            return NSColor(srgbRed: 0.97, green: 0.96, blue: 0.86, alpha: 1)
        case "D":
            return NSColor(srgbRed: 0.08, green: 0.16, blue: 0.20, alpha: 1)
        default:
            return nil
        }
    }

    private func tooltip(for state: State, mode: TranslationMode) -> String {
        switch state {
        case .idle, .run:
            return "Nugumi pet"
        case .ready:
            return "Choose an action"
        case .thinking:
            return "Thinking…"
        case .talking:
            return "Double-click to close"
        case .flying:
            return "Weeee!"
        }
    }
}

extension PetMascotView {
    /// The mascot rendered into a standalone image — the app's mark on
    /// surfaces that can't host a live view (menu bar, floating button).
    @MainActor
    static func markImage(height: CGFloat, mode: TranslationMode = .selection) -> NSImage? {
        let renderSize = NSSize(width: 42, height: 34)
        let mascot = PetMascotView(frame: NSRect(origin: .zero, size: renderSize))
        mascot.wantsLayer = false  // draw straight via draw(_:) so off-window cacheDisplay is reliable
        mascot.apply(state: .idle, mode: mode)
        guard let rep = mascot.bitmapImageRepForCachingDisplay(in: mascot.bounds) else {
            return nil
        }
        mascot.cacheDisplay(in: mascot.bounds, to: rep)

        let image = NSImage(size: NSSize(width: renderSize.width * height / renderSize.height, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}

/// Where a ring button's hover bubble sits relative to its circle. Also
/// names the bubble edge (or corner, for diagonals) carrying the tail via
/// `opposite`.
enum RadialMenuLabelPlacement {
    case top
    case left
    case right
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// The facing edge — a bubble ABOVE the circle points its tail DOWN,
    /// a bubble to the TOP-RIGHT points its tail from its BOTTOM-LEFT corner.
    var opposite: RadialMenuLabelPlacement {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .left: return .right
        case .right: return .left
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

/// One button on the radial menu that opens around the floating bar / pet:
/// an image (SF Symbol or, for contextual entries, an app icon), a hover
/// label, and the action to run when picked. Labels avoid "translate"
/// wording deliberately — house copy rule.
struct RingItem {
    let label: String
    let image: NSImage
    let handler: () -> Void
    /// When non-empty, this button is a hover-expandable parent: hovering (or
    /// clicking) it reveals these buttons as a second-layer fan while the first
    /// ring stays. The parent's own `handler` is then unused.
    var subItems: [RingItem] = []

    /// Builds a ring item from an SF Symbol, applying the same fixed
    /// size/weight the ring has always rendered its glyphs at.
    static func symbol(_ name: String, label: String, handler: @escaping () -> Void) -> RingItem {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            ?? NSImage()
        return RingItem(label: label, image: img, handler: handler)
    }

    /// Builds a ring item from a bundled Phosphor icon (bold weight, rendered
    /// to a 40px template PNG in Resources/PhosphorIcons — see LICENSE.txt
    /// there). Template + 20pt logical size = tints and scales exactly like
    /// the SF Symbol items it replaced.
    static func phosphor(_ name: String, label: String, handler: @escaping () -> Void) -> RingItem {
        let img = Bundle.module.url(forResource: "\(name)-bold", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 20, height: 20)
        return RingItem(label: label, image: img, handler: handler)
    }
}

/// A time window for a chat summary — the second-layer ring buttons.
enum SummaryTimeRange: CaseIterable {
    case today, week, month

    var label: String {
        switch self {
        case .today: return "Today"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }

    /// Messages sent at or after this instant are included.
    func cutoff(now: Date = Date()) -> Date {
        switch self {
        case .today: return Calendar.current.startOfDay(for: now)
        case .week:  return now.addingTimeInterval(-7 * 24 * 3600)
        case .month: return now.addingTimeInterval(-30 * 24 * 3600)
        }
    }
}

/// Contextual ring entry that reveals the chat-summary time-range layer. Non-nil
/// only when the frontmost app is a supported messenger — see
/// `NugumiApp.makeSummarizeOption`. `run` is coordinator-owned: it opens the
/// chat archive, matches the frontmost chat, fetches messages in the chosen
/// range, and panels the summary through the existing `translate(...)` path.
/// Reads the text of the web page open in a browser window straight off the
/// Accessibility tree. No Apple Events entitlement, no per-browser TCC
/// Automation prompt, no "Allow JavaScript from Apple Events" toggle — it
/// rides on the Accessibility permission Nugumi already holds.
enum BrowserPageReader {
    /// Frontmost apps that get the ring's summarize-page button. WebKit
    /// builds its AX tree eagerly; Chromium-based browsers build it lazily
    /// (see the attribute pokes in `pageText`).
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.naver.whale",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    enum PageError: Error, CustomStringConvertible {
        case noWebArea
        case emptyPage
        var description: String {
            switch self {
            case .noWebArea: return "Couldn't find a readable web page in the browser window."
            case .emptyPage: return "The page has no readable text."
            }
        }
    }

    /// Matches the chat transcript's ~12k-token budget.
    private static let characterBudget = 48_000
    // ponytail: hard node cap bounds the AX IPC walk on pathological pages;
    // raise if real pages come back truncated.
    private static let nodeBudget = 20_000

    /// Collects the page text of `pid`'s focused browser window, top to
    /// bottom. Every AX call is a blocking mach IPC round-trip — call off
    /// the main thread.
    static func pageText(pid: pid_t) throws -> String {
        let appEl = AXUIElementCreateApplication(pid)
        // Chromium only builds its renderer AX tree once an assistive client
        // shows up. AXManualAccessibility is its "an app wants the tree, not
        // VoiceOver" switch; a harmless no-op on Safari/WebKit.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var webArea: AXUIElement?
        for attempt in 0..<10 {
            if attempt > 0 { usleep(200_000) }
            // Older Chromium ignores AXManualAccessibility — fall back to the
            // VoiceOver flag, but only after the polite switch produced
            // nothing (it has known window-manager side effects).
            if attempt == 4 {
                AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            guard let window = focusedWindow(of: appEl) else { continue }
            var areas: [AXUIElement] = []
            collectWebAreas(in: window, depth: 0, into: &areas)
            // A window can hold several web areas (sidebars, extension
            // popovers) — the page is the biggest one.
            if let biggest = areas.max(by: { area($0) < area($1) }), area(biggest) > 10_000 {
                webArea = biggest
                break
            }
        }
        guard let webArea else { throw PageError.noWebArea }

        var parts: [String] = []
        var characters = characterBudget
        var nodes = nodeBudget
        collectText(webArea, into: &parts, characters: &characters, nodes: &nodes, depth: 0)
        let text = parts.joined(separator: "\n")
        guard text.count >= 40 else { throw PageError.emptyPage }
        return text
    }

    private static func focusedWindow(of appEl: AXUIElement) -> AXUIElement? {
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let winEl = win, CFGetTypeID(winEl) == AXUIElementGetTypeID() else { return nil }
        return (winEl as! AXUIElement)
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    private static func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func area(_ el: AXUIElement) -> CGFloat {
        var v: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID(),
              AXValueGetValue((val as! AXValue), .cgSize, &size) else { return 0 }
        return size.width * size.height
    }

    private static func collectWebAreas(in el: AXUIElement, depth: Int, into out: inout [AXUIElement]) {
        if depth > 24 || out.count >= 8 { return }
        if role(of: el) == "AXWebArea" { out.append(el); return }
        for child in children(of: el) { collectWebAreas(in: child, depth: depth + 1, into: &out) }
    }

    /// Depth-first, matching the page's visual top-to-bottom reading order.
    /// Buttons/links/headings all bottom out in AXStaticText leaves, so one
    /// role check covers the whole page (nav noise is the prompt's job).
    private static func collectText(
        _ el: AXUIElement,
        into parts: inout [String],
        characters: inout Int,
        nodes: inout Int,
        depth: Int
    ) {
        guard characters > 0, nodes > 0, depth <= 64 else { return }
        nodes -= 1
        if role(of: el) == kAXStaticTextRole {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
               let s = v as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                    characters -= trimmed.count + 1
                }
            }
            return
        }
        for child in children(of: el) {
            collectText(child, into: &parts, characters: &characters, nodes: &nodes, depth: depth + 1)
            if characters <= 0 || nodes <= 0 { return }
        }
    }
}

struct RingSummarizeOption {
    let appLabel: String            // e.g. "KakaoTalk"
    let appIcon: NSImage
    /// Messenger flow: the ring expands into time-range subitems and calls
    /// this with the picked range. nil for browsers.
    var run: ((_ range: SummaryTimeRange) -> Void)? = nil
    /// Browser flow: a web page has no time axis, so the ring renders a
    /// single button that fires immediately. nil for messengers.
    var runDirect: (() -> Void)? = nil
    /// Generic "summarize from anywhere" flow (frontmost app isn't summarizable):
    /// the ring's second layer becomes an app picker — one button per available
    /// source (Kakao/Telegram/Browser), each firing its own `runDirect` or
    /// expanding into its own time-range third orbit (`run`).
    var appChoices: [RingSummarizeOption]? = nil
}

/// Builds the ring's Summarize item from a `RingSummarizeOption`, shared by
/// all three ring presenters (quick menu, pet, floating button). `dismiss`
/// is the presenter's own teardown, run before any action fires. Chat
/// sources expand into time ranges; browsers fire directly.
@MainActor
func summarizeRingItem(_ opt: RingSummarizeOption, dismiss: @escaping () -> Void) -> RingItem {
    func rangeItems(_ run: @escaping (_ range: SummaryTimeRange) -> Void) -> [RingItem] {
        SummaryTimeRange.allCases.map { range in
            RingItem(label: range.label, image: RingTextBadge.image(range.label)) {
                dismiss()
                run(range)
            }
        }
    }

    if let choices = opt.appChoices {
        let subItems: [RingItem] = choices.map { choice in
            if let run = choice.run {
                // Hovering the app choice opens its own (third) orbit of ranges.
                return RingItem(label: choice.appLabel, image: choice.appIcon, handler: {}, subItems: rangeItems(run))
            }
            return RingItem(label: choice.appLabel, image: choice.appIcon) {
                dismiss()
                choice.runDirect?()
            }
        }
        return RingItem(label: "", image: opt.appIcon, handler: {}, subItems: subItems)
    }
    if let direct = opt.runDirect {
        return RingItem(label: "", image: opt.appIcon) {
            dismiss()
            direct()
        }
    }
    if let run = opt.run {
        return RingItem(label: "", image: opt.appIcon, handler: {}, subItems: rangeItems(run))
    }
    return RingItem(label: "", image: opt.appIcon, handler: { dismiss() })
}

/// Renders a short word badge ("Today", "Week", "Month") as an `NSImage` for
/// the time-range ring buttons, which otherwise expect an SF Symbol image.
/// Auto-fits the font so the word fills the circle without clipping.
enum RingTextBadge {
    static func image(_ text: String) -> NSImage {
        let d = RadialMenuLayoutPolicy.buttonDiameter
        let size = NSSize(width: d, height: d)
        let maxWidth: CGFloat = d - 14
        var fontSize: CGFloat = d * 0.31
        var attrs: [NSAttributedString.Key: Any] = [:]
        var r = CGRect.zero
        repeat {
            attrs = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            r = (text as NSString).boundingRect(with: NSSize(width: 200, height: 40), options: [], attributes: attrs)
            fontSize -= 1
        } while r.width > maxWidth && fontSize > 8
        let img = NSImage(size: size)
        img.lockFocus()
        (text as NSString).draw(
            at: NSPoint(x: (size.width - r.width) / 2, y: (size.height - r.height) / 2),
            withAttributes: attrs
        )
        img.unlockFocus()
        // Template so the button's contentTintColor flips the word black/white
        // to contrast with the glass (same as the SF-symbol buttons).
        img.isTemplate = true
        return img
    }
}

/// Pure geometry for the radial menu: where the four buttons sit around the
/// anchor and how the ring shifts to stay on screen. Kept free of AppKit
/// state so it is unit-testable.
enum RadialMenuLayoutPolicy {
    static let ringRadius: CGFloat = 78
    static let buttonDiameter: CGFloat = 46
    /// Room around the ring for hover label bubbles AND the outermost
    /// hover-revealed orbit (`thirdRingRadius` + a button + margin).
    static let panelPadding: CGFloat = 160

    static var panelSide: CGFloat {
        (ringRadius + buttonDiameter / 2 + panelPadding) * 2
    }

    /// `count` evenly-spaced positions. 1–4 keep the original right/bottom arc
    /// order (reply top-right, explain right, ask bottom-right, rewrite bottom);
    /// extra items fill the free left arc counter-clockwise.
    static func buttonCenters(count: Int) -> [CGPoint] {
        let diagonal = ringRadius * sqrt(0.5)
        let base: [CGPoint] = [
            CGPoint(x: ringRadius, y: 0),            // right       (Explain)
            CGPoint(x: 0, y: -ringRadius),           // bottom      (Rewrite)
            CGPoint(x: diagonal, y: diagonal),       // top-right   (Reply)
            CGPoint(x: diagonal, y: -diagonal),      // bottom-right(Ask)
            CGPoint(x: -diagonal, y: -diagonal),     // bottom-left (5th: Capture)
            CGPoint(x: -ringRadius, y: 0),           // left        (6th: summarize)
            CGPoint(x: 0, y: ringRadius),            // top
            CGPoint(x: -diagonal, y: diagonal)       // top-left
        ]
        return Array(base.prefix(count))
    }

    /// Radius of the hover-revealed second orbit — a concentric ring well
    /// OUTSIDE the main one, clear of the inner buttons and their bubbles.
    static let outerRingRadius: CGFloat = 152

    /// Third orbit (sub-items of a second-layer item, e.g. the time ranges
    /// behind a picked messenger) — same ring-to-ring spacing again.
    static let thirdRingRadius: CGFloat = 226

    /// Offsets (from the panel center) for an outer-orbit cluster: buttons sit
    /// on a concentric ring of `radius`, occupying the arc that points outward
    /// from the parent (`parentOffset`), fanned symmetrically around it. Their
    /// center-to-center spacing matches the first ring's (buttons 45° apart at
    /// `ringRadius`) — so at larger radii the angular step is smaller. The
    /// inner rings are untouched; each cluster is a further orbit around the
    /// same center.
    static func subClusterCenters(
        parentOffset: CGPoint,
        count: Int,
        radius: CGFloat = outerRingRadius
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        let firstRingChord = 2 * Double(ringRadius) * sin((45.0 * .pi / 180) / 2)
        let stepAngle = 2 * asin(min(1, firstRingChord / (2 * Double(radius))))
        let parentAngle = atan2(Double(parentOffset.y), Double(parentOffset.x))
        let spreadStart = -Double(count - 1) / 2.0
        return (0..<count).map { i in
            let a = parentAngle + (spreadStart + Double(i)) * stepAngle
            return CGPoint(
                x: radius * CGFloat(cos(a)),
                y: radius * CGFloat(sin(a))
            )
        }
    }

    /// Which of the eight ring directions an offset points to — that
    /// button's hover bubble continues radially outward on the same side
    /// (Logi Options+ style), tail back toward the circle.
    static func labelPlacement(for offset: CGPoint) -> RadialMenuLabelPlacement {
        // Snap the offset's angle to the nearest 45° sector.
        let sector = Int((atan2(offset.y, offset.x) / .pi * 4).rounded())
        switch sector {
        case 0: return .right
        case 1: return .topRight
        case 2: return .top
        case 3: return .topLeft
        case -1: return .bottomRight
        case -2: return .bottom
        case -3: return .bottomLeft
        default: return .left
        }
    }

    // Wide enough that the hover scale-up (+16% of the disc, ~4pt of radius)
    // still leaves visible air between the disc and its label bubble.
    static let bubbleGap: CGFloat = 10

    /// Where a hover bubble's frame starts so it sits outside the ring on
    /// the button's side, tail toward the circle. For diagonals the bubble's
    /// near corner (where its tail lives) anchors just off the circle's
    /// edge along the same diagonal.
    static func bubbleOrigin(
        for placement: RadialMenuLabelPlacement,
        buttonFrame: NSRect,
        bubbleSize: NSSize
    ) -> NSPoint {
        let diagonalInset = (buttonFrame.width / 2 + bubbleGap) * sqrt(0.5)
        switch placement {
        case .top:
            return NSPoint(
                x: buttonFrame.midX - bubbleSize.width / 2,
                y: buttonFrame.maxY + bubbleGap
            )
        case .bottom:
            return NSPoint(
                x: buttonFrame.midX - bubbleSize.width / 2,
                y: buttonFrame.minY - bubbleGap - bubbleSize.height
            )
        case .left:
            return NSPoint(
                x: buttonFrame.minX - bubbleGap - bubbleSize.width,
                y: buttonFrame.midY - bubbleSize.height / 2
            )
        case .right:
            return NSPoint(
                x: buttonFrame.maxX + bubbleGap,
                y: buttonFrame.midY - bubbleSize.height / 2
            )
        case .topRight:
            return NSPoint(
                x: buttonFrame.midX + diagonalInset,
                y: buttonFrame.midY + diagonalInset
            )
        case .topLeft:
            return NSPoint(
                x: buttonFrame.midX - diagonalInset - bubbleSize.width,
                y: buttonFrame.midY + diagonalInset
            )
        case .bottomRight:
            return NSPoint(
                x: buttonFrame.midX + diagonalInset,
                y: buttonFrame.midY - diagonalInset - bubbleSize.height
            )
        case .bottomLeft:
            return NSPoint(
                x: buttonFrame.midX - diagonalInset - bubbleSize.width,
                y: buttonFrame.midY - diagonalInset - bubbleSize.height
            )
        }
    }

    /// Panel frame centered on `anchor` — always. Deliberately no screen-edge
    /// clamping: near an edge part of the ring may fall off-screen (Logi
    /// Options+ behaves the same), but the ring never detaches from the
    /// button, which read as worse than a clipped button.
    static func panelFrame(anchor: NSPoint) -> NSRect {
        NSRect(
            x: anchor.x - panelSide / 2,
            y: anchor.y - panelSide / 2,
            width: panelSide,
            height: panelSide
        )
    }
}

/// The ring of action buttons that opens around the floating bar / pet.
/// Purely presentational: owns one transparent panel, reports the picked
/// action via `onSelect`, and calls `onDismiss` when it closed itself
/// (outside click, Escape, empty-area click). The presenter owns the
/// toggle state and calls `close()` for its own teardown paths.
@MainActor
final class RadialActionMenuController {
    private let panel: NSPanel
    /// Hover over the ring's center (the bar/pet under the ✕). The presenter
    /// subscribes to drive its close-button hover tint — its own tracking
    /// area is occluded by this panel while the ring is open.
    var onCenterHoverChange: ((Bool) -> Void)?
    /// The bar/pet panel that opened the menu. Its clicks are exempt from
    /// the local dismiss monitor: if a click reaches the presenter (past the
    /// menu's own backdrop), its handler must see the menu still open and
    /// toggle it — dismissing here first would make that handler reopen.
    private weak var presenterWindow: NSWindow?
    private let items: [RingItem]
    private let onDismiss: () -> Void
    private var buttons: [RadialMenuButtonView] = []
    /// Second-layer buttons for a hover-expandable item (the time-range orbit).
    /// Kept separate from `buttons` so the open/close ring animations ignore
    /// them — they show/hide only on hover.
    private var subButtons: [RadialMenuButtonView] = []
    /// The expandable (messenger) button that owns the second orbit, and the
    /// index of the sub-button highlighted by default (the middle one).
    private weak var expandableButton: RadialMenuButtonView?
    private var middleSubIndex = 0
    /// Which sub-button the cursor is currently over — overrides the default
    /// middle highlight while hovered.
    private var hoveredSubIndex: Int?
    private var subClusterVisible = false
    /// The expandable button's center (sub-buttons spring out from / collapse
    /// into it) and their final outer-ring frames. `isSubAnimating` ignores
    /// hover while the fly-out plays so the highlight doesn't jump to a button
    /// passing under the cursor.
    private var subOrigin: NSPoint = .zero
    private var subTargets: [NSRect] = []
    private var isSubAnimating = false
    /// Third orbit — sub-items of an expandable SECOND-layer button (e.g. a
    /// messenger in the app picker expanding into time ranges). Pre-built
    /// hidden at init, keyed by the sub button's index; only one open at a
    /// time (`expandedThirdIndex`).
    private var thirdButtons: [Int: [RadialMenuButtonView]] = [:]
    private var thirdTargets: [Int: [NSRect]] = [:]
    private var thirdOrigins: [Int: NSPoint] = [:]
    private var expandedThirdIndex: Int?
    private var dismissMonitors: [Any] = []
    private var didClose = false
    /// Center ✕ for presenter-less rings (the quick menu): a real
    /// `FloatingTranslateButtonView` in its menu-open state, so the center
    /// looks exactly like the floating button under a selection ring. Rings
    /// opened from the floating button / pet leave this nil — their presenter
    /// shows through the panel's transparent center and renders its own ✕.
    private var centerCloseButton: FloatingTranslateButtonView?

    init(
        centeredOn anchor: NSPoint,
        ignoring presenterWindow: NSWindow?,
        items: [RingItem],
        showsCenterClose: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.presenterWindow = presenterWindow
        self.items = items
        self.onDismiss = onDismiss

        let frame = RadialMenuLayoutPolicy.panelFrame(anchor: anchor)

        panel = RadialMenuPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        // The app forces darkAqua globally, but the ring's glass should match
        // the SYSTEM look (Control Center behavior): inherited forced-dark
        // renders the smoky dark glass variant even on a light-mode system.
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        panel.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)

        let container = RadialMenuBackdropView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        container.onEmptyClick = { [weak self] in self?.dismiss() }
        container.onCenterHoverChange = { [weak self] hovered in
            // Hovering the center ✕ dismisses the open second orbit too.
            if hovered { self?.hideSubCluster() }
            self?.centerCloseButton?.setCloseHovered(hovered)
            self?.onCenterHoverChange?(hovered)
        }
        let centerDiameter = RadialMenuLayoutPolicy.buttonDiameter
        container.trackCenterHover(in: NSRect(
            x: frame.width / 2 - centerDiameter / 2,
            y: frame.height / 2 - centerDiameter / 2,
            width: centerDiameter,
            height: centerDiameter
        ))

        let panelCenter = NSPoint(x: frame.width / 2, y: frame.height / 2)
        for (item, offset) in zip(items, RadialMenuLayoutPolicy.buttonCenters(count: items.count)) {
            let isExpandable = !item.subItems.isEmpty
            let button = RadialMenuButtonView(image: item.image) { [weak self] in
                // Expandable parents (the messenger button) reveal their
                // second layer instead of firing/closing — the first ring stays.
                if isExpandable { self?.showSubCluster() } else { self?.finish(with: item) }
            }
            button.setFrameOrigin(NSPoint(
                x: panelCenter.x + offset.x - button.frame.width / 2,
                y: panelCenter.y + offset.y - button.frame.height / 2
            ))
            container.addSubview(button)
            buttons.append(button)

            if isExpandable {
                // Hovering the messenger button opens the second orbit and keeps
                // it open (sticky) — it closes only when a DIFFERENT first-ring
                // button is hovered. The messenger and sub highlights are driven
                // by the controller, not each button's own hover tint.
                expandableButton = button
                button.suppressHoverTint = true
                middleSubIndex = item.subItems.count / 2
                subOrigin = NSPoint(x: panelCenter.x + offset.x, y: panelCenter.y + offset.y)
                let subOffsets = RadialMenuLayoutPolicy.subClusterCenters(
                    parentOffset: offset, count: item.subItems.count
                )
                for (index, pair) in zip(item.subItems, subOffsets).enumerated() {
                    let (sub, subOffset) = pair
                    let subButton = RadialMenuButtonView(image: sub.image) { [weak self] in
                        // An expandable sub (messenger with time ranges)
                        // reveals its third orbit on click; leaves fire.
                        if sub.subItems.isEmpty {
                            self?.finish(with: sub)
                        } else {
                            self?.showThirdCluster(index)
                        }
                    }
                    subButton.setFrameOrigin(NSPoint(
                        x: panelCenter.x + subOffset.x - subButton.frame.width / 2,
                        y: panelCenter.y + subOffset.y - subButton.frame.height / 2
                    ))
                    subTargets.append(subButton.frame)
                    subButton.isHidden = true
                    subButton.alphaValue = 0
                    subButton.suppressHoverTint = true
                    subButton.onHoverChange = { [weak self] hovered in
                        self?.subHoverChanged(index: index, hovered: hovered)
                    }
                    container.addSubview(subButton)
                    subButtons.append(subButton)

                    if !sub.subItems.isEmpty {
                        let thirdOffsets = RadialMenuLayoutPolicy.subClusterCenters(
                            parentOffset: subOffset,
                            count: sub.subItems.count,
                            radius: RadialMenuLayoutPolicy.thirdRingRadius
                        )
                        var thirds: [RadialMenuButtonView] = []
                        var targets: [NSRect] = []
                        for (subSub, thirdOffset) in zip(sub.subItems, thirdOffsets) {
                            let thirdButton = RadialMenuButtonView(image: subSub.image) { [weak self] in
                                self?.finish(with: subSub)
                            }
                            thirdButton.setFrameOrigin(NSPoint(
                                x: panelCenter.x + thirdOffset.x - thirdButton.frame.width / 2,
                                y: panelCenter.y + thirdOffset.y - thirdButton.frame.height / 2
                            ))
                            targets.append(thirdButton.frame)
                            thirdButton.isHidden = true
                            thirdButton.alphaValue = 0
                            container.addSubview(thirdButton)
                            thirds.append(thirdButton)
                        }
                        thirdButtons[index] = thirds
                        thirdTargets[index] = targets
                        thirdOrigins[index] = NSPoint(
                            x: panelCenter.x + subOffset.x,
                            y: panelCenter.y + subOffset.y
                        )
                    }
                }
                button.onHoverChange = { [weak self] hovered in
                    if hovered { self?.showSubCluster() }
                }
                continue
            }

            // An empty label means "highlight only, no callout" — the app
            // summarize button carries its identity in its app icon, so its
            // hover shows just the glass highlight (no "Telegram" bubble).
            guard !item.label.isEmpty else { continue }

            let placement = RadialMenuLayoutPolicy.labelPlacement(for: offset)
            let bubble = RadialMenuLabelBubbleView(
                text: item.label,
                tailEdge: placement.opposite
            )
            bubble.setFrameOrigin(RadialMenuLayoutPolicy.bubbleOrigin(
                for: placement,
                buttonFrame: button.frame,
                bubbleSize: bubble.frame.size
            ))
            bubble.alphaValue = 0
            container.addSubview(bubble)
            button.onHoverChange = { [weak self, weak bubble] hovered in
                // The collapse animation flies every button into the center —
                // right under the cursor when the ✕ was clicked — and each
                // pass fires a phantom mouseEntered. Dead ring, no bubbles.
                guard let self, !self.didClose else { return }
                // Hovering any other first-ring button dismisses the open
                // second orbit (the only thing that closes it besides picking).
                if hovered { self.hideSubCluster() }
                NSAnimationContext.runAnimationGroup { context in
                    // Ease the bubble in gently; hide fast so it never lags
                    // behind the cursor leaving the button.
                    context.duration = hovered ? 0.3 : 0.15
                    bubble?.animator().alphaValue = hovered ? 1 : 0
                }
            }
        }

        if showsCenterClose {
            let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
            let closeButton = FloatingTranslateButtonView(initialMode: .selection)
            closeButton.frame = NSRect(
                x: panelCenter.x - side / 2,
                y: panelCenter.y - side / 2,
                width: side,
                height: side
            )
            // Menu-open state = ✕ glyph, red-hovered right away — correct
            // here too, since the ring opens centered on the cursor.
            closeButton.setMenuOpen(true)
            closeButton.onClick = { [weak self] in self?.dismiss() }
            container.addSubview(closeButton)
            centerCloseButton = closeButton
        }

        // Batch every button's NSGlassEffectView into one backdrop pass via
        // NSGlassEffectContainerView (resolved by name — see GlassHostView).
        // Standalone glass views each capture the backdrop on their own,
        // asynchronously: buttons came up as darker placeholders and snapped
        // to real glass seconds later, one by one.
        if let containerCls = NSClassFromString("NSGlassEffectContainerView") as? NSView.Type {
            let glassGroup = containerCls.init(frame: NSRect(origin: .zero, size: frame.size))
            if glassGroup.responds(to: NSSelectorFromString("setContentView:")) {
                glassGroup.setValue(container, forKey: "contentView")
                panel.contentView = glassGroup
            } else {
                panel.contentView = container
            }
        } else {
            panel.contentView = container
        }
    }

    func show() {
        panel.orderFrontRegardless()
        animateButtonsIn()
        installDismissMonitors()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        removeDismissMonitors()
        subButtons.forEach { $0.animator().alphaValue = 0 }
        thirdButtons.values.forEach { $0.forEach { $0.animator().alphaValue = 0 } }
        // Mirror the open animation: buttons collapse back into the center.
        // The panel dies in the completion and is captured strongly, so the
        // teardown outlives self (presenters drop their reference right after
        // calling close). Mouse events stop immediately — the buttons are
        // already dead, only their ghosts animate.
        panel.ignoresMouseEvents = true
        let panel = self.panel
        guard let container = panel.contentView else {
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for button in buttons {
                button.animator().frame = NSRect(
                    x: container.bounds.midX - button.frame.width / 2,
                    y: container.bounds.midY - button.frame.height / 2,
                    width: button.frame.width,
                    height: button.frame.height
                )
                button.animator().alphaValue = 0
            }
            for bubble in container.subviews where bubble is RadialMenuLabelBubbleView {
                bubble.animator().alphaValue = 0
            }
            centerCloseButton?.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
    }

    private func dismiss() {
        guard !didClose else { return }
        close()
        onDismiss()
    }

    private func finish(with item: RingItem) {
        guard !didClose else { return }
        close()
        item.handler()
    }

    // MARK: - Hover-revealed second layer (sticky)

    /// Opens the second orbit and keeps it open. Hovering the messenger button
    /// calls this; it stays up until a DIFFERENT first-ring button is hovered,
    /// the ring is dismissed, or a time button is picked. The messenger button
    /// stays highlighted while it's open, and the middle sub-button is
    /// highlighted by default.
    private func showSubCluster() {
        guard !didClose else { return }
        expandableButton?.setHighlighted(true)
        if !subClusterVisible {
            subClusterVisible = true
            isSubAnimating = true
            // Stage the starting state (parked on the messenger button,
            // invisible) and let this CA transaction commit BEFORE animating:
            // animations scheduled in the same commit that unhides a layer are
            // skipped by Core Animation — the reveal used to pop in fully
            // settled while the collapse (already-visible layers) animated fine.
            for (sub, target) in zip(subButtons, subTargets) {
                sub.frame = NSRect(
                    x: subOrigin.x - target.width / 2,
                    y: subOrigin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                sub.isHidden = false
                sub.alphaValue = 0
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.subClusterVisible, !self.didClose else { return }
                for (sub, target) in zip(self.subButtons, self.subTargets) {
                    // Spring out from the messenger button to the outer slot —
                    // the same feel/timing as the first ring opening. Hover is
                    // ignored until it settles (isSubAnimating) so the highlight
                    // doesn't jump to a button passing under the cursor
                    // mid-flight; tracking re-arms at the settled frame.
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.22
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
                        sub.animator().frame = target
                        sub.animator().alphaValue = 1
                    }, completionHandler: { [weak self, weak sub] in
                        sub?.updateTrackingAreas()
                        self?.isSubAnimating = false
                    })
                }
            }
        }
        hoveredSubIndex = nil
        refreshSubHighlight()
        hideThirdCluster()
    }

    private func subHoverChanged(index: Int, hovered: Bool) {
        // Sticky: hovering a time button moves the highlight to it and it STAYS
        // there after the cursor leaves into empty space. Only re-hovering the
        // messenger button resets the default back to the middle (in
        // `showSubCluster`). Ignore hover while the fly-out animates.
        guard !isSubAnimating, hovered else { return }
        hoveredSubIndex = index
        refreshSubHighlight()
        // Expandable subs (messenger → ranges) open their third orbit on
        // hover; hovering a plain sub (browser) closes any open one.
        if thirdButtons[index] != nil {
            showThirdCluster(index)
        } else {
            hideThirdCluster()
        }
    }

    /// Reveals the third orbit for the expandable sub at `index`, collapsing
    /// any other open one. Same two-transaction reveal as `showSubCluster` —
    /// animations scheduled in the commit that unhides a layer are skipped.
    private func showThirdCluster(_ index: Int) {
        guard !didClose, expandedThirdIndex != index else { return }
        hideThirdCluster()
        guard let thirds = thirdButtons[index],
              let targets = thirdTargets[index],
              let origin = thirdOrigins[index]
        else { return }
        expandedThirdIndex = index
        for (third, target) in zip(thirds, targets) {
            third.frame = NSRect(
                x: origin.x - target.width / 2,
                y: origin.y - target.height / 2,
                width: target.width,
                height: target.height
            )
            third.isHidden = false
            third.alphaValue = 0
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expandedThirdIndex == index, !self.didClose else { return }
            for (third, target) in zip(thirds, targets) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
                    third.animator().frame = target
                    third.animator().alphaValue = 1
                }, completionHandler: { [weak third] in
                    third?.updateTrackingAreas()
                })
            }
        }
    }

    private func hideThirdCluster() {
        guard let index = expandedThirdIndex else { return }
        expandedThirdIndex = nil
        guard let thirds = thirdButtons[index],
              let targets = thirdTargets[index],
              let origin = thirdOrigins[index]
        else { return }
        for (third, target) in zip(thirds, targets) {
            NSAnimationContext.runAnimationGroup({ context in
                // Collapse back INTO the parent sub button, mirroring the
                // second orbit's close.
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                third.animator().frame = NSRect(
                    x: origin.x - target.width / 2,
                    y: origin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                third.animator().alphaValue = 0
            }, completionHandler: { [weak third] in
                third?.isHidden = true
                third?.frame = target   // reset for the next reveal
            })
        }
    }

    /// Highlights the hovered sub-button, or the middle one by default.
    private func refreshSubHighlight() {
        guard subClusterVisible else { return }
        let active = hoveredSubIndex ?? middleSubIndex
        for (i, sub) in subButtons.enumerated() {
            sub.setHighlighted(i == active)
        }
    }

    private func hideSubCluster() {
        hideThirdCluster()
        guard subClusterVisible else { return }
        subClusterVisible = false
        hoveredSubIndex = nil
        isSubAnimating = true
        expandableButton?.setHighlighted(false)
        for (sub, target) in zip(subButtons, subTargets) {
            sub.setHighlighted(false)
            NSAnimationContext.runAnimationGroup({ context in
                // Collapse back INTO the messenger button, mirroring the first
                // ring's close.
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                sub.animator().frame = NSRect(
                    x: subOrigin.x - target.width / 2,
                    y: subOrigin.y - target.height / 2,
                    width: target.width,
                    height: target.height
                )
                sub.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak sub] in
                sub?.isHidden = true
                sub?.frame = target   // reset for the next reveal
                self?.isSubAnimating = false
            })
        }
    }

    private func animateButtonsIn() {
        guard let container = panel.contentView else { return }
        for button in buttons {
            let target = button.frame
            button.frame = NSRect(
                x: container.bounds.midX - target.width / 2,
                y: container.bounds.midY - target.height / 2,
                width: target.width,
                height: target.height
            )
            button.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                // Same springy overshoot as the bar's hover scale.
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.34, 1.45, 0.5, 1
                )
                button.animator().frame = target
                button.animator().alphaValue = 1
            }
        }
    }

    /// The panel is non-activating and never key, so Escape needs both a
    /// local monitor (Nugumi frontmost) and a global one (another app
    /// frontmost — observed, not consumed). Mouse clicks: the global monitor
    /// covers other apps, the local one covers Nugumi's own windows — except
    /// the menu itself and the presenting bar/pet, whose click handler owns
    /// the toggle.
    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        var monitors: [Any?] = []
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window !== self.panel,
                  event.window !== self.presenterWindow
            else { return event }
            Task { @MainActor [weak self] in self?.dismiss() }
            return event
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            Task { @MainActor [weak self] in self?.dismiss() }
            return nil
        })
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        dismissMonitors = monitors.compactMap { $0 }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
    }
}

/// Panel that may hang off the screen edges. AppKit's default
/// `constrainFrameRect` silently pulls windows below the menu bar and back
/// onto the screen at the top/left — which detached the ring from its button
/// there while the bottom/right edges worked. The ring must stay centered on
/// the button even when part of it is off-screen.
private final class RadialMenuPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Transparent backdrop behind the ring buttons. A click that lands on it —
/// rather than on a button — dismisses the menu. It also tracks hover over
/// the ring's center: the panel occludes the presenter's own tracking area,
/// so the bar underneath cannot see those hovers itself.
private final class RadialMenuBackdropView: NSView {
    var onEmptyClick: (() -> Void)?
    var onCenterHoverChange: ((Bool) -> Void)?
    private var centerTrackingArea: NSTrackingArea?

    func trackCenterHover(in rect: NSRect) {
        if let centerTrackingArea {
            removeTrackingArea(centerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        centerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onCenterHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onCenterHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onEmptyClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEmptyClick?()
    }
}

/// One circular glass button on the ring: SF Symbol icon, hover tint, and a
/// small label that fades in under the circle on hover.
private final class RadialMenuButtonView: NSView {
    private let onPick: () -> Void
    private let circleView = NSVisualEffectView()
    /// Liquid Glass backing (NSGlassEffectView) when the OS has it; the class
    /// is resolved by name at runtime because the release SDK predates the
    /// symbol (same constraint as GlassHostView). nil → circleView fallback.
    private var liquidGlassView: NSView?
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?

    /// Runtime-only NSGlassEffectView factory. KVC keys are guarded by
    /// responds checks so a future rename degrades to the fallback glass
    /// instead of throwing.
    private static func makeLiquidGlass(diameter: CGFloat) -> (glass: NSView, content: NSView)? {
        guard let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let glass = cls.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        guard glass.responds(to: NSSelectorFromString("setCornerRadius:")),
              glass.responds(to: NSSelectorFromString("setContentView:"))
        else { return nil }
        glass.setValue(NSNumber(value: Double(diameter / 2)), forKey: "cornerRadius")
        let content = NSView(frame: glass.bounds)
        content.autoresizingMask = [.width, .height]
        glass.setValue(content, forKey: "contentView")
        return (glass, content)
    }

    /// Fired on hover in/out — the controller shows the label bubble, which
    /// lives outside this view so the ring hit-areas stay circle-sized.
    var onHoverChange: ((Bool) -> Void)?

    /// When true, hover does NOT toggle the glass tint itself — the controller
    /// drives it via `setHighlighted` instead (for the sticky second layer,
    /// where the highlight is decoupled from the raw cursor position).
    var suppressHoverTint = false

    init(image: NSImage, onPick: @escaping () -> Void) {
        self.onPick = onPick

        let diameter = RadialMenuLayoutPolicy.buttonDiameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true

        // Content (tint overlay + icon) goes inside whichever glass backs the
        // circle: Liquid Glass on macOS 26+, the frosted effect view before.
        let contentHost: NSView
        if let liquid = Self.makeLiquidGlass(diameter: diameter) {
            liquid.glass.frame = bounds
            addSubview(liquid.glass)
            liquidGlassView = liquid.glass
            contentHost = liquid.content
        } else {
            circleView.material = .hudWindow
            circleView.state = .active
            circleView.blendingMode = .behindWindow
            circleView.wantsLayer = true
            circleView.layer?.cornerRadius = diameter / 2
            circleView.layer?.masksToBounds = true
            circleView.frame = bounds
            addSubview(circleView)
            contentHost = circleView
        }

        iconView.image = image
        iconView.contentTintColor = .labelColor
        iconView.imageAlignment = .alignCenter
        // Natural symbol size, dead-center: proportional-down fitting can
        // nudge the glyph a point off-center when the fitted size rounds.
        iconView.imageScaling = .scaleNone
        iconView.frame = contentHost.bounds
        iconView.autoresizingMask = [.width, .height]
        contentHost.addSubview(iconView)

        // Resting look is the inverted glass (colors swapped vs. the old
        // default) — highlight flips it back to plain system glass.
        applyHighlight(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    // A smaller cousin of the floating button's halo — enough to lift the
    // discs off the backdrop without a heavy drop shadow.
    override func updateLayer() {
        guard let layer = self.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    // Swallow mouseDown: unhandled it would bubble up the responder chain to
    // the backdrop, whose mouseDown dismisses the menu before mouseUp lands.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        onPick()
    }

    private func setHovered(_ hovered: Bool) {
        if !suppressHoverTint { applyHighlight(hovered) }
        onHoverChange?(hovered)
    }

    /// Controller-driven highlight (used by the sticky second layer, where the
    /// highlighted button isn't necessarily the one under the cursor).
    func setHighlighted(_ on: Bool) {
        applyHighlight(on)
    }

    private func applyHighlight(_ on: Bool) {
        // Bare glass always — no color wash. Hover/selection is a springy
        // size bump of the glass disc itself. Only the CHILD's frame moves;
        // the root frame belongs to the ring's fan/collapse animations, so
        // the bump can never fight them (bounds stays the fixed diameter).
        let diameter = RadialMenuLayoutPolicy.buttonDiameter
        let scaled = on ? diameter * 1.16 : diameter
        let inset = (diameter - scaled) / 2
        let target = NSRect(x: inset, y: inset, width: scaled, height: scaled)
        let glass = liquidGlassView ?? circleView
        // Keep the disc a true circle: the corner radius doesn't animate with
        // the frame, but a 3-4pt radius jump on a growing circle is invisible.
        if let liquidGlassView {
            if liquidGlassView.responds(to: NSSelectorFromString("setCornerRadius:")) {
                liquidGlassView.setValue(NSNumber(value: Double(scaled / 2)), forKey: "cornerRadius")
            }
        } else {
            circleView.layer?.cornerRadius = scaled / 2
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
            glass.animator().frame = target
        }
    }
}

/// Logi-style callout for a ring button's hover label: solid rounded rect
/// plus a small tail pointing back at the circle. Deliberately fixed white
/// with black text — the old translucent in-panel label was unreadable on
/// busy or dark backgrounds, and a solid callout reads on any of them.
final class RadialMenuLabelBubbleView: NSView {
    private static let tailLength: CGFloat = 6
    /// Corner tails read much larger than side ones — their base already spans
    /// the whole rounded corner — so they poke out less to compensate.
    private static let cornerTailLength: CGFloat = 3
    private static let tailHalfWidth: CGFloat = 5
    private static let hPad: CGFloat = 9
    private static let vPad: CGFloat = 5
    private static let corner: CGFloat = 9
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]

    private let text: String
    /// The bubble edge carrying the tail — the edge that faces the circle.
    private let tailEdge: RadialMenuLabelPlacement

    init(text: String, tailEdge: RadialMenuLabelPlacement) {
        self.text = text
        self.tailEdge = tailEdge

        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        var size = NSSize(
            width: ceil(textSize.width) + Self.hPad * 2,
            height: ceil(textSize.height) + Self.vPad * 2
        )
        switch tailEdge {
        case .left, .right:
            size.width += Self.tailLength
        case .top, .bottom:
            size.height += Self.tailLength
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // A corner tail pokes out along both axes.
            size.width += Self.cornerTailLength
            size.height += Self.cornerTailLength
        }
        super.init(frame: NSRect(origin: .zero, size: size))

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // The tail is drawn outside the body but inside the frame — the body
        // rect cedes `tailLength` on the tail edge.
        var body = bounds
        switch tailEdge {
        case .left:
            body.origin.x += Self.tailLength
            body.size.width -= Self.tailLength
        case .right:
            body.size.width -= Self.tailLength
        case .bottom:
            body.origin.y += Self.tailLength
            body.size.height -= Self.tailLength
        case .top:
            body.size.height -= Self.tailLength
        case .bottomLeft:
            body.origin.x += Self.cornerTailLength
            body.size.width -= Self.cornerTailLength
            body.origin.y += Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        case .bottomRight:
            body.size.width -= Self.cornerTailLength
            body.origin.y += Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        case .topLeft:
            body.origin.x += Self.cornerTailLength
            body.size.width -= Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        case .topRight:
            body.size.width -= Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        }

        let path = NSBezierPath(roundedRect: body, xRadius: Self.corner, yRadius: Self.corner)
        let tail = NSBezierPath()
        let length = Self.tailLength
        let half = Self.tailHalfWidth
        // Corner tails: the base chord spans the rounded corner (radius
        // `corner` along each edge), the tip pokes diagonally outward.
        switch tailEdge {
        case .left:
            tail.move(to: NSPoint(x: body.minX, y: body.midY - half))
            tail.line(to: NSPoint(x: body.minX - length, y: body.midY))
            tail.line(to: NSPoint(x: body.minX, y: body.midY + half))
        case .right:
            tail.move(to: NSPoint(x: body.maxX, y: body.midY - half))
            tail.line(to: NSPoint(x: body.maxX + length, y: body.midY))
            tail.line(to: NSPoint(x: body.maxX, y: body.midY + half))
        case .bottom:
            tail.move(to: NSPoint(x: body.midX - half, y: body.minY))
            tail.line(to: NSPoint(x: body.midX, y: body.minY - length))
            tail.line(to: NSPoint(x: body.midX + half, y: body.minY))
        case .top:
            tail.move(to: NSPoint(x: body.midX - half, y: body.maxY))
            tail.line(to: NSPoint(x: body.midX, y: body.maxY + length))
            tail.line(to: NSPoint(x: body.midX + half, y: body.maxY))
        case .bottomLeft:
            tail.move(to: NSPoint(x: body.minX, y: body.minY + Self.corner))
            tail.line(to: NSPoint(x: body.minX - Self.cornerTailLength, y: body.minY - Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.minX + Self.corner, y: body.minY))
        case .bottomRight:
            tail.move(to: NSPoint(x: body.maxX - Self.corner, y: body.minY))
            tail.line(to: NSPoint(x: body.maxX + Self.cornerTailLength, y: body.minY - Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.maxX, y: body.minY + Self.corner))
        case .topLeft:
            tail.move(to: NSPoint(x: body.minX, y: body.maxY - Self.corner))
            tail.line(to: NSPoint(x: body.minX - Self.cornerTailLength, y: body.maxY + Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.minX + Self.corner, y: body.maxY))
        case .topRight:
            tail.move(to: NSPoint(x: body.maxX - Self.corner, y: body.maxY))
            tail.line(to: NSPoint(x: body.maxX + Self.cornerTailLength, y: body.maxY + Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.maxX, y: body.maxY - Self.corner))
        }
        tail.close()

        // Fill the two shapes separately: a corner tail overlaps the body's
        // rounded-corner bulge, and appending into one path punches an
        // even-odd hole exactly there (the dark sliver bug).
        NSColor.white.setFill()
        path.fill()
        tail.fill()

        (text as NSString).draw(
            at: NSPoint(x: body.minX + Self.hPad, y: body.minY + Self.vPad),
            withAttributes: Self.textAttributes
        )
    }
}

@MainActor
final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void
    private let onRewrite: (String) -> Void
    private let onSmartReply: (String) -> Void
    private let buttonView: FloatingTranslateButtonView
    private let onAsk: () -> Void
    private let onScreenshot: () -> Void
    private let onLive: () -> Void
    private let onDictate: () -> Void
    private let summarizeOption: RingSummarizeOption?
    private var radialMenu: RadialActionMenuController?

    init(
        screenPoint: NSPoint,
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void,
        onAsk: @escaping () -> Void,
        onScreenshot: @escaping () -> Void = {},
        onLive: @escaping () -> Void = {},
        onDictate: @escaping () -> Void = {},
        summarizeOption: RingSummarizeOption? = nil
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.onAsk = onAsk
        self.onScreenshot = onScreenshot
        self.onLive = onLive
        self.onDictate = onDictate
        self.summarizeOption = summarizeOption

        let buttonSize = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        let shadowPadding = AskNugumiFloatingTargetPresentationPolicy.shadowPadding
        let totalSize = AskNugumiFloatingTargetPresentationPolicy.totalSize
        let origin = NSPoint(
            x: screenPoint.x + 5 - shadowPadding,
            y: screenPoint.y - buttonSize - 5 - shadowPadding
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: totalSize, height: totalSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: totalSize, height: totalSize)))
        buttonView = FloatingTranslateButtonView(initialMode: initialMode)
        buttonView.frame = NSRect(x: shadowPadding, y: shadowPadding, width: buttonSize, height: buttonSize)
        buttonView.wantsLayer = true
        container.addSubview(buttonView)
        panel.contentView = container

        buttonView.onClick = { [weak self] in
            self?.toggleRadialMenu()
        }
    }

    func show() {
        panel.orderFrontRegardless()
        buttonView.enableHoverScaling()
    }

    func close() {
        radialMenu?.close()
        radialMenu = nil
        panel.close()
    }

    func setLoading() {
        panel.ignoresMouseEvents = true
        radialMenu?.close()
        radialMenu = nil
        buttonView.setLoading(true)
    }

    private func toggleRadialMenu() {
        if let radialMenu {
            radialMenu.close()
            self.radialMenu = nil
            buttonView.setMenuOpen(false)
            return
        }
        var items: [RingItem] = [
            .phosphor("magnifying-glass", label: "Explain") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onTranslate(self.selectedText)
            },
            .phosphor("pencil-line", label: "Rewrite") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onRewrite(self.selectedText)
            },
            .phosphor("arrow-bend-up-left", label: "Reply") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onSmartReply(self.selectedText)
            },
            .phosphor("question", label: "Ask") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onAsk()
            },
            .phosphor("scan", label: "Capture") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onScreenshot()
            },
            .symbol("mic", label: "Dictate") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onDictate()
            },
            .symbol("waveform", label: "Live") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
                self.onLive()
            },
        ]
        if let opt = summarizeOption {
            items.insert(summarizeRingItem(opt, dismiss: { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
            }), at: 5)
        }
        let menu = RadialActionMenuController(
            centeredOn: buttonCenterInScreen(),
            ignoring: panel,
            items: items,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.buttonView.setMenuOpen(false)
            }
        )
        menu.onCenterHoverChange = { [weak self] hovered in
            self?.buttonView.setCloseHovered(hovered)
        }
        radialMenu = menu
        menu.show()
        buttonView.setMenuOpen(true)
    }

    private func buttonCenterInScreen() -> NSPoint {
        let frameInWindow = buttonView.convert(buttonView.bounds, to: nil)
        let screenRect = panel.convertToScreen(frameInWindow)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }
}

/// The Ask Nugumi capsule's glass body. Any click inside it focuses the text
/// field instead of starting a window drag, so the whole pill is clickable.
private final class AskPromptGlassView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private final class AskPromptTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSCell.init(textCell:) yields a label-style cell (isEditable/isSelectable
        // default to false), so re-enable both or the field can't take focus —
        // no caret, clicks do nothing.
        cell = AskPromptTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private final class AskPromptTextFieldCell: NSTextFieldCell {}

/// The translation panel's "Revise or ask a follow-up" field. A plain
/// `NSTextField` is editable by default; we only add Esc-to-close.
/// A non-bezeled `NSTextField` draws its text near the top of its frame, not
/// centered — so the leading icon (centered in the row) sat below the text.
/// This cell vertically centers the text in both draw and edit states.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        let dy = (rect.height - textHeight) / 2
        return NSRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: textHeight)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}

final class FollowUpTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSCell(textCell:) yields a label-style cell (not editable), so
        // re-enable editing/selection or the field can't take focus.
        cell = VerticallyCenteredTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    // The panel uses `becomesKeyOnlyIfNeeded`, so it won't grab key until a view
    // asks for it. Force key + first responder on click so typing works even
    // while the source app is frontmost.
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private final class AskPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The translation result panel. Plain borderless `NSPanel` returns
/// `canBecomeKey == false`, so its text field (the follow-up input) could never
/// take focus. Overriding it — while keeping `becomesKeyOnlyIfNeeded` on the
/// instance — lets the field become key on click without the panel stealing key
/// the moment it appears (which would disrupt the source app's selection).
private final class TranslationResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Activating an `.accessory` app that wasn't frontmost makes macOS deliver a
/// reopen event — the same one a Dock relaunch sends. Our own panels activate
/// the app to take focus, so `applicationShouldHandleReopen` can't tell those
/// apart from a genuine relaunch and would pop the main window. Any internal
/// activation routes through here, opening a brief window during which the
/// delegate ignores reopen.
@MainActor
enum SelfActivationGuard {
    private static var suppressUntil = Date.distantPast

    static func activate() {
        suppressUntil = Date().addingTimeInterval(0.6)
        NSApp.activate(ignoringOtherApps: true)
    }

    static var isSuppressing: Bool { Date() < suppressUntil }
}

/// Click-through overlay that renders the model's explanation shapes
/// (`annotations` in the Ask response) over the captured screen. Purely
/// visual: it never takes mouse or keyboard input, so the user keeps
/// working "through" it. Every answer replaces the whole layer.
@MainActor
final class AskAnnotationOverlayController {
    private final class AnnotationPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class AnnotationCanvasView: NSView {
        var screenFrame: NSRect = .zero
        var annotations: [AskNugumiAnnotation] = [] {
            didSet { needsDisplay = true }
        }

        private static let strokeWidth: CGFloat = 3
        private static let haloWidth: CGFloat = 5.5
        private static let haloColor = NSColor.white.withAlphaComponent(0.9)

        override func draw(_ dirtyRect: NSRect) {
            guard !annotations.isEmpty,
                  let context = NSGraphicsContext.current?.cgContext
            else { return }
            // A soft drop shadow lifts the shapes off busy or light
            // backgrounds. The transparency layer makes the halo+stroke
            // composite cast one shadow as a unit instead of every stroke
            // shadowing its neighbors.
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -2),
                blur: 8,
                color: NSColor.black.withAlphaComponent(0.6).cgColor
            )
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for annotation in annotations {
                switch annotation.type {
                case .ellipse:
                    if let rect = localRect(for: annotation) {
                        strokeWithHalo(NSBezierPath(ovalIn: rect))
                    }
                case .rect:
                    if let rect = localRect(for: annotation) {
                        strokeWithHalo(NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6))
                    }
                case .arrow:
                    drawArrow(annotation)
                case .label:
                    drawLabel(annotation)
                }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        // Window covers `screenFrame`, so view-local = screen − frame origin.
        private func localPoint(_ screenPoint: CGPoint) -> CGPoint {
            CGPoint(x: screenPoint.x - screenFrame.minX, y: screenPoint.y - screenFrame.minY)
        }

        private func localRect(for annotation: AskNugumiAnnotation) -> CGRect? {
            guard let cx = annotation.cx, let cy = annotation.cy,
                  let w = annotation.w, let h = annotation.h
            else { return nil }
            let screenRect = AskNugumiCoordinateMapper.screenRect(
                centerX: cx,
                centerY: cy,
                normalizedWidth: w,
                normalizedHeight: h,
                screenFrame: screenFrame
            )
            return CGRect(
                origin: localPoint(screenRect.origin),
                size: screenRect.size
            )
        }

        private func strokeWithHalo(_ path: NSBezierPath) {
            path.lineWidth = Self.haloWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Self.haloColor.setStroke()
            path.stroke()
            path.lineWidth = Self.strokeWidth
            NSColor.nugumiAccent.setStroke()
            path.stroke()
        }

        private func drawArrow(_ annotation: AskNugumiAnnotation) {
            guard let fromX = annotation.fromX, let fromY = annotation.fromY,
                  let toX = annotation.toX, let toY = annotation.toY
            else { return }
            let from = localPoint(AskNugumiCoordinateMapper.exactScreenPoint(
                normalizedX: fromX, normalizedY: fromY, screenFrame: screenFrame
            ))
            let to = localPoint(AskNugumiCoordinateMapper.exactScreenPoint(
                normalizedX: toX, normalizedY: toY, screenFrame: screenFrame
            ))

            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength: CGFloat = 14
            let headWidth: CGFloat = 11
            let shaftEnd = CGPoint(
                x: to.x - cos(angle) * headLength,
                y: to.y - sin(angle) * headLength
            )

            let shaft = NSBezierPath()
            shaft.move(to: from)
            shaft.line(to: shaftEnd)
            strokeWithHalo(shaft)

            let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: CGPoint(
                x: shaftEnd.x + perpendicular.x * headWidth / 2,
                y: shaftEnd.y + perpendicular.y * headWidth / 2
            ))
            head.line(to: CGPoint(
                x: shaftEnd.x - perpendicular.x * headWidth / 2,
                y: shaftEnd.y - perpendicular.y * headWidth / 2
            ))
            head.close()
            head.lineWidth = 2.5
            Self.haloColor.setStroke()
            head.stroke()
            NSColor.nugumiAccent.setFill()
            head.fill()
        }

        private func drawLabel(_ annotation: AskNugumiAnnotation) {
            guard let x = annotation.x, let y = annotation.y,
                  let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            let anchor = localPoint(AskNugumiCoordinateMapper.exactScreenPoint(
                normalizedX: x, normalizedY: y, screenFrame: screenFrame
            ))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            let paddingX: CGFloat = 8
            let paddingY: CGFloat = 4
            var pill = CGRect(
                x: anchor.x - textSize.width / 2 - paddingX,
                y: anchor.y - textSize.height / 2 - paddingY,
                width: textSize.width + paddingX * 2,
                height: textSize.height + paddingY * 2
            )
            // Keep the pill on screen even for edge anchors.
            pill.origin.x = min(max(pill.origin.x, 2), bounds.maxX - pill.width - 2)
            pill.origin.y = min(max(pill.origin.y, 2), bounds.maxY - pill.height - 2)

            let background = NSBezierPath(
                roundedRect: pill,
                xRadius: pill.height / 2,
                yRadius: pill.height / 2
            )
            background.lineWidth = 2
            Self.haloColor.setStroke()
            background.stroke()
            NSColor.nugumiAccent.setFill()
            background.fill()
            string.draw(at: CGPoint(
                x: pill.midX - textSize.width / 2,
                y: pill.midY - textSize.height / 2
            ))
        }
    }

    private let panel: AnnotationPanel
    private let canvas: AnnotationCanvasView
    private var didClose = false

    let screenFrame: NSRect

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        canvas.screenFrame = screenFrame
        panel = AnnotationPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Same shelf as the drawing canvas: below the .floating Ask panels.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Capturable on purpose: annotations should survive into the user's
        // own screenshots. Nugumi's own follow-up captures still exclude this
        // layer via the capture-time sharing snapshot (which force-sets .none
        // and restores), and invisibility mode applies like any other window.
        InvisibilityState.apply(to: panel)
        // Purely visual layer: the user clicks straight through it.
        panel.ignoresMouseEvents = true
        panel.contentView = canvas
        panel.orderFrontRegardless()
    }

    /// Replaces the whole layer with this answer's shapes. Re-ordering front
    /// keeps replace semantics robust if another same-level window appeared
    /// since init.
    func show(_ annotations: [AskNugumiAnnotation]) {
        canvas.annotations = annotations
        panel.orderFrontRegardless()
    }

    /// Idempotent: teardown paths overlap.
    func close() {
        guard !didClose else { return }
        didClose = true
        panel.close()
    }
}

/// Transparent, non-activating overlay that covers the captured screen while
/// the Ask Nugumi prompt is open. Mouse drags become freehand red strokes;
/// at submit they are composited into the pending screen capture. The panel
/// never becomes key, so typing stays in the prompt field the whole time.
@MainActor
final class AskDrawingOverlayController {
    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        // Blanket updates (InvisibilityState.applyToAllOpenWindows, sharing
        // snapshot/restore) must never make the stroke canvas capturable:
        // clamp every assignment to .none. The super call is load-bearing —
        // an empty setter would never push .none to the window server at all.
        override var sharingType: NSWindow.SharingType {
            get { super.sharingType }
            set { super.sharingType = .none }
        }
    }

    private final class StrokeCanvasView: NSView {
        var strokes: [[NSPoint]] = [] {
            didSet { needsDisplay = true }
        }
        private(set) var strokeDates: [Date] = []
        private var activeStroke: [NSPoint] = []

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Cursor rects only apply to the key window and this panel is never
        // key, so the crosshair needs an always-active tracking area instead.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        override func mouseDown(with event: NSEvent) {
            activeStroke = [convert(event.locationInWindow, from: nil)]
        }

        override func mouseDragged(with event: NSEvent) {
            activeStroke.append(convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            // A plain click (no drag) draws nothing — stray clicks stay
            // harmless and never leave a dot on the screenshot.
            if activeStroke.count > 1 {
                strokes.append(activeStroke)
                strokeDates.append(Date())
            }
            activeStroke = []
            needsDisplay = true
        }

        func removeLastStroke() {
            guard !strokes.isEmpty else { return }
            strokes.removeLast()
            if !strokeDates.isEmpty {
                strokeDates.removeLast()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.setStroke()
            for stroke in strokes + [activeStroke] where stroke.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = 4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: stroke[0])
                for point in stroke.dropFirst() {
                    path.line(to: point)
                }
                path.stroke()
            }
        }
    }

    private let panel: OverlayPanel
    private let canvas: StrokeCanvasView
    private let screenFrame: NSRect
    private var undoKeyMonitor: Any?
    private var lastTextEditAt: Date?
    private var didClose = false

    var window: NSWindow { panel }

    /// Committed strokes in AppKit global (screen) coordinates — the exact
    /// input `AskNugumiScreenCapture.annotated(with:)` expects.
    var strokes: [[NSPoint]] {
        canvas.strokes.map { stroke in
            stroke.map { NSPoint(x: $0.x + screenFrame.minX, y: $0.y + screenFrame.minY) }
        }
    }

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        canvas = StrokeCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        panel = OverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One notch below .floating so the Ask pill and pet panels (both
        // .floating) stay clickable above the canvas.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Strokes must never leak into a screen capture — they are
        // composited into the image at submit instead.
        panel.sharingType = .none
        // Explicit `false` opts out of AppKit's per-pixel transparency hit
        // test: a fully clear window must still receive drawing drags.
        panel.ignoresMouseEvents = false
        panel.contentView = canvas
        panel.orderFrontRegardless()
        installUndoKeyMonitor()
    }

    /// Idempotent: every Ask teardown path calls this, some more than once.
    func close() {
        guard !didClose else { return }
        didClose = true
        if let undoKeyMonitor {
            NSEvent.removeMonitor(undoKeyMonitor)
            self.undoKeyMonitor = nil
        }
        panel.close()
    }

    enum UndoTarget: Equatable {
        case textField
        case stroke
    }

    /// Chronological ⌘Z arbitration between the prompt's text field and the
    /// stroke canvas: undo whatever the user touched last, and fall back to
    /// strokes once the field's undo stack is exhausted.
    static func undoTarget(
        lastStrokeAt: Date?,
        lastTextEditAt: Date?,
        textCanUndo: Bool
    ) -> UndoTarget {
        guard let lastStrokeAt else { return .textField }
        if let lastTextEditAt, lastTextEditAt > lastStrokeAt, textCanUndo {
            return .textField
        }
        return .stroke
    }

    /// Keystrokes that plausibly edit the prompt text (typing, delete,
    /// paste/cut) — used only to order text edits against strokes for ⌘Z.
    /// Caret movement also stamps here; that skews arbitration toward the
    /// field the user is actively in, which is the intuitive outcome.
    private static func isTextEditKeystroke(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        if modifiers == .command {
            let key = event.charactersIgnoringModifiers
            return key == "v" || key == "x"
        }
        guard modifiers.subtracting([.shift, .option]).isEmpty else { return false }
        return event.charactersIgnoringModifiers?.isEmpty == false
    }

    // ⌘Z anywhere while the Ask UI is open undoes the user's most recent
    // action: a stroke on the canvas or an edit in the prompt field,
    // whichever came last. A local monitor works for both the pill and the
    // pet prompt (whichever is key); non-⌘Z keystrokes are only observed to
    // timestamp text edits and always pass through.
    private func installUndoKeyMonitor() {
        undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isUndo = modifiers == .command && event.charactersIgnoringModifiers == "z"
            guard isUndo else {
                if Self.isTextEditKeystroke(event, modifiers: modifiers) {
                    self.lastTextEditAt = Date()
                }
                return event
            }
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
            switch Self.undoTarget(
                lastStrokeAt: self.canvas.strokeDates.last,
                lastTextEditAt: self.lastTextEditAt,
                textCanUndo: textView?.undoManager?.canUndo == true
            ) {
            case .stroke:
                self.canvas.removeLastStroke()
                return nil
            case .textField:
                return event
            }
        }
    }
}

@MainActor
final class AskPromptController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let textMovementUserInfoKey = "NSTextMovement"

    private let panel: NSPanel
    private let textField: AskPromptTextField
    private let onSubmit: (String) -> Void
    private let onClose: () -> Void
    private var didClose = false
    private var isSubmitting = false

    var isVisible: Bool { panel.isVisible }

    /// Center of the pill's window in screen coordinates. Used by the
    /// caller to position the substitute floating loading bar at the same
    /// spot when the pill is hidden during an in-flight question.
    var panelCenter: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    init(
        near screenPoint: NSPoint,
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose

        let layout = AskNugumiFloatingPromptMetrics.layout
        let origin = Self.origin(near: screenPoint, size: layout.panelSize)
        panel = AskPromptPanel(
            contentRect: NSRect(origin: origin, size: layout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        textField = AskPromptTextField(frame: .zero)

        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        buildUI()
    }

    func show() {
        textField.stringValue = ""
        textField.isEnabled = true
        SelfActivationGuard.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func setLoading() {
        panel.sharingType = .none
        textField.isEnabled = false
        textField.stringValue = ""
        setPlaceholder("Looking...")
    }

    /// Visually removes the pill while keeping the controller alive, so
    /// `showError` can bring it back via `makeKeyAndOrderFront`.
    func hidePanel() {
        panel.orderOut(nil)
    }

    func showError(_ message: String) {
        isSubmitting = false
        textField.isEnabled = true
        textField.stringValue = ""
        setPlaceholder(message)
        SelfActivationGuard.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        panel.close()
        onClose()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.didClose else { return }
            self.didClose = true
            self.onClose()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        submit()
    }

    private func buildUI() {
        let layout = AskNugumiFloatingPromptMetrics.layout
        let rootView = NSView(frame: NSRect(origin: .zero, size: layout.panelSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false

        // Same liquid-glass capsule as the main window and the language HUD —
        // no glow gradients, just the hud material with a hairline border.
        let glass = AskPromptGlassView(frame: layout.pillFrame)
        glass.onClick = { [weak self] in
            guard let self else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.textField)
        }
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glass.layer?.cornerRadius = layout.cornerRadius
        glass.layer?.masksToBounds = true
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        glass.layer?.borderWidth = 1
        rootView.addSubview(glass)

        textField.delegate = self
        textField.onEscape = { [weak self] in
            self?.close()
        }
        setPlaceholder("Ask Nugumi")
        textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.88)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(
                equalTo: glass.leadingAnchor,
                constant: layout.textFrame.minX - layout.pillFrame.minX
            ),
            textField.trailingAnchor.constraint(
                equalTo: glass.trailingAnchor,
                constant: -(layout.pillFrame.maxX - layout.textFrame.maxX)
            ),
            // Intrinsic height + centerY keeps the text optically centered in
            // the capsule (a fixed-height cell draws its baseline high).
            textField.centerYAnchor.constraint(equalTo: glass.centerYAnchor)
        ])

        panel.contentView = rootView
    }

    private func submit() {
        guard textField.isEnabled, !isSubmitting else { return }
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            panel.makeFirstResponder(textField)
            return
        }
        isSubmitting = true
        onSubmit(text)
    }

    private func setPlaceholder(_ text: String) {
        textField.placeholderString = text
        textField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.44),
                .font: textField.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
            ]
        )
    }

    private func textMovement(from notification: Notification) -> Int? {
        notification.userInfo?[Self.textMovementUserInfoKey] as? Int
    }

    private static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let visibleFrame = NSScreen.visibleFrame(containing: point)
        let edgeMargin = AskNugumiFloatingPromptMetrics.edgeMargin
        let preferredGap: CGFloat = 10
        let preferredBelowY = point.y - size.height - preferredGap
        let preferredAboveY = point.y + preferredGap
        let desiredY: CGFloat
        if preferredBelowY < visibleFrame.minY + edgeMargin,
           preferredAboveY + size.height <= visibleFrame.maxY - edgeMargin {
            desiredY = preferredAboveY
        } else {
            desiredY = preferredBelowY
        }

        return NSPoint(
            x: clamped(point.x - size.width / 2, min: visibleFrame.minX + edgeMargin, max: visibleFrame.maxX - size.width - edgeMargin),
            y: clamped(desiredY, min: visibleFrame.minY + edgeMargin, max: visibleFrame.maxY - size.height - edgeMargin)
        )
    }

    private static func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else {
            return (minValue + maxValue) / 2
        }
        return Swift.min(Swift.max(value, minValue), maxValue)
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingTranslateButtonView: NSView {
    var onClick: (() -> Void)?

    private let actionButton = FirstMouseButton()
    private let progressIndicator = NSProgressIndicator()
    private var glassView: GlassHostView!
    private var currentMode: TranslationMode
    private var isLoading = false
    private var isMenuOpen = false
    private var isCloseHovered = false

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverScalingEnabled = false
    /// The full-size frame the controller laid out; rest/hover scale around it.
    private var fullFrame: NSRect = .zero
    /// Resting scale for the idle floating button; springs up to 1.0 on hover.
    private static let restScale: CGFloat = 0.84

    init(initialMode: TranslationMode) {
        self.currentMode = initialMode
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        buildUI()
        apply(mode: initialMode)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = self.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
    }

    /// Shrinks the idle button and starts tracking hover. Called only for the
    /// persistent floating button; the loading/target variants stay full-size.
    func enableHoverScaling() {
        hoverScalingEnabled = true
        fullFrame = frame
        // Let the glyph image ride the frame: it rescales with the button bounds.
        actionButton.imageScaling = .scaleProportionallyUpOrDown
        applyScale(Self.restScale, animated: false)
        updateTrackingAreas()
    }

    // Same rationale as GlassHostView.resizeSubviews: the rapid hover in/out
    // retargeting of `animator().frame` loses autoresizing deltas and the
    // inner glass/glyph shrink cumulatively. Lay the chain out absolutely.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        glassView.frame = bounds
        let content = glassView.contentView
        actionButton.frame = content.bounds
        let indicatorSize = progressIndicator.frame.size
        progressIndicator.frame = NSRect(
            x: (content.bounds.width - indicatorSize.width) / 2,
            y: (content.bounds.height - indicatorSize.height) / 2,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        // Re-run updateLayer so the shadow ellipse follows the new bounds.
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        guard hoverScalingEnabled else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverScalingEnabled, !isLoading else { return }
        applyScale(1.0, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        // The ring panel covering the bar fires a synthetic exit the moment
        // it opens; keep the close button full-size while the ring is up.
        guard hoverScalingEnabled, !isLoading, !isMenuOpen else { return }
        applyScale(Self.restScale, animated: true)
    }

    /// Resizes the whole button via its frame — the only resize an
    /// `NSVisualEffectView` honors. The glyph is an `imageScaling` image, so it
    /// stretches with the animating button bounds: bar and icon scale as one.
    private func applyScale(_ scale: CGFloat, animated: Bool) {
        guard hoverScalingEnabled, fullFrame.width > 0 else { return }

        let targetFrame = NSRect(
            x: fullFrame.midX - fullFrame.width * scale / 2,
            y: fullFrame.midY - fullFrame.height * scale / 2,
            width: fullFrame.width * scale,
            height: fullFrame.height * scale
        )

        guard animated else {
            frame = targetFrame
            return
        }

        // Springy overshoot makes the grow feel lively rather than mechanical.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
            animator().frame = targetFrame
        }
    }

    private func buildUI() {
        let glass = GlassHostView(
            frame: bounds,
            cornerRadius: bounds.width / 2,
            tintColor: NSColor(srgbRed: 0.06, green: 0.12, blue: 0.22, alpha: 0.55),
            style: .regular
        )
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        glassView = glass

        actionButton.target = self
        actionButton.action = #selector(buttonTapped)
        actionButton.frame = bounds
        actionButton.autoresizingMask = [.width, .height]
        actionButton.isBordered = false
        actionButton.contentTintColor = .white
        actionButton.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        actionButton.imageScaling = .scaleNone
        glass.contentView.addSubview(actionButton)

        let indicatorSize: CGFloat = 16
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.appearance = NSAppearance(named: .darkAqua)
        progressIndicator.frame = NSRect(
            x: (bounds.width - indicatorSize) / 2,
            y: (bounds.height - indicatorSize) / 2,
            width: indicatorSize,
            height: indicatorSize
        )
        progressIndicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        progressIndicator.isHidden = true
        glass.contentView.addSubview(progressIndicator)
    }

    func apply(mode: TranslationMode) {
        currentMode = mode
        guard !isLoading else { return }
        applyModeVisuals()
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if loading {
            // The spinner reads best at full size — drop any resting shrink.
            applyScale(1.0, animated: true)
            actionButton.isHidden = true
            actionButton.toolTip = nil
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            actionButton.isHidden = false
            applyModeVisuals()
        }
    }

    private func applyModeVisuals() {
        // Render every glyph as an image (not a title/fixed-point symbol) so the
        // hover frame animation can scale it — `imageScaling` stretches it to the
        // animating button bounds.
        actionButton.image = Self.glyphImage(for: currentMode)
        actionButton.title = ""
        actionButton.imagePosition = .imageOnly
        actionButton.toolTip = "Choose an action"
    }

    /// While the radial menu is open the bar is its close affordance — the
    /// glyph flips to an ✕ so the second click reads as "close", not "act",
    /// and hovering it turns the whole button red (destructive affordance).
    func setMenuOpen(_ open: Bool) {
        guard !isLoading else { return }
        isMenuOpen = open
        if open {
            // The click that opened the menu happened on this button, so
            // the cursor starts on the ✕ — red right away.
            isCloseHovered = true
            actionButton.image = Self.closeGlyphImage(hovered: true)
            actionButton.toolTip = "Close"
        } else {
            isCloseHovered = false
            applyScale(Self.restScale, animated: true)
            applyModeVisuals()
        }
    }

    /// Hover over the ring's center, reported by the menu overlay — its
    /// panel occludes this view's own tracking area while the ring is open,
    /// so the bar cannot see these hovers itself.
    func setCloseHovered(_ hovered: Bool) {
        guard isMenuOpen, isCloseHovered != hovered else { return }
        isCloseHovered = hovered
        actionButton.image = Self.closeGlyphImage(hovered: hovered)
    }

    /// Plain white ✕ at rest; a solid red disc with a dark ✕ on hover. The
    /// disc is drawn opaque, so the ✕ is tinted via a palette symbol config —
    /// the sourceAtop trick in `glyphImage(symbolName:)` only works on a
    /// transparent canvas.
    private static func closeGlyphImage(hovered: Bool) -> NSImage {
        guard hovered else { return glyphImage(symbolName: "xmark") }
        let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Translucent so the glass underneath shows through — a solid
            // red disc read too loud.
            NSColor.systemRed.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.8)]))
            guard let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            symbol.draw(in: NSRect(
                x: rect.midX - symbol.size.width / 2,
                y: rect.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            return true
        }
    }

    /// A mode's glyph centered in a button-sized canvas with baked-in padding, so
    /// `imageScaling` shrinks/grows it proportionally as the button frame animates.
    private static func glyphImage(for mode: TranslationMode) -> NSImage {
        let name: String
        switch mode {
        case .selection, .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // The mascot, not a generic sparkles glyph: the button that
            // opens the radial menu wears the app's own mark.
            return mascotGlyphImage()
        case .draftMessage:
            name = "text.insert"
        case .smartReply:
            name = "bubble.left.fill"
        }
        return glyphImage(symbolName: name)
    }

    /// The mascot centered in a button-sized canvas, same baked-in padding
    /// contract as `glyphImage(symbolName:)` so frame animations scale it.
    /// The mascot renders once up front — the drawing handler can re-run at
    /// draw time and must not build views.
    private static func mascotGlyphImage() -> NSImage {
        guard let mark = PetMascotView.markImage(height: 18) else {
            return glyphImage(symbolName: "sparkles")
        }
        let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            mark.draw(in: NSRect(
                x: rect.midX - mark.size.width / 2,
                y: rect.midY - mark.size.height / 2,
                width: mark.size.width,
                height: mark.size.height
            ))
            return true
        }
    }

    private static func glyphImage(symbolName: String) -> NSImage {
        let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            let target = NSRect(
                x: rect.midX - symbol.size.width / 2,
                y: rect.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: target)
            // Template symbols draw as black; tint the drawn glyph white.
            NSColor.white.set()
            target.fill(using: .sourceAtop)
            return true
        }
    }

    @objc private func buttonTapped() {
        onClick?()
    }
}

final class TranslationPanelController {
    enum Side { case left, right }

    enum Anchor {
        // Click point with explicit side. .right = panel goes right of point
        // (default for LTR drags / unknown direction). .left = panel goes left
        // of point (used when user dragged right-to-left in non-AX apps).
        case point(NSPoint, panelSide: Side)
        case selection(NSRect)      // selection rect, NSScreen coords (bottom-left origin)
    }

    private static let sideGap: CGFloat = 10
    private static let edgeMargin: CGFloat = 16

    private let panel: NSPanel
    private let contentView: TranslationContentView
    private let anchor: Anchor
    private var activeRequestID = UUID()
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    /// Esc closes the panel whenever Nugumi receives the keystroke (e.g.
    /// right after an Ask Nugumi answer, when the prompt left Nugumi active).
    private var localEscapeKeyMonitor: Any?
    private var commandCopyInterceptor: CommandCopyInterceptor?
    private var returnKeyInterceptor: ReturnKeyInterceptor?
    private var didClose = false
    private var wasDismissedByUser = false
    private let onClose: (() -> Void)?
    /// Fires after `onClose` only when the user dismissed the panel (Esc, ✕,
    /// copy, outside click) — never on programmatic closes (panel replaced,
    /// Replace action, screenshot capture starting).
    var onUserDismiss: (() -> Void)?
    private let replaceShortcutSourcePID: pid_t?
    /// When false, a click outside the panel does NOT dismiss it — only the ✕
    /// button or Esc. The Ask Nugumi answer uses this so reading it isn't a
    /// one-misclick-away-from-gone affair.
    private let dismissesOnOutsideClick: Bool

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }
    var displayedResultText: String { contentView.currentResultText }
    var currentSourceText: String { contentView.currentSourceText }
    var currentTargetLanguageValue: TranslationLanguage { contentView.currentTargetLanguageValue }

    private let loadingPlaceholder: String

    init(
        anchor: Anchor,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        loadingPlaceholder: String = "Thinking",
        showsSource: Bool = true,
        showsFollowUp: Bool = false,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil,
        onFollowUp: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil,
        dismissesOnOutsideClick: Bool = true,
        onClose: (() -> Void)? = nil
    ) {
        self.loadingPlaceholder = loadingPlaceholder
        self.anchor = anchor
        self.onClose = onClose
        self.replaceShortcutSourcePID = replaceShortcutSourcePID
        self.dismissesOnOutsideClick = dismissesOnOutsideClick
        let referencePoint = Self.anchorReferencePoint(for: anchor)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "\(loadingPlaceholder)...", showsSource: showsSource, showsFollowUp: showsFollowUp),
            visibleFrame.height - 32
        )
        let panelSize = NSSize(width: TranslationContentView.preferredWidth, height: panelHeight)
        let origin = Self.panelOrigin(anchor: anchor, panelSize: panelSize, visibleFrame: visibleFrame)
        let anchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: origin.y,
            panelHeight: panelHeight
        )

        contentView = TranslationContentView(
            sourceText: sourceText,
            targetLanguage: targetLanguage,
            resultLabel: resultLabel,
            anchorY: anchorY,
            showsSource: showsSource,
            showsFollowUp: showsFollowUp,
            onTargetLanguageSelected: onTargetLanguageSelected,
            onReplace: onReplace
        )
        contentView.onFollowUp = onFollowUp
        panel = TranslationResultPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Keeps the source app's text view key so the action buttons fire on
        // the first click. Without this, the panel grabs key on initial click
        // and the button-tap is swallowed by the activation.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = contentView
        contentView.onClose = { [weak self] in self?.dismissByUser() }
        contentView.onNeedsResize = { [weak self] in
            self?.resizeToFitContent(animated: true)
        }
        // Resize only when a result actually renders (throttled), so streaming
        // doesn't shake the panel on every chunk.
        contentView.onResultRendered = { [weak self] in
            self?.resizeToFitContent(animated: false)
        }
        contentView.onFollowUpFocusChange = { [weak self] focused in
            // Only the rewrite panel installs an interceptor; nil elsewhere = no-op.
            focused ? self?.returnKeyInterceptor?.disable() : self?.returnKeyInterceptor?.enable()
        }
    }

    deinit {
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
    }

    @discardableResult
    func showLoading(targetLanguage: TranslationLanguage? = nil, placeholder: String? = nil) -> UUID {
        activeRequestID = UUID()
        if let targetLanguage {
            contentView.setTargetLanguage(targetLanguage)
        }
        contentView.startLoadingAnimation(baseText: placeholder ?? loadingPlaceholder)
        resizeToFitContent(animated: false)
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
        installCommandCopyInterceptor()
        installReturnKeyInterceptor()
        return activeRequestID
    }

    func showTranslation(_ text: String, requestID: UUID? = nil, isFinal: Bool = false) {
        guard requestIsCurrent(requestID) else {
            return
        }

        // Partials render inline (stable while streaming); the final chunk
        // (isFinal) re-renders as block markdown — tables/headers/lists.
        contentView.setResult(text, isFinal: isFinal)
    }

    func showError(_ message: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setError(message)
    }

    func close() {
        guard !didClose else {
            return
        }

        didClose = true
        contentView.stopLoadingAnimation()
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
        panel.close()
        onClose?()
        if wasDismissedByUser {
            onUserDismiss?()
        }
    }

    private func dismissByUser() {
        wasDismissedByUser = true
        close()
    }

    private func installOutsideClickMonitors() {
        if dismissesOnOutsideClick, globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.closeIfClickIsOutside(event)
            }

            localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.closeIfClickIsOutside(event)
                return event
            }
        }

        guard localEscapeKeyMonitor == nil else { return }
        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == UInt16(kVK_Escape),
                  self.panel.isVisible,
                  !self.contentView.isTargetLanguageMenuOpen
            else {
                return event
            }
            self.dismissByUser()
            return nil
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }

        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }

        if let localEscapeKeyMonitor {
            NSEvent.removeMonitor(localEscapeKeyMonitor)
            self.localEscapeKeyMonitor = nil
        }
    }

    private func installCommandCopyInterceptor() {
        guard commandCopyInterceptor == nil else {
            return
        }

        let interceptor = CommandCopyInterceptor { [weak self] in
            self?.copyResultAndClose()
        }
        commandCopyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeCommandCopyInterceptor() {
        commandCopyInterceptor?.disable()
        commandCopyInterceptor = nil
    }

    private func installReturnKeyInterceptor() {
        guard returnKeyInterceptor == nil, let pid = replaceShortcutSourcePID else {
            return
        }

        let interceptor = ReturnKeyInterceptor(sourcePID: pid) { [weak self] in
            self?.triggerReplaceFromShortcut()
        }
        returnKeyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeReturnKeyInterceptor() {
        returnKeyInterceptor?.disable()
        returnKeyInterceptor = nil
    }

    private func triggerReplaceFromShortcut() {
        guard panel.isVisible else { return }
        contentView.triggerReplaceProgrammatically()
    }

    private func copyResultAndClose() {
        guard panel.isVisible else {
            return
        }

        contentView.copyResultToPasteboard()
        dismissByUser()
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        guard !contentView.isTargetLanguageMenuOpen else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        dismissByUser()
    }

    private func requestIsCurrent(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return true
        }

        return requestID == activeRequestID
    }

    private func resizeToFitContent(animated: Bool) {
        let currentFrame = panel.frame
        if TranslationContentView.streamDebug {
            print(String(format: "[stream] resize curH=%.1f curY=%.1f", currentFrame.height, currentFrame.minY))
        }
        let visibleFrame = NSScreen.visibleFrame(containing: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        let targetHeight = min(contentView.preferredHeightForCurrentContent(), visibleFrame.height - 32)
        let targetWidth = TranslationContentView.preferredWidth
        let preserveCurrentPosition = panel.isVisible
        let targetSize = NSSize(width: targetWidth, height: targetHeight)

        let targetOrigin: NSPoint
        if preserveCurrentPosition {
            // Resize-in-place: preserve top edge (panel.maxY) and X. Works
            // identically for both .point and .selection anchors.
            let preservedY = min(
                max(currentFrame.maxY - targetHeight, visibleFrame.minY + Self.edgeMargin),
                visibleFrame.maxY - targetHeight - Self.edgeMargin
            )
            let preservedX = min(
                max(currentFrame.minX, visibleFrame.minX + Self.edgeMargin),
                visibleFrame.maxX - targetWidth - Self.edgeMargin
            )
            targetOrigin = NSPoint(x: preservedX, y: preservedY)
        } else {
            targetOrigin = Self.panelOrigin(
                anchor: anchor,
                panelSize: targetSize,
                visibleFrame: visibleFrame
            )
        }

        let targetAnchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: targetOrigin.y,
            panelHeight: targetHeight
        )
        contentView.setAnchorY(targetAnchorY)

        let targetFrame = NSRect(
            x: targetOrigin.x,
            y: targetOrigin.y,
            width: targetWidth,
            height: targetHeight
        )

        let frameUnchanged = abs(targetFrame.minX - currentFrame.minX) < 0.5
            && abs(targetFrame.minY - currentFrame.minY) < 0.5
            && abs(targetFrame.width - currentFrame.width) < 0.5
            && abs(targetFrame.height - currentFrame.height) < 0.5
        if frameUnchanged {
            contentView.layoutForCurrentSize()
            return
        }

        let heightDelta = abs(targetFrame.height - currentFrame.height)
        if !animated || heightDelta < 1.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(targetFrame, display: true)
            CATransaction.commit()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private static func anchorReferencePoint(for anchor: Anchor) -> NSPoint {
        switch anchor {
        case .point(let p, _):    return p
        case .selection(let r):   return NSPoint(x: r.midX, y: r.midY)
        }
    }

    private static func anchorY(for anchor: Anchor) -> CGFloat {
        switch anchor {
        case .point(let p, _):    return p.y
        case .selection(let r):   return r.midY
        }
    }

    private static func panelOrigin(
        anchor: Anchor,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        switch anchor {
        case .point(let p, let panelSide):
            // X depends on which side we want the panel relative to the point.
            // .right is the historical default (panel goes right of click point);
            // .left is used when the user dragged RTL so the panel flips to the
            // left to avoid overlapping the selection in non-AX apps.
            let desiredX: CGFloat
            switch panelSide {
            case .right: desiredX = p.x + sideGap
            case .left:  desiredX = p.x - sideGap - panelSize.width
            }
            let desiredY = p.y - panelSize.height * 0.52
            let clampedX = min(max(desiredX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)

        case .selection(let sel):
            // Prefer right of the selection; fall back to left; if neither side
            // fits, gracefully degrade to .point at the selection center.
            let rightX = sel.maxX + sideGap
            let leftX  = sel.minX - sideGap - panelSize.width
            let rightFits = rightX + panelSize.width <= visibleFrame.maxX - edgeMargin
            let leftFits  = leftX >= visibleFrame.minX + edgeMargin

            let chosenX: CGFloat
            if rightFits {
                chosenX = rightX
            } else if leftFits {
                chosenX = leftX
            } else {
                return panelOrigin(
                    anchor: .point(NSPoint(x: sel.midX, y: sel.midY), panelSide: .right),
                    panelSize: panelSize,
                    visibleFrame: visibleFrame
                )
            }

            // Center-align: panel.midY lines up with sel.midY (vertical center of
            // the selection). Clamp inside the visible frame so a tall panel beside
            // a short selection doesn't escape the screen.
            let desiredY = sel.midY - panelSize.height / 2
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            let clampedX = min(max(chosenX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)
        }
    }
}

private extension NSScreen {
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }
}

enum GlassHostStyle {
    case regular
    case clear
}

/// NSVisualEffectView that re-clamps its corner radius on every resize tick.
/// AppKit's `animator().frame` machinery animates subview sizes with its own
/// timer, so a radius set once (or at pin time) goes stale mid-animation and a
/// radius above half the side pinches the mask into a squircle — the floating
/// button rendered non-circular below full size.
final class ClampedCornerEffectView: NSVisualEffectView {
    var desiredCornerRadius: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = min(
            desiredCornerRadius,
            min(newSize.width, newSize.height) / 2
        )
    }
}

final class GlassHostView: NSView {
    let contentView = NSView()
    private let material = ClampedCornerEffectView()

    init(frame: NSRect, cornerRadius: CGFloat, tintColor: NSColor?, style: GlassHostStyle) {
        super.init(frame: frame)
        wantsLayer = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]

        // Keep this compatible with the current public macOS SDK used by CI/release builds.
        // Referencing NSGlassEffectView directly breaks compilation on Xcode versions whose
        // SDK does not yet define that symbol, even inside an #available(macOS 26.0, *) block.
        material.desiredCornerRadius = cornerRadius
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        addSubview(material)
        material.addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    // Absolute layout instead of mask-based autoresizing: interrupting an
    // in-flight `animator().frame` animation drops autoresizing deltas, so
    // full-bleed subviews drift smaller with every interrupted hover cycle
    // (the floating button's glass visibly shrank). Pinning to bounds on every
    // resize is self-healing — any later resize restores exact geometry.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        material.frame = bounds
        contentView.frame = material.bounds
    }
}

final class GlassChromeOverlayView: NSView {
    var cornerRadius: CGFloat = 22

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let innerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1))
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

final class HairlineSeparatorView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
        bounds.fill()
    }
}

private enum TranslationPanelPalette {
    static let targetTitle = NSColor(calibratedWhite: 1.0, alpha: 0.5)
    static let resultText = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    static let resultLink = NSColor(calibratedWhite: 1.0, alpha: 0.82)
    static let actionIconEnabled = NSColor(calibratedWhite: 1.0, alpha: 0.68)
    static let actionIconDisabled = NSColor(calibratedWhite: 1.0, alpha: 0.30)
    static let sourceAction = NSColor(calibratedWhite: 1.0, alpha: 0.70)
}

final class LanguagePickerButton: NSButton {
    static let titleLeadingInset: CGFloat = 8

    private static let horizontalPadding: CGFloat = 8
    private static let chevronGap: CGFloat = 6
    private static let pickerIndicatorWidth: CGFloat = 12

    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let titleColor = TranslationPanelPalette.targetTitle

    private var hoverTrackingArea: NSTrackingArea?
    private var displayTitle = ""
    private var isHovered = false
    private var isMenuOpen = false
    private var pickerEnabled = true

    var preferredWidth: CGFloat {
        let titleWidth = ceil((displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        let affordanceWidth = pickerEnabled ? Self.chevronGap + Self.pickerIndicatorWidth : 0
        let paddedWidth = titleWidth + Self.horizontalPadding * 2 + affordanceWidth
        return min(max(paddedWidth, 64), 220)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        alignment = .left
        focusRingType = .none
        title = ""
        setButtonType(.momentaryChange)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard pickerEnabled else {
            return
        }

        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .kern: 0
        ])
        let titleSize = title.size()
        let titleOrigin = NSPoint(
            x: Self.horizontalPadding,
            y: floor((bounds.height - titleSize.height) / 2) - 1
        )
        title.draw(at: titleOrigin)

        guard pickerEnabled && (isHovered || isMenuOpen || isHighlighted),
              bounds.width > Self.horizontalPadding * 2 + Self.pickerIndicatorWidth
        else {
            return
        }

        drawPickerIndicator(titleHeight: titleSize.height)
    }

    private func drawPickerIndicator(titleHeight: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        guard let base = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return
        }

        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            self.titleColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        // Center on the title's vertical center, mirroring the title's -1 nudge.
        let textCenterY = floor((bounds.height - titleHeight) / 2) - 1 + titleHeight / 2
        let x = bounds.maxX - Self.horizontalPadding - size.width
        let y = textCenterY - size.height / 2
        tinted.draw(at: NSPoint(x: floor(x), y: floor(y)), from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    func setTitle(_ title: String, pickerEnabled: Bool) {
        displayTitle = title
        self.pickerEnabled = pickerEnabled
        toolTip = pickerEnabled ? "Choose translation language" : nil
        isEnabled = true
        applyStyle()
        needsLayout = true
    }

    func setMenuOpen(_ isMenuOpen: Bool) {
        self.isMenuOpen = isMenuOpen
        applyStyle()
    }

    private func applyStyle() {
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }
}

final class SourcePreviewView: NSView {
    private static let moreButtonWidth: CGFloat = 50
    private static let moreGap: CGFloat = 8
    private static let sourceTextYOffset: CGFloat = 2
    private static let moreButtonYOffset: CGFloat = 1

    private let textLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "more", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var canExpand = false

    var onMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textLabel.font = NSFont.systemFont(ofSize: TranslationContentView.sourceFontSize, weight: .semibold)
        textLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.90)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.usesSingleLineMode = true
        addSubview(textLabel)

        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.isBordered = false
        moreButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        moreButton.contentTintColor = TranslationPanelPalette.sourceAction
        moreButton.isHidden = true
        moreButton.toolTip = "Show full source"
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateMoreVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateMoreVisibility()
    }

    override func layout() {
        super.layout()
        let buttonVisible = !moreButton.isHidden
        let labelWidth = buttonVisible
            ? max(0, bounds.width - Self.moreButtonWidth - Self.moreGap)
            : bounds.width
        let sourceTextHeight = ceil(textLabel.intrinsicContentSize.height)
        let moreButtonHeight = ceil(moreButton.intrinsicContentSize.height)
        let rowHeight = max(sourceTextHeight, moreButtonHeight)
        let rowY = floor((bounds.height - rowHeight) / 2)
        textLabel.frame = NSRect(
            x: 0,
            y: rowY + Self.sourceTextYOffset,
            width: labelWidth,
            height: rowHeight
        )
        moreButton.frame = NSRect(
            x: bounds.maxX - Self.moreButtonWidth,
            y: rowY + Self.moreButtonYOffset,
            width: Self.moreButtonWidth,
            height: rowHeight
        )
    }

    func configure(text: String, canExpand: Bool) {
        textLabel.stringValue = text
        self.canExpand = canExpand
        updateMoreVisibility()
    }

    private func updateMoreVisibility() {
        moreButton.isHidden = !(canExpand && isHovered)
        needsLayout = true
    }

    @objc private func moreTapped() {
        onMore?()
    }
}

/// A single line of text with a highlight that sweeps across it — the "AI is
/// working" shimmer. Used as the result panel's loading state instead of
/// cycling dots. The text shape masks an animated gradient.
final class ShimmerTextLabel: NSView {
    private let gradientLayer = CAGradientLayer()
    private let textLayer = CATextLayer()
    private var displayFont = NSFont.systemFont(ofSize: 16, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.contentsScale = scale
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.mask = textLayer
        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, font: NSFont, base: NSColor, highlight: NSColor) {
        displayFont = font
        textLayer.string = text
        textLayer.font = font as CTFont
        textLayer.fontSize = font.pointSize
        // Narrow bright band riding on a dim base; animating `locations` sweeps it.
        gradientLayer.colors = [base, base, highlight, base, base].map(\.cgColor)
        gradientLayer.locations = [0, 0.35, 0.5, 0.65, 1]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        let lineHeight = ceil(displayFont.ascender - displayFont.descender + displayFont.leading)
        textLayer.frame = NSRect(x: 0, y: max(0, (bounds.height - lineHeight) / 2), width: bounds.width, height: lineHeight)
    }

    func startAnimating() {
        guard gradientLayer.animation(forKey: "shimmer") == nil else { return }
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-0.6, -0.25, 0.0, 0.25, 0.6]
        anim.toValue = [0.4, 0.75, 1.0, 1.25, 1.6]
        anim.duration = 1.4
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(anim, forKey: "shimmer")
    }

    func stopAnimating() {
        gradientLayer.removeAnimation(forKey: "shimmer")
    }
}

final class TranslationContentView: NSView, NSTextFieldDelegate {
    private enum ResultTone {
        case normal
        case error

        var color: NSColor {
            switch self {
            case .normal:
                return TranslationPanelPalette.resultText
            case .error:
                return NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.30, alpha: 0.96)
            }
        }
    }

    static let bodyWidth: CGFloat = 400
    static let preferredWidth: CGFloat = bodyWidth
    private static let minHeight: CGFloat = 168
    private static let maxHeight: CGFloat = 540
    private static let contentWidth: CGFloat = 364
    static let sourceFontSize: CGFloat = 16
    private static let collapsedSourceBoxHeight: CGFloat = 34
    private static let minimumExpandedSourceBoxHeight: CGFloat = 48
    private static let minimumResultBoxHeight: CGFloat = 58
    private static let maximumSourceBoxHeight: CGFloat = 140
    private static let maximumResultBoxHeight: CGFloat = 340

    private static let panelPaddingX: CGFloat = 18
    private static let panelPaddingTop: CGFloat = 20
    private static let panelPaddingBottom: CGFloat = 18
    private static let labelHeight: CGFloat = 18
    private static let labelToBoxGap: CGFloat = 8
    private static let sourceToDividerGap: CGFloat = 13
    private static let dividerToTargetGap: CGFloat = 16
    private static let dividerHeight: CGFloat = 1

    // Footer "Revise or ask a follow-up" row (selection panel only).
    private static let followUpTopGap: CGFloat = 12
    // Equal to panelPaddingBottom so the field's center sits equidistant from the
    // divider above and the panel's bottom edge below.
    private static let followUpDividerToFieldGap: CGFloat = panelPaddingBottom
    private static let followUpFieldHeight: CGFloat = 20
    private static let followUpIconSize: CGFloat = 16
    static var followUpFooterHeight: CGFloat {
        followUpTopGap + dividerHeight + followUpDividerToFieldGap + followUpFieldHeight
    }
    private static let buttonSize: CGFloat = 18
    private static let resultFontSize: CGFloat = 18
    private static let resultParagraphSpacingFactor: CGFloat = 0.35
    // Gap between block paragraphs. Markdown collapses the blank line the model
    // emits between paragraphs, so spacing has to stand in for it — sized near a
    // full line so it reads like the literal blank line the plain-text render
    // shows. Paragraphs only; lists/headers keep the tighter base factor.
    private static let resultParagraphGapFactor: CGFloat = 1.1
    private static let textInsetY: CGFloat = 3
    private static let scrollableTextBottomPadding: CGFloat = 18

    var onClose: (() -> Void)?
    var onNeedsResize: (() -> Void)?
    /// Fires after an actual (throttled) result render so the panel resizes only
    /// when content really changed — not on every streamed chunk.
    var onResultRendered: (() -> Void)?
    /// Fires when the user submits the footer "Revise or ask a follow-up" field.
    var onFollowUp: ((String) -> Void)?
    /// Fires when the follow-up field gains (`true`) or loses (`false`) focus, so
    /// the controller can suspend the Return-key interceptor while the user is
    /// typing a follow-up (the rewrite flow otherwise steals Return to paste).
    var onFollowUpFocusChange: ((Bool) -> Void)?

    private let sourceText: String
    private var targetLanguage: TranslationLanguage
    private let showsSource: Bool
    private let showsFollowUp: Bool
    private let followUpDivider = HairlineSeparatorView()
    private let followUpField = FollowUpTextField()
    private let followUpIcon = NSImageView()
    private let resultLabel: String?
    private var resultText = "Thinking..."
    private var resultDisplayText = "Thinking..."
    /// The last non-loading result shown. Revise composes against this so a
    /// follow-up typed mid-revise builds on the real answer, not "Revising...".
    private var lastRealResultText = ""

    // Streaming throttle: just coalesces the per-chunk resize now that streaming
    // renders plain text (no markdown/NSTextTable re-layout to amortize). Kept
    // small so tokens land near word-by-word; first and final chunks always
    // render (leading + trailing edge).
    static let streamDebug = ProcessInfo.processInfo.environment["NUGUMI_STREAM_DEBUG"] == "1"
    private static let resultThrottleInterval: TimeInterval = 0.03
    private var pendingResultText: String?
    private var pendingResultTone: ResultTone = .normal
    private var resultThrottleScheduled = false
    private var lastResultRenderTime: TimeInterval = 0
    /// Whether the last render used the full block renderer (tables/headers) vs
    /// the inline streaming renderer — so the final block render isn't skipped
    /// just because its text matches the last streamed partial.
    private var lastRenderUsedBlock = false
    private var resultTone: ResultTone = .normal
    /// Streaming replaces the result storage ~33×/s; NSTextView's implicit
    /// insertion-point autoscroll (async, after didChangeText) then walks the
    /// viewport down a few px per chunk. All scrolling here is explicit
    /// (scrollToTop / clip pinning), so implicit autoscroll is never wanted.
    private final class NonAutoscrollingTextView: NSTextView {
        override func scrollRangeToVisible(_ range: NSRange) {}
    }

    /// NUGUMI_STREAM_DEBUG only: logs who moves the result clip's origin.
    private final class StreamDebugClipView: NSClipView {
        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            if abs(newOrigin.y - bounds.origin.y) > 0.5 {
                print("[stream] CLIP setBoundsOrigin \(bounds.origin.y) -> \(newOrigin.y)")
                Thread.callStackSymbols.prefix(10).forEach { print("[stream]   \($0)") }
            }
            super.setBoundsOrigin(newOrigin)
        }
    }

    private let resultTextView = NonAutoscrollingTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let sourcePreviewView = SourcePreviewView(frame: .zero)
    private let targetTitleButton = LanguagePickerButton(frame: .zero)
    private let sourceTextView = NSTextView()
    private let sourceScrollView = NSScrollView()
    private let resultScrollView = NSScrollView()
    private let sourceDivider = HairlineSeparatorView()
    private var panelGlass: GlassHostView?
    private var chromeOverlay: GlassChromeOverlayView?
    private var closeButton: NSButton?
    private var copyButton: NSButton?
    private var replaceButton: NSButton?
    private var sourceExpanded = false
    private var shouldScrollSourceToTop = true
    private var shouldScrollResultToTop = true
    private var anchorYValue: CGFloat
    private let onTargetLanguageSelected: ((TranslationLanguage) -> Void)?
    private let onReplace: ((String) -> Void)?
    private var loadingBaseText: String?
    private let loadingShimmer = ShimmerTextLabel()

    var isTargetLanguageMenuOpen = false

    init(
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        anchorY: CGFloat,
        showsSource: Bool = true,
        showsFollowUp: Bool = false,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil
    ) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.resultLabel = resultLabel
        self.anchorYValue = anchorY
        self.showsSource = showsSource
        self.showsFollowUp = showsFollowUp
        self.onTargetLanguageSelected = onTargetLanguageSelected
        self.onReplace = onReplace
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.preferredWidth,
            height: Self.preferredHeight(sourceText: sourceText, resultText: "Thinking...", showsSource: showsSource, showsFollowUp: showsFollowUp)
        ))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func preferredHeight(sourceText: String, resultText: String, sourceExpanded: Bool = false, showsSource: Bool = true, showsFollowUp: Bool = false) -> CGFloat {
        preferredHeight(
            sourceText: sourceText,
            resultBoxHeight: renderedResultHeight(markdown: resultText, width: contentWidth),
            sourceExpanded: sourceExpanded,
            showsSource: showsSource,
            showsFollowUp: showsFollowUp
        )
    }

    static func preferredHeight(sourceText: String, resultBoxHeight: CGFloat, sourceExpanded: Bool, showsSource: Bool, showsFollowUp: Bool) -> CGFloat {
        let sourceBoxHeight = sourceHeight(for: sourceText, expanded: sourceExpanded)

        // Source section (label + box + divider + gaps) is omitted entirely when
        // showsSource is false — the result becomes the top section.
        let sourceSectionHeight = showsSource
            ? (labelHeight + labelToBoxGap + sourceBoxHeight + sourceToDividerGap + dividerHeight + dividerToTargetGap)
            : 0
        let fixedHeight = panelPaddingTop
            + sourceSectionHeight
            + labelHeight + labelToBoxGap
            + panelPaddingBottom
            + (showsFollowUp ? followUpFooterHeight : 0)
        return min(max(fixedHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        // Measure what's actually shown (inline while streaming, block on final),
        // not a re-rendered block version — otherwise the panel height disagrees
        // with the displayed text mid-stream and the result twitches.
        let resultBox: CGFloat
        if !isShowingLoadingState, let storage = resultTextView.textStorage, storage.length > 0 {
            resultBox = Self.resultBoxHeight(rawTextHeight: Self.attributedTextHeight(storage, width: Self.contentWidth))
        } else {
            // While loading, size for the placeholder (e.g. "Revising"), not the
            // prior answer still held in resultText — otherwise revise blows the
            // panel up to the old result's height with the shimmer floating in it.
            resultBox = Self.renderedResultHeight(markdown: loadingBaseText ?? resultText, width: Self.contentWidth)
        }
        return Self.preferredHeight(
            sourceText: sourceText,
            resultBoxHeight: resultBox,
            sourceExpanded: sourceExpanded,
            showsSource: showsSource,
            showsFollowUp: showsFollowUp
        )
    }

    var currentResultText: String { lastRealResultText }
    var currentSourceText: String { sourceText }
    var currentTargetLanguageValue: TranslationLanguage { targetLanguage }

    static func anchorY(for screenY: CGFloat, panelOriginY: CGFloat, panelHeight: CGFloat) -> CGFloat {
        min(max(screenY - panelOriginY, 0), panelHeight)
    }

    func setAnchorY(_ anchorY: CGFloat) {
        guard abs(anchorYValue - anchorY) >= 0.5 else {
            return
        }
        // No layout here: the only caller (resizeToFitContent) always runs
        // layoutForCurrentSize right after — via setFrame → setFrameSize or
        // explicitly. Laying out now would use the OLD panel height with the
        // new text: a transient overflow that blinks the scroller and lets
        // NSTextView scroll/resize itself before the real layout lands.
        anchorYValue = anchorY
    }

    func setTargetLanguage(_ language: TranslationLanguage) {
        guard resultLabel == nil else {
            return
        }

        targetLanguage = language
        targetTitleButton.setTitle(language.displayName, pickerEnabled: true)
        layoutForCurrentSize()
    }

    private func expandSource() {
        guard !sourceExpanded else {
            return
        }

        sourceExpanded = true
        shouldScrollSourceToTop = true
        onNeedsResize?()
        layoutForCurrentSize()
    }

    private static func boxHeight(
        for text: String,
        font: NSFont,
        width: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        paragraphSpacing: CGFloat = 0
    ) -> CGFloat {
        let height = textHeight(for: text, font: font, width: width, paragraphSpacing: paragraphSpacing) + textInsetY * 2 + 4
        return min(max(height, minimum), maximum)
    }

    private static func sourceHeight(for text: String, expanded: Bool) -> CGFloat {
        guard expanded else {
            return collapsedSourceBoxHeight
        }

        return boxHeight(
            for: text,
            font: NSFont.systemFont(ofSize: sourceFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumExpandedSourceBoxHeight,
            maximum: maximumSourceBoxHeight
        )
    }

    private static func singleLineWidth(for text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func collapsedSourceText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func layoutScrollableTextView(
        _ textView: NSTextView,
        inside scrollView: NSScrollView,
        scrollFrame: NSRect,
        rawTextHeight: CGFloat,
        showsOverflowScroller: Bool = true,
        topAligned: Bool = false
    ) {
        scrollView.frame = scrollFrame

        let minimumVerticalTextPadding: CGFloat = 4
        let fitsInScrollFrame = rawTextHeight + minimumVerticalTextPadding * 2 <= scrollFrame.height
        let verticalInset: CGFloat
        let textViewHeight: CGFloat
        if fitsInScrollFrame {
            // Streaming pins to the top: centering re-derives the inset from the
            // text height, so every appended chunk shifts the whole block up and
            // the panel-growth pass shifts it back — visible trembling at ~33Hz.
            verticalInset = topAligned
                ? minimumVerticalTextPadding
                : floor(max(2, (scrollFrame.height - rawTextHeight) / 2))
            textViewHeight = scrollFrame.height
        } else {
            verticalInset = minimumVerticalTextPadding
            textViewHeight = max(
                scrollFrame.height + 1,
                rawTextHeight + verticalInset * 2 + scrollableTextBottomPadding
            )
        }

        let scrollerInset: CGFloat = 8
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: scrollFrame.width, height: textViewHeight)
        )
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollFrame.width - scrollerInset),
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasVerticalScroller = showsOverflowScroller && !fitsInScrollFrame
    }

    private static func textHeight(
        for text: String,
        font: NSFont,
        width: CGFloat,
        paragraphSpacing: CGFloat = 0
    ) -> CGFloat {
        let cleanText = text.isEmpty ? " " : text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = paragraphSpacing
        let storage = NSTextStorage(string: cleanText, attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Markdown resolved to plain text (list markers survive as glyphs,
    /// emphasis/table syntax is consumed) — for surfaces that can't render
    /// rich text, like the pet's pixel-font answer bubble.
    static func flattenedMarkdown(_ text: String) -> String {
        renderedMarkdownText(
            text,
            font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            color: .white
        ).string
    }

    /// Block-level markdown: paragraphs, ATX headers, bullet/numbered lists, and
    /// GitHub-style tables. Answers (follow-ups) emit real markdown now, not just
    /// plain translations, so block constructs must render instead of leaking as
    /// raw `|` pipes and `#`. Inline styling (bold/italic/code/links) is applied
    /// per block via `inlineAttributed`.
    static func renderedMarkdownText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        var i = 0
        var lastWasTable = false

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Table: a row with pipes immediately followed by a `|---|---|` rule.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparatorRow(lines[i + 1]) {
                var rows = [raw]
                i += 2 // header row + separator
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(lines[i])
                    i += 1
                }
                out.append(renderTable(rows: rows, font: font, color: color))
                lastWasTable = true
                continue
            }

            // ATX header (# .. ######)
            if let (level, content) = parseHeader(trimmed) {
                out.append(renderHeader(content, level: level, baseFont: font, color: color))
                lastWasTable = false
                i += 1
                continue
            }

            // List item (-, *, +, or "1.")
            if let item = parseListItem(raw) {
                out.append(renderListItem(marker: item.marker, content: item.content, font: font, color: color))
                lastWasTable = false
                i += 1
                continue
            }

            // Paragraph: consecutive non-blank, non-block lines. Joined with "\n"
            // so the model's intended soft breaks survive (matches prior behavior).
            var paragraphLines = [raw]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if parseHeader(t) != nil { break }
                if parseListItem(l) != nil { break }
                if t.contains("|"), i + 1 < lines.count, isTableSeparatorRow(lines[i + 1]) { break }
                paragraphLines.append(l)
                i += 1
            }
            out.append(renderParagraph(paragraphLines.joined(separator: "\n"), font: font, color: color))
            lastWasTable = false
        }

        // Drop the final newline so the box isn't padded with a blank line — but
        // not after a table, where it terminates the last cell's paragraph.
        if !lastWasTable, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    /// Streaming render: plain text, no markdown at all. Even inline syntax
    /// (bold/italic/code) reflows the line as it completes mid-stream — a
    /// half-streamed `**bol` shows its asterisks, then snaps to bold and shifts.
    /// So *all* markdown is deferred to the final block render
    /// (`renderedMarkdownText`): raw syntax shows briefly while text streams in,
    /// then resolves once. One transform instead of a twitch per token.
    static func renderedStreamingText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.paragraphSpacing = font.pointSize * resultParagraphSpacingFactor
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: p
        ])
    }

    /// Inline-only markdown (bold/italic/code/links) for a single block of text.
    /// No paragraph style, no trailing newline — block renderers add those.
    private static func inlineAttributed(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options))
            .map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: text)

        guard rendered.length > 0 else {
            return rendered
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.addAttributes([.font: font, .foregroundColor: color], range: fullRange)

        var fontRuns: [(NSRange, NSFont)] = []
        rendered.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let intent = (value as? NSNumber)?.intValue else { return }
            if let styledFont = markdownFont(for: intent, baseFont: font) {
                fontRuns.append((range, styledFont))
            }
        }
        for (range, styledFont) in fontRuns {
            rendered.addAttribute(.font, value: styledFont, range: range)
        }

        rendered.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            rendered.addAttributes([
                .foregroundColor: TranslationPanelPalette.resultLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }
        return rendered
    }

    private static func blockParagraphStyle(font: NSFont, headIndent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingFactor: CGFloat = resultParagraphSpacingFactor) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.paragraphSpacing = font.pointSize * spacingFactor
        p.paragraphSpacingBefore = spacingBefore
        if headIndent > 0 {
            p.headIndent = headIndent
            p.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)]
        }
        return p
    }

    private static func renderParagraph(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let s = inlineAttributed(text, font: font, color: color)
        s.addAttribute(.paragraphStyle, value: blockParagraphStyle(font: font, spacingFactor: resultParagraphGapFactor), range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n"))
        return s
    }

    private static func renderHeader(_ text: String, level: Int, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let scale: CGFloat = level <= 1 ? 1.3 : (level == 2 ? 1.15 : 1.05)
        let headerFont = NSFont.systemFont(ofSize: baseFont.pointSize * scale, weight: .bold)
        let s = inlineAttributed(text, font: headerFont, color: color)
        s.addAttribute(
            .paragraphStyle,
            value: blockParagraphStyle(font: headerFont, spacingBefore: baseFont.pointSize * 0.4),
            range: NSRange(location: 0, length: s.length)
        )
        s.append(NSAttributedString(string: "\n"))
        return s
    }

    private static func renderListItem(marker: String, content: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let indent = font.pointSize * 1.5
        let s = NSMutableAttributedString(string: "\(marker)\t", attributes: [.font: font, .foregroundColor: color])
        s.append(inlineAttributed(content, font: font, color: color))
        s.addAttribute(.paragraphStyle, value: blockParagraphStyle(font: font, headIndent: indent), range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n"))
        return s
    }

    private static func isTableSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        let cells = t.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseHeader(_ trimmed: String) -> (level: Int, content: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        return (level, String(trimmed[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> (marker: String, content: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] where t.hasPrefix(prefix) {
            return ("•", String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        if let dot = t.range(of: ". ") {
            let num = t[t.startIndex..<dot.lowerBound]
            if !num.isEmpty, num.allSatisfy(\.isNumber) {
                return ("\(num).", String(t[dot.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderTable(rows: [String], font: NSFont, color: NSColor) -> NSAttributedString {
        let parsed = rows.map { splitTableRow($0) }
        let columns = parsed.map(\.count).max() ?? 0
        guard columns > 0 else { return NSAttributedString(string: "\n") }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false

        let borderColor = color.withAlphaComponent(0.22)
        let result = NSMutableAttributedString()
        for (rowIndex, cells) in parsed.enumerated() {
            let isHeader = rowIndex == 0
            let cellFont = isHeader ? NSFont.systemFont(ofSize: font.pointSize, weight: .bold) : font
            for column in 0..<columns {
                let cellText = column < cells.count ? cells[column] : ""
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(borderColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if isHeader {
                    block.backgroundColor = color.withAlphaComponent(0.06)
                }

                let cellStyle = NSMutableParagraphStyle()
                cellStyle.textBlocks = [block]
                cellStyle.lineBreakMode = .byWordWrapping

                let cellAttr = inlineAttributed(cellText, font: cellFont, color: color)
                cellAttr.append(NSAttributedString(string: "\n"))
                cellAttr.addAttribute(.paragraphStyle, value: cellStyle, range: NSRange(location: 0, length: cellAttr.length))
                result.append(cellAttr)
            }
        }
        return result
    }

    /// Height of an already-rendered attributed string (incl. NSTextTable blocks)
    /// at a given width. The plain-string `textHeight` undercounts tables.
    private static func attributedTextHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Result box height for markdown source: render then measure so tables and
    /// headers get their true height. Clamped to the result box bounds.
    private static func resultBoxHeight(rawTextHeight: CGFloat) -> CGFloat {
        min(max(rawTextHeight + textInsetY * 2 + 4, minimumResultBoxHeight), maximumResultBoxHeight)
    }

    private static func renderedResultHeight(markdown: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: resultFontSize, weight: .semibold)
        let attr = renderedMarkdownText(markdown, font: font, color: .white)
        return resultBoxHeight(rawTextHeight: attributedTextHeight(attr, width: width))
    }

    private static func markdownFont(for intent: Int, baseFont: NSFont) -> NSFont? {
        let emphasized = 1
        let stronglyEmphasized = 2
        let code = 4

        if intent & code != 0 {
            return NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.94, weight: .regular)
        }

        var font = baseFont
        var changed = false
        if intent & stronglyEmphasized != 0 {
            font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
            changed = true
        }
        if intent & emphasized != 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            changed = true
        }
        return changed ? font : nil
    }

    private func buildUI() {
        let panelGlass = GlassHostView(
            frame: NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bounds.height),
            cornerRadius: 22,
            tintColor: NSColor(calibratedRed: 0.10, green: 0.095, blue: 0.045, alpha: 0.72),
            style: .regular
        )
        panelGlass.autoresizingMask = [.height]
        addSubview(panelGlass)
        let content = panelGlass.contentView
        self.panelGlass = panelGlass

        closeButton = makeIconButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            pointSize: 10,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        if showsSource {
            configureSectionLabel(
                sourceTitleLabel,
                text: "Source",
                color: NSColor(calibratedWhite: 1.0, alpha: 0.74)
            )
            content.addSubview(sourceTitleLabel)

            configureScrollView(sourceScrollView)
            configureTextView(
                sourceTextView,
                text: sourceText,
                font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
                color: NSColor(calibratedWhite: 1.0, alpha: 0.90)
            )
            sourceScrollView.documentView = sourceTextView
            sourceScrollView.isHidden = true
            sourcePreviewView.onMore = { [weak self] in
                self?.expandSource()
            }
            content.addSubview(sourcePreviewView)
            content.addSubview(sourceScrollView)
            content.addSubview(sourceDivider)
        }

        targetTitleButton.target = self
        targetTitleButton.action = #selector(showTargetLanguageMenu)
        targetTitleButton.setTitle(resultLabel ?? targetLanguage.displayName, pickerEnabled: resultLabel == nil)
        content.addSubview(targetTitleButton)

        copyButton = makeIconButton(
            symbolName: "doc.on.doc",
            accessibilityDescription: "Copy translation",
            pointSize: 11,
            target: self,
            action: #selector(copyResult),
            to: content
        )
        copyButton?.contentTintColor = TranslationPanelPalette.actionIconEnabled

        if onReplace != nil {
            let replaceButton = makeIconButton(
                symbolName: "text.insert",
                accessibilityDescription: "Replace selected text",
                pointSize: 12,
                target: self,
                action: #selector(replaceSelectedText),
                to: content
            )
            replaceButton.isEnabled = false
            replaceButton.contentTintColor = TranslationPanelPalette.actionIconDisabled
            self.replaceButton = replaceButton
        }

        configureScrollView(resultScrollView)
        if Self.streamDebug {
            resultScrollView.contentView = StreamDebugClipView()
        }
        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            color: ResultTone.normal.color
        )
        // The result view's height is fully managed by layoutScrollableTextView.
        // Self-sizing would shrink it back (stripping the bottom padding) after
        // every layout pass — fractional heights and a pulsing scroller knob.
        resultTextView.isVerticallyResizable = false
        resultScrollView.documentView = resultTextView
        content.addSubview(resultScrollView)

        let chromeOverlay = GlassChromeOverlayView(frame: content.bounds)
        chromeOverlay.autoresizingMask = [.width, .height]
        content.addSubview(chromeOverlay)
        self.chromeOverlay = chromeOverlay

        loadingShimmer.isHidden = true
        content.addSubview(loadingShimmer)

        if showsFollowUp {
            buildFollowUpFooter(in: content)
        }

        setResult(resultText)
    }

    private func buildFollowUpFooter(in content: NSView) {
        content.addSubview(followUpDivider)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        followUpIcon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        followUpIcon.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        followUpIcon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(followUpIcon)

        followUpField.placeholderAttributedString = NSAttributedString(
            string: "Revise or ask a follow-up",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.42)
            ]
        )
        followUpField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        followUpField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.92)
        followUpField.isBezeled = false
        followUpField.isBordered = false
        followUpField.drawsBackground = false
        followUpField.focusRingType = .none
        followUpField.cell?.usesSingleLineMode = true
        followUpField.cell?.wraps = false
        followUpField.cell?.isScrollable = true
        followUpField.delegate = self
        followUpField.onEscape = { [weak self] in self?.onClose?() }
        content.addSubview(followUpField)
    }

    private func submitFollowUp() {
        let text = followUpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpField.stringValue = ""
        onFollowUp?(text)
    }

    // Submit on Return only (not on focus loss), and swallow the keystroke so
    // the field doesn't beep or insert a newline.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === followUpField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        submitFollowUp()
        return true
    }

    // Suspend the Return-key interceptor while the follow-up field is being
    // edited (Return must submit the follow-up, not paste the rewrite). Pressing
    // Return to submit keeps editing, so this only re-enables when focus truly
    // leaves the field (the user clicks/tabs away).
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) === followUpField else { return }
        onFollowUpFocusChange?(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) === followUpField else { return }
        onFollowUpFocusChange?(false)
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.knobStyle = .light
        scrollView.borderType = .noBorder
    }

    private func configureTextView(_ textView: NSTextView, text: String, font: NSFont, color: NSColor) {
        // Accessing layoutManager opts the view into TextKit 1, whose NSTextTable
        // support is mature and matches our TextKit-1 height measurement.
        _ = textView.layoutManager
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textColor = color
        textView.font = font
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)
    }

    @discardableResult
    private func makeIconButton(
        symbolName: String,
        accessibilityDescription: String,
        pointSize: CGFloat,
        target: AnyObject,
        action: Selector,
        to parent: NSView
    ) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) ?? NSImage()
        let image = baseImage.withSymbolConfiguration(config) ?? baseImage
        let button = FirstMouseButton(image: image, target: target, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        button.toolTip = accessibilityDescription
        parent.addSubview(button)
        return button
    }

    private func configureSectionLabel(_ label: NSTextField, text: String, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: color,
            .kern: 0
        ])
        label.attributedStringValue = attributed
    }

    func layoutForCurrentSize() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bodyHeight = bounds.height
        panelGlass?.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.bodyWidth,
            height: bodyHeight
        )
        chromeOverlay?.frame = NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bodyHeight)

        let resolvedResultBoxHeight: CGFloat
        var y: CGFloat

        if showsSource {
            let sourceBoxHeight = Self.sourceHeight(for: sourceText, expanded: sourceExpanded)
            let fixedHeight = Self.panelPaddingTop
                + Self.labelHeight + Self.labelToBoxGap
                + Self.sourceToDividerGap + Self.dividerHeight + Self.dividerToTargetGap
                + Self.labelHeight + Self.labelToBoxGap
                + Self.panelPaddingBottom
                + (showsFollowUp ? Self.followUpFooterHeight : 0)
            let availableBoxHeight = max(
                Self.collapsedSourceBoxHeight + Self.minimumResultBoxHeight,
                bounds.height - fixedHeight
            )
            let resolvedSourceBoxHeight = min(
                sourceBoxHeight,
                max(Self.collapsedSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
            )
            resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

            y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
            sourceTitleLabel.frame = NSRect(
                x: Self.panelPaddingX,
                y: y,
                width: Self.contentWidth - Self.buttonSize - 8,
                height: Self.labelHeight
            )
            closeButton?.frame = NSRect(
                x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
                y: y + (Self.labelHeight - Self.buttonSize) / 2,
                width: Self.buttonSize,
                height: Self.buttonSize
            )

            y -= Self.labelToBoxGap + resolvedSourceBoxHeight
            let sourceScrollFrame = NSRect(
                x: Self.panelPaddingX,
                y: y,
                width: Self.contentWidth,
                height: resolvedSourceBoxHeight
            )
            let collapsedSourceText = Self.collapsedSourceText(sourceText)
            let sourceCanExpand = Self.singleLineWidth(
                for: collapsedSourceText,
                font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold)
            ) > Self.contentWidth
                || collapsedSourceText != sourceText.trimmingCharacters(in: .whitespacesAndNewlines)

            sourcePreviewView.frame = sourceScrollFrame
            sourcePreviewView.configure(text: collapsedSourceText, canExpand: sourceCanExpand)
            sourcePreviewView.isHidden = sourceExpanded
            sourceScrollView.isHidden = !sourceExpanded

            if sourceExpanded {
                let sourceRawTextHeight = Self.textHeight(
                    for: sourceText,
                    font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
                    width: sourceScrollFrame.width
                )
                Self.layoutScrollableTextView(
                    sourceTextView,
                    inside: sourceScrollView,
                    scrollFrame: sourceScrollFrame,
                    rawTextHeight: sourceRawTextHeight,
                    showsOverflowScroller: true
                )
                if shouldScrollSourceToTop {
                    scrollToTop(sourceScrollView)
                    shouldScrollSourceToTop = false
                }
            }

            y -= Self.sourceToDividerGap + Self.dividerHeight
            sourceDivider.frame = NSRect(
                x: Self.panelPaddingX,
                y: y,
                width: Self.contentWidth,
                height: Self.dividerHeight
            )

            y -= Self.dividerToTargetGap + Self.labelHeight
            layoutTargetRow(topY: y, includeClose: false)
        } else {
            let fixedHeight = Self.panelPaddingTop
                + Self.labelHeight + Self.labelToBoxGap
                + Self.panelPaddingBottom
                + (showsFollowUp ? Self.followUpFooterHeight : 0)
            resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, bounds.height - fixedHeight)

            y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
            layoutTargetRow(topY: y, includeClose: true)
        }

        y -= Self.labelToBoxGap + resolvedResultBoxHeight
        let resultScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedResultBoxHeight
        )
        // Fit the shimmer to the text width so the highlight sweeps across the
        // word itself, not mostly empty result-box space to its right.
        let shimmerFont = NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold)
        let shimmerTextWidth = ceil(((loadingBaseText ?? "") as NSString).size(withAttributes: [.font: shimmerFont]).width) + 4
        loadingShimmer.frame = NSRect(
            x: resultScrollFrame.minX,
            y: resultScrollFrame.minY,
            width: min(max(shimmerTextWidth, 1), resultScrollFrame.width),
            height: resultScrollFrame.height
        )
        // Measure the rendered attributed content (tables/headers included), not
        // the plain string, so tall blocks get the right scroll height.
        let resultRawTextHeight: CGFloat
        if let storage = resultTextView.textStorage, storage.length > 0 {
            resultRawTextHeight = Self.attributedTextHeight(storage, width: resultScrollFrame.width)
        } else {
            resultRawTextHeight = Self.textHeight(
                for: resultDisplayText,
                font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
                width: resultScrollFrame.width,
                paragraphSpacing: Self.resultFontSize * Self.resultParagraphSpacingFactor
            )
        }
        // Re-tiling the scroll view/text view can shift the clip's origin
        // through paths that bypass every public scroll override (observed:
        // a jump to the document bottom the first time the text outgrows the
        // box). User scrolls happen between layout passes, never inside one —
        // so pin the origin across the re-tile, clamped to the new document.
        let clipOriginBeforeTile = resultScrollView.contentView.bounds.origin
        Self.layoutScrollableTextView(
            resultTextView,
            inside: resultScrollView,
            scrollFrame: resultScrollFrame,
            rawTextHeight: resultRawTextHeight,
            topAligned: !lastRenderUsedBlock
        )
        if shouldScrollResultToTop {
            scrollToTop(resultScrollView)
            shouldScrollResultToTop = false
        } else {
            let maxScrollY = max(0, resultTextView.frame.height - resultScrollFrame.height)
            let pinnedY = min(max(0, clipOriginBeforeTile.y), maxScrollY)
            if abs(resultScrollView.contentView.bounds.origin.y - pinnedY) > 0.5 {
                resultScrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
                resultScrollView.reflectScrolledClipView(resultScrollView.contentView)
            }
        }

        if showsFollowUp {
            layoutFollowUpFooter()
        }

        if Self.streamDebug {
            print(String(
                format: "[stream] layout bounds=%.1f box=%.1f raw=%.1f tvH=%.1f inset=%.1f clipY=%.1f scroller=%d",
                bounds.height, resolvedResultBoxHeight, resultRawTextHeight,
                resultTextView.frame.height, resultTextView.textContainerInset.height,
                resultScrollView.contentView.bounds.origin.y,
                resultScrollView.hasVerticalScroller ? 1 : 0
            ))
        }
    }

    /// Lays out the "<language> … [replace] [copy] [close?]" row with its top at
    /// `y`. `includeClose` puts the ✕ here (used when the source section above it
    /// is hidden, so this row is the panel's header).
    private func layoutTargetRow(topY y: CGFloat, includeClose: Bool) {
        var actionButtonCount = 1 // copy
        if replaceButton != nil { actionButtonCount += 1 }
        if includeClose { actionButtonCount += 1 }
        let targetActionWidth = CGFloat(actionButtonCount) * Self.buttonSize
            + CGFloat(max(0, actionButtonCount - 1)) * 8
        let titleLeadingInset = LanguagePickerButton.titleLeadingInset
        targetTitleButton.frame = NSRect(
            x: Self.panelPaddingX - titleLeadingInset,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: min(
                targetTitleButton.preferredWidth,
                Self.contentWidth - targetActionWidth - 8 + titleLeadingInset
            ),
            height: Self.buttonSize
        )

        let buttonY = y + (Self.labelHeight - Self.buttonSize) / 2
        var rightX = Self.bodyWidth - Self.panelPaddingX - Self.buttonSize
        if includeClose {
            closeButton?.frame = NSRect(x: rightX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
            rightX -= Self.buttonSize + 8
        }
        copyButton?.frame = NSRect(x: rightX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
        rightX -= Self.buttonSize + 8
        replaceButton?.frame = NSRect(x: rightX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
    }

    private func layoutFollowUpFooter() {
        let fieldY = Self.panelPaddingBottom
        followUpIcon.frame = NSRect(
            x: Self.panelPaddingX,
            y: fieldY + (Self.followUpFieldHeight - Self.followUpIconSize) / 2,
            width: Self.followUpIconSize,
            height: Self.followUpIconSize
        )
        let fieldX = Self.panelPaddingX + Self.followUpIconSize + 8
        followUpField.frame = NSRect(
            x: fieldX,
            y: fieldY,
            width: Self.panelPaddingX + Self.contentWidth - fieldX,
            height: Self.followUpFieldHeight
        )
        followUpDivider.frame = NSRect(
            x: Self.panelPaddingX,
            y: fieldY + Self.followUpFieldHeight + Self.followUpDividerToFieldGap,
            width: Self.contentWidth,
            height: Self.dividerHeight
        )
    }

    func setResult(_ text: String, isFinal: Bool = false) {
        if isFinal {
            // Final chunk: drop any throttled partial, render full block markdown.
            pendingResultText = nil
            renderResultNow(text, tone: .normal, useBlockMarkdown: true)
        } else {
            scheduleResult(text, tone: .normal)
        }
    }

    func setError(_ text: String) {
        // Errors are terminal and rare — render immediately, no throttle.
        pendingResultText = nil
        renderResultNow(text, tone: .error, useBlockMarkdown: true)
    }

    /// Coalesces streamed partials: renders on the leading edge, then at most
    /// once per `resultThrottleInterval`. Streaming uses the inline renderer; the
    /// final chunk re-renders as block markdown via `setResult(isFinal:)`.
    private func scheduleResult(_ text: String, tone: ResultTone) {
        pendingResultText = text
        pendingResultTone = tone
        let now = Date().timeIntervalSinceReferenceDate
        let elapsed = now - lastResultRenderTime
        if elapsed >= Self.resultThrottleInterval {
            flushPendingResult()
        } else if !resultThrottleScheduled {
            resultThrottleScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.resultThrottleInterval - elapsed)) { [weak self] in
                self?.flushPendingResult()
            }
        }
    }

    private func flushPendingResult() {
        resultThrottleScheduled = false
        guard let text = pendingResultText else { return }
        pendingResultText = nil
        lastResultRenderTime = Date().timeIntervalSinceReferenceDate
        renderResultNow(text, tone: pendingResultTone, useBlockMarkdown: false)
    }

    private func renderResultNow(_ text: String, tone: ResultTone, useBlockMarkdown: Bool) {
        // Any real content (partial or final) ends the loading shimmer.
        stopLoadingAnimation()
        let cleanedText = TextNormalizer.cleanedTranslation(text)
        if Self.streamDebug {
            print(String(
                format: "[stream] pre   len=%d prefixOK=%d tvH=%.1f clipY=%.1f",
                cleanedText.count, cleanedText.hasPrefix(resultText) ? 1 : 0,
                resultTextView.frame.height, resultScrollView.contentView.bounds.origin.y
            ))
        }

        if cleanedText == resultText, tone == resultTone, useBlockMarkdown == lastRenderUsedBlock {
            return
        }
        lastRenderUsedBlock = useBlockMarkdown

        if !cleanedText.hasPrefix(resultText) || tone != resultTone {
            shouldScrollResultToTop = true
        }

        resultTone = tone
        resultTextView.textColor = tone.color
        let renderFont = resultTextView.font ?? NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular)
        let renderedText = useBlockMarkdown
            ? Self.renderedMarkdownText(cleanedText, font: renderFont, color: tone.color)
            : Self.renderedStreamingText(cleanedText, font: renderFont, color: tone.color)
        if let textStorage = resultTextView.textStorage {
            // Replacing the whole storage nudges the clip a few px down each
            // chunk (autoscroll toward the changed range) — the summary's first
            // line creeps off the top mid-stream. Pin the viewport (and any
            // user scroll position) across the replacement.
            let clipOrigin = resultScrollView.contentView.bounds.origin
            textStorage.setAttributedString(renderedText)
            resultScrollView.contentView.scroll(to: clipOrigin)
            resultScrollView.reflectScrolledClipView(resultScrollView.contentView)
        } else {
            resultTextView.string = renderedText.string
        }

        resultText = cleanedText
        resultDisplayText = resultTextView.string
        lastRealResultText = cleanedText
        updateActionButtonStates()
        // No direct layout here: onResultRendered resizes the panel, and both
        // resize outcomes (setFrame → setFrameSize, or frame-unchanged) run
        // layoutForCurrentSize exactly once with the NEW bounds. Laying out
        // first with the stale height flashes a transient overflow state per
        // chunk (scroller blinks in/out, clip scrolls off the top).
        onResultRendered?()
    }

    func startLoadingAnimation(baseText: String) {
        // Drop any throttled render still queued from a previous request.
        pendingResultText = nil
        loadingBaseText = baseText
        loadingShimmer.configure(
            text: baseText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            base: NSColor(calibratedWhite: 1.0, alpha: 0.42),
            highlight: NSColor(calibratedWhite: 1.0, alpha: 0.98)
        )
        loadingShimmer.isHidden = false
        loadingShimmer.startAnimating()
        resultScrollView.isHidden = true
        layoutForCurrentSize()
    }

    func stopLoadingAnimation() {
        guard loadingBaseText != nil else { return }
        loadingBaseText = nil
        loadingShimmer.stopAnimating()
        loadingShimmer.isHidden = true
        resultScrollView.isHidden = false
    }

    var isShowingLoadingState: Bool { loadingBaseText != nil }

    private func scrollToTop(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        let y = documentView.isFlipped
            ? CGFloat.zero
            : max(0, documentView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutForCurrentSize()
    }

    @objc private func showTargetLanguageMenu() {
        guard resultLabel == nil else {
            return
        }

        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTemporaryTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            item.state = language.id == targetLanguage.id ? .on : .off
            menu.addItem(item)
        }

        isTargetLanguageMenuOpen = true
        targetTitleButton.setMenuOpen(true)
        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: -4),
            in: targetTitleButton
        )
        targetTitleButton.setMenuOpen(false)
        isTargetLanguageMenuOpen = false
    }

    @objc private func selectTemporaryTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        let language = TranslationLanguage.language(id: languageID)
        guard language != targetLanguage else {
            return
        }

        setTargetLanguage(language)
        onTargetLanguageSelected?(language)
    }

    @objc private func copyResult() {
        copyResultToPasteboard()
        onClose?()
    }

    func copyResultToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func replaceSelectedText() {
        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        guard !replacement.isEmpty,
              !isShowingLoadingState,
              resultTone != .error
        else {
            return
        }

        onReplace?(replacement)
    }

    func triggerReplaceProgrammatically() {
        replaceSelectedText()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateActionButtonStates() {
        let result = TextNormalizer.cleanedTranslation(resultTextView.string)
        let canUseResult = !result.isEmpty
            && !isShowingLoadingState
            && resultTone != .error

        copyButton?.isEnabled = canUseResult
        copyButton?.contentTintColor = canUseResult
            ? TranslationPanelPalette.actionIconEnabled
            : TranslationPanelPalette.actionIconDisabled

        guard let replaceButton else {
            return
        }
        replaceButton.isEnabled = canUseResult
        replaceButton.contentTintColor = canUseResult
            ? TranslationPanelPalette.actionIconEnabled
            : TranslationPanelPalette.actionIconDisabled
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// User-authored "About you" background appended to every system prompt so the
/// model picks meanings relevant to this user (e.g. "RLS" → Row-Level Security
/// for a developer, not Restless Legs Syndrome). Deliberately manual and
/// transparent — the user writes it in Settings; nothing is auto-learned.
enum UserAboutContext {
    static let maxLength = 1000
    static let defaultsKey = "aboutUserContext"

    static var text: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Appends the background section to a system prompt. Returns the prompt
    /// unchanged when the user wrote nothing, so empty stays zero-cost.
    static func appending(to prompt: String, about: String? = nil) -> String {
        let trimmed = (about ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        return prompt + """


        Background about the user, in their own words:
        \(String(trimmed.prefix(maxLength)))

        Use this background only to disambiguate terms and choose the meaning most relevant to this user. Do not change the output's tone, style, language, or format because of it unless it explicitly says to. Never mention this background in the output.
        """
    }
}

enum TranslationMode {
    case selection
    case draftMessage
    case smartReply
    /// Internal re-render of an existing `.selection` result: the user typed a
    /// "revise or ask a follow-up" instruction and we regenerate the answer in
    /// place. Never assigned to a pet/mascot surface — only the result panel.
    case revise
    /// Revise/follow-up for an outgoing message — both `.smartReply` (a drafted
    /// reply) and `.draftMessage` (a polished draft). Keeps composition (writing
    /// style/voice). Panel-only, never a pet/mascot surface.
    case reviseMessage
    /// Summarizes a chat transcript (see `ChatTranscript.format`) into a
    /// TL;DR + key points + action items. Read-only, no composition settings.
    /// Panel-only, never a pet/mascot surface.
    case summarizeChat
    /// Summarizes the web page open in the frontmost browser (text read off
    /// the AX tree — see `BrowserPageReader`). Same behavior contract as
    /// `.summarizeChat`: read-only, never persisted, panel-only.
    case summarizePage

    var usesCompositionSettings: Bool {
        switch self {
        case .selection, .revise, .summarizeChat, .summarizePage:
            return false
        case .draftMessage, .smartReply, .reviseMessage:
            return true
        }
    }

    var resultLabel: String? {
        switch self {
        case .selection, .draftMessage, .revise:
            return nil
        case .smartReply, .reviseMessage:
            return "Reply"
        case .summarizeChat, .summarizePage:
            return "Summary"
        }
    }

    var loadingPlaceholder: String {
        switch self {
        case .smartReply:
            return "Thinking"
        case .draftMessage:
            return "Rewriting"
        case .selection:
            return "Thinking"
        case .revise, .reviseMessage:
            return "Revising"
        case .summarizeChat, .summarizePage:
            return "Summarizing"
        }
    }

    /// Wraps the original text, the prior answer, and the user's instruction into
    /// the single `text` argument the existing one-shot `translate(...)` path
    /// carries — so revise reuses all four backends with no transport changes.
    static func composeReviseInput(source: String, previous: String, instruction: String) -> String {
        """
        Original text:
        \(source)

        Your previous response:
        \(previous)

        Revision request:
        \(instruction)
        """
    }

    func systemPrompt(
        targetLanguage: TranslationLanguage,
        appCategory: AppCategory,
        composition: CompositionSettings?
    ) -> String {
        let base: String = switch self {
        case .selection:
            """
            Translate the user's text into plain, accessible \(targetLanguage.promptName) aimed at a curious ~12-year-old reader with no background in the field — accessible, but not babyish or condescending. The goal is to make the content understandable, not to produce a literal word-for-word rendering. This applies whether the source is already in \(targetLanguage.promptName), in another language entirely, or a mix of both.

            Render any foreign-language parts into \(targetLanguage.promptName), then simplify the whole result: break long sentences into shorter ones, replace jargon and rare or technical vocabulary with plain everyday words, unwind passive voice and nested clauses, and prefer concrete wording over abstract phrasing. Where a concept stays abstract after a plain-word swap, anchor it inline with a short concrete example or everyday analogy in parentheses or em-dashes — e.g. "a queue (like the line at a coffee shop — first in, first served)".

            Match output complexity to source complexity. If the source is already a casual, simple message — a chat line, a greeting, a short sentence with no jargon, a menu item, a button label — translate it plainly and stop. Do not force analogies, examples, or expansions onto content that is already simple. The simplification rules are for when there is something genuinely complex to make accessible; short, plain inputs get short, plain outputs. (A single standalone word or term that the user is looking up is the exception — see the Lookup case below.)

            Lookup case — if the source is a single word or a short standalone term (not a sentence, greeting, or casual phrase) and rendering it into \(targetLanguage.promptName) would leave it essentially unchanged — because it is already in \(targetLanguage.promptName), or is a borrowed or technical term with no distinct \(targetLanguage.promptName) translation — then the user has selected it to understand what it means, not to translate it. Do not echo the word back unchanged. Instead, explain it in 1–2 short, plain \(targetLanguage.promptName) sentences: what it means in everyday words, and a quick concrete example if it helps. Keep it simple enough for a curious ~12-year-old. If the word has several common meanings, give the most everyday one first and you may note a field-specific sense in a few words. Do not add a dictionary header, the word itself as a title, pronunciation, or part-of-speech labels — just the plain explanation.

            Treat a single `\\n` as a wrapped line inside one paragraph — join it silently. Treat a blank line (`\\n\\n`) as a deliberate paragraph break that the user wants to keep — render it as a blank line in the output. Clean repeated spaces, OCR artifacts, and hyphenated line wraps. If the source has no paragraph breaks but is long or dense, split the output into readable paragraphs instead of returning one wall of text.

            Keep every fact, name, date, number, quotation, URL, proper noun, and the original paragraph/bullet/list structure exactly. Do not summarize, do not drop content, do not add new claims, opinions, or facts — examples and analogies must only illustrate what is already there, never extend it. If your output differs from a literal translation only by swapping a few synonyms (e.g. "specialized" → "special", "utilize" → "use") or replacing punctuation, you have not simplified — go further: add an illustrative example, restructure the sentence, or name the topic in plainer terms.

            Context — the source text is from \(appCategory.promptHint)\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))

            Return only the \(targetLanguage.promptName) output. No preamble, no commentary, no quotes around the output. Never write a wrapper like "Here is the translation:" — output the text directly.
            """
        case .draftMessage:
            """
            Translate the user's drafted outgoing message into natural \(targetLanguage.promptName). Infer the user's actual intent, emotion, and social situation, then say it the way a native \(targetLanguage.promptName) speaker would send it in a chat or message. If the draft is already entirely in \(targetLanguage.promptName), do not translate it; lightly rewrite/polish it only when needed so it sounds natural and sendable. If only part of the draft is in \(targetLanguage.promptName) and the rest is in one or more other languages, translate the foreign parts into \(targetLanguage.promptName) and weave everything into one cohesive, natural-sounding message — keep the \(targetLanguage.promptName) portions intact unless they need light polish to flow with the rest. Treat code-switching as the user reaching for words they didn't know in \(targetLanguage.promptName), not as a stylistic choice to preserve.

            The selected Writing style is authoritative. The source draft tells you meaning, intent, emotion, and how direct the user wants to be, but it must not override the selected Writing style. When goals conflict, follow this priority: (1) meaning, (2) selected Writing style, (3) intended directness and emotional signal within that style, (4) cultural naturalness — idioms, honorifics, word order, (5) surface details to preserve verbatim — emojis, URLs, usernames, product names, numbers, line breaks, (6) literal wording (always lowest). If the draft is blunt, keep the result concise and direct, but still use the selected Writing style. Do not pad a curt one-liner into a long paragraph unless the meaning requires it. If the draft is awkward or phrased like a direct translation, smooth it while keeping the same intent. If the draft is a fragment, return a natural sendable fragment without inventing extra context.

            Emoji shorthand — replace `[X emoji]` patterns with the matching Unicode emoji (`[smile emoji]` → 😊, `[fire emoji]` → 🔥, `[thumbs up emoji]` → 👍, `[crying emoji]` → 😭). Pick the most common, neutral variant when several emojis fit the description. Only expand when the bracketed content reads as an emoji description — leave bracketed dates, citations, code, placeholders, and other non-emoji content untouched (e.g. `[2025-01-01]`, `[1]`, `[redacted]`, `[insert name]` stay as-is).

            Context — the user is composing this message in \(appCategory.promptHint)

            Writing style — \(composition?.writingStyleDirective(for: targetLanguage.id) ?? "")\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))\(TranslationMode.cleanupSection(for: composition?.cleanup))\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

            Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
            """
        case .smartReply:
            """
            The user has selected text in another app. The text is either (a) a message they received — email, chat message, DM, comment, support ticket, or similar; or (b) a question they need to answer — a quiz item, exam question, multiple-choice question, or open question. Decide which it is from the text itself, then respond appropriately. Write your reply or answer in \(targetLanguage.promptName), regardless of what language the source text is in.

            If it is a received message: write a natural, ready-to-send reply as if the user is sending it now. Match the intent, emotional signal, and approximate length of the original, but use the selected Writing style below for register and formality. Be concise. Don't restate or quote the original. Don't add greetings or sign-offs unless the original suggests them. Don't address the user — produce only the message body they would paste into the reply field.

            If it is a multiple-choice question: identify the correct option and respond with the option letter or number followed by the option text, then a brief one-sentence justification. Example: "B. Mitochondria — they generate most of the cell's ATP."

            If it is an open question: give a clear, direct answer. Keep it short unless the question demands depth.

            Context — the user is replying inside \(appCategory.promptHint)

            Writing style — \(composition?.writingStyleDirective(for: targetLanguage.id) ?? "")\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))

            Cleanup — \(composition?.cleanup.promptDescription ?? "")\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

            Return only the reply or answer text. No commentary, no labels, no preface, no explanation of what you're doing, no quotes around the answer.
            """
        case .revise:
            """
            You are refining a response you previously gave the user. Their message has three labeled parts: the original text they were looking at, your previous response to it, and a revision request.

            Apply the revision request to your previous response. If the request asks you to change the response (shorter, simpler, more detail, different tone, etc.), produce the updated version. If it asks a follow-up question instead of an edit, answer it directly — your answer replaces the previous response.

            Write the result in \(targetLanguage.promptName), in the same plain, accessible style aimed at a curious ~12-year-old reader with no background in the field — accessible, but not babyish or condescending. Keep every fact, name, number, and quotation accurate; do not invent claims.

            Return only the updated response text. No preamble, no labels, no quotes, never a wrapper like "Here is the revised version:" — just the text.
            """
        case .reviseMessage:
            """
            You previously wrote a message for the user to send. Their input has three labeled parts: the original text (what they were working from — a message they received, a question, or their own rough draft), your previous message, and a revision request.

            Apply the revision request to your previous message. If it is an instruction (shorter, warmer, more formal, add a detail, fix something, etc.), produce the updated message. If it asks a follow-up question instead of an edit, answer it in the context of this message — your answer replaces the previous message.

            Write the result in \(targetLanguage.promptName), natural and ready to send, in the user's voice. Match the selected Writing style below. Don't restate or quote the original, don't add greetings or sign-offs unless warranted, and don't address the user — produce only the message body they would paste into the field.

            Writing style — \(composition?.writingStyleDirective(for: targetLanguage.id) ?? "")\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))

            Return only the updated message text. No preamble, no labels, no quotes, never a wrapper like "Here is the revised version:" — just the text.
            """
        case .summarizeChat:
            """
            You are given a chat transcript as "Sender: message" lines, oldest first. \
            Write a concise summary in \(targetLanguage.promptName): a one-line TL;DR, \
            then a short bulleted list of the key points and decisions, then any action \
            items or open questions addressed to the reader. Preserve names, dates, \
            numbers, and links exactly. Do not invent anything not in the transcript. \
            Return only the summary — no preamble, no quotes.
            """
        case .summarizePage:
            """
            You are given the text of a web page the user has open, extracted \
            top-to-bottom; the first line is the page title. It may contain stray \
            navigation labels, cookie banners, buttons, or ad text — ignore that \
            boilerplate and summarize the actual content. Write a concise summary \
            in \(targetLanguage.promptName): a one-line TL;DR, then a short \
            bulleted list of the key points, then any conclusions or next steps \
            the page offers the reader. Preserve names, dates, numbers, and links \
            exactly. Do not invent anything not on the page. Return only the \
            summary — no preamble, no quotes.
            """
        }
        return UserAboutContext.appending(to: base)
    }

    private static func glossarySection(for snippets: [Snippet], includeSnippets: Bool) -> String {
        let usable = snippets.filter(\.isUsable)
        guard !usable.isEmpty else { return "" }

        let expansions = includeSnippets ? usable.filter { $0.kind == .snippet } : []
        let dictionaryTerms = usable.filter { $0.kind == .dictionaryTerm }
        guard !expansions.isEmpty || !dictionaryTerms.isEmpty else { return "" }

        var sections: [String] = []
        sections.append(#"Glossary — apply these user-saved rules exactly when relevant."#)

        if !expansions.isEmpty {
            let lines = expansions.map { snippet -> String in
                let trigger = promptLine(snippet.trigger)
                let value = promptLine(snippet.value)
                return "- \"\(trigger)\" → \(value)"
            }
            sections.append("Snippets — expand BEFORE rewriting for tone/style. After expansion, treat the expanded text as canonical and do not paraphrase it:\n" + lines.joined(separator: "\n"))
        }

        if !dictionaryTerms.isEmpty {
            let lines = dictionaryTerms.map { "- \(promptLine($0.trigger))" }
            sections.append("Dictionary — preserve these terms verbatim. Never translate, paraphrase, or alter spelling/capitalization:\n" + lines.joined(separator: "\n"))
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    /// Language-specific Gen Z styling block, appended to compose prompts when
    /// the Gen Z toggle is on. Empty string when off (so callsites stay inline).
    private static func genZSection(for languageID: String, enabled: Bool) -> String {
        guard enabled else { return "" }
        return "\n\n" + GenZStyle.promptSection(for: languageID)
    }

    /// Cleanup/polish instruction block. Empty string for `.none` (and nil), so
    /// "no cleanup" injects no prompt at all and the writing style stays the only
    /// authority — cleanup is a polish axis, orthogonal to register/Gen Z styling.
    private static func cleanupSection(for level: CleanupLevel?) -> String {
        guard let level, level != .none else { return "" }
        return "\n\nCleanup — \(level.promptDescription)"
    }

    /// The user's email voice sample as a template block. Empty string when
    /// there's no sample (so callsites stay inline). `compositionSettings` only
    /// populates `voiceSample` for the email category, so this is a no-op
    /// everywhere else.
    ///
    /// Division of authority (resolves the sample-vs-Writing-style conflict):
    /// the sample owns STRUCTURE (that there's a greeting, a sign-off carrying the
    /// name, the rhythm) and overrides the draft prompt's chat-style brevity; the
    /// Writing style pill owns REGISTER (formality), overriding the sample's own
    /// formality line by line — so a casual register yields a casual greeting and
    /// sign-off even when the sample is written formally.
    private static func voiceSampleSection(for sample: String?) -> String {
        let trimmed = sample?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let instruction = "Voice sample — the example below is the user's own email template. Take its STRUCTURE from it: that the email opens with a greeting, closes with a sign-off carrying the user's name, plus its general rhythm and layout. This structure OVERRIDES any length-matching or brevity guidance above — always produce the full greeting + body + sign-off, even when the user's draft is a single short line or fragment; expand a terse draft into a complete email. The selected Writing style register, however, controls the FORMALITY of every line: render the greeting, body, and sign-off at that register even if the template itself is written more or less formally — e.g. if the register is casual, the greeting and sign-off become casual too, not the formal wording shown in the template. Write the body to convey the current draft's meaning; do not reuse the template's body text. Render everything in the target language. Reproduce the user's name in the signature exactly as written:"
        return "\n\n" + instruction + "\n" + trimmed
    }

    private static func promptLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum AppCategory: String, CaseIterable, Codable {
    case personalMessages
    case workMessages
    case email
    case other
    /// User-authored style: apps the user explicitly assigns here use a
    /// free-text instruction (see `customStyleInstruction`) in place of a
    /// register. Never an auto-fallback — reachable only via explicit assignment.
    case custom

    var displayName: String {
        switch self {
        case .personalMessages: return "Personal messages"
        case .workMessages: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        case .custom: return "Custom"
        }
    }

    var promptHint: String {
        switch self {
        case .personalMessages:
            return "a personal messaging app — chats with friends, family, partner, or close contacts. Short fragments are common, but the writing style setting decides the register."
        case .workMessages:
            return "a workplace messaging app — Slack, Teams, LinkedIn. Colleagues and clients. Conversational but professional; complete thoughts but not stiff."
        case .email:
            return "an email client. Longer-form medium where greetings, full sentences, and sign-offs are normal."
        case .other:
            return "an unspecified app. No strong medium expectation — defer to the user's chosen style."
        case .custom:
            return "an app you've assigned a custom writing style to. The custom writing style below is authoritative — follow it exactly."
        }
    }
}

enum WritingStyle: String, CaseIterable, Codable {
    case formal
    case polite
    case casual

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .polite: return "Polite"
        case .casual: return "Casual"
        }
    }

    /// Language-neutral description of the register. The per-language
    /// grammatical realization is appended by `promptDescription(for:)`.
    private var registerSummary: String {
        switch self {
        case .formal:
            return "highest formal register — the way you'd write to a senior client, superior, or in a business letter. No exclamation marks unless the source had them. This register overrides any informality implied by the app context."
        case .polite:
            return "polite, friendly register, the way you'd write to a colleague, acquaintance, or in a warm but professional message. This register overrides any informality implied by the app context. Never use the em dash (—), and don't substitute an en dash in its place; the long dash reads as AI writing and is out of place in a warm, conversational message. Use a comma, a period and a new sentence, or parentheses instead."
        case .casual:
            return "casual register, the way you'd write to a close friend. Lighter punctuation; periods optional at the ends of short messages. Conversational rhythm. Never use the em dash (—), and don't substitute an en dash in its place; the long dash reads as AI writing and clashes with a casual message. Use a comma, a period and a new sentence, or parentheses instead."
        }
    }

    /// Per-language grammatical realization of each register, keyed by
    /// `TranslationLanguage.id`. The output language is always known at
    /// prompt-build time, so only the matching language's rule is injected —
    /// keeping the prompt lean. Add a language = add one line per style; a
    /// language absent here falls back to `registerSummary` alone.
    private static let languageRules: [WritingStyle: [String: String]] = [
        .formal: [
            "en": "In English: NO contractions — write 'I am', 'cannot', 'I would', 'do not' in full. Complete, well-structured sentences. Open deferentially when it fits ('I hope you are well', 'Thank you for your message') and close formally ('Kind regards', 'Best regards', 'Sincerely'). Precise, slightly formal vocabulary (request, regarding, assistance, apologise, kindly, at your earliest convenience); soften requests fully ('Could you kindly...', 'I would be grateful if you could...', 'Would it be possible to...'). No slang, no abbreviations, no emoji, no exclamation marks. Professional and modern, never pompous or archaic. Example: 'can you send me the report?' → 'Could you kindly send me the report at your earliest convenience? I would be most grateful.'",
            "ko": "In Korean: use 합쇼체 (-습니다 / -십시오), never 해요체 and never 반말.",
            "ja": "In Japanese: use です/ます with deferential phrasing.",
            "ru": "In Russian: use Вы with full formal constructions.",
            "de": "In German: use Siezen (Sie/Ihnen) with formal salutations and closings; full sentences, no slangy contractions.",
            "fr": "In French: use vouvoiement (vous) with formal phrasing and closings (e.g. « Je vous prie d'agréer »).",
            "es": "In Spanish: use usted with deferential phrasing and complete sentences.",
            "zh-Hans": "In Chinese: use 您 with respectful set phrases (请, 麻烦您, 敬请) and no slang.",
        ],
        .polite: [
            "en": "In English: contractions are welcome (I'd, you're, can't, won't) — this is the warm, everyday professional register of a friendly email to a colleague. Complete but relaxed sentences. A light greeting ('Hi', 'Hope you're well') and a friendly sign-off ('Thanks so much', 'Best', 'Cheers') fit naturally. Plain, direct words (ask, about, help, sorry, sure) with lightly softened requests ('Could you...', 'Would you mind...', 'When you get a chance...'). At most one exclamation mark; the warmth comes from word choice, not punctuation. No slang and no texting abbreviations (no lmk/btw/tmrw). Example: 'can you send me the report?' → 'Hi! Could you send me the report when you get a chance? Thanks so much.'",
            "ko": "In Korean: use 해요체 (-아요 / -어요 / -해요), not 합쇼체 and not 반말.",
            "ja": "In Japanese: use です/ます in their everyday softer form.",
            "ru": "In Russian: use Вы with conversational warmth.",
            "de": "In German: use Sie in a warm, friendly tone — still Siezen, but conversational, not stiff.",
            "fr": "In French: use vous in a warm, friendly tone — polite but approachable.",
            "es": "In Spanish: use usted in a warm, friendly tone (or tú where the context is clearly informal).",
            "zh-Hans": "In Chinese: use 您 or 你 with a warm, polite tone and 请 where natural.",
        ],
        .casual: [
            "en": "In English: how you'd actually text a close friend. Heavy contractions and reductions (gonna, wanna, kinda, lemme, dunno, 'cause), short fragments and the odd run-on, blunt and direct ('sure', 'my bad', 'no worries', 'sounds good'). Everyday texting abbreviations are fine (lmk, btw, idk, tbh, rn, tmrw) but NOT loud Gen-Z slang — that's a separate mode. Keep natural casual capitalization (still capitalize names and sentence starts), light punctuation: periods optional on short messages, '...' and a single '!' fine. Drop formal greetings and sign-offs — 'hey' or nothing. Example: 'I will be unable to attend the meeting tomorrow, I apologize' → 'Hey, can't make the meeting tmrw, my bad'",
            "ko": "In Korean: use 반말 (-해, -야, -지), never 해요체 and never 합쇼체.",
            "ja": "In Japanese: use plain form (だ/する).",
            "ru": "In Russian: use ты-forms.",
            "de": "In German: use Duzen (du/dir) with relaxed phrasing and everyday contractions (geht's, hab's).",
            "fr": "In French: use tutoiement (tu) with relaxed everyday phrasing and common contractions (t'as, j'sais).",
            "es": "In Spanish: use tú (or vos where regionally natural), relaxed and conversational.",
            "zh-Hans": "In Chinese: use 你 with relaxed, conversational phrasing and everyday particles (啊, 吧, 呢).",
        ],
    ]

    /// Register description tailored to one target language: the neutral
    /// summary plus that language's specific rule when one exists.
    func promptDescription(for languageID: String) -> String {
        guard let rule = WritingStyle.languageRules[self]?[languageID] else {
            return registerSummary
        }
        return "\(registerSummary) \(rule)"
    }

    /// The style currently in effect for `category`, honoring the user's saved
    /// per-category choice and falling back to the category default.
    static func resolved(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return category.defaultWritingStyle
    }
}

extension AppCategory {
    /// Default register when the user hasn't picked one for this category.
    var defaultWritingStyle: WritingStyle {
        switch self {
        case .personalMessages: return .casual
        case .workMessages, .other, .custom: return .polite
        case .email: return .formal
        }
    }
}

enum CleanupLevel: String, CaseIterable, Codable {
    case none
    case light
    case medium
    case high

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var promptDescription: String {
        switch self {
        case .none:
            return "do not polish wording — preserve the source phrasing as faithfully as the target language allows."
        case .light:
            return "fix obvious typos, grammar errors, OCR/line-break artifacts. Do not rewrite for style."
        case .medium:
            return "edit lightly for clarity and flow — fix typos and awkward phrasing, but do not rephrase aggressively."
        case .high:
            return "polish thoroughly for brevity and clarity. Tighten verbose sentences, drop filler words, keep meaning intact."
        }
    }
}

/// Gen Z styling overlay for compose prompts. Activated by the global Gen Z
/// toggle (`CompositionSettings.genZ`). The language-neutral `coreGuidance`
/// always leads — its load-bearing instruction is FULL transformation (rewrite
/// the whole message in slang, don't sprinkle one marker on formal text) —
/// followed by one target language's native-youth-slang block.
///
/// Synthesized from 2024–2026 per-language research. Slang churns fast, so each
/// block favors the durable signal (lowercase, dropped end-period, 💀/😭 over 😂,
/// tone) over fleeting vocabulary, and flags terms that already read as cringe.
enum GenZStyle {
    /// UserDefaults key for the global Gen Z toggle — single source of truth.
    static let defaultsKey = "genZMode"
    /// Current state of the global Gen Z toggle. Read wherever the prompt is
    /// assembled (delegate-owned compose path and the Ask client classes alike).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static let coreGuidance = """
        Gen Z mode is ON. Rewrite the message the way a Gen Z native (born ~1997–2012) would text it to a friend — casual digital register, not formal writing.
        CRITICAL — preserve the user's real meaning, intent, and information exactly. Change only the voice and styling, never what they are saying, and never invent new content.
        The #1 rule is to FULLY transform the message: rewrite the whole thing in slang, don't just sprinkle one marker on top of otherwise-formal text. Replace every formal/earnest word with its slang equivalent (impressed → lowkey obsessed, excellent → it ate / fire, very successful → so gonna cook / big W, talking about it → everyone's on it). Aim for 3+ slang markers per message. The failure mode to avoid is leaving formal phrasing untouched — if a sentence still reads corporate after you rewrite it, you under-did it.
        Default to all-lowercase. Drop the period at the end of a message (a trailing period reads cold or passive-aggressive). Keep it punchy.
        Tone skews ironic, deadpan, hyperbolic-for-jokes, and lightly self-deprecating — never earnest, peppy, or corporate.
        Use the target language's OWN native youth slang below — never translate English slang word-for-word into the target language.
        Still respect the selected register/honorific level (e.g. politeness or formality) while adding the Gen Z flavor.
        """

    static let languageGuidance: [String: String] = [
        "en": enGuide, "ru": ruGuide, "ko": koGuide, "ja": jaGuide,
        "zh-Hans": zhGuide, "es": esGuide, "fr": frGuide, "de": deGuide,
    ]

    /// Core rules plus the target language's specifics (core alone if the
    /// language has no dedicated block).
    static func promptSection(for languageID: String) -> String {
        guard let lang = languageGuidance[languageID] else { return coreGuidance }
        return "\(coreGuidance)\n\n\(lang)"
    }

    private static let enGuide = """
        English (US / global internet). All-lowercase; abbreviate freely: fr (for real), ngl, istg, idk, rn, tbh, lowkey/highkey, ong, deadass, iykyk, atp. Laughter is 💀 or 😭 or 'lmao' — never 😂 (a millennial tell).
        Current vocab: rizz (charm), no cap (no lie), it's giving X (gives off X), ate / understood the assignment (nailed it), cooked (doomed), mid (mediocre), crash out (lose it), delulu (delusional), bet (ok/deal), fire/bussin (great), 'that's so real' (agreement), aura (cool points).
        Cringe — avoid: skibidi, gyatt, sigma, Ohio, rizzler (Gen-Alpha brainrot); and millennial fossils: slay (overused), bae, on fleek, adulting, yas.
        Examples (note how every formal word gets swapped, not just one):
        - 'I'm really excited, this is going to be great' → 'ngl im so hyped this is gonna be fire fr'
        - 'Sorry, I can't make it tonight, I'm exhausted' → 'cant make it tn im so cooked 💀 sorry'
        - 'I was genuinely impressed by your presentation today. It was excellent, everyone was talking about it, and I think you're going to be very successful' → 'ngl your presentation today? it ate and left no crumbs fr 💀 no cap everyone was lowkey obsessed, you're so gonna cook, big W'
        """

    private static let ruGuide = """
        Russian. All-lowercase, no end-period, short fragments; heavy transliterated anglicisms. Laughter: ор / ору / орнул, ахах, пхпх — not 😂. Emoji sparse and ironic: 💀 🥲 🗿.
        Current vocab: база (facts/agreed), вайб (vibe), имба (op/awesome), рофл / рофлить (joke), окак (ironic 'oh wow'), чел (dude), го (let's go), жиза (relatable, postironic), делулу (delusional), скуф (unkempt older guy), слэй (nailed it).
        Tone: deadpan, postironic, understated. Don't overdo краш / кринж / чилить / флексить (now read slightly dated / adult).
        Examples:
        - 'Фильм очень понравился, советую посмотреть' → 'фильм имба реально советую'
        - 'Согласен, ты абсолютно прав' → 'база'
        """

    private static let koGuide = """
        Korean. Lean on 초성체: ㅋㅋㅋ (laugh; more ㅋ = funnier), ㅎㅎ (soft), ㅇㅇ (yes), ㄴㄴ (no), ㅇㅋ (ok), ㄱㄱ (go), ㄱㅅ (thanks), ㅈㅅ (sorry), ㄹㅇ (for real), ㅇㅈ (agreed), ㅁㅊ (omg). Cry with ㅠㅠ / ㅜㅜ. Clip words, drop spacing, use 음슴체 endings (먹음, 웃김, 가는중). Intensify with 개- / 존- / 핵- (개웃김, 존좋).
        Current vocab: 갓생 (grind-life), 찐 (genuine), 폼 미쳤다 (killing it), 현타 (reality crash), 꾸안꾸 (effortless style). Avoid dated: 어쩔티비, 존맛탱/JMT.
        Honorifics: if the input is 해요체, soften with ㅎㅎ / ~용 rather than dropping fully to 반말.
        Examples:
        - '오늘 정말 피곤해, 집에 가서 쉬고 싶어' → '오늘 진짜 개피곤 ㅠㅠ 집가서 눕고싶음'
        - '미안한데 약속에 좀 늦을 것 같아' → 'ㅈㅅㅈㅅ 나 좀 늦을듯 ㅠㅠ'
        """

    private static let jaGuide = """
        Japanese. Short fragments, タメ口, no 「。」 (reads cold). Drop particles (これヤバい). Laughter: 草 / w / wwww (more w = harder). 語尾: clip and stretch (しんど〜, きまず〜), nominalize with 〜み (つらみ, やばみ), 〜すぎ / 〜すぎる. Truncate: りょ→り (ok), とりま (anyway).
        Current vocab: それな (totally), ガチ / ガチで (for real), えぐい (insane), エモい (moving), ワンチャン (maybe), 知らんけど (…idk though — deadpan hedge), 神 (awesome), 推し. Avoid dead slang: ぴえん / ぱおん, マジ卍, あざまる, なう, タピる. Minimal emoji.
        Examples:
        - '今日は疲れたので早く寝ます' → '今日まじ疲れたわ〜もう寝る'
        - 'すごく助かりました、ありがとう' → 'まじ助かった〜ありがと🙏'
        """

    private static let zhGuide = """
        Simplified Chinese (Mainland). Lowercase pinyin-acronyms mixed with characters; repeat for emphasis. Laughter: 哈哈哈哈, 2333, xswl, 笑死 — not 😂.
        Current vocab: 那咋了 (so what / unbothered), emo了 (feeling down), 麻了 (numb / over it), 破防 (defenses broken / moved), 红温 (flushed with anger or embarrassment), 偷感 (acting low-key), 班味 (worn-down work vibe), 邪修 (unorthodox hack), 显眼包 (goofball), city不city (fancy?). Acronyms: yyds (GOAT), xswl (lmao), nbcs (nobody cares), awsl (so cute), u1s1 (real talk), dbq (sorry). Numbers: 666 (sick), 886 (bye), 555 (sob).
        Self-mocking 躺平 / 摆烂 tone. Avoid now-cringe: 绝绝子, 栓Q, overused yyds.
        Examples:
        - '这家餐厅真好吃，我很喜欢' → '这家真的绝了我爱住了哈哈哈哈'
        - '今天工作太累了，想休息' → '今天班味太重直接麻了 只想躺平'
        """

    private static let esGuide = """
        Spanish. Lowercase, drop opening ¿ ¡, no end-period, stretch vowels (siii, holaaa). Laughter: jajaja / jsjs / 💀 / 😭 — not 😂 or xD.
        Prefer PAN-HISPANIC terms (the user's region is usually unknown): cringe, random, crush, shippear, stalkear, mood, literal (intensifier), real / x2 (= same), mid, NPC, POV, red/green flag, modo X; peak term aura / farmear aura (clout). Regional — use only if signaled. Spain: tío/tía, en plan (filler), flipar, rayarse, mazo (= very). Mexico: neta, no manches, qué pedo, equis (= meh), alv. Argentina: che, boludo, re + adj, posta, de una (voseo: sos/tenés). Never mix regions — it reads instantly fake.
        Examples:
        - '¿Viste el video que te mandé? Es muy gracioso' → 'viste el video q te mande?? me morí 💀'
        - 'No quiero salir hoy, estoy muy cansado' → 'nah hoy no tengo ganas de salir estoy muerto'
        """

    private static let frGuide = """
        French. Default tu, never vous with peers (vous + slang = instant fake). All-lowercase; drop accents, apostrophes and the 'ne' (jai pas, jsp). Phonetic: c'est→c, j'ai→g, quoi→koi, t'inquiète→tkt, je sais pas→jsp, j'en peux plus→jpp, beaucoup→bcp. Laughter: mdr / ptdr / mdrrr and 💀 / 😭 — not 😂.
        Current vocab: wesh (yo), frérot / frr (bro), askip (apparently), c'est ouf / de ouf (insane), chelou (sketchy), relou (annoying), seum (bitter), bg (hot), validé (approved), banger, c'est carré (sorted), sah / wallah (i swear), jpp. Hyperbole for funny: 'je suis mort', 'ça m'a tué'. Avoid dated: swag, quoicoubeh, lol.
        Examples:
        - 'Tu es libre ce soir pour qu'on se voie ?' → 'wesh ça dit quoi tas dispo ce soir'
        - 'Je n'en peux plus, ce cours était trop long' → 'jpp ce cours ct giga long 💀'
        """

    private static let deGuide = """
        German. All-lowercase — drop even noun capitals (correct caps read old / try-hard). Default du. Drop the end-period (a lone 'Ok.' reads annoyed; 'ok' / 'kk' is fine). Laughter: 💀 / 😭, 'ich lieg', 'ich kann nicht' — not 😂.
        Current vocab: digga / diggah (bro, the #1 word), alter, bruda, wallah / ich schwör (i swear), lowkey, safe (definitely), mid, no cap, W / L (großes W, nimm das L), krass / geil (still live), 'das crazy', lost, cringe, random, aura. English verbs take German endings: gelikt, gecancelt, geghostet. Avoid corny / Jugendwort-bait: slay, lit, swag, yolo, smash, 'gönn dir', Ehrenmann. Do NOT generate Talahon or amk (slur / obscene).
        Examples:
        - 'Kannst du mir später beim Umzug helfen?' → 'digga hilfst du mir später beim umzug 🙏'
        - 'Der neue Film ist ziemlich mittelmäßig' → 'ngl der neue film war lowkey mid'
        """
}

enum AppCategoryClassifier {
    static let bundleIDMap: [String: AppCategory] = [
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "com.linkedin.LinkedIn": .workMessages,
        "com.apple.MobileSMS": .personalMessages,
        "com.apple.iChat": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.telegram.desktop": .personalMessages,
        "net.whatsapp.WhatsApp": .personalMessages,
        // KakaoTalk is deliberately NOT mapped: in Korea it is as much a work
        // channel as a personal one, and personalMessages defaults to casual
        // (반말) — too risky to assume. Unmapped → .other → polite (해요체),
        // safe in both directions. Users can assign it via custom app rules.
        "com.hnc.Discord": .personalMessages,
    ]

    /// User-added app→category assignments. Take precedence over `bundleIDMap`.
    /// Kept in sync by `NugumiApp` from persisted `CustomAppAssignment`s.
    static var userOverrides: [String: AppCategory] = [:]
    /// Built-in `bundleIDMap` apps the user removed — treated as unclassified.
    static var suppressedBuiltIns: Set<String> = []

    static func category(for bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        if let override = userOverrides[id] { return override }
        if suppressedBuiltIns.contains(id) { return .other }
        if let mapped = bundleIDMap[id] { return mapped }
        let lower = id.lowercased()
        if lower.contains("mail") || lower.contains("outlook") { return .email }
        if lower.contains("slack") || lower.contains("teams") { return .workMessages }
        return .other
    }

    /// Category of the current frontmost app, by bundle ID.
    static func frontmostCategory() -> AppCategory {
        category(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}

/// A user-added app→category assignment, persisted in UserDefaults.
struct CustomAppAssignment: Codable, Equatable {
    let bundleID: String
    let name: String
    let category: AppCategory
}

enum CloudProvider: String, Codable, CaseIterable {
    case openAI
    case openAICodex
    case anthropic
    case gemini
    case openRouter
    /// Anthropic Claude subscription (Pro/Max) via Claude Code OAuth. Uses a
    /// Bearer OAuth token against the *native* /v1/messages API, not the
    /// OpenAI-compat endpoint `.anthropic` uses. See `ClaudeCodeClient`.
    case anthropicClaudeCode

    /// OAuth (subscription) providers use a sign-in flow instead of an API key
    /// — branches that present the API-key sheet must consult this flag.
    var usesOAuth: Bool {
        switch self {
        case .openAICodex, .anthropicClaudeCode: true
        case .openAI, .anthropic, .gemini, .openRouter: false
        }
    }

    var baseURL: URL {
        switch self {
        case .openAI:      URL(string: "https://api.openai.com/v1/chat/completions")!
        case .openAICodex: URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        case .anthropic:   URL(string: "https://api.anthropic.com/v1/chat/completions")!
        case .gemini:      URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        case .openRouter:  URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .anthropicClaudeCode: URL(string: "https://api.anthropic.com/v1/messages")!
        }
    }

    var keychainService: String { "com.nugumi.app.\(rawValue.lowercased())" }

    /// Single brand label used everywhere the provider is named — the
    /// Cloud access rows and the model picker section headers — so the two
    /// agree. The API-key vs subscription distinction is carried by the
    /// sign-in button ("Add key" vs "Sign in"), not the name.
    var displayName: String {
        switch self {
        case .openAI:      "OpenAI"
        case .openAICodex: "Codex"
        case .anthropic:   "Anthropic"
        case .gemini:      "Google"
        case .openRouter:  "OpenRouter"
        case .anthropicClaudeCode: "Claude Code"
        }
    }

    var apiKeyHelpURL: URL {
        switch self {
        case .openAI:      URL(string: "https://platform.openai.com/api-keys")!
        case .openAICodex: URL(string: "https://chatgpt.com/")!
        case .anthropic:   URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini:      URL(string: "https://aistudio.google.com/app/apikey")!
        case .openRouter:  URL(string: "https://openrouter.ai/keys")!
        case .anthropicClaudeCode: URL(string: "https://claude.ai")!
        }
    }

    var modelsURL: URL {
        switch self {
        case .openAI:      URL(string: "https://api.openai.com/v1/models")!
        case .openAICodex: URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")!
        case .anthropic:   URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:      URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models")!
        case .openRouter:  URL(string: "https://openrouter.ai/api/v1/models")!
        case .anthropicClaudeCode: URL(string: "https://api.anthropic.com/v1/models")!
        }
    }
}

enum APIKeyValidator {
    enum Outcome {
        case valid
        case invalid(reason: String)
        case networkUnreachable(detail: String)
    }

    static func validate(_ apiKey: String, for provider: CloudProvider) async -> Outcome {
        var request = URLRequest(url: provider.modelsURL)
        request.httpMethod = "GET"
        switch provider {
        case .openAI, .gemini, .openAICodex, .openRouter, .anthropicClaudeCode:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            // Native Anthropic /v1/models requires x-api-key + anthropic-version,
            // not the OpenAI-compat Bearer header (compat only covers /chat/completions).
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .invalid(reason: "Invalid response from \(provider.displayName).")
            }
            switch http.statusCode {
            case 200..<300:
                // The body is the provider's /models list — feed discovery so
                // the picker updates the moment a key is added. Free: no
                // extra request beyond the validation GET itself.
                CloudModelCache.update(
                    provider: provider,
                    models: CloudModelDiscovery.parse(provider: provider, data: data)
                )
                return .valid
            case 401, 403:
                return .invalid(reason: "\(provider.displayName) rejected this key.")
            case 429:
                return .invalid(reason: "\(provider.displayName) rate-limited the check. Try later.")
            default:
                let reason = CloudHTTPError.extractMessage(from: data)
                    ?? CloudHTTPError.friendlyMessage(status: http.statusCode)
                return .invalid(reason: "\(provider.displayName): \(reason)")
            }
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
            || urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .timedOut
            || urlError.code == .networkConnectionLost {
            return .networkUnreachable(detail: urlError.localizedDescription)
        } catch {
            return .networkUnreachable(detail: error.localizedDescription)
        }
    }
}

/// Launch-at-login via the native ServiceManagement API (macOS 13+). The app
/// bundle registers *itself* as the login item — no separate helper target.
/// Callers MUST gate on `isRunningFromAppBundle`: `SMAppService` is meaningless
/// under `swift run` (no bundle) and the registration would point at the
/// transient `.build` binary.
enum KeychainStore {
    private enum CacheEntry {
        case missing
        case present(String)
    }
    private static var cache: [CloudProvider: CacheEntry] = [:]

    private static let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func apiKey(for provider: CloudProvider) -> String? {
        if let entry = cache[provider] {
            switch entry {
            case .missing: return nil
            case .present(let key): return key
            }
        }
        let key = readFromFile(for: provider)
        cache[provider] = key.map { .present($0) } ?? .missing
        return key
    }

    static func setAPIKey(_ key: String?, for provider: CloudProvider) {
        let url = fileURL(for: provider)
        guard let key, !key.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            cache[provider] = .missing
            return
        }
        do {
            try key.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // If we can't write, at least keep the in-memory cache so this session works.
        }
        cache[provider] = .present(key)
    }

    private static func readFromFile(for provider: CloudProvider) -> String? {
        let url = fileURL(for: provider)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fileURL(for provider: CloudProvider) -> URL {
        storageDirectory.appending(path: "\(provider.rawValue).key", directoryHint: .notDirectory)
    }
}

struct ImageInput {
    let data: Data
    let mediaType: String

    var base64String: String { data.base64EncodedString() }
    var openAIDataURI: String { "data:\(mediaType);base64,\(base64String)" }
}

/// One-time acknowledgement that a chat summary sent through a cloud backend
/// leaves the device (and may include other people's messages). Local Ollama
/// summaries never consult this — nothing leaves the machine. Persisted so
/// the modal only shows once per install, not once per summary.
enum SummaryConsent {
    private static let key = "summary.cloudConsentAccepted"
    static var accepted: Bool {
        get { value(forKey: key) }
        set { set(newValue, forKey: key) }
    }
    static func value(forKey k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func set(_ v: Bool, forKey k: String) { UserDefaults.standard.set(v, forKey: k) }
}

protocol LLMBackend {
    func translate(
        _ text: String,
        images: [ImageInput],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse
}

struct OllamaClient: LLMBackend {
    let baseURL: URL
    let model: String

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if image != nil, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled))
        ]
        for turn in history {
            messages.append(ChatMessage(role: "user", content: turn.question))
            messages.append(ChatMessage(role: "assistant", content: turn.answer))
        }
        let prompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        messages.append(ChatMessage(role: "user", content: prompt, images: image.map { [$0.base64String] }))

        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, stream: true, think: thinkingLevel.rawValue, messages: messages)
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }
        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }
            let decoded = try decoder.decode(ChatResponse.self, from: data)
            answer += decoded.message.content
            onPartial(answer)
            if decoded.done { break }
        }

        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return parsed
    }

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        case .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // Already composed deliberately (labeled sections) — don't let the
            // selection cleaner collapse the structure the prompt relies on.
            sourceText = text
        }
        guard !sourceText.isEmpty else {
            throw TranslationError.emptyResponse
        }

        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if !images.isEmpty, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let imageStrings = images.isEmpty ? nil : images.map(\.base64String)
        let body = ChatRequest(
            model: model,
            stream: true,
            think: thinkingLevel.rawValue,
            messages: [
                ChatMessage(
                    role: "system",
                    content: mode.systemPrompt(
                        targetLanguage: targetLanguage,
                        appCategory: appCategory,
                        composition: composition
                    )
                ),
                ChatMessage(role: "user", content: sourceText, images: imageStrings)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }

        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
            }

            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }

            let decoded = try decoder.decode(ChatResponse.self, from: data)
            translated += decoded.message.content

            let partial = TextNormalizer.cleanedTranslation(translated)
            if !partial.isEmpty {
                onPartial(partial)
            }

            if decoded.done {
                break
            }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }

        return finalTranslation
    }

    static func classifyStreamError(message: String, model: String) -> TranslationError {
        let lowered = message.lowercased()
        if lowered.contains("not found") && (lowered.contains("model") || lowered.contains("manifest")) {
            return .modelMissing(model)
        }
        if lowered.contains("unauthorized")
            || lowered.contains("sign in")
            || lowered.contains("not signed in")
            || lowered.contains("signin")
            || lowered.contains("authenticate")
            || lowered.contains("forbidden") {
            return .signInRequired
        }
        return .ollama(message)
    }
}

struct OpenAIChatClient: LLMBackend {
    let provider: CloudProvider
    let apiKey: String
    let model: String

    private static let maxImageBytes = 5 * 1024 * 1024

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        if let image {
            guard LLMModel.option(id: model).supportsImages else {
                throw TranslationError.cloudError(provider, "Ask Nugumi with a screenshot needs a vision model.")
            }
            guard image.data.count <= Self.maxImageBytes else {
                throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
            }
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }

        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        let currentUserContent: OpenAIContent
        if let image {
            currentUserContent = .parts([
                .text(currentPrompt),
                .imageURL(image.openAIDataURI)
            ])
        } else {
            currentUserContent = .string(currentPrompt)
        }

        var messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system", content: .string(AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled)))
        ]
        for turn in history {
            messages.append(OpenAIMessage(role: "user", content: .string(turn.question)))
            messages.append(OpenAIMessage(role: "assistant", content: .string(turn.answer)))
        }
        messages.append(OpenAIMessage(role: "user", content: currentUserContent))

        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: messages,
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        case 402:
            throw TranslationError.outOfCredits(provider)
        default:
            let body = await CloudHTTPError.readBody(bytes)
            throw TranslationError.cloudError(
                provider,
                CloudHTTPError.detail(status: httpResponse.statusCode, body: body)
            )
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                answer += delta
                onPartial(answer)
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return parsed
    }

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        case .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // Already composed deliberately (labeled sections) — don't let the
            // selection cleaner collapse the structure the prompt relies on.
            sourceText = text
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }

        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        let userContent: OpenAIContent = images.isEmpty
            ? .string(sourceText)
            : .parts([.text(sourceText)] + images.map { .imageURL($0.openAIDataURI) })

        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: [
                OpenAIMessage(role: "system", content: .string(systemPrompt)),
                OpenAIMessage(role: "user", content: userContent)
            ],
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        case 402:
            throw TranslationError.outOfCredits(provider)
        default:
            let body = await CloudHTTPError.readBody(bytes)
            throw TranslationError.cloudError(
                provider,
                CloudHTTPError.detail(status: httpResponse.statusCode, body: body)
            )
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                translated += delta
                let partial = TextNormalizer.cleanedTranslation(translated)
                if !partial.isEmpty {
                    onPartial(partial)
                }
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return finalTranslation
    }
}

private enum OpenAIContent: Encodable {
    case string(String)
    case parts([OpenAIPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private enum OpenAIPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    private struct ImageURLBox: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLBox(url: url), forKey: .image_url)
        }
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: OpenAIContent
}

struct CloudThinkingOptions: Encodable, Equatable {
    let reasoningEffort: String?
    let thinking: AnthropicThinkingConfig?
    let outputConfig: AnthropicOutputConfig?

    init(provider: CloudProvider, model: String, thinkingLevel: ThinkingLevel) {
        // All four providers POST to OpenAI-compatible /chat/completions
        // endpoints. Anthropic's compat endpoint rejects native thinking params
        // — `thinking: {type:"adaptive"}` returns HTTP 400 "Adaptive thinking is
        // not available via the OpenAI compatibility endpoint" — but accepts the
        // OpenAI-style `reasoning_effort` knob (verified against the live API),
        // so every compat provider routes through it. Do NOT send native
        // `thinking`/`output_config` here.
        switch provider {
        case .openAI, .gemini, .openAICodex, .anthropic, .openRouter, .anthropicClaudeCode:
            // .anthropicClaudeCode never constructs this type (it builds a
            // native Messages body via ClaudeCodeClient); the case exists only
            // for exhaustiveness.
            reasoningEffort = thinkingLevel.cloudReasoningEffort
            thinking = nil
            outputConfig = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }
}

struct AnthropicThinkingConfig: Encodable, Equatable {
    let type: String
    let budgetTokens: Int?

    init(type: String, budgetTokens: Int? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

struct AnthropicOutputConfig: Encodable, Equatable {
    let effort: String
}

private extension ThinkingLevel {
    var cloudReasoningEffort: String { rawValue }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let stream: Bool
    let messages: [OpenAIMessage]
    let thinkingOptions: CloudThinkingOptions?

    private enum CodingKeys: String, CodingKey {
        case model
        case stream
        case messages
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    init(
        model: String,
        stream: Bool,
        messages: [OpenAIMessage],
        thinkingOptions: CloudThinkingOptions? = nil
    ) {
        self.model = model
        self.stream = stream
        self.messages = messages
        self.thinkingOptions = thinkingOptions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(stream, forKey: .stream)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(thinkingOptions?.reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinkingOptions?.thinking, forKey: .thinking)
        try container.encodeIfPresent(thinkingOptions?.outputConfig, forKey: .outputConfig)
    }
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct OpenAIStreamError: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }

    let error: ErrorBody

    var displayMessage: String {
        error.message ?? error.type ?? error.code ?? "stream error"
    }
}

struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    // NOTE: send the effort level string ("low"/"medium"/"high"), never a bool.
    // gpt-oss is a level-based reasoning model: `think: false` is ignored and
    // falls back to default effort, which still reasons and is ~2x SLOWER than
    // "low" (measured on gpt-oss:20b and :120b-cloud). "low" is the fast path.
    let think: String
    let messages: [ChatMessage]
    /// Keep the model resident in (V)RAM between requests so intermittent use
    /// doesn't pay a cold model-load each time. Ollama-only concept.
    var keepAlive: String = "30m"

    private enum CodingKeys: String, CodingKey {
        case model, stream, think, messages
        case keepAlive = "keep_alive"
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String
    let images: [String]?

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

struct ChatResponse: Decodable {
    let message: ChatMessage
    let done: Bool
}

struct StreamError: Decodable {
    let error: String?
}

/// Turns a non-2xx cloud HTTP response into a human sentence instead of a bare
/// "HTTP 402". Prefers the provider's own error message from the JSON body
/// (OpenAI-compat `{"error":{"message":...}}`), falling back to a friendly
/// status-code map. Shared by every cloud client so the Test result and the
/// Ask Nugumi error pill read the same way.
enum CloudHTTPError {
    /// The provider's own error message from a JSON error body, if present.
    static func extractMessage(from data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = obj["error"] as? [String: Any],
           let m = err["message"] as? String, !m.isEmpty { return m }
        if let s = obj["error"] as? String, !s.isEmpty { return s }
        if let m = obj["message"] as? String, !m.isEmpty { return m }
        return nil
    }

    /// Friendly fallback for a status the caller didn't map to a more specific
    /// TranslationError (401/403 → invalidAPIKey, 429 → rateLimited are handled
    /// before this). Phrased to read after "Provider: " — cloudError prepends
    /// the provider name.
    static func friendlyMessage(status: Int) -> String {
        switch status {
        case 400: return "Couldn't process that request. Try shorter text or another model."
        case 402: return "You're out of credits. Add funds to use paid models - free models still work."
        case 404: return "That model isn't available right now. Pick another in settings."
        case 408: return "The request timed out. Try again."
        case 413: return "The text or image is too large for this model."
        case 500, 502, 503, 504, 529: return "Their server had a problem. Try again in a moment."
        default: return "Unexpected error (HTTP \(status))."
        }
    }

    /// Best available detail: the provider's own message, else the friendly map.
    static func detail(status: Int, body: Data?) -> String {
        extractMessage(from: body) ?? friendlyMessage(status: status)
    }

    /// Drain a (small) error-response byte stream into Data for `detail`. Capped
    /// so a misbehaving endpoint can't stream forever into an error message.
    static func readBody(_ bytes: URLSession.AsyncBytes, cap: Int = 16 * 1024) async -> Data? {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= cap { break }
            }
        } catch { return data.isEmpty ? nil : data }
        return data.isEmpty ? nil : data
    }
}

enum TranslationError: LocalizedError {
    case ollama(String)
    case emptyResponse
    case serverUnavailable
    case modelMissing(String)
    case signInRequired
    case modelDownloading(String)
    case invalidAPIKey(CloudProvider)
    case rateLimited(CloudProvider)
    case outOfCredits(CloudProvider)
    case cloudError(CloudProvider, String)

    /// True for failures that prove the key authenticated (the provider is
    /// reachable and the credentials are valid) but the request couldn't run —
    /// out of credits or rate-limited. The connectivity test treats these as
    /// "connected", not a broken key.
    var provesCredentialsValid: Bool {
        switch self {
        case .rateLimited, .outOfCredits: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "Translation request failed: \(message)"
        case .emptyResponse:
            "Got an empty translation. Try again."
        case .serverUnavailable:
            "The translator isn't running. Open setup to fix it."
        case .modelMissing:
            "The translator isn't downloaded yet. Open setup to download it."
        case .signInRequired:
            "Sign in to Ollama to use the online translator. Open setup to finish."
        case .modelDownloading(let detail):
            "\(detail) Try again when the translator is ready."
        case .invalidAPIKey(let provider):
            "\(provider.displayName) rejected the API key. Open settings to update it."
        case .rateLimited(let provider):
            "\(provider.displayName) rate limit reached. Try again in a minute, or switch model."
        case .outOfCredits(let provider):
            "\(provider.displayName) is out of credits. Add funds to use paid models - free models still work."
        case .cloudError(let provider, let detail):
            "\(provider.displayName): \(detail)"
        }
    }
}

// MARK: - OpenAI Codex (ChatGPT subscription) OAuth
//
// Lets ChatGPT Plus/Pro subscribers use Nugumi without an OpenAI API key.
// The flow mirrors what the official Codex CLI does (and what Hermes Agent
// replicates): OAuth device-code login against auth.openai.com, then inference
// against chatgpt.com/backend-api/codex/responses (the Responses API, not the
// public /v1/chat/completions surface).
//
// IMPORTANT: this endpoint is unofficial. The same client_id and Cloudflare
// allow-listed `originator` header are shared with Codex CLI; OpenAI could
// tighten the allow-list at any time and break this backend.

struct CodexCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountId: String?
    let planType: String?

    func isExpiring(within seconds: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow < seconds
    }
}

enum CodexJWT {
    struct Claims {
        let expiresAt: Date?
        let accountId: String?
        let planType: String?
    }

    static func decode(_ jwt: String) -> Claims {
        let empty = Claims(expiresAt: nil, accountId: nil, planType: nil)
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return empty }

        let exp: Date? = {
            if let v = json["exp"] as? Double { return Date(timeIntervalSince1970: v) }
            if let v = json["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(v)) }
            return nil
        }()
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        return Claims(
            expiresAt: exp,
            accountId: auth?["chatgpt_account_id"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String
        )
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 { b64.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: b64)
    }
}

extension KeychainStore {
    private static var codexCache: CodexCredentials?
    private static var codexCacheLoaded = false
    private static let codexFileName = "openai.codex.tokens.json"

    private static var codexFileURL: URL {
        storageDirectory.appending(path: codexFileName, directoryHint: .notDirectory)
    }

    static func codexCredentials() -> CodexCredentials? {
        if codexCacheLoaded { return codexCache }
        codexCacheLoaded = true
        guard let data = try? Data(contentsOf: codexFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        codexCache = try? decoder.decode(CodexCredentials.self, from: data)
        return codexCache
    }

    static func setCodexCredentials(_ creds: CodexCredentials?) {
        guard let creds else {
            try? FileManager.default.removeItem(at: codexFileURL)
            codexCache = nil
            codexCacheLoaded = true
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(creds) {
            try? data.write(to: codexFileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: codexFileURL.path
            )
        }
        codexCache = creds
        codexCacheLoaded = true
    }
}

extension CloudProvider {
    /// True if the user has saved credentials for this provider (API key OR OAuth tokens).
    var hasCredentials: Bool {
        switch self {
        case .openAICodex:
            return KeychainStore.codexCredentials() != nil
        case .anthropicClaudeCode:
            return KeychainStore.claudeCodeCredentials() != nil
        case .openAI, .anthropic, .gemini, .openRouter:
            let key = KeychainStore.apiKey(for: self)
            return !(key?.isEmpty ?? true)
        }
    }

    /// Order in which providers appear in the onboarding wizard's Cloud tab.
    /// ChatGPT subscription (OAuth) first — it's the most-friction-free
    /// option for users who already have a ChatGPT account — followed by
    /// the API-key providers in their declaration order.
    static var cloudOnboardingCases: [CloudProvider] {
        // OAuth/subscription providers first (most-friction-free for users who
        // already have an account), then the API-key providers in declaration
        // order. usesOAuth providers must be listed explicitly since the filter
        // below excludes them.
        [.openAICodex, .anthropicClaudeCode] + allCases.filter { !$0.usesOAuth }
    }

    /// Default model ID to assign to the everyday-text scope when the user
    /// signs in / saves a key for this provider during onboarding. Picks a
    /// fast/cheap option from the provider's lineup.
    var preferredTextModelID: String {
        switch self {
        case .openAICodex: "codex/gpt-5.4-mini"
        case .openAI:      "gpt-5.4-mini"
        case .anthropic:   "claude-haiku-4-5-20251001"
        case .gemini:      "gemini-2.5-flash-lite"
        case .openRouter:  "openai/gpt-5.4-mini"
        case .anthropicClaudeCode: "claude-code/claude-haiku-4-5-20251001"
        }
    }

    /// Default model ID for Ask Nugumi (the multimodal scope) when this
    /// provider's credentials get set during onboarding. Picks the flagship
    /// vision model from the provider's lineup.
    var preferredAskModelID: String {
        switch self {
        case .openAICodex: "codex/gpt-5.5"
        case .openAI:      "gpt-5.5"
        case .anthropic:   "claude-sonnet-4-6"
        case .gemini:      "gemini-2.5-pro"
        case .openRouter:  "google/gemini-2.5-pro"
        case .anthropicClaudeCode: "claude-code/claude-sonnet-4-6"
        }
    }
}

// MARK: Codex diagnostics log

/// File-based debug log for the Codex auth flow. NSLog/os_log can get
/// silenced when the app is launched via `open` (stderr → /dev/null) and the
/// system log filter is unfriendly, so for the duration of debugging the
/// OAuth dance we mirror everything to ~/Library/Logs/Nugumi/codex.log
/// where the user can always `tail -f` it.
enum CodexDebugLog {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appending(path: "Logs/Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appending(path: "codex.log", directoryHint: .notDirectory)
    }()

    static func append(_ message: String) {
        let stamped = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = stamped.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        NSLog("[Nugumi/Codex] %@", message)
    }
}

// MARK: Codex OAuth client (device-code login + refresh)

/// Endpoints + flow shape mirror Hermes Agent's hermes_cli/auth.py:
/// `app_EMoamEEZ73f0CkXaXp7hrann` is the public Codex CLI client_id;
/// device-code returns {user_code, device_auth_id} then poll
/// /api/accounts/deviceauth/token until 200 returns {authorization_code,
/// code_verifier}, then exchange those at /oauth/token.
actor CodexOAuthClient {
    static let shared = CodexOAuthClient()

    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    struct DeviceCodeStart {
        let userCode: String       // e.g. "LI50-8AOZ1"
        let deviceAuthID: String
        let verificationURL: URL   // https://auth.openai.com/codex/device
        let pollInterval: TimeInterval
    }

    enum CodexAuthError: LocalizedError {
        case network(String)
        case server(Int, String)
        case malformedResponse(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .network(let d): "Network error: \(d)"
            case .server(let code, let d): "Server returned HTTP \(code): \(d.prefix(200))"
            case .malformedResponse(let d): "Unexpected response: \(d)"
            case .timeout: "Login timed out after 15 minutes."
            }
        }
    }

    func startDeviceCode() async throws -> DeviceCodeStart {
        CodexDebugLog.append("startDeviceCode: requesting device code from \(issuer)")
        var req = URLRequest(url: URL(string: "\(issuer)/api/accounts/deviceauth/usercode")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, resp) = try await dataTask(req)
        guard let http = resp as? HTTPURLResponse else {
            throw CodexAuthError.malformedResponse("not an HTTP response")
        }
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
        CodexDebugLog.append("startDeviceCode: status=\(http.statusCode) body=\(bodyPreview)")
        guard http.statusCode == 200 else {
            throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceAuthID = json["device_auth_id"] as? String
        else { throw CodexAuthError.malformedResponse("missing user_code / device_auth_id") }

        let interval: TimeInterval = {
            if let i = json["interval"] as? Double { return i }
            if let i = json["interval"] as? Int { return Double(i) }
            if let s = json["interval"] as? String, let v = Double(s) { return v }
            return 5
        }()
        CodexDebugLog.append("startDeviceCode: got userCode=\(userCode) interval=\(interval) keys=\(Array(json.keys))")
        return DeviceCodeStart(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            verificationURL: URL(string: "\(issuer)/codex/device")!,
            pollInterval: max(3, interval)
        )
    }

    func pollForTokens(
        deviceAuthID: String,
        userCode: String,
        interval: TimeInterval
    ) async throws -> CodexCredentials {
        let deadline = Date().addingTimeInterval(15 * 60)
        let pollURL = URL(string: "\(issuer)/api/accounts/deviceauth/token")!
        CodexDebugLog.append("pollForTokens: start — interval=\(interval)s deviceAuthID=\(deviceAuthID) userCode=\(userCode)")
        var lastStatusLogged = -1
        var iteration = 0
        while Date() < deadline {
            iteration += 1
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()

            var req = URLRequest(url: pollURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceAuthID,
                "user_code": userCode
            ])

            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await dataTask(req)
            } catch {
                CodexDebugLog.append("poll #\(iteration): network error \(error)")
                continue
            }
            guard let http = resp as? HTTPURLResponse else {
                CodexDebugLog.append("poll #\(iteration): non-HTTP response")
                continue
            }
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            if http.statusCode != lastStatusLogged {
                CodexDebugLog.append("poll #\(iteration) status=\(http.statusCode) body=\(bodyPreview)")
                lastStatusLogged = http.statusCode
            }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    CodexDebugLog.append("poll 200 but body not JSON: \(bodyPreview)")
                    throw CodexAuthError.malformedResponse("poll 200 body not JSON")
                }
                if let _ = json["access_token"] as? String {
                    CodexDebugLog.append("poll 200: direct access_token, skipping exchange")
                    return try parseTokenResponseJSON(json, fallbackRefreshToken: "")
                }
                if let authCode = json["authorization_code"] as? String,
                   let verifier = json["code_verifier"] as? String {
                    CodexDebugLog.append("poll 200: got authorization_code, exchanging…")
                    return try await exchangeAuthorizationCode(authCode, verifier: verifier)
                }
                CodexDebugLog.append("poll 200 unknown shape — keys=\(Array(json.keys))")
                throw CodexAuthError.malformedResponse("poll 200 unknown shape: \(Array(json.keys))")
            case 403, 404:
                continue // user hasn't completed sign-in yet
            case 400, 408, 425, 429:
                continue // "authorization_pending", "slow_down", or rate limit
            default:
                CodexDebugLog.append("poll #\(iteration) unexpected status \(http.statusCode) body=\(bodyPreview)")
                throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        }
        throw CodexAuthError.timeout
    }

    private func parseTokenResponseJSON(_ json: [String: Any], fallbackRefreshToken: String) throws -> CodexCredentials {
        guard let access = json["access_token"] as? String else {
            throw CodexAuthError.malformedResponse("missing access_token")
        }
        let refresh = (json["refresh_token"] as? String) ?? fallbackRefreshToken
        let claims = CodexJWT.decode(access)
        let fallbackExpiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        let expiry = claims.expiresAt ?? Date().addingTimeInterval(fallbackExpiresIn)
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry,
            accountId: claims.accountId,
            planType: claims.planType
        )
    }

    private func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> CodexCredentials {
        try await postTokenRequest(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "\(issuer)/deviceauth/callback",
            "client_id": clientID,
            "code_verifier": verifier
        ])
    }

    func refresh(_ refreshToken: String) async throws -> CodexCredentials {
        try await postTokenRequest(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private func postTokenRequest(form: [String: String]) async throws -> CodexCredentials {
        let grantType = form["grant_type"] ?? "?"
        CodexDebugLog.append("postTokenRequest: building \(grantType) request to /oauth/token")
        var req = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.urlencode(form).data(using: .utf8)
        CodexDebugLog.append("postTokenRequest: sending \(grantType), body \(req.httpBody?.count ?? 0) bytes")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await dataTask(req)
        } catch {
            CodexDebugLog.append("postTokenRequest: dataTask threw — \(error)")
            throw error
        }
        guard let http = resp as? HTTPURLResponse else {
            CodexDebugLog.append("postTokenRequest: not an HTTPURLResponse")
            throw CodexAuthError.malformedResponse("not an HTTP response")
        }
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
        CodexDebugLog.append("postTokenRequest: \(grantType) status=\(http.statusCode) body=\(bodyPreview)")
        guard http.statusCode == 200 else {
            throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw CodexAuthError.malformedResponse("missing access_token") }

        let refresh = (json["refresh_token"] as? String) ?? form["refresh_token"] ?? ""
        let claims = CodexJWT.decode(access)
        let fallbackExpiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        let expiry = claims.expiresAt ?? Date().addingTimeInterval(fallbackExpiresIn)
        CodexDebugLog.append("postTokenRequest: \(grantType) success — accountId=\(claims.accountId ?? "nil") plan=\(claims.planType ?? "nil")")
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry,
            accountId: claims.accountId,
            planType: claims.planType
        )
    }

    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let url = req.url?.absoluteString ?? "?"
        CodexDebugLog.append("dataTask: starting \(req.httpMethod ?? "?") \(url)")
        do {
            let result = try await session.data(for: req)
            CodexDebugLog.append("dataTask: completed \(url)")
            return result
        } catch let err as URLError {
            CodexDebugLog.append("dataTask: URLError on \(url) — \(err.code.rawValue) \(err.localizedDescription)")
            throw CodexAuthError.network(err.localizedDescription)
        } catch {
            CodexDebugLog.append("dataTask: unexpected error on \(url) — \(error)")
            throw error
        }
    }

    private static func urlencode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        return form.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

// MARK: Token broker — refresh-on-demand for inference paths

/// Resolves a fresh access token + JWT-derived account ID for the Codex
/// backend. Persists refreshed tokens back to Keychain. Serialized on the
/// shared CodexOAuthClient actor so concurrent translate/ask calls don't
/// stampede the token endpoint.
enum CodexCredentialBroker {
    /// Returns an access token guaranteed not to expire within ~2 minutes,
    /// refreshing transparently if needed. Throws if the user is not logged in.
    static func resolveAccessToken() async throws -> (token: String, accountId: String?) {
        guard let creds = KeychainStore.codexCredentials() else {
            throw TranslationError.invalidAPIKey(.openAICodex)
        }
        if !creds.isExpiring(within: 120) {
            return (creds.accessToken, creds.accountId)
        }
        do {
            let refreshed = try await CodexOAuthClient.shared.refresh(creds.refreshToken)
            await MainActor.run { KeychainStore.setCodexCredentials(refreshed) }
            return (refreshed.accessToken, refreshed.accountId)
        } catch let err as CodexOAuthClient.CodexAuthError {
            if case .server(let status, _) = err, status == 400 || status == 401 || status == 403 {
                // Refresh token revoked or rotated by another client — force re-login.
                await MainActor.run { KeychainStore.setCodexCredentials(nil) }
                throw TranslationError.invalidAPIKey(.openAICodex)
            }
            throw TranslationError.cloudError(.openAICodex, err.errorDescription ?? "auth error")
        }
    }

    static func forceRefresh() async throws -> (token: String, accountId: String?) {
        guard let creds = KeychainStore.codexCredentials() else {
            throw TranslationError.invalidAPIKey(.openAICodex)
        }
        let refreshed = try await CodexOAuthClient.shared.refresh(creds.refreshToken)
        await MainActor.run { KeychainStore.setCodexCredentials(refreshed) }
        return (refreshed.accessToken, refreshed.accountId)
    }
}

// MARK: - Claude Code (Anthropic subscription) OAuth
//
// Lets a user drive Nugumi with their Claude Pro/Max subscription instead of a
// pay-as-you-go Anthropic API key. Uses the Claude Code OAuth client + PKCE
// flow and the *native* /v1/messages API (the OpenAI-compat endpoint used by
// the `.anthropic` API-key provider does not accept OAuth Bearer tokens).
//
// NOTE: Anthropic restricts subscription OAuth to its own first-party clients;
// using it here means presenting as Claude Code (the claude-code beta header +
// claude-cli user-agent). The maintainer accepted this trade-off deliberately.

/// Sign-in result, mirroring CodexLoginAlert.Outcome's shape.
enum ClaudeCodeSignInOutcome {
    case success
    case cancelled
    case failed(String)
}

struct ClaudeCodeCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    func isExpiring(within seconds: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow < seconds
    }
}

extension KeychainStore {
    private static var claudeCodeCache: ClaudeCodeCredentials?
    private static var claudeCodeCacheLoaded = false
    private static let claudeCodeFileName = "anthropic.claudecode.tokens.json"

    private static var claudeCodeFileURL: URL {
        storageDirectory.appending(path: claudeCodeFileName, directoryHint: .notDirectory)
    }

    static func claudeCodeCredentials() -> ClaudeCodeCredentials? {
        if claudeCodeCacheLoaded { return claudeCodeCache }
        claudeCodeCacheLoaded = true
        guard let data = try? Data(contentsOf: claudeCodeFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        claudeCodeCache = try? decoder.decode(ClaudeCodeCredentials.self, from: data)
        return claudeCodeCache
    }

    static func setClaudeCodeCredentials(_ creds: ClaudeCodeCredentials?) {
        guard let creds else {
            try? FileManager.default.removeItem(at: claudeCodeFileURL)
            claudeCodeCache = nil
            claudeCodeCacheLoaded = true
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(creds) {
            try? data.write(to: claudeCodeFileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: claudeCodeFileURL.path
            )
        }
        claudeCodeCache = creds
        claudeCodeCacheLoaded = true
    }
}

/// PKCE-based OAuth against the Claude Code client. The authorize-URL +
/// manual-paste-code variant (no local callback server): the user approves in
/// the browser, Anthropic shows a `code#state` string, they paste it back.
actor ClaudeCodeOAuthClient {
    static let shared = ClaudeCodeOAuthClient()

    fileprivate static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    fileprivate static let authorizeEndpoint = "https://claude.ai/oauth/authorize"
    fileprivate static let tokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
    fileprivate static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    fileprivate static let scope = "org:create_api_key user:profile user:inference"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    struct PKCE {
        let verifier: String
        let challenge: String
        let state: String
    }

    enum AuthError: LocalizedError {
        case network(String)
        case server(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .network(let d): "Network error: \(d)"
            case .server(let code, let d): "Sign-in failed (HTTP \(code)): \(d.prefix(200))"
            case .malformedResponse(let d): "Unexpected response: \(d)"
            }
        }
    }

    /// Pure/sync — the UI builds the authorize URL on the main actor before any
    /// network work. Static members of an actor are not actor-isolated.
    static func makePKCE() -> PKCE {
        let verifier = randomURLSafe(byteCount: 64)
        let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(byteCount: 32)
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    static func authorizeURL(pkce: PKCE) -> URL {
        var comps = URLComponents(string: authorizeEndpoint)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state)
        ]
        return comps.url!
    }

    /// Anthropic shows the user a `code#state` string. Tolerate a bare code too.
    func exchange(pastedCode: String, pkce: PKCE) async throws -> ClaudeCodeCredentials {
        let pieces = pastedCode.split(separator: "#", maxSplits: 1).map(String.init)
        let code = pieces[0]
        let state = pieces.count > 1 ? pieces[1] : pkce.state
        return try await postToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": pkce.verifier
        ])
    }

    func refresh(_ refreshToken: String) async throws -> ClaudeCodeCredentials {
        try await postToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ])
    }

    private func postToken(form: [String: String]) async throws -> ClaudeCodeCredentials {
        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: form)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let err as URLError {
            throw AuthError.network(err.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.malformedResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            throw AuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw AuthError.malformedResponse("missing access_token") }

        let refresh = (json["refresh_token"] as? String) ?? form["refresh_token"] ?? ""
        let expiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        return ClaudeCodeCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Refresh-on-demand token broker for the Claude Code inference path. Mirrors
/// CodexCredentialBroker: serialized on the shared actor, refreshes ~2 min
/// before expiry, wipes creds + forces re-login on a revoked refresh token.
enum ClaudeCodeCredentialBroker {
    static func resolveAccessToken() async throws -> String {
        guard let creds = KeychainStore.claudeCodeCredentials() else {
            throw TranslationError.invalidAPIKey(.anthropicClaudeCode)
        }
        if !creds.isExpiring(within: 120) { return creds.accessToken }
        do {
            let refreshed = try await ClaudeCodeOAuthClient.shared.refresh(creds.refreshToken)
            await MainActor.run { KeychainStore.setClaudeCodeCredentials(refreshed) }
            return refreshed.accessToken
        } catch let err as ClaudeCodeOAuthClient.AuthError {
            if case .server(let status, _) = err, status == 400 || status == 401 || status == 403 {
                await MainActor.run { KeychainStore.setClaudeCodeCredentials(nil) }
                throw TranslationError.invalidAPIKey(.anthropicClaudeCode)
            }
            throw TranslationError.cloudError(.anthropicClaudeCode, err.errorDescription ?? "auth error")
        }
    }

    static func forceRefresh() async throws -> String {
        guard let creds = KeychainStore.claudeCodeCredentials() else {
            throw TranslationError.invalidAPIKey(.anthropicClaudeCode)
        }
        let refreshed = try await ClaudeCodeOAuthClient.shared.refresh(creds.refreshToken)
        await MainActor.run { KeychainStore.setClaudeCodeCredentials(refreshed) }
        return refreshed.accessToken
    }
}

/// LLM client for the Claude subscription path: native Anthropic /v1/messages
/// (SSE) authed with the OAuth Bearer token + Claude Code beta headers. Reuses
/// the same prompt-building helpers as OpenAIChatClient; only the wire format
/// differs (native content blocks + `content_block_delta` stream events).
struct ClaudeCodeClient: LLMBackend {
    let model: String
    private let provider = CloudProvider.anthropicClaudeCode

    private static let maxImageBytes = 5 * 1024 * 1024
    /// Identity prefix Claude Code conventionally sends as its first system
    /// block. Convention, not a hard auth gate for tool-less calls — but cheap.
    private static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        case .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // Already composed deliberately (labeled sections) — don't let the
            // selection cleaner collapse the structure the prompt relies on.
            sourceText = text
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }
        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        let userContent = Self.contentBlocks(text: sourceText, images: images)
        return try await stream(
            systemPrompt: systemPrompt,
            messages: [["role": "user", "content": userContent]],
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )
    }

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if let image {
            guard image.data.count <= Self.maxImageBytes else {
                throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
            }
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }

        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        let prompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        messages.append([
            "role": "user",
            "content": Self.contentBlocks(text: prompt, images: image.map { [$0] } ?? [])
        ])

        let answer = try await stream(
            systemPrompt: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled),
            messages: messages,
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )
        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else { throw TranslationError.emptyResponse }
        return parsed
    }

    /// Native content array: a text block plus one image block per attachment.
    private static func contentBlocks(text: String, images: [ImageInput]) -> [[String: Any]] {
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        for image in images {
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.base64String
                ]
            ])
        }
        return blocks
    }

    /// Extended thinking budget per level; nil = no thinking block. Native
    /// `thinking` replaces the compat `reasoning_effort` knob. max_tokens must
    /// stay above the budget (it does — see `maxTokens`).
    private static func thinkingBlock(for level: ThinkingLevel) -> [String: Any]? {
        switch level {
        case .low:    return nil
        case .medium: return ["type": "enabled", "budget_tokens": 4096]
        case .high:   return ["type": "enabled", "budget_tokens": 8192]
        }
    }
    private static let maxTokens = 16384

    private func stream(
        systemPrompt: String,
        messages: [[String: Any]],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        // One transparent refresh-and-retry on a 401 (token revoked mid-flight),
        // matching the Codex client's resilience.
        do {
            return try await send(systemPrompt: systemPrompt, messages: messages,
                                  thinkingLevel: thinkingLevel, onPartial: onPartial)
        } catch TranslationError.invalidAPIKey {
            _ = try? await ClaudeCodeCredentialBroker.forceRefresh()
            return try await send(systemPrompt: systemPrompt, messages: messages,
                                  thinkingLevel: thinkingLevel, onPartial: onPartial)
        }
    }

    private func send(
        systemPrompt: String,
        messages: [[String: Any]],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let token = try await ClaudeCodeCredentialBroker.resolveAccessToken()

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": [
                ["type": "text", "text": Self.claudeCodeIdentity],
                ["type": "text", "text": systemPrompt]
            ],
            "messages": messages
        ]
        if let thinking = Self.thinkingBlock(for: thinkingLevel) {
            body["thinking"] = thinking
        }

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(
            "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }
        switch httpResponse.statusCode {
        case 200..<300: break
        case 401, 403: throw TranslationError.invalidAPIKey(provider)
        case 429:      throw TranslationError.rateLimited(provider)
        case 402:      throw TranslationError.outOfCredits(provider)
        default:
            let body = await CloudHTTPError.readBody(bytes)
            throw TranslationError.cloudError(
                provider,
                CloudHTTPError.detail(status: httpResponse.statusCode, body: body)
            )
        }

        // Native SSE: lines like `event: content_block_delta` / `data: {…}`.
        // Only `text_delta` deltas carry visible output; thinking deltas and
        // lifecycle events are ignored.
        var answer = ""
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch json["type"] as? String {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String, !text.isEmpty {
                    answer += text
                    onPartial(answer)
                }
            case "message_stop":
                return answer
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String
                throw TranslationError.cloudError(provider, message ?? "stream error")
            default:
                continue
            }
        }
        return answer
    }
}

// MARK: Discovered Codex models (live API + cached fallback)

/// Thread-safe cache of Codex model slugs discovered from
/// chatgpt.com/backend-api/codex/models. Falls back to the Hermes-curated
/// list when discovery hasn't run yet. Lives outside any actor so
/// `LLMModel.codexModels` can be read from any thread that builds the
/// menu / dispatches a backend.
enum CodexModelCache {
    /// Hermes' curated fallback (hermes_cli/codex_models.py DEFAULT_CODEX_MODELS).
    /// Used until live discovery succeeds.
    static let fallbackSlugs: [String] = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex-mini"
    ]

    private static let cacheKey = "codex.discoveredModels.v1"
    private static let lock = NSLock()
    private static var memo: [String]?

    static var slugs: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let memo { return memo }
        let stored = UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
        let resolved = stored.isEmpty ? fallbackSlugs : stored
        memo = resolved
        return resolved
    }

    static func update(_ slugs: [String]) {
        lock.lock()
        memo = slugs
        lock.unlock()
        UserDefaults.standard.set(slugs, forKey: cacheKey)
        NotificationCenter.default.post(name: .codexModelsUpdated, object: nil)
    }

    static func clear() {
        lock.lock()
        memo = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        NotificationCenter.default.post(name: .codexModelsUpdated, object: nil)
    }
}

enum CodexModelDiscovery {
    /// Live fetch + cache. Best-effort: failure leaves the cache untouched.
    static func refreshFromAPI() async {
        let token: String
        do {
            token = try await CodexCredentialBroker.resolveAccessToken().token
        } catch {
            return
        }
        var req = URLRequest(url: CloudProvider.openAICodex.modelsURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in OpenAICodexClient.cloudflareHeaders(accessToken: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["models"] as? [[String: Any]]
        else { return }

        struct Entry { let slug: String; let priority: Int }
        var parsed: [Entry] = []
        for item in entries {
            guard let slug = (item["slug"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !slug.isEmpty
            else { continue }
            // Surface every returned model except the review-only variants
            // (codex-auto-review) — they're not chat models and error if picked
            // for translation.
            if slug.contains("auto-review") { continue }
            let priority: Int = {
                if let n = item["priority"] as? Int { return n }
                if let n = item["priority"] as? Double { return Int(n) }
                return 10_000
            }()
            parsed.append(Entry(slug: slug, priority: priority))
        }
        guard !parsed.isEmpty else { return }
        parsed.sort { $0.priority == $1.priority ? $0.slug < $1.slug : $0.priority < $1.priority }
        CodexModelCache.update(parsed.map(\.slug))
    }
}

// MARK: Discovered API-key cloud models (live /models + cached fallback)

/// Discovery for the three API-key providers (OpenAI, Anthropic, Gemini).
/// Same contract as CodexModelDiscovery: best-effort, failures never touch
/// the cache, the curated LLMModel.all entries remain the permanent floor.
enum CloudModelDiscovery {
    struct DiscoveredModel: Equatable {
        let id: String
        /// Provider-supplied pretty name (Anthropic's `display_name`).
        /// nil for providers whose list API returns bare ids.
        let displayName: String?
    }

    /// Substrings that mark an OpenAI id as non-chat or Codex-only. `-pro`
    /// models (gpt-5-pro, gpt-5.2-pro, …) are Responses-API-only and reject
    /// /v1/chat/completions with "not a chat model" — our client only speaks
    /// chat/completions, so drop them.
    private static let openAIDropMarkers = [
        "-audio", "-realtime", "-search", "-tts", "-transcribe", "-image", "-codex", "-pro"
    ]
    /// Substrings that mark a Gemini id as non-chat. Dash-anchored so a
    /// marker can't match inside an unrelated word (e.g. "-live" skips
    /// "gemini-live-2.5-flash" but not a hypothetical "gemini-alive").
    private static let geminiDropMarkers = [
        "-embedding", "-tts", "-image", "-live", "-audio"
    ]
    /// OpenRouter lists 300+ models. Keep recognizable chat vendors plus ANY
    /// `:free` model (free-ness is its own reason to surface it), and drop
    /// non-chat variants so the picker isn't flooded.
    private static let openRouterVendorAllowlist = [
        "openai/", "anthropic/", "google/", "x-ai/", "meta-llama/",
        "mistralai/", "deepseek/", "qwen/"
    ]
    private static let openRouterDropMarkers = [
        "-image", "-tts", "-audio", "-embedding",
        "-search", "-realtime", "-transcribe", "-codex"
    ]

    /// Parse a provider's `/models` response body into chat-capable models,
    /// in response order. All three providers use the OpenAI-style
    /// `{"data": [{"id": ...}]}` envelope (Anthropic adds `display_name`).
    /// Unknown payloads and the OAuth-only Codex provider yield [].
    static func parse(provider: CloudProvider, data: Data) -> [DiscoveredModel] {
        guard provider != .openAICodex,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return [] }

        var out: [DiscoveredModel] = []
        for item in entries {
            guard var id = (item["id"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty
            else { continue }
            switch provider {
            case .openAI:
                // gpt-5 and newer text-chat families only.
                guard id.hasPrefix("gpt-5") || id.hasPrefix("gpt-6"),
                      !openAIDropMarkers.contains(where: id.contains)
                else { continue }
            case .anthropic, .anthropicClaudeCode:
                guard id.hasPrefix("claude-") else { continue }
            case .gemini:
                if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }
                guard id.hasPrefix("gemini-"),
                      !geminiDropMarkers.contains(where: id.contains)
                else { continue }
            case .openRouter:
                let isFree = id.hasSuffix(":free")
                guard isFree || openRouterVendorAllowlist.contains(where: id.hasPrefix),
                      !openRouterDropMarkers.contains(where: id.contains)
                else { continue }
            case .openAICodex:
                // ChatGPT subscription uses its own codex/models endpoint
                // (CodexModelDiscovery), not the OpenAI /v1/models list.
                continue
            }
            // OpenRouter supplies a pretty `name`; the others use `display_name`.
            var pretty = (provider == .openRouter ? item["name"] : item["display_name"]) as? String
            // Tag free models so the picker shows it. OpenRouter's `name` almost
            // always already ends in "(free)" — guarantee it when it doesn't.
            if provider == .openRouter, id.hasSuffix(":free") {
                let base = pretty ?? id
                pretty = base.lowercased().contains("free") ? base : "\(base) (free)"
            }
            out.append(DiscoveredModel(id: id, displayName: pretty))
        }
        return out
    }

    /// Anthropic pins releases with a trailing -YYYYMMDD date stamp
    /// (claude-haiku-4-5-20251001). Strip it so a curated dated id and the
    /// API's undated alias (or vice versa) compare equal.
    static func canonicalID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return parts.dropLast().joined(separator: "-")
        }
        return id
    }

    /// Human-readable name for a discovered model with no curated entry.
    /// Matches the curated naming style per provider: "GPT-5.6 mini",
    /// "Claude Opus 4.8", "Gemini 3.0 Pro". Tier hints ("fast", "flagship")
    /// are curated-only — we can't infer them from an id.
    static func prettyName(provider: CloudProvider, id: String) -> String {
        switch provider {
        case .openAI, .openAICodex:
            // gpt-5.6-mini → GPT-5.6 mini
            var name = id
            if name.hasPrefix("gpt-") { name = "GPT-" + name.dropFirst("gpt-".count) }
            return name.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "GPT ", with: "GPT-")
        case .anthropic, .anthropicClaudeCode:
            // claude-opus-4-8 → Claude Opus 4.8 (numeric tail joins with dots)
            let parts = canonicalID(id).split(separator: "-").map(String.init)
            var words: [String] = []
            for part in parts {
                if part.allSatisfy({ $0.isASCII && $0.isNumber }), let last = words.last,
                   last.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) {
                    words[words.count - 1] = last + "." + part
                } else {
                    words.append(part.capitalized)
                }
            }
            return words.joined(separator: " ")
        case .gemini:
            // gemini-2.5-flash-lite → Gemini 2.5 Flash Lite
            return id.split(separator: "-")
                .map { $0.first?.isNumber == true ? String($0) : String($0).capitalized }
                .joined(separator: " ")
        case .openRouter:
            // ids are "vendor/model"; the API's `name` is preferred upstream,
            // so this fallback only fires if `name` is absent — the slug reads
            // well enough.
            return id
        }
    }

    /// Launch-time refresh for every provider with a stored key. Best-effort:
    /// any failure (no key, network, non-200, unparseable body) leaves the
    /// cache untouched. Same contract as CodexModelDiscovery.refreshFromAPI.
    static func refreshAll() async {
        // KeychainStore's in-memory cache is main-actor-confined everywhere
        // else; read the keys there, then do the network work off-actor.
        let credentials: [(CloudProvider, String)] = await MainActor.run {
            [CloudProvider.openAI, .anthropic, .gemini, .openRouter].compactMap { provider in
                guard let key = KeychainStore.apiKey(for: provider), !key.isEmpty else { return nil }
                return (provider, key)
            }
        }
        for (provider, key) in credentials {
            var request = URLRequest(url: provider.modelsURL)
            request.httpMethod = "GET"
            switch provider {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200
            else { continue }
            CloudModelCache.update(provider: provider, models: parse(provider: provider, data: data))
        }
        await refreshClaudeCode()
    }

    /// Claude Code (OAuth subscription) has no dedicated models endpoint, so
    /// try the standard Anthropic /v1/models with the OAuth bearer + Claude Code
    /// headers. If the inference-only OAuth scope forbids the list call, the
    /// request 401s (or the body is unparseable) and the cache is left
    /// untouched — the curated Claude Code entries in LLMModel.all stay the
    /// floor. No-ops silently when the user isn't signed in.
    static func refreshClaudeCode() async {
        let token: String
        do {
            token = try await ClaudeCodeCredentialBroker.resolveAccessToken()
        } catch {
            return
        }
        var request = URLRequest(url: CloudProvider.anthropicClaudeCode.modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200
        else { return }
        CloudModelCache.update(
            provider: .anthropicClaudeCode,
            models: parse(provider: .anthropicClaudeCode, data: data)
        )
    }
}

/// Thread-safe per-provider cache of model ids discovered from the
/// API-key providers' /models endpoints, persisted to UserDefaults.
/// nil (never fetched) and "fetched" are distinct states: merge logic
/// falls back to the curated list only in the former. Lives outside any
/// actor so LLMModel.cloudModels(for:) can be read from any thread that
/// builds the menu / dispatches a backend.
enum CloudModelCache {
    private static let lock = NSLock()
    private static var memoIDs: [CloudProvider: [String]] = [:]
    private static var memoNames: [CloudProvider: [String: String]] = [:]

    private static func idsKey(_ p: CloudProvider) -> String { "cloud.discoveredModels.\(p.rawValue).v1" }
    private static func namesKey(_ p: CloudProvider) -> String { "cloud.discoveredNames.\(p.rawValue).v1" }

    /// Discovered models for one provider, or nil if discovery has never
    /// succeeded for it (curated fallback applies).
    static func discovered(for provider: CloudProvider) -> [CloudModelDiscovery.DiscoveredModel]? {
        lock.lock()
        defer { lock.unlock() }
        let ids: [String]
        if let memo = memoIDs[provider] {
            ids = memo
        } else if let stored = UserDefaults.standard.stringArray(forKey: idsKey(provider)) {
            memoIDs[provider] = stored
            ids = stored
        } else {
            return nil
        }
        let names = memoNames[provider]
            ?? (UserDefaults.standard.dictionary(forKey: namesKey(provider)) as? [String: String])
            ?? [:]
        memoNames[provider] = names
        return ids.map { .init(id: $0, displayName: names[$0]) }
    }

    static func update(provider: CloudProvider, models: [CloudModelDiscovery.DiscoveredModel]) {
        guard provider != .openAICodex, !models.isEmpty else { return }
        let ids = models.map(\.id)
        var names: [String: String] = [:]
        for m in models { names[m.id] = m.displayName }
        lock.lock()
        let changed = memoIDs[provider] != ids || memoNames[provider] != names
        memoIDs[provider] = ids
        memoNames[provider] = names
        if changed {
            // Persist inside the lock so memo and UserDefaults can't diverge
            // when two providers refresh concurrently. UserDefaults writes are
            // fast in-process mutations; the daemon sync is asynchronous.
            UserDefaults.standard.set(ids, forKey: idsKey(provider))
            UserDefaults.standard.set(names, forKey: namesKey(provider))
        }
        lock.unlock()
        guard changed else { return }
        NotificationCenter.default.post(name: .cloudModelsUpdated, object: nil)
    }
}

extension Notification.Name {
    static let codexModelsUpdated = Notification.Name("com.nugumi.codex.modelsUpdated")
    static let ollamaModelsUpdated = Notification.Name("com.nugumi.ollama.modelsUpdated")
    static let cloudModelsUpdated = Notification.Name("com.nugumi.cloud.modelsUpdated")
    static let updateAvailabilityChanged = Notification.Name("com.nugumi.updateAvailabilityChanged")
}

// MARK: Discovered Ollama models (live /api/tags + cached fallback)

/// Thread-safe cache of Ollama model names discovered from the running
/// server's `/api/tags`. Fed by OllamaBootstrap's existing tags request (see
/// Bootstrap.swift `modelsPresent()`), persisted to UserDefaults so the menu
/// has something to show before the first refresh lands. Lives outside any
/// actor so `LLMModel.ollamaModels` can be read from any thread.
enum OllamaModelCache {
    private static let cacheKey = "ollama.discoveredModels.v1"
    private static let visionKey = "ollama.visionModels.v1"
    private static let lock = NSLock()
    private static var memoNames: [String]?
    private static var memoVision: Set<String>?

    /// Model names from the last successful `/api/tags`. Empty until the
    /// server is reachable.
    static var discovered: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let memoNames { return memoNames }
        let stored = UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
        memoNames = stored
        return stored
    }

    /// Names the server reported as vision-capable (`/api/show` capabilities
    /// include "vision"). Drives `supportsImages` so only these appear in the
    /// vision-only Ask Nugumi picker.
    static var visionCapable: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let memoVision { return memoVision }
        let stored = Set(UserDefaults.standard.stringArray(forKey: visionKey) ?? [])
        memoVision = stored
        return stored
    }

    static func update(names: [String], vision: Set<String>) {
        lock.lock()
        let changed = memoNames != names || memoVision != vision
        memoNames = names
        memoVision = vision
        lock.unlock()
        guard changed else { return }
        UserDefaults.standard.set(names, forKey: cacheKey)
        UserDefaults.standard.set(Array(vision), forKey: visionKey)
        NotificationCenter.default.post(name: .ollamaModelsUpdated, object: nil)
    }
}

// MARK: OpenAICodexClient — Responses API + Cloudflare allow-list headers

/// Talks to chatgpt.com/backend-api/codex/responses on behalf of a
/// ChatGPT Plus/Pro subscriber. Sits behind Cloudflare which 403s any
/// request that doesn't advertise an allow-listed `originator` — we pin
/// `codex_cli_rs` (the value the Rust Codex CLI uses), the matching
/// User-Agent shape, and a `ChatGPT-Account-ID` extracted from the JWT.
/// All three are required; dropping any one trips the WAF.
struct OpenAICodexClient: LLMBackend {
    let apiModelID: String
    private static let maxImageBytes = 5 * 1024 * 1024

    /// Pulls a user-facing error message out of an OpenAI error JSON body.
    /// Accepts both `{"error": {"message": "…"}}` and `{"error": "…"}` shapes.
    private func extractOpenAIErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = obj["error"] as? [String: Any] {
            if let m = err["message"] as? String, !m.isEmpty { return m }
        } else if let s = obj["error"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    /// Headers that mimic the Rust Codex CLI so Cloudflare doesn't block us.
    /// Extracted as a static helper so model discovery can reuse them.
    static func cloudflareHeaders(accessToken: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "codex_cli_rs/0.0.0 (Nugumi)",
            "originator": "codex_cli_rs"
        ]
        let claims = CodexJWT.decode(accessToken)
        if let acct = claims.accountId, !acct.isEmpty {
            headers["ChatGPT-Account-ID"] = acct
        }
        return headers
    }

    func translate(
        _ text: String,
        images: [ImageInput],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        case .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // Already composed deliberately (labeled sections) — don't let the
            // selection cleaner collapse the structure the prompt relies on.
            sourceText = text
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }
        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(.openAICodex, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        // TEMP DIAGNOSTIC (voice-sample issue) — remove once resolved.
        CodexDebugLog.append("[voice-debug] codex mode=\(mode) promptHasVoice=\(systemPrompt.contains("Voice sample —")) promptChars=\(systemPrompt.count)")
        let userContent: [CodexInputContent] = {
            var parts: [CodexInputContent] = [.text(sourceText, role: "user")]
            parts.append(contentsOf: images.map { .image($0.openAIDataURI) })
            return parts
        }()
        let body = CodexResponsesRequest(
            model: apiModelID,
            instructions: systemPrompt,
            input: [CodexInputItem(role: "user", content: userContent)],
            stream: true,
            store: false,
            reasoning: CodexReasoningConfig(effort: thinkingLevel.cloudReasoningEffort)
        )

        var streamed = ""
        try await runStreaming(body: body, timeoutInterval: 25) { delta in
            streamed += delta
            let partial = TextNormalizer.cleanedTranslation(streamed)
            if !partial.isEmpty { onPartial(partial) }
        }
        let final = TextNormalizer.cleanedTranslation(streamed)
        guard !final.isEmpty else { throw TranslationError.emptyResponse }
        return final
    }

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if let image, image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(.openAICodex, "Image too large (limit 5 MB)")
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }
        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)

        var items: [CodexInputItem] = []
        for turn in history {
            items.append(CodexInputItem(role: "user", content: [.text(turn.question, role: "user")]))
            items.append(CodexInputItem(role: "assistant", content: [.text(turn.answer, role: "assistant")]))
        }
        var currentContent: [CodexInputContent] = [.text(currentPrompt, role: "user")]
        if let image { currentContent.append(.image(image.openAIDataURI)) }
        items.append(CodexInputItem(role: "user", content: currentContent))

        let body = CodexResponsesRequest(
            model: apiModelID,
            instructions: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled),
            input: items,
            stream: true,
            store: false,
            reasoning: CodexReasoningConfig(effort: thinkingLevel.cloudReasoningEffort)
        )

        var answer = ""
        try await runStreaming(body: body, timeoutInterval: 60) { delta in
            answer += delta
            onPartial(answer)
        }
        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else { throw TranslationError.emptyResponse }
        return parsed
    }

    // MARK: Streaming transport (Responses API SSE)

    private func runStreaming(
        body: CodexResponsesRequest,
        timeoutInterval: TimeInterval,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let encoded = try JSONEncoder().encode(body)
        do {
            try await performStreamingRequest(encodedBody: encoded, timeoutInterval: timeoutInterval, allowRefresh: true, onDelta: onDelta)
        } catch TranslationError.invalidAPIKey(.openAICodex) {
            // One transparent retry after a forced refresh — covers tokens
            // revoked between our last JWT-exp check and the actual request.
            try await performStreamingRequest(encodedBody: encoded, timeoutInterval: timeoutInterval, allowRefresh: false, onDelta: onDelta)
        }
    }

    private func performStreamingRequest(
        encodedBody: Data,
        timeoutInterval: TimeInterval,
        allowRefresh: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let (token, accountId) = try await CodexCredentialBroker.resolveAccessToken()
        CodexDebugLog.append("inference: POST /responses (model=\(apiModelID), account=\(accountId ?? "nil"), bodyBytes=\(encodedBody.count))")

        var request = URLRequest(url: CloudProvider.openAICodex.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        for (k, v) in Self.cloudflareHeaders(accessToken: token) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // chatgpt.com/backend-api/codex/responses returns response headers in
        // <2s when healthy; when it black-holes, it black-holes forever.
        // Translate uses 25s (fast iteration); Ask uses 60s (longer responses,
        // more typing invested in the question).
        request.timeoutInterval = timeoutInterval
        request.httpBody = encodedBody

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            CodexDebugLog.append("inference: URLError \(urlError.code.rawValue) — \(urlError.localizedDescription)")
            // The subscription endpoint sometimes drops individual requests
            // upstream — be explicit about that so users don't think Nugumi
            // is broken.
            let message: String
            if urlError.code == .notConnectedToInternet {
                message = "No internet connection."
            } else {
                message = "Sometimes drops requests - just try one more time."
            }
            throw TranslationError.cloudError(.openAICodex, message)
        }

        guard let http = response as? HTTPURLResponse else {
            CodexDebugLog.append("inference: non-HTTP response")
            throw TranslationError.cloudError(.openAICodex, "invalid response")
        }
        CodexDebugLog.append("inference: status=\(http.statusCode)")
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // Drain the body so we can show OpenAI's actual error message —
            // 401/403 from the Codex endpoint for free accounts surfaces as
            // a JSON body with a useful explanation we should pass through
            // rather than swallowing as "rejected the API key."
            var bodyData = Data()
            for try await chunk in bytes { bodyData.append(chunk) }
            let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(800) ?? ""
            CodexDebugLog.append("inference: \(http.statusCode) body=\(bodyPreview)")
            if http.statusCode == 401, allowRefresh {
                _ = try? await CodexCredentialBroker.forceRefresh()
                throw TranslationError.invalidAPIKey(.openAICodex)
            }
            // Try to extract a human-readable message from OpenAI's error JSON.
            let detail = extractOpenAIErrorMessage(from: bodyData) ?? CloudHTTPError.friendlyMessage(status: http.statusCode)
            throw TranslationError.cloudError(.openAICodex, detail)
        case 429:
            throw TranslationError.rateLimited(.openAICodex)
        default:
            var bodyData = Data()
            for try await chunk in bytes { bodyData.append(chunk) }
            let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(800) ?? ""
            CodexDebugLog.append("inference: \(http.statusCode) body=\(bodyPreview)")
            let detail = extractOpenAIErrorMessage(from: bodyData) ?? CloudHTTPError.friendlyMessage(status: http.statusCode)
            throw TranslationError.cloudError(.openAICodex, detail)
        }

        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") || line.hasPrefix("event:") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let chunk = try? decoder.decode(CodexResponsesStreamEvent.self, from: data) {
                if chunk.type == "response.output_text.delta", let delta = chunk.delta, !delta.isEmpty {
                    onDelta(delta)
                } else if chunk.type == "response.completed" {
                    break
                } else if chunk.type == "response.error" || chunk.type == "error" {
                    let msg = chunk.message ?? chunk.error?.message ?? "stream error"
                    throw TranslationError.cloudError(.openAICodex, msg)
                }
            }
        }
    }
}

// MARK: Codex Responses API wire types

private struct CodexResponsesRequest: Encodable {
    let model: String
    let instructions: String?
    let input: [CodexInputItem]
    let stream: Bool
    let store: Bool
    let reasoning: CodexReasoningConfig?
}

private struct CodexReasoningConfig: Encodable {
    let effort: String
}

private struct CodexInputItem: Encodable {
    let role: String
    let content: [CodexInputContent]
}

private enum CodexInputContent: Encodable {
    case text(String, role: String)
    case image(String) // data: URI

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s, let role):
            try c.encode(role == "assistant" ? "output_text" : "input_text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let url):
            try c.encode("input_image", forKey: .type)
            try c.encode(url, forKey: .image_url)
        }
    }
}

private struct CodexResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let message: String?
    let error: CodexResponsesStreamError?
}

private struct CodexResponsesStreamError: Decodable {
    let message: String?
}

// MARK: Codex login UI (device-code alert)

/// Modal NSAlert that drives the device-code dance:
///   1. Calls /api/accounts/deviceauth/usercode to get a code + interval.
///   2. Shows the code + URL with copy/open buttons.
///   3. Polls /api/accounts/deviceauth/token until the user finishes sign-in
///      in their browser (or until 15-minute timeout / Cancel).
///   4. On success, persists CodexCredentials to Keychain and dismisses
///      the alert programmatically via NSApp.stopModal.
/// ChatGPT (Codex) device-flow sign-in, shown as a compact floating panel.
///
/// Deliberately NOT an `NSAlert.runModal`: the app-modal alert activated
/// Nugumi on every click, yanking the main window in front of the browser
/// page the user was trying to sign in with. A `.nonactivatingPanel` floats
/// above the browser, takes clicks without activating the app, and needs no
/// nested modal run loop — completion is a plain continuation.
@MainActor
final class CodexLoginAlert: NSObject {
    enum Outcome {
        case success(CodexCredentials)
        case cancelled
        case failed(String)
    }

    private var panel: NSPanel?
    private var pollTask: Task<Void, Never>?
    private var verificationURL: URL!
    private var userCode: String!
    /// Resumes `run()`'s continuation exactly once, whichever finishes first
    /// (successful poll, poll failure, or Cancel).
    private var finish: ((Outcome) -> Void)?

    static func present() async -> Outcome {
        let controller = CodexLoginAlert()
        return await controller.run()
    }

    private func run() async -> Outcome {
        // Step 1: one-time prerequisite. The device-code flow only works once
        // the user has enabled "device code authorization for Codex" in ChatGPT
        // settings. Open that page for them and gate the code step on Done.
        let settingsURL = URL(string: "https://chatgpt.com/#settings/Security")!
        NSWorkspace.shared.open(settingsURL)
        let proceed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let resolve: (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            presentPrereqPanel(
                openSettings: { NSWorkspace.shared.open(settingsURL) },
                done: { resolve(true) },
                cancel: { resolve(false) }
            )
        }
        closePanel()
        guard proceed else { return .cancelled }

        let start: CodexOAuthClient.DeviceCodeStart
        do {
            start = try await CodexOAuthClient.shared.startDeviceCode()
        } catch {
            return .failed("Couldn't start sign-in: \(error.localizedDescription)")
        }

        verificationURL = start.verificationURL
        userCode = start.userCode

        // Open the browser WITHOUT activating Nugumi — the sign-in page must
        // stay in front; the panel floats above it.
        NSWorkspace.shared.open(start.verificationURL)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            var resumed = false
            finish = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }

            CodexDebugLog.append("CodexLoginAlert: launching poll task")
            pollTask = Task { [weak self] in
                do {
                    let creds = try await CodexOAuthClient.shared.pollForTokens(
                        deviceAuthID: start.deviceAuthID,
                        userCode: start.userCode,
                        interval: start.pollInterval
                    )
                    // Persist before resuming so the caller always finds them.
                    KeychainStore.setCodexCredentials(creds)
                    CodexDebugLog.append("CodexLoginAlert: tokens persisted")
                    self?.finish?(.success(creds))
                } catch is CancellationError {
                    CodexDebugLog.append("CodexLoginAlert: poll cancelled")
                } catch {
                    CodexDebugLog.append("CodexLoginAlert: poll failed — \(error)")
                    self?.finish?(.failed(error.localizedDescription))
                }
            }

            presentPanel()
        }

        pollTask?.cancel()
        finish = nil
        closePanel()

        if case .success = outcome {
            // Fire-and-forget model discovery so the menu reflects this
            // account's catalog (Plus vs Pro see different lineups).
            Task.detached { await CodexModelDiscovery.refreshFromAPI() }
        }
        return outcome
    }

    private func presentPanel() {
        presentHosting(NSHostingView(rootView: CodexLoginPanelView(
            code: userCode,
            openPage: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.verificationURL)
            },
            cancel: { [weak self] in
                self?.finish?(.cancelled)
            }
        )))
    }

    private func presentPrereqPanel(
        openSettings: @escaping () -> Void,
        done: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        presentHosting(NSHostingView(rootView: CodexEnableDeviceCodeView(
            openSettings: openSettings,
            done: done,
            cancel: cancel
        )))
    }

    /// Shared chrome for the sign-in panels — a borderless dark HUD that floats
    /// above the browser without stealing focus. Used for both the prerequisite
    /// step and the device-code step.
    private func presentHosting<Content: View>(_ hosting: NSHostingView<Content>) {
        self.panel = SignInHUD.makePanel(hosting: hosting, title: "Sign in with ChatGPT")
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// First step of ChatGPT sign-in: the device-code flow only works once the user
/// has enabled it in ChatGPT settings, so walk them through it — with a
/// screenshot of the exact toggle — and gate the code step on a Done click.
private struct CodexEnableDeviceCodeView: View {
    let openSettings: () -> Void
    let done: () -> Void
    let cancel: () -> Void

    private static let mint = Color(red: 0.67, green: 0.93, blue: 0.88)

    private var settingImage: NSImage? {
        Bundle.module.url(forResource: "codex-device-code-setting", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One quick step in ChatGPT")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("We opened ChatGPT's Security settings. Scroll down, turn on the toggle below, then come back and press Done.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            if let image = settingImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
            }

            HStack(spacing: 10) {
                Button(action: openSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Open settings")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Self.mint)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                Button(action: cancel) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(height: 28)
                        .padding(.horizontal, 16)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Button(action: done) {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(height: 28)
                        .padding(.horizontal, 20)
                        .background(Capsule().fill(Self.mint))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Compact content for the sign-in panel: one-line explanation, the code in a
/// selectable chip with a copy icon, and a status/cancel row.
private struct CodexLoginPanelView: View {
    let code: String
    let openPage: () -> Void
    let cancel: () -> Void

    @State private var copied = false

    private static let mint = Color(red: 0.67, green: 0.93, blue: 0.88)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in with ChatGPT")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
            Text("On the page that opened:")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.66))
            VStack(alignment: .leading, spacing: 5) {
                stepRow(1, "Log in to ChatGPT")
                stepRow(2, "Confirm it's you")
                stepRow(3, "Enter the code below, then press Continue")
            }

            HStack(spacing: 10) {
                Text(code)
                    .font(.system(size: 21, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.mint)
                    .textSelection(.enabled)
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied ? Self.mint : Color.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Text("Nugumi finishes the rest automatically once you continue.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: openPage) {
                    Text("Open page again")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Self.mint)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                ProgressView()
                    .controlSize(.small)
                Text("Waiting…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))

                Button(action: cancel) {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(16)
        .frame(width: 336)
    }

    @ViewBuilder
    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 15, height: 15)
                .background(Circle().fill(Self.mint))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
    }
}

// MARK: - Sign-in HUD chrome (shared by ChatGPT + Claude sign-in panels)

/// Builds the borderless dark HUD panel that floats above the browser without
/// stealing focus. Shared so the ChatGPT and Claude sign-in flows look identical.
enum SignInHUD {
    static let mint = Color(red: 0.67, green: 0.93, blue: 0.88)

    static func makePanel<Content: View>(hosting: NSHostingView<Content>, title: String) -> NSPanel {
        // The titled+fullSizeContentView panel reports the titlebar as a top
        // safe-area inset, which SwiftUI turns into ~28pt of dead air above the
        // content. The panel has no visible titlebar — drop the inset.
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        panel.contentView = backdrop

        let size = hosting.fittingSize
        panel.setContentSize(size)
        // Upper middle of the screen: visible alongside the browser without
        // covering the page content in the center.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.16
            ))
        }
        panel.orderFrontRegardless()
        return panel
    }

    /// Numbered mint step bullet + label, shared by both sign-in panels.
    @ViewBuilder
    static func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 15, height: 15)
                .background(Circle().fill(mint))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Claude (subscription) sign-in panel

/// Drives the Claude Code OAuth (PKCE) sign-in with the same floating HUD as the
/// ChatGPT flow: open the browser to the authorize URL, then the user pastes the
/// `code#state` Anthropic shows them. The panel stays up on a failed exchange so
/// they can fix the code and retry without restarting.
@MainActor
final class ClaudeCodeLoginAlert: NSObject {
    private var panel: NSPanel?
    private var finish: ((ClaudeCodeSignInOutcome) -> Void)?
    private var pkce: ClaudeCodeOAuthClient.PKCE!
    private let model = ClaudeCodeLoginModel()

    static func present() async -> ClaudeCodeSignInOutcome {
        await ClaudeCodeLoginAlert().run()
    }

    private func run() async -> ClaudeCodeSignInOutcome {
        pkce = ClaudeCodeOAuthClient.makePKCE()
        NSWorkspace.shared.open(ClaudeCodeOAuthClient.authorizeURL(pkce: pkce))

        model.onSignIn = { [weak self] in self?.submit() }
        model.onOpenPage = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(ClaudeCodeOAuthClient.authorizeURL(pkce: self.pkce))
        }
        model.onCancel = { [weak self] in self?.finish?(.cancelled) }

        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<ClaudeCodeSignInOutcome, Never>) in
            var resumed = false
            finish = { o in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: o)
            }
            panel = SignInHUD.makePanel(
                hosting: NSHostingView(rootView: ClaudeCodeLoginPanelView(model: model)),
                title: "Sign in with Claude"
            )
        }
        finish = nil
        panel?.orderOut(nil)
        panel = nil
        return outcome
    }

    private func submit() {
        let code = model.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, model.phase != .working else { return }
        model.phase = .working
        Task { @MainActor in
            do {
                let creds = try await ClaudeCodeOAuthClient.shared.exchange(pastedCode: code, pkce: pkce)
                KeychainStore.setClaudeCodeCredentials(creds)
                finish?(.success)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                model.phase = .error(message)
            }
        }
    }
}

@MainActor
final class ClaudeCodeLoginModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case error(String)
    }
    @Published var code: String = ""
    @Published var phase: Phase = .idle
    var onSignIn: () -> Void = {}
    var onOpenPage: () -> Void = {}
    var onCancel: () -> Void = {}
}

private struct ClaudeCodeLoginPanelView: View {
    @ObservedObject var model: ClaudeCodeLoginModel

    private var isWorking: Bool { model.phase == .working }
    private var errorText: String? {
        if case .error(let m) = model.phase { return m }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with Claude")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
            Text("In the browser tab that just opened:")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.66))

            VStack(alignment: .leading, spacing: 6) {
                SignInHUD.stepRow(1, "Approve access for Claude Code")
                SignInHUD.stepRow(2, "Copy the code Anthropic shows you")
                SignInHUD.stepRow(3, "Paste it below, then press Sign in")
            }

            TextField("Paste code here", text: $model.code)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(errorText == nil ? Color.white.opacity(0.12) : Color(red: 1, green: 0.5, blue: 0.45).opacity(0.6), lineWidth: 1)
                )
                .disabled(isWorking)
                .onSubmit { model.onSignIn() }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1, green: 0.58, blue: 0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: { model.onOpenPage() }) {
                    Text("Open page again")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SignInHUD.mint)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Signing in…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                Button(action: { model.onCancel() }) {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button(action: { model.onSignIn() }) {
                    Text("Sign in")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(SignInHUD.mint.opacity(model.code.isEmpty || isWorking ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(model.code.isEmpty || isWorking)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Cloud API key panel

/// Floating HUD for entering an API-key provider's key, matching the sign-in
/// panels. "Get a key" opens the provider's console and leaves the panel up so
/// the user can paste straight back. Validates on Save; an invalid key keeps the
/// panel open with the reason inline instead of relaunching a fresh modal.
@MainActor
final class CloudAPIKeyAlert: NSObject {
    enum Outcome {
        case saved
        case savedUnverified(String)
        case cancelled
    }

    private var panel: NSPanel?
    private var finish: ((Outcome) -> Void)?
    private let provider: CloudProvider
    private let model = CloudAPIKeyModel()

    private init(provider: CloudProvider) {
        self.provider = provider
        super.init()
    }

    static func present(provider: CloudProvider) async -> Outcome {
        await CloudAPIKeyAlert(provider: provider).run()
    }

    private func run() async -> Outcome {
        model.key = KeychainStore.apiKey(for: provider) ?? ""
        model.onSave = { [weak self] in self?.save() }
        model.onGetKey = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.provider.apiKeyHelpURL)
        }
        model.onCancel = { [weak self] in self?.finish?(.cancelled) }

        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            var resumed = false
            finish = { o in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: o)
            }
            panel = SignInHUD.makePanel(
                hosting: NSHostingView(rootView: CloudAPIKeyPanelView(model: model, providerName: provider.displayName)),
                title: "Connect \(provider.displayName)"
            )
        }
        finish = nil
        panel?.orderOut(nil)
        panel = nil
        return outcome
    }

    private func save() {
        let key = model.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, model.phase != .working else { return }
        model.phase = .working
        Task { @MainActor in
            switch await APIKeyValidator.validate(key, for: provider) {
            case .valid:
                KeychainStore.setAPIKey(key, for: provider)
                finish?(.saved)
            case .invalid(let reason):
                model.phase = .error(reason)
            case .networkUnreachable(let detail):
                // Save anyway so the user isn't stuck offline; the host shows a note.
                KeychainStore.setAPIKey(key, for: provider)
                finish?(.savedUnverified(detail))
            }
        }
    }
}

@MainActor
final class CloudAPIKeyModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case error(String)
    }
    @Published var key: String = ""
    @Published var phase: Phase = .idle
    var onSave: () -> Void = {}
    var onGetKey: () -> Void = {}
    var onCancel: () -> Void = {}
}

private struct CloudAPIKeyPanelView: View {
    @ObservedObject var model: CloudAPIKeyModel
    let providerName: String

    private var isWorking: Bool { model.phase == .working }
    private var errorText: String? {
        if case .error(let m) = model.phase { return m }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(providerName)")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
            Text("Paste your \(providerName) API key. It's stored locally on this Mac and only sent to \(providerName) for translation.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Paste your API key", text: $model.key)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(errorText == nil ? Color.white.opacity(0.12) : Color(red: 1, green: 0.5, blue: 0.45).opacity(0.6), lineWidth: 1)
                )
                .disabled(isWorking)
                .onSubmit { model.onSave() }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1, green: 0.58, blue: 0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: { model.onGetKey() }) {
                    Text("Get a key…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SignInHUD.mint)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                Button(action: { model.onCancel() }) {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button(action: { model.onSave() }) {
                    Text("Save")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(SignInHUD.mint.opacity(model.key.isEmpty || isWorking ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(model.key.isEmpty || isWorking)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Main window bridge

extension NugumiApp: SettingsHost {
    var usageStats: UsageStatsStore { usageStatsStore }
    var snippets: SnippetsStore { snippetsStore }
    var history: TranslationHistoryStore { translationHistoryStore }
    var isAppBundle: Bool { isRunningFromAppBundle }
    var appVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    var availableUpdateVersion: String? { availableUpdate?.displayVersionString }
    /// Resume the pending update session — Sparkle re-focuses the found update
    /// and shows its standard install dialog (release notes + Install).
    func installAvailableUpdate() { checkForUpdates() }

    func cloudProviderHasCredentials(_ provider: CloudProvider) -> Bool {
        provider.hasCredentials
    }

    var bootstrapState: BootstrapState { bootstrap.state }
    func refreshBootstrap() { bootstrap.refresh() }
    var ollamaModels: [OllamaModelOption] { bootstrap.models }

    func makeSettingsSnapshot() -> SettingsSnapshot {
        var styles: [AppCategory: WritingStyle] = [:]
        for category in AppCategory.allCases {
            styles[category] = writingStyle(for: category)
        }
        var shortcuts: [GlobalShortcutAction: GlobalShortcut] = [:]
        for action in GlobalShortcutAction.allCases {
            shortcuts[action] = shortcut(for: action)
        }
        return SettingsSnapshot(
            targetLanguage: targetLanguage,
            draftTargetLanguage: draftTargetLanguage,
            writingToggleAlternate: writingToggleAlternate,
            floatingDefaultMode: floatingDefaultMode,
            selectionDisplayMode: selectionDisplayMode,
            cleanupLevel: cleanupLevel,
            genZMode: genZModeEnabled,
            emailVoiceSample: emailVoiceSample,
            customStyleInstruction: customStyleInstruction,
            invisibilityEnabled: invisibilityModeEnabled,
            launchAtLogin: isRunningFromAppBundle && LaunchAtLogin.isEnabled,
            writingStyles: styles,
            textModelID: textModelID,
            askNugumiModelID: askNugumiModelID,
            textThinkingLevel: textThinkingLevel,
            askNugumiThinkingLevel: askNugumiThinkingLevel,
            shortcuts: shortcuts,
            appsByCategory: appsByCategory()
        )
    }

    private static let appsMigratedKey = "appCategoryDefaultsMigratedV1"

    /// One-time: fold the built-in `bundleIDMap` defaults into the persisted
    /// assignment list (installed apps only, de-duplicated by name). After this the
    /// strip is built purely from the persisted list, so hardcoded defaults can no
    /// longer collide with user edits — which is what produced duplicate icons (two
    /// Telegram bundle IDs) and apps re-appearing after add/remove.
    private func migrateDefaultAppsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.appsMigratedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.appsMigratedKey)

        var list = customAppAssignments()
        var seenBundles = Set(list.map(\.bundleID))
        var seenNames = Set(list.map { $0.name.lowercased() })
        let suppressed = suppressedBuiltInApps()

        for (bundleID, category) in AppCategoryClassifier.bundleIDMap.sorted(by: { $0.key < $1.key }) {
            guard !suppressed.contains(bundleID),
                  !seenBundles.contains(bundleID),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            guard !seenNames.contains(name.lowercased()) else { continue }
            seenBundles.insert(bundleID)
            seenNames.insert(name.lowercased())
            list.append(CustomAppAssignment(bundleID: bundleID, name: name, category: category))
        }
        saveCustomAppAssignments(list)
    }

    /// Apps shown per category in the Style page — built purely from the persisted
    /// assignment list (defaults migrated in once), de-duplicated by app name so the
    /// same app never shows twice. Icons are resolved lazily in the UI by bundle ID.
    private func appsByCategory() -> [AppCategory: [AppRef]] {
        migrateDefaultAppsIfNeeded()
        var result: [AppCategory: [AppRef]] = [:]
        for category in AppCategory.allCases { result[category] = [] }

        var seenNames: Set<String> = []
        for assignment in customAppAssignments() {
            let nameKey = assignment.name.lowercased()
            guard !seenNames.contains(nameKey) else { continue }
            seenNames.insert(nameKey)
            result[assignment.category, default: []].append(
                AppRef(bundleID: assignment.bundleID, name: assignment.name, isBuiltIn: false)
            )
        }
        for category in result.keys {
            result[category]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return result
    }

    /// Presents an open panel scoped to applications so the user can assign any
    /// installed app to a Style category.
    @MainActor
    private func presentAppPicker(for category: AppCategory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to assign to “\(category.displayName)”."
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        addCustomApp(bundleID: bundleID, name: name, category: category)
        mainWindowController?.bridge.refreshFromHost()
    }

    func performSettingsIntent(_ intent: SettingsIntent) {
        switch intent {
        case .setTargetLanguage(let language):
            targetLanguage = language
            translationPanelController?.close()
            translationPanelController = nil
            updateMenuState()
        case .setDraftTargetLanguage(let language):
            draftTargetLanguage = language
            translationPanelController?.close()
            translationPanelController = nil
            updateMenuState()
        case .setWritingToggleAlternate(let language):
            writingToggleAlternate = language
        case .setFloatingDefaultMode(let mode):
            floatingDefaultMode = mode
            petController?.setActionMode(mode.translationMode)
            refreshStatusBarIcon()
            updateMenuState()
        case .setSelectionDisplayMode(let mode):
            selectionDisplayMode = mode
            applySelectionDisplayMode()
        case .setCleanupLevel(let level):
            cleanupLevel = level
            updateMenuState()
        case .setGenZMode(let enabled):
            if genZModeEnabled != enabled {
                // Replayed Ask turns are few-shot style examples: history written
                // in the old register overrides the new system prompt, so a
                // style flip must start the Ask conversation fresh.
                askHistory = []
                AskNugumiHistoryStore.save(askHistory)
            }
            genZModeEnabled = enabled
            updateMenuState()
        case .setLaunchAtLogin(let enabled):
            guard isRunningFromAppBundle else { break }
            LaunchAtLogin.set(enabled)
        case .setEmailVoiceSample(let sample):
            emailVoiceSample = sample
        case .setCustomStyleInstruction(let text):
            customStyleInstruction = text
        case .setWritingStyle(let style, let category):
            setWritingStyle(style, for: category)
            updateMenuState()
        case .addAppToCategory(let category):
            presentAppPicker(for: category)
        case .removeApp(let bundleID):
            removeApp(bundleID: bundleID)
        case .setThinkingLevel(let level, let scope):
            guard level != thinkingLevel(for: scope) else { return }
            setThinkingLevel(level, for: scope)
            updateMenuState()
        case .chooseModel(let modelID, let scope):
            let option = LLMModel.option(id: modelID)
            guard option.id != self.modelID(for: scope) else { return }
            if let provider = option.cloudProvider, !provider.hasCredentials {
                presentCredentialPrompt(for: provider) { [weak self] saved in
                    guard let self, saved else { return }
                    self.applyModelSelection(option.id, for: scope)
                }
                return
            }
            applyModelSelection(option.id, for: scope)
        case .toggleInvisibility:
            toggleInvisibilityMode()
        case .recordShortcut(let action):
            presentShortcutRecorder(for: action)
        case .resetShortcuts:
            resetKeyboardShortcuts()
        case .signInCloud(let provider):
            presentCredentialPrompt(for: provider) { [weak self] saved in
                guard let self else { return }
                // Just connected from the Providers tab → take the user to
                // Models so they can pick one of the newly-available models.
                if saved { self.mainWindowController?.bridge.aiEngineTab = 0 }
                self.mainWindowController?.bridge.refreshFromHost()
            }
        case .signOutCloud(let provider):
            disconnectCloudProvider(provider)
        case .openOllamaInstall:
            bootstrap.openInstallPage()
        case .launchOllama:
            bootstrap.launchOllamaApp()
        case .openOllamaSignIn:
            bootstrap.openOllamaForSignIn()
        case .refreshBootstrap:
            bootstrap.refresh()
        case .startModelPull(let modelID):
            // Remember the model the user just requested so that when its pull
            // finishes we can auto-promote it to the everyday-text default —
            // mirroring the old onboarding window's onOllamaReady behavior.
            pendingOllamaAutoSelectID = modelID
            bootstrap.startModelPull(for: modelID)
        case .cancelModelPull(let modelID):
            if pendingOllamaAutoSelectID == modelID { pendingOllamaAutoSelectID = nil }
            bootstrap.cancelPull(for: modelID)
        case .checkForUpdates:
            checkForUpdates()
        case .contactSupport:
            contactSupport()
        case .openPermissionsHelp:
            // Show the full first-run sequence exactly as a new user sees it.
            presentPermissionsWindow(force: true, replay: true)
        case .resetSettings:
            resetSettings()
        case .quit:
            quit()
        }
    }
}

// MARK: - Language toggle HUD

/// Small auto-fading toast shown when the writing language flips via the
/// global shortcut — without it the toggle is invisible to the user. One
/// shared instance so rapid toggles replace the text instead of stacking.
@MainActor
final class LanguageToggleHUD {
    static let shared = LanguageToggleHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(text: String) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()

        let padding = NSSize(width: 22, height: 12)
        let size = NSSize(
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2
        )
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 60,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        (panel.contentView?.layer)?.cornerRadius = size.height / 2

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    if self?.dismissTask?.isCancelled == false {
                        self?.panel?.orderOut(nil)
                    }
                }
            })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // Same liquid-glass material as the main window, so the toast reads
        // as part of the same family.
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        content.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        content.addSubview(label)

        panel.contentView = content
        InvisibilityState.apply(to: panel)
        self.panel = panel
        self.label = label
        return panel
    }
}
