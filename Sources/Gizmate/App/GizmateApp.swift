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
final class GizmateApp: NSObject, NSApplicationDelegate {
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
    private let ollamaBaseURL = LLMBackendFactory.ollamaBaseURL
    var currentBackend: any LLMBackend {
        backend(for: textModelID)
    }
    var askBackend: any LLMBackend {
        backend(for: askGizmateModelID)
    }

    private func backend(for modelID: String) -> any LLMBackend {
        LLMBackendFactory.backend(for: modelID)
    }

    var translateButtonController: FloatingTranslateButtonController?
    var floatingLoadingBar: FloatingTranslateButtonController?
    /// Click-through layer with the model's explanation shapes; replaced on
    /// every Ask answer, torn down with the answer UI.
    var askAnnotationOverlay: AskAnnotationOverlayController?
    /// Round loading bubble shown in place of the Ask Gizmate pill while a
    /// question is in flight. Unlike the pill, it has no outside-click
    /// monitors, so clicking elsewhere can't dismiss the in-flight request.
    var askFloatingLoadingBar: FloatingTranslateButtonController?
    var translationPanelController: TranslationPanelController?
    var askPromptController: AskPromptController?
    /// The same capsule, borrowed by a `.ask` tool for its one input. Kept
    /// apart from `askPromptController` on purpose: that one is wired to the
    /// Ask flow's screen capture, drawing overlay and in-flight request, none
    /// of which a tool wants.
    var toolPromptController: AskPromptController?
    var askGizmateTask: Task<Void, Never>?
    var askGizmateRequestID: UUID?
    /// The one Ask conversation. Both surfaces drive it: the docked chat
    /// through `send`, the floating capsule through `record` while it still
    /// runs its own submit path. `askHistory` reads through it so neither can
    /// answer with the other's context missing.
    lazy var askConversation = AskConversationStore(engine: makeAskEngine())
    /// Home's plain conversation. Same backend as Ask, different transcript and
    /// different system prompt — see `ToolChatConversation` for why they are not
    /// one conversation.
    lazy var homeChat = ToolChatConversation { [weak self] history, question, onPartial in
        guard let self else { throw CancellationError() }
        let transcript = history
            .map { "User: \($0.question)\nGizmate: \($0.answer)" }
            .joined(separator: "\n\n")
        let prompt = transcript.isEmpty ? question : "\(transcript)\n\nUser: \(question)"
        return try await self.askBackend.complete(
            systemPrompt: Self.homeChatSystemPrompt,
            userPrompt: prompt,
            images: [],
            thinkingLevel: self.askGizmateThinkingLevel,
            onPartial: onPartial
        )
    }

