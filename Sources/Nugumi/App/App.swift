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
