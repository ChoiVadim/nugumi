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
    var mouseMonitor: Any?
    var keyboardMonitor: Any?
    var lastLeftMouseDownLocation: NSPoint?
    /// Pasteboard changeCount at the start of the current selection gesture.
    /// If it advances before the clipboard fallback runs, the frontmost app
    /// copied on its own (copy-on-select TUIs, click-to-copy sites) — that
    /// copy is the selection and must survive on the clipboard.
    var lastMouseDownPasteboardChangeCount: Int?
    var lastMouseDownDragPasteboardChangeCount: Int?
    var lastMouseDownWindowNumber: Int?
    var lastMouseDownWindowBounds: CGRect?
    /// Per-bundle count of consecutive selection-gesture attempts that returned
    /// no readable text. Apps like KakaoTalk expose neither AX text attributes
    /// nor a working Cmd+C path, so the floating bar silently never appears —
    /// this counter lets us surface a one-time hint pointing users at
    /// Screenshot Translation instead.
    var unreadableSelectionFailureCounts: [String: Int] = [:]
    static let unreadableSelectionFailureThreshold = 3
    static let unreadableSelectionHintShownDefaultsKey = "unreadableSelectionHintShownBundles"
    let selectionReader = SelectionReader()
    private let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    var currentBackend: any LLMBackend {
        backend(for: textModelID)
    }
    var askBackend: any LLMBackend {
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

    var translateButtonController: FloatingTranslateButtonController?
    var floatingLoadingBar: FloatingTranslateButtonController?
    /// Click-through layer with the model's explanation shapes; replaced on
    /// every Ask answer, torn down with the answer UI.
    var askAnnotationOverlay: AskAnnotationOverlayController?
    /// Round loading bubble shown in place of the Ask Nugumi pill while a
    /// question is in flight. Unlike the pill, it has no outside-click
    /// monitors, so clicking elsewhere can't dismiss the in-flight request.
    var askFloatingLoadingBar: FloatingTranslateButtonController?
    var petController: PetController?
    var translationPanelController: TranslationPanelController?
    var askPromptController: AskPromptController?
    var askNugumiTask: Task<Void, Never>?
    var askNugumiRequestID: UUID?
    var askHistory: [AskNugumiTurn] = AskNugumiHistoryStore.load()
    /// Screen capture taken the moment Ask Nugumi is summoned, before the
    /// prompt steals focus. Activating Nugumi deactivates the frontmost app,
    /// which instantly closes its open menus/popovers, so a submit-time
    /// capture can never see them. Consumed by `submitAskNugumiPrompt`.
    var pendingAskNugumiCapture: AskNugumiScreenCapture?
    /// Draw-anywhere canvas over the captured screen; alive while the Ask
    /// prompt is open, consumed (strokes → image) at submit.
    var askDrawingOverlay: AskDrawingOverlayController?
    var isScreenshotTranslationRunning = false
    var isAskNugumiRunning = false
    /// True while a cloud sign-in flow (ChatGPT or Claude) is on screen.
    /// Suspends the mouse/Cmd+A selection auto-readers so they don't fire
    /// synthetic ⌘+C at the sign-in page on every click — which makes macOS beep
    /// when there's nothing to copy. Set around the login alerts' `present()`.
    var isCloudSignInActive = false
    var screenshotDragStartLocation: NSPoint?
    var screenshotDragEndLocation: NSPoint?
    var screenshotPanelSide: TranslationPanelController.Side?
    var screenshotDragTracker: ScreenshotDragTracker?
    var globalHotKeys: [GlobalHotKey] = []
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
    var modifierDetectors: [DoubleModifierPressDetector] = []
    var mouseButtonMonitors: [MouseButtonShortcutMonitor] = []
    var quickMenuRing: RadialActionMenuController?
    var shortcutRecorderWindowController: ShortcutRecorderWindowController?
    var lastReplacementSourcePID: pid_t?
    var translationCache = TranslationCache()
    let usageStatsStore = UsageStatsStore()
    let analyticsClient = AnalyticsClient()
    let snippetsStore = SnippetsStore()
    let translationHistoryStore = TranslationHistoryStore()
    lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        models: LLMModel.ollamaModels
    )
    var snippetsWindowController: SnippetsWindowController?
    var mainWindowController: MainWindowController?
    /// Ollama model whose pull the user kicked off from the AI Engine setup card.
    /// When it finishes we promote it to the everyday-text default once, mirroring
    /// the retired onboarding window's `onOllamaReady` behavior.
    private var pendingOllamaAutoSelectID: String?
    var accessibilityTrustTimer: Timer?
    var screenRecordingTrustTimer: Timer?

    struct WindowSharingSnapshot {
        let window: NSWindow
        let sharingType: NSWindow.SharingType
    }
    var onboardingWindowController: OnboardingWindowController?
    private var lastObservedModelReadyState: [String: BootstrapStepStatus] = [:]
    lazy var updaterController: SPUStandardUpdaterController? = {
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
    var availableUpdate: SUAppcastItem?
    var isRunningFromAppBundle: Bool {
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
    var floatingDefaultMode: FloatingButtonDefaultMode {
        get {
            FloatingButtonDefaultMode.storedMode(
                rawValue: UserDefaults.standard.string(forKey: "floatingButtonDefaultMode")
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "floatingButtonDefaultMode")
        }
    }
    var selectionDisplayMode: SelectionDisplayMode {
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
    var textModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.defaultsKey)
                ?? ModelUseScope.textActions.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.textActions.defaultsKey)
        }
    }
    var askNugumiModelID: String {
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
    var textThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.textActions.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.textActions.thinkingDefaultsKey)
        }
    }
    var askNugumiThinkingLevel: ThinkingLevel {
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
    var cleanupLevel: CleanupLevel {
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
    var genZModeEnabled: Bool {
        get { GenZStyle.isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: GenZStyle.defaultsKey) }
    }

    /// The user's email voice sample — a typical email they write, used as a
    /// style reference for the `email` category only. Empty by default. Treated
    /// as personal content (like Snippets), so it survives a settings reset.
    var emailVoiceSample: String {
        get { UserDefaults.standard.string(forKey: "voiceSample.email") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSample.email") }
    }

    /// Free-text instruction for the `custom` style. Personal content (like the
    /// email voice sample and Snippets), so it survives a settings reset.
    var customStyleInstruction: String {
        get { UserDefaults.standard.string(forKey: "customStyleInstructionV1") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "customStyleInstructionV1") }
    }

    var invisibilityModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: InvisibilityState.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: InvisibilityState.defaultsKey) }
    }

    func writingStyle(for category: AppCategory) -> WritingStyle {
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
    func showMainWindowOnFirstRunIfNeeded() {
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

    var lastAccessibilitySelectionPromptAt: Date?
    func startScreenshotTranslation() {
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
    func presentScreenshotTranslationError(_ error: Error) {
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
    func presentSelectionTranslationError(_ message: String, title: String = "No text selected") {
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: title,
            message: message,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    func presentCredentialPrompt(for provider: CloudProvider, onSave: @escaping (Bool) -> Void) {
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

