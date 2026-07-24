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
    var statusItem: NSStatusItem?
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
    var translationPanelController: TranslationPanelController?
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
    lazy var liveTranslationController: LiveTranslationController = {
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
    lazy var dictationController: DictationController = {
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
    var mainWindowController: MainWindowController?
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
    var targetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "targetLanguageID") ?? TranslationLanguage.defaultLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "targetLanguageID")
        }
    }
    var draftTargetLanguage: TranslationLanguage {
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
    var writingToggleAlternate: TranslationLanguage {
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

    var invisibilityModeEnabled: Bool {
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

    func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
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

    func updateMenuState() {
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
    func presentMainWindow(section: MainWindowSection? = nil) {
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