    /// Deliberately not Ask's persona. Ask answers about the screen; this
    /// answers about Gizmate and about whatever else was asked, and it must not
    /// claim to see anything, because nothing here sends a picture.
    static let homeChatSystemPrompt = """
        You are Gizmate, a macOS assistant. Answer the user's question directly and concisely. \
        Markdown is welcome where structure helps.

        You cannot see the user's screen in this conversation and must never claim to. \
        If they ask about something on screen, tell them Ask does that.

        The user can also have you build small tools, called gizmos, by describing what they want. \
        If they seem to be asking for one, say so in a sentence and let them ask again \
        rather than describing how to build it yourself.
        """
    var askHistory: [AskGizmateTurn] { askConversation.turns }
    /// Screen capture taken the moment Ask Gizmate is summoned, before the
    /// prompt steals focus. Activating Gizmate deactivates the frontmost app,
    /// which instantly closes its open menus/popovers, so a submit-time
    /// capture can never see them. Consumed by `submitAskGizmatePrompt`.
    var pendingAskGizmateCapture: AskGizmateScreenCapture?
    /// Draw-anywhere canvas over the captured screen; alive while the Ask
    /// prompt is open, consumed (strokes → image) at submit.
    var askDrawingOverlay: AskDrawingOverlayController?
    /// The same canvas serving a `.drawnScreen` gizmo instead of Ask. Kept
    /// apart so a gizmo run started while Ask is open cannot tear down Ask's.
    var gizmoDrawingOverlay: AskDrawingOverlayController?
    /// A `.annotate` gizmo's shapes, and the Esc watcher that clears them.
    /// Ask's copy dies with its panel; this one has no panel to die with.
    var gizmoAnnotationOverlay: AskAnnotationOverlayController?
    var gizmoAnnotationDismissMonitor: Any?
    var isScreenshotTranslationRunning = false
    var isAskGizmateRunning = false
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
    /// The quick menu's transient hub: a floating button spawned at the
    /// cursor whose ring is opened immediately (see `toggleQuickMenuRing`).
    var quickMenuButton: FloatingTranslateButtonController?
    var shortcutRecorderWindowController: ShortcutRecorderWindowController?
    var lastReplacementSourcePID: pid_t?
    var translationCache = TranslationCache()
    let usageStatsStore = UsageStatsStore()
    let analyticsClient = AnalyticsClient()
    let snippetsStore = SnippetsStore()
    let notesStore = NotesStore()
    let toolsStore = ToolsStore()
    let uvBootstrap = UVBootstrap()
    let ringLayoutStore = RingLayoutStore()
    let builtInOverridesStore = BuiltInOverridesStore()
    let dockStore = DockStore()
    let folderHubStore = FolderHubStore()
    /// The last rows each surface gizmo's script printed, kept across a
    /// gizmo's whole run so a refresh only ever costs one disk read on a
    /// cold miss. See `SurfaceRowsCache`.
    let surfaceRowsCache = SurfaceRowsCache()
    /// One per edge, built in `startDocks()`.
    var dockControllers: [EdgeDockController] = []
    lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        models: LLMModel.ollamaModels
    )
    var snippetsWindowController: SnippetsWindowController?
    var mainWindowController: MainWindowController?
    /// Ollama model whose pull the user kicked off from the Providers setup card.
    /// When it finishes we promote it to the everyday-text default once, mirroring
    /// the retired onboarding window's `onOllamaReady` behavior.
    var pendingOllamaAutoSelectID: String?
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

    // MARK: - Custom app → category assignments

    private static let customAppAssignmentsKey = "customAppAssignmentsV1"
    private static let suppressedBuiltInAppsKey = "suppressedBuiltInAppsV1"

    func customAppAssignments() -> [CustomAppAssignment] {
        guard let data = UserDefaults.standard.data(forKey: Self.customAppAssignmentsKey),
              let list = try? JSONDecoder().decode([CustomAppAssignment].self, from: data)
        else { return [] }
        return list
    }

    func saveCustomAppAssignments(_ list: [CustomAppAssignment]) {
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

    /// The prompt path is not `@MainActor` and is reached from four LLM
    /// clients, so a built-in's edits arrive through statics the store keeps
    /// current rather than through every call signature.
    func applyBuiltInOverridesToPrompts() {
        TranslationMode.promptOverrides = builtInOverridesStore.promptOverrides()
        TranslationMode.voiceOffBuiltIns = builtInOverridesStore.voiceOffBuiltIns()
        TranslationMode.notesOffBuiltIns = builtInOverridesStore.notesOffBuiltIns()
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
        if let evalMode = ToolEvalMode.parse(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            _ = NSApplication.shared
            Task { @MainActor in
                let status = await evalMode.run()
                exit(status)
            }
            dispatchMain()
        }
        if let gateMode = ToolAgentGateMode.parse(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            _ = NSApplication.shared
            Task {
                let status = await gateMode.run()
                exit(status)
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = GizmateApp()
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
        // Gizmate is a dark-only design (white ink on dark glass everywhere). Pin
        // the whole app to dark so windows/panels render correctly even when macOS
        // is in light mode — otherwise the system serves a light material and the
        // white text on the floating Ask Gizmate panels becomes invisible. This is
        // the single source of truth; the per-window .darkAqua pins are redundant.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Every dialog AppKit draws for us — NSAlert, the About panel, user
        // notifications — falls back to the application icon. Under `swift run`
        // there is no bundle, so that fallback is the generic placeholder, which
        // AppKit renders as a blue folder. Point it at the shipped artwork once
        // and all of them are branded, instead of setting `.icon` per alert.
        if let icon = BrandMark.appIcon {
            NSApp.applicationIconImage = icon
        }

        if let probeMode = ToolWorkerProbeMode.parse(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            Task { @MainActor in
                let status = await ToolWorkerClient.runAndWriteReport(
                    to: probeMode.reportURL
                )
                Darwin.exit(status)
            }
            return
        }

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
        // The ring reads its contents through this hook every time it opens, so
        // a slot edited in the Ring tab lands on the very next ring.
        RingConfigurationProvider.current = { [weak self] selection in
            guard let self else { return .default }
            return RingConfiguration(
                layout: self.ringLayoutStore.layout,
                // Unrunnable tools (no prompt, or a script tool with no script)
                // are filtered here so the builder never has to consult the store.
                tools: self.toolsStore.tools.filter(self.toolsStore.isRunnable),
                folders: self.ringLayoutStore.folders,
                overrides: self.builtInOverridesStore.overrides
            )
        }
        // The prompt path is not @MainActor and is reached from four LLM
        // clients, so overrides arrive through a static the store keeps current
        // rather than through every call signature.
        applyBuiltInOverridesToPrompts()
        builtInOverridesStore.onChange = { [weak self] in
            self?.applyBuiltInOverridesToPrompts()
        }
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
        startDocks()
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

    /// First launch from the app bundle registers Gizmate as a login item so the
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
            if self.bootstrap.isReady(for: self.textModelID) {
                self.presentMainWindow()
            } else {
                self.presentEngineSetup()
            }
        }
    }

    private func setupBootstrap() {
        wireBootstrap()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            // While onboarding is up, don't stack the main window on top of
            // it — the onboarding close handler opens it (on Settings → Providers when
            // no model is ready) via showMainWindowOnFirstRunIfNeeded.
            guard self.onboardingWindowController == nil else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentEngineSetup()
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
    func onModelSelectionChanged(for scope: ModelUseScope) {
        bootstrap.refresh()
        guard scope == .textActions else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentEngineSetup()
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
        // A pull the user started from the Providers setup card just finished —
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
        content.title = "Gizmate is ready"
        content.body = "The translator finished downloading. Press your shortcut or select text to start."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "gizmate.translator.ready.\(Date().timeIntervalSince1970)",
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
        modifierDetectors.forEach { $0.stop() }
        modifierDetectors.removeAll()
        globalHotKeys.forEach { $0.unregister() }
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
        screenRecordingTrustTimer?.invalidate()
        screenRecordingTrustTimer = nil
    }

    var lastAccessibilitySelectionPromptAt: Date?
}
