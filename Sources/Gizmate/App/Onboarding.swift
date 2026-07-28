import AppKit
import AVKit
import Combine
import SwiftUI

// MARK: - Permission model

enum PermissionKind {
    case accessibility
    case screenRecording
    case fullDiskAccess

    var analyticsValue: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "screen_recording"
        case .fullDiskAccess: return "full_disk_access"
        }
    }
}

// MARK: - Full Disk Access probe

/// No macOS API reports Full Disk Access status directly. Probe by attempting
/// to list the KakaoTalk container (what the chat-summary feature actually
/// needs to read): success ⇒ granted, failure ⇒ missing.
enum FullDiskAccessProbe {
    static func isGranted() async -> Bool {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let container = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
            // If KakaoTalk isn't installed, fall back to a generic TCC-gated path.
            let probe = FileManager.default.fileExists(atPath: container)
                ? container
                : "\(home)/Library/Application Support/com.apple.TCC"
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }.value
    }
}

// MARK: - Feature tour data

struct FeatureTourStep {
    let title: String
    let body: String
    /// Dead-simple "how to use" as a 1·2·3 list — plain language, no jargon.
    let steps: [String]
    let videoURL: URL

    static var all: [FeatureTourStep] {
        let askShortcut = GlobalShortcutStore.shortcut(for: .askGizmate)

        return [
            FeatureTourStep(
                title: "Ask Gizmate anything",
                body: "Confused by something on your screen? Ask Gizmate - it looks and answers.",
                steps: askSteps(for: askShortcut),
                videoURL: videoURL(named: "ask", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/demo.mp4")
            ),
            FeatureTourStep(
                title: "Understand anything you read",
                body: "Stuck on a word or a sentence? Gizmate explains it in simple words - and you can keep asking.",
                steps: [
                    "Select the text you don't get.",
                    "Click the Gizmate that pops up and pick Explain.",
                    "Read the answer. Ask more if you want.",
                ],
                videoURL: videoURL(named: "understand", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/translate.mp4")
            ),
            FeatureTourStep(
                title: "Write it rough, send it clean",
                body: "Write however it comes out. Gizmate makes it clean and natural - in a style you pick for each app.",
                steps: [
                    "Write your message.",
                    "Select it.",
                    "Click the Gizmate that pops up and pick Rewrite.",
                ],
                videoURL: videoURL(named: "fix", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/make-native.mp4")
            ),
            FeatureTourStep(
                title: "Replies that know the answer",
                body: "Gizmate reads the message you got and writes the reply for you.",
                steps: [
                    "Select the message you got.",
                    "Click the Gizmate that pops up.",
                    "Pick Reply.",
                ],
                videoURL: videoURL(named: "reply", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/reply.mp4")
            )
        ]
    }

    /// Bundled clip first (works offline); CloudFront only as a safety net if
    /// the resource is somehow missing from the bundle.
    private static func videoURL(named name: String, remote: String) -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: "MOV", subdirectory: "Onboarding")
            ?? Bundle.module.url(forResource: name, withExtension: "MOV") {
            return url
        }
        return URL(string: remote)!
    }

    /// Ask's first step depends on the user's configured shortcut.
    private static func askSteps(for shortcut: GlobalShortcut) -> [String] {
        let trigger: String
        switch shortcut.kind {
        case .doubleTap:
            let glyph = shortcut.displayString
            let single = String(glyph.prefix(glyph.count / 2))
            trigger = "Press \(modifierName(forGlyph: single)) twice."
        case .combo:
            trigger = "Press \(shortcut.displayString)."
        case .mouseButton:
            trigger = "Click \(shortcut.displayString) on your mouse."
        }
        return [trigger, "Type your question.", "Press Return."]
    }

    private static func modifierName(forGlyph glyph: String) -> String {
        switch glyph {
        case "⌃": return "Control"
        case "⌥": return "Option"
        case "⇧": return "Shift"
        case "⌘": return "Command"
        default: return glyph
        }
    }
}

// MARK: - Intro video

/// First-run intro clip. Optional so a missing resource simply skips the page.
enum OnboardingIntroVideo {
    static let url: URL? = Bundle.module.url(forResource: "intro", withExtension: "mov", subdirectory: "Onboarding")
        ?? Bundle.module.url(forResource: "intro", withExtension: "mov")
}

// MARK: - Onboarding state machine

@MainActor
final class OnboardingModel: ObservableObject {
    /// `.firstRun` keeps the historical auto-advance/auto-close behavior;
    /// `.review` (opened from Help) always shows permission status and never
    /// closes itself — the user looks around and leaves when they want.
    /// `.replay` walks the exact first-run sequence (intro → tour → permissions
    /// → finale) from the top, ignoring the completed flags, so an existing user
    /// sees precisely what a brand-new user would. Never auto-closes.
    enum Mode {
        case firstRun
        case review
        case replay
    }

    enum Page: Equatable {
        /// Full-window intro video, shown once at the very start of first run.
        case intro
        case permissions
        case feature(Int)
        /// Closing page: what's left to do (pick an AI engine) and the choices.
        case finale
    }

    static let featureTourCompletedKey = "permissionsOnboarding.featureTourCompleted"
    static let introPlayedKey = "permissionsOnboarding.introPlayed"

    static var hasCompletedFeatureTour: Bool {
        UserDefaults.standard.bool(forKey: featureTourCompletedKey)
    }

    static var hasPlayedIntro: Bool {
        UserDefaults.standard.bool(forKey: introPlayedKey)
    }

    /// Proxy for "initial setup finished": the key is consumed by
    /// `showMainWindowOnFirstRunIfNeeded` in App.swift the first time the main
    /// window auto-opens, which happens right after onboarding completes.
    /// While it's still false, completing permissions should land on the
    /// engine choice, not silently close.
    static var mainWindowEverAutoShown: Bool {
        UserDefaults.standard.bool(forKey: "mainWindowAutoShownV1")
    }

    let mode: Mode
    let steps = FeatureTourStep.all

    @Published var page: Page = .permissions {
        didSet { pageDidChange?(page) }
    }
    /// Set by the window controller — drives the intro ↔ standard window resize.
    var pageDidChange: ((Page) -> Void)?
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var scrTrusted = CGPreflightScreenCaptureAccess()
    /// Full Disk Access is optional — unlike `axTrusted`/`scrTrusted`, nothing
    /// in this model ever gates first-run completion or auto-advance on it.
    @Published var fdaGranted = false

    /// Set by the window controller.
    var requestClose: (() -> Void)?
    var closeBeforeSystemDialog: (() -> Void)?
    /// Fired when the user hits a terminal point of the tour. `skipped` is
    /// true when they bailed from a feature page (Skip button, closed the
    /// window mid-tour) rather than reaching the finale. Distinct from
    /// `markTourComplete`, which also runs mid-flow purely to persist the
    /// don't-replay flag across the Screen Recording restart.
    var onTourFinished: ((_ skipped: Bool) -> Void)?
    /// Opens the main window on AI Engine → Providers so the user lands in
    /// the setup flow for the engine they just picked on the finale page.
    var openEngineSetup: ((EngineSetupFocus) -> Void)?

    private let fullDiskAccessProbe: @Sendable () async -> Bool
    private var fullDiskAccessProbeTask: Task<Void, Never>?

    init(
        mode: Mode,
        fullDiskAccessProbe: @escaping @Sendable () async -> Bool = {
            await FullDiskAccessProbe.isGranted()
        }
    ) {
        self.mode = mode
        self.fullDiskAccessProbe = fullDiskAccessProbe
        // First-run order: intro video → feature tour → permissions (only if
        // something is missing) → engine choice. Review mode always starts on
        // the permissions page so granted status stays visible.
        if mode == .replay {
            // Always from the very top, regardless of what's already completed.
            page = OnboardingIntroVideo.url != nil ? .intro : .feature(0)
        } else if mode == .firstRun, !Self.hasCompletedFeatureTour {
            if !Self.hasPlayedIntro, OnboardingIntroVideo.url != nil {
                page = .intro
            } else if Self.hasPlayedIntro, nextPermission != nil {
                // Resuming mid-flow (e.g. re-presented after granting a
                // permission in System Settings) — the tour is behind us,
                // pick up at the permission checklist.
                page = .permissions
            } else {
                page = .feature(0)
            }
        } else if mode == .firstRun, !Self.mainWindowEverAutoShown, axTrusted, scrTrusted {
            // Post-restart resume: granting Screen Recording relaunches the
            // app. Required permissions are done — only the engine choice is
            // left. Full Disk Access is optional and resolves asynchronously.
            page = .finale
        }
        if let override = Self.devPageOverride {
            page = override
        }
        refreshFullDiskAccessStatus()
    }

    /// Developer switch: NUGUMI_ONBOARDING_PAGE=intro|permissions|feature|finale
    /// jumps straight to that page, for iterating on onboarding UI without
    /// clicking through the whole flow.
    static var devPageOverride: Page? {
        switch ProcessInfo.processInfo.environment["NUGUMI_ONBOARDING_PAGE"] {
        case "intro": return .intro
        case "permissions": return .permissions
        case "feature": return .feature(0)
        case "finale": return .finale
        default: return nil
        }
    }

    func advanceFromIntro() {
        guard page == .intro else { return }
        // Remember so a re-presented onboarding (after a System Settings
        // round-trip) never replays the video.
        UserDefaults.standard.set(true, forKey: Self.introPlayedKey)
        page = .feature(0)
    }

    var nextPermission: PermissionKind? {
        if !axTrusted { return .accessibility }
        if !scrTrusted { return .screenRecording }
        if !fdaGranted { return .fullDiskAccess }
        return nil
    }

    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        let scr = CGPreflightScreenCaptureAccess()
        if ax != axTrusted { axTrusted = ax }
        if scr != scrTrusted { scrTrusted = scr }
        refreshFullDiskAccessStatus()

        // First-run auto-advance once both REQUIRED permissions land; review
        // mode stays put so the user can see (and revisit) the granted state.
        // Full Disk Access is optional and deliberately excluded here — this
        // must never wait on it (it has no OS-prompted flow and many users
        // will simply never grant it).
        if mode == .firstRun, page == .permissions, ax, scr {
            if !Self.mainWindowEverAutoShown {
                page = .finale
            } else {
                requestClose?()
            }
        }
    }

    func primaryAction() {
        switch page {
        case .intro:
            advanceFromIntro()
        case .finale:
            finishTour(skipped: false)
            requestClose?()
        case .feature(let index):
            advanceFeature(from: index)
        case .permissions:
            refreshTrustFlags()
            switch nextPermission {
            case .accessibility:
                openAccessibilitySettings()
            case .screenRecording:
                openScreenRecordingSettings()
            case .fullDiskAccess:
                openFullDiskAccessSettings()
            case nil:
                if mode == .replay {
                    page = .finale
                } else if mode == .review {
                    page = .feature(0)
                } else if !Self.mainWindowEverAutoShown {
                    // Initial setup is still in progress (the main window has
                    // never been reached) — finish with the engine choice.
                    page = .finale
                } else {
                    requestClose?()
                }
            }
        }
    }

    func skipAction() {
        switch page {
        case .feature:
            // Skipping the feature walkthrough must not also skip the
            // permissions step. Route to the permissions page (still skippable
            // from there) instead of closing onboarding outright — mirrors the
            // end-of-tour routing in advanceFeature.
            if (mode == .firstRun && nextPermission != nil) || mode == .replay {
                markTourComplete()
                page = .permissions
                return
            }
            finishTour(skipped: true)
        case .finale:
            finishTour(skipped: false)
        case .permissions:
            // Permissions are optional: translate/reply work without Screen
            // Recording, and the clipboard path covers a missing Accessibility
            // grant. Declining one must not strand the user here — on first run
            // fall through to the engine choice (the actually-required setup
            // step) instead of closing onboarding outright.
            if mode == .replay || (mode == .firstRun && !Self.mainWindowEverAutoShown) {
                page = .finale
                return
            }
        case .intro:
            break
        }
        requestClose?()
    }

    /// Finale choice tapped: onboarding is done, go set up that engine.
    func pickEngine(_ choice: EngineSetupFocus) {
        finishTour(skipped: false)
        requestClose?()
        openEngineSetup?(choice)
    }

    func markTourComplete() {
        UserDefaults.standard.set(true, forKey: Self.featureTourCompletedKey)
    }

    /// Terminal point of the tour: persist the flag and report how it ended.
    func finishTour(skipped: Bool) {
        markTourComplete()
        onTourFinished?(skipped)
    }

    private func refreshTrustFlags() {
        axTrusted = AXIsProcessTrusted()
        scrTrusted = CGPreflightScreenCaptureAccess()
        refreshFullDiskAccessStatus()
    }

    /// TCC-protected directory enumeration can block inside `open(2)` for a
    /// packaged app. Keep it off the main actor and coalesce the 1-second UI
    /// poll so one slow check cannot create an unbounded queue of checks.
    private func refreshFullDiskAccessStatus() {
        guard fullDiskAccessProbeTask == nil else { return }
        let probe = fullDiskAccessProbe
        fullDiskAccessProbeTask = Task { [weak self] in
            let granted = await probe()
            guard let self, !Task.isCancelled else { return }
            self.fullDiskAccessProbeTask = nil
            if granted != self.fdaGranted {
                self.fdaGranted = granted
            }
        }
    }

    private func advanceFeature(from index: Int) {
        let nextIndex = index + 1
        if nextIndex < steps.count {
            page = .feature(nextIndex)
            return
        }
        // Tour done — persist that NOW, not at window close: granting Screen
        // Recording force-restarts the app from the permissions page, and the
        // tour must not replay after that restart.
        markTourComplete()
        // Collect missing permissions before the engine choice, now that the
        // user has seen what they unlock. Replay always shows this page so the
        // sequence matches a new user's even when permissions are already set.
        if (mode == .firstRun && nextPermission != nil) || mode == .replay {
            page = .permissions
        } else {
            page = .finale
        }
    }

    private func openAccessibilitySettings() {
        // Re-probe (prompt: false) so the Gizmate row exists in the list even
        // if permissions were reset (tccutil) while the app is running.
        let probe = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(probe)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        closeBeforeSystemDialog?()
        NSWorkspace.shared.open(url)
    }

    private func openFullDiskAccessSettings() {
        // Deliberately does NOT call closeBeforeSystemDialog(): that hides the
        // window in anticipation of a "trust watcher" (App.swift) re-presenting
        // it once the permission lands — a mechanism that only exists for
        // Accessibility/Screen Recording. Full Disk Access has no equivalent
        // watcher and never restarts the app, so closing here would leave
        // onboarding gone with nothing to bring it back. Instead, leave the
        // window open — its own 1s poll (refreshPermissions) picks up the
        // change live once the user flips the toggle in System Settings.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecordingSettings() {
        // macOS shows the stock "would like to record" dialog only ONCE per
        // app: after that, CGRequestScreenCaptureAccess() is a silent no-op
        // and the user would be left staring at nothing. So request the
        // system prompt only the first time; afterwards open the Privacy &
        // Security pane directly so there's always visible next UI.
        let requestedOnceKey = "permissionsOnboarding.screenCaptureRequested"
        let needsSystemPrompt = !CGPreflightScreenCaptureAccess()
            && !UserDefaults.standard.bool(forKey: requestedOnceKey)
        closeBeforeSystemDialog?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            UserDefaults.standard.set(true, forKey: requestedOnceKey)
            // Always request: beyond the one-time stock dialog, this call is
            // what REGISTERS Gizmate in the Screen Recording list. After a TCC
            // reset the UserDefaults flag still says "already asked" — without
            // re-requesting, the user opens Settings and there is no Gizmate
            // row to toggle at all.
            _ = CGRequestScreenCaptureAccess()
            if !needsSystemPrompt {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Display strings

    var stageText: String {
        switch page {
        case .intro:
            return ""
        case .permissions:
            switch nextPermission {
            case .accessibility: return "Step 1 of 2"
            case .screenRecording: return "Step 2 of 2"
            case .fullDiskAccess: return "Optional"
            case nil: return "Ready"
            }
        case .feature(let index):
            return "Feature \(index + 1) of \(steps.count)"
        case .finale:
            return "One last thing"
        }
    }

    var titleText: String {
        switch page {
        case .intro:
            return ""
        case .permissions:
            return "Give Gizmate the access it needs"
        case .feature(let index):
            return steps[index].title
        case .finale:
            return "Pick your AI engine"
        }
    }

    var subtitleText: String {
        switch page {
        case .intro:
            return ""
        case .permissions:
            return "Gizmate only reads what you explicitly select or capture."
        case .feature(let index):
            return steps[index].body
        case .finale:
            return "Gizmate needs a model to think with. Pick one of three options - you can switch anytime."
        }
    }

    var primaryTitle: String {
        switch page {
        case .intro:
            return ""
        case .permissions:
            switch nextPermission {
            case .accessibility: return "Open Accessibility Settings"
            case .screenRecording: return "Allow Screen Capture"
            case .fullDiskAccess: return "Open Full Disk Access Settings"
            case nil: return "Continue"
            }
        case .feature:
            return "Next"
        case .finale:
            return "Finish setup"
        }
    }

    var skipTitle: String {
        page == .permissions ? "Set up later" : "Skip tour"
    }
}

// MARK: - Window controller

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static var hasCompletedFeatureTour: Bool { OnboardingModel.hasCompletedFeatureTour }

    /// True when the window closed only to make room for a macOS permission
    /// dialog (it will be re-presented by the trust watchers) — distinguishes
    /// that from the user actually finishing or dismissing onboarding.
    private(set) var closedForSystemDialog = false

    /// 16:9 so the 1920×1080 intro clip fills the window edge to edge.
    private static let introContentSize = NSSize(width: 960, height: 540)
    private static let standardContentSize = NSSize(width: 900, height: 640)
    /// Feature tour: a full-width 16:9 video hero on top (720×405) with the
    /// title, how-to card and buttons stacked beneath it. Height is sized to
    /// hug the content so the buttons sit just under the steps, not way below.
    private static let featureContentSize = NSSize(width: 720, height: 735)

    private let model: OnboardingModel
    private let onClose: () -> Void

    init(
        mode: OnboardingModel.Mode,
        onPickEngine: @escaping (EngineSetupFocus) -> Void,
        onTourFinished: ((_ skipped: Bool) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        let model = OnboardingModel(mode: mode)
        self.model = model
        self.onClose = onClose
        model.openEngineSetup = onPickEngine
        model.onTourFinished = onTourFinished

        let contentSize = Self.contentSize(for: model.page)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Gizmate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        super.init(window: window)
        window.delegate = self

        // Same liquid-glass backdrop as the main window.
        let hosting = NSHostingView(rootView: OnboardingRootView(model: model))
        // Don't let SwiftUI's ideal size drive the window frame — the layout
        // stretches to .infinity, which would balloon the window. The window
        // size is controlled here (960×540 for the intro, 900×640 after)
        // and SwiftUI fills it.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
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
        window.contentView = backdrop

        model.requestClose = { [weak self] in
            self?.close()
        }
        model.closeBeforeSystemDialog = { [weak self] in
            self?.closedForSystemDialog = true
            self?.window?.orderOut(nil)
            self?.close()
        }
        model.pageDidChange = { [weak self] page in
            self?.resizeWindow(for: page)
        }
    }

    /// Grows the window from the widescreen intro frame to the standard
    /// two-column frame (and back, in theory), keeping it centered in place.
    private static func contentSize(for page: OnboardingModel.Page) -> NSSize {
        switch page {
        case .intro: return introContentSize
        case .feature: return featureContentSize
        case .permissions, .finale: return standardContentSize
        }
    }

    private func resizeWindow(for page: OnboardingModel.Page) {
        guard let window else { return }
        let target = Self.contentSize(for: page)
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin.x = window.frame.midX - frame.width / 2
        frame.origin.y = window.frame.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            switch self.model.page {
            case .feature:
                self.model.finishTour(skipped: true)
            case .finale:
                self.model.finishTour(skipped: false)
            case .intro, .permissions:
                break
            }
            self.onClose()
        }
    }
}

// MARK: - Root view

private struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel

    private let poll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch model.page {
            case .intro:
                IntroVideoPage(onFinish: { model.advanceFromIntro() })
            case .finale:
                finaleColumn
            case .feature(let index):
                featureStacked(index: index)
            case .permissions:
                HStack(spacing: 0) {
                    leftColumn
                        .frame(width: 360)
                    Rectangle()
                        .fill(FlowTheme.hairline)
                        .frame(width: 1)
                    rightColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The backdrop is a translucent `.hudWindow` vibrancy view that samples
        // the desktop behind the window. On a bright wallpaper it washes out to
        // light, dropping `inkSecondary` body text to near-invisible. The main
        // window never shows this because its text always sits on a scrimmed
        // card (material + black 0.26); onboarding text sits on the bare
        // backdrop, so it needs its own root scrim to keep the dark theme — and
        // the text — readable regardless of what's behind the window.
        // ponytail: single tunable scrim; bump opacity if still too light.
        .background(Color.black.opacity(0.55))
        .animation(.easeInOut(duration: 0.18), value: model.page)
        .onReceive(poll) { _ in model.refreshPermissions() }
    }

    /// Closing page: a single centered column — eyebrow, title, subtitle, and
    /// the three engine choices side by side. Each choice IS the action:
    /// clicking it closes onboarding and opens that engine's setup.
    private var finaleColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Text(model.stageText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(OnboardingPalette.mint)
            Text(model.titleText)
                .font(FlowTheme.serif(29))
                .foregroundStyle(FlowTheme.ink)
                .padding(.top, 12)
            Text(model.subtitleText)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 10)

            HStack(alignment: .top, spacing: 24) {
                FinaleChoiceButton(
                    symbol: "desktopcomputer",
                    title: "Local - Ollama",
                    detail: "Free and private. Runs entirely on your Mac, works offline.",
                    action: { model.pickEngine(.local) }
                )
                FinaleChoiceButton(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: "ChatGPT or Claude",
                    detail: "Already pay for ChatGPT or Claude? Just sign in - no extra cost.",
                    action: { model.pickEngine(.subscription) }
                )
                FinaleChoiceButton(
                    symbol: "key.fill",
                    title: "API keys",
                    detail: "OpenAI, Anthropic, Google, or OpenRouter. Pay as you go with your own key.",
                    action: { model.pickEngine(.apiKeys) }
                )
            }
            .padding(.top, 44)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .feature(let index) = model.page {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        ForEach(0..<model.steps.count, id: \.self) { segment in
                            Capsule()
                                .fill(segment <= index ? FlowTheme.accent : Color.white.opacity(0.14))
                                .frame(width: 26, height: 4)
                        }
                    }
                    Text("\(index + 1) / \(model.steps.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FlowTheme.inkTertiary)
                }
                .frame(height: 16)
            } else {
                Text(model.stageText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OnboardingPalette.mint)
                    .frame(height: 16)
            }

            Text(model.titleText)
                .font(FlowTheme.serif(29))
                .foregroundStyle(FlowTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Text(model.subtitleText)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Group {
                switch model.page {
                case .permissions:
                    VStack(spacing: 26) {
                        PermissionCard(
                            symbol: "keyboard.badge.eye",
                            fallbackSymbol: "keyboard",
                            title: "Work with selected text anywhere",
                            detail: "Reads the text you select in other apps.",
                            state: model.axTrusted
                                ? .granted
                                : (model.nextPermission == .accessibility ? .active : .waiting)
                        )
                        PermissionCard(
                            symbol: "rectangle.dashed.badge.record",
                            fallbackSymbol: "rectangle.dashed",
                            title: "Understand what's on screen",
                            detail: "Only used when you capture a screen area.",
                            state: model.scrTrusted
                                ? .granted
                                : (model.nextPermission == .screenRecording ? .active : .waiting)
                        )
                        PermissionCard(
                            symbol: "externaldrive.fill.badge.checkmark",
                            fallbackSymbol: "externaldrive.fill",
                            title: "Full Disk Access",
                            detail: "Read your KakaoTalk chat history to summarize it.",
                            state: model.fdaGranted
                                ? .granted
                                : (model.nextPermission == .fullDiskAccess ? .active : .waiting)
                        )
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                case .feature(let index):
                    FeatureInstructionCard(step: model.steps[index])
                        .frame(maxHeight: .infinity, alignment: .center)
                case .intro, .finale:
                    // Rendered by dedicated full-window layouts, never here.
                    EmptyView()
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 16)

            primaryButton

            if model.page != .finale {
                skipButton
            } else {
                Spacer().frame(height: 29)
            }
        }
        .padding(.leading, 36)
        .padding(.trailing, 26)
        .padding(.top, 52)
        .padding(.bottom, 30)
        .animation(.easeInOut(duration: 0.18), value: model.page)
    }

    private var rightColumn: some View {
        Group {
            switch model.page {
            case .permissions:
                PermissionPreviewPanel(
                    active: model.nextPermission ?? .screenRecording,
                    axTrusted: model.axTrusted,
                    scrTrusted: model.scrTrusted,
                    fdaGranted: model.fdaGranted
                )
            case .feature(let index):
                FeatureVideoPanel(step: model.steps[index])
            case .intro, .finale:
                EmptyView()
            }
        }
        .padding(EdgeInsets(top: 44, leading: 24, bottom: 32, trailing: 26))
        .animation(.easeInOut(duration: 0.18), value: model.page)
    }

    // MARK: Feature tour — stacked layout (full-width video on top)

    /// Feature pages put the demo clip first, edge to edge across the window's
    /// full width, then the title, how-to card and buttons beneath it. Landscape
    /// 16:9 clips fill the width with no letterboxing, unlike the old two-column
    /// layout where a wide clip left empty bands above and below.
    private func featureStacked(index: Int) -> some View {
        let step = model.steps[index]
        return GeometryReader { geo in
            VStack(spacing: 0) {
                // Full-bleed 16:9 hero across the ENTIRE window width. Height is
                // driven explicitly from the measured width (× 9/16) so the
                // greedy content below can't squeeze it narrower — that's what
                // left side margins when it used aspectRatio(.fit).
                LoopingVideoPlayer(url: step.videoURL)
                    .frame(width: geo.size.width, height: geo.size.width * 9.0 / 16.0)
                    .clipped()

                VStack(alignment: .leading, spacing: 0) {
                    featureProgress(index: index)

                    HStack(alignment: .top, spacing: 26) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(step.title)
                                .font(FlowTheme.serif(26))
                                .foregroundStyle(FlowTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(step.body)
                                .font(.system(size: 13))
                                .foregroundStyle(FlowTheme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        FeatureInstructionCard(step: step)
                            .frame(width: 300)
                    }
                    .padding(.top, 22)

                    Spacer(minLength: 18)

                    primaryButton
                    skipButton
                }
                .padding(.horizontal, 38)
                .padding(.top, 22)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // Match the intro clip: reach under the transparent titlebar so the
        // hero is flush with the very top edge.
        .ignoresSafeArea(edges: .top)
        .animation(.easeInOut(duration: 0.18), value: model.page)
    }

    private func featureProgress(index: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<model.steps.count, id: \.self) { segment in
                    Capsule()
                        .fill(segment <= index ? FlowTheme.accent : Color.white.opacity(0.14))
                        .frame(width: 26, height: 4)
                }
            }
            Text("\(index + 1) / \(model.steps.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(FlowTheme.inkTertiary)
            Spacer()
        }
        .frame(height: 16)
    }

    private var primaryButton: some View {
        Button(action: { model.primaryAction() }) {
            Text(model.primaryTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FlowTheme.raisedStrong)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(FlowTheme.edge, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var skipButton: some View {
        Button(action: { model.skipAction() }) {
            Text(model.skipTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.56))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

private enum OnboardingPalette {
    /// Stage labels and eyebrows. Aliases the shared accent so the palette has
    /// one source of truth.
    static let mint = FlowTheme.accentBright
}

// MARK: - Finale choice button

/// One engine choice on the finale page. The whole tile is clickable and
/// lights up on hover so it reads as a button, not a feature list.
private struct FinaleChoiceButton: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.white.opacity(hovered ? 0.14 : 0.07))
                    Circle().strokeBorder(
                        hovered ? FlowTheme.accent.opacity(0.8) : FlowTheme.hairline,
                        lineWidth: 1
                    )
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(OnboardingPalette.mint)
                }
                .frame(width: 56, height: 56)
                .scaleEffect(hovered ? 1.06 : 1.0)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovered ? .white : FlowTheme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .frame(maxWidth: 220)
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovered = inside }
        }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

// MARK: - Permission card

private struct PermissionCard: View {
    enum CardState {
        case active
        case waiting
        case granted
    }

    let symbol: String
    let fallbackSymbol: String
    let title: String
    let detail: String
    let state: CardState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: resolvedSymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            statusChip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedSymbol: String {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : fallbackSymbol
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            if state == .granted {
                // palette-ok: a 7pt dot carries no label, so there is no
                // foreground for the accent to swallow.
                Circle()
                    .fill(FlowTheme.accent)
                    .frame(width: 7, height: 7)
            }
            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        switch state {
        case .active: return "Next"
        case .waiting: return "Later"
        case .granted: return "Done"
        }
    }

    private var iconColor: Color {
        switch state {
        case .active: return .white
        case .waiting: return Color.white.opacity(0.44)
        case .granted: return Color.white.opacity(0.70)
        }
    }

    private var titleColor: Color {
        switch state {
        case .active: return .white
        case .waiting: return Color.white.opacity(0.76)
        case .granted: return Color.white.opacity(0.92)
        }
    }

    private var detailColor: Color {
        switch state {
        case .active: return Color.white.opacity(0.68)
        case .waiting: return Color.white.opacity(0.43)
        case .granted: return Color.white.opacity(0.55)
        }
    }

    private var statusColor: Color {
        switch state {
        case .active: return OnboardingPalette.mint
        case .waiting: return Color.white.opacity(0.48)
        case .granted: return FlowTheme.accent
        }
    }
}

// MARK: - Feature instruction card

/// "How to use" as a left-aligned, numbered 1·2·3 list — the simplest possible
/// read, like a settings menu's step list.
private struct FeatureInstructionCard: View {
    let step: FeatureTourStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to use")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(step.steps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .top, spacing: 11) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(OnboardingPalette.mint)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                            .overlay(Circle().strokeBorder(FlowTheme.hairline, lineWidth: 1))
                        Text(text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(FlowTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Intro video page

/// First-run intro: just the clip, edge to edge with the window's rounded
/// corners — no chrome, no container. Auto-advances when the video ends;
/// a quiet Skip pill is the only control.
private struct IntroVideoPage: View {
    let onFinish: () -> Void

    var body: some View {
        IntroPlayerView(onFinish: onFinish)
            // Extend under the (transparent) titlebar — the window itself
            // rounds the corners, so the clip fills every pixel of the frame.
            .ignoresSafeArea()
            .overlay(alignment: .bottomTrailing) {
                Button(action: onFinish) {
                    Text("Skip")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(Color.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .padding(16)
            }
    }
}

/// Plays the intro once (no looping) and reports when it reaches the end.
private struct IntroPlayerView: NSViewRepresentable {
    let onFinish: () -> Void

    final class Coordinator {
        var player: AVPlayer?
        var endObserver: NSObjectProtocol?

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        guard let url = OnboardingIntroVideo.url else { return view }
        let player = AVPlayer(url: url)
        let onFinish = onFinish
        context.coordinator.player = player
        context.coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in onFinish() }
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.player = nil
        view.player = nil
    }
}

// MARK: - Permission preview (right column)

private func loadOnboardingImage(named name: String) -> NSImage? {
    // .process("Resources") flattens subdirectories into the bundle root, so
    // try the subdirectory first (in case packaging ever changes) and fall
    // back to the root, where the files actually live today.
    let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Onboarding")
        ?? Bundle.module.url(forResource: name, withExtension: "png")
    guard let url else { return nil }
    return NSImage(contentsOf: url)
}

private struct PermissionPreviewPanel: View {
    let active: PermissionKind
    let axTrusted: Bool
    let scrTrusted: Bool
    let fdaGranted: Bool

    private static let promptImage = loadOnboardingImage(named: "screen-recording-prompt")
    private static let settingsImage = loadOnboardingImage(named: "screen-recording-settings")

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 0)
            if active == .accessibility || active == .fullDiskAccess {
                // No stock macOS dialog for Accessibility or Full Disk Access —
                // both are silent registrations/manual toggles, so the button
                // opens System Settings directly. One step only.
                VStack(alignment: .leading, spacing: 9) {
                    plainCaption("The button opens System Settings - turn Gizmate on in the list.")
                    settingsListPreview
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    stepCaption(1, "macOS will ask first - click “Open System Settings”.")
                    if let prompt = Self.promptImage {
                        Image(nsImage: prompt)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        FauxSystemDialog(active: active)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    stepCaption(2, "Then turn Gizmate on in the list.")
                    settingsListPreview
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The real System Settings screenshot (shared by all three permissions —
    /// the list UI is identical), with the faux list as a fallback.
    @ViewBuilder
    private var settingsListPreview: some View {
        if let settings = Self.settingsImage {
            Image(nsImage: settings)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            FauxSettingsList(
                active: active,
                gizmateEnabled: currentlyEnabled
            )
        }
    }

    private var currentlyEnabled: Bool {
        switch active {
        case .accessibility: return axTrusted
        case .screenRecording: return scrTrusted
        case .fullDiskAccess: return fdaGranted
        }
    }

    private func plainCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(FlowTheme.inkSecondary)
    }

    private func stepCaption(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(FlowTheme.raisedStrong)
                        .overlay(Circle().strokeBorder(FlowTheme.edge, lineWidth: 1))
                )
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkSecondary)
        }
    }
}

/// Flat mock of the macOS permission dialog, so users recognize what to click.
private struct FauxSystemDialog: View {
    let active: PermissionKind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(active == .screenRecording ? "Screen Recording" : "Accessibility")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.05))

            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Color(red: 0.95, green: 0.59, blue: 0.15))

                VStack(alignment: .leading, spacing: 7) {
                    Text(active == .accessibility
                        ? "\u{201C}Gizmate\u{201D} would like to control this computer"
                        : "\u{201C}Gizmate\u{201D} would like to record this computer's screen and audio.")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Grant access to this application in Privacy & Security settings, located in System Settings.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Text("Open System Settings")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.90))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(FlowTheme.accent.opacity(0.85)))
                        Text("Deny")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
                    }
                    .padding(.top, 8)
                }
            }
            .padding(18)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Flat mock of the System Settings privacy list with Gizmate's toggle live.
private struct FauxSettingsList: View {
    let active: PermissionKind
    let gizmateEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            FauxSettingsRow(
                name: active == .screenRecording ? "Loom" : "Slack",
                iconColor: .blue,
                enabled: true,
                highlighted: false
            )
            Divider().background(Color.white.opacity(0.075))
            FauxSettingsRow(
                name: "Gizmate",
                iconColor: FlowTheme.accent,
                enabled: gizmateEnabled,
                highlighted: true
            )
            Divider().background(Color.white.opacity(0.075))
            FauxSettingsRow(
                name: active == .screenRecording ? "Raycast" : "Notes",
                iconColor: active == .screenRecording ? .red : Color(white: 0.34),
                enabled: true,
                highlighted: false
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
    }
}

private struct FauxSettingsRow: View {
    let name: String
    let iconColor: Color
    let enabled: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(iconColor)
                .frame(width: 26, height: 26)
                .overlay(
                    Group {
                        if highlighted {
                            Text("⌘")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                )

            Text(name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(highlighted ? 0.92 : 0.84))

            Spacer()

            if highlighted, !enabled {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
            }

            // Faux toggle.
            Capsule()
                .fill(enabled ? Color.blue : Color(white: 0.31))
                .frame(width: 42, height: 24)
                .overlay(
                    Circle()
                        .fill(Color(white: 0.92))
                        .frame(width: 20, height: 20)
                        .offset(x: enabled ? 9 : -9)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Feature video (right column)

private struct FeatureVideoPanel: View {
    let step: FeatureTourStep

    /// The clip's real aspect ratio (width / height), loaded from the asset so
    /// portrait recordings get their full height instead of being cropped
    /// into a landscape frame. Portrait-ish fallback until the asset loads.
    @State private var videoAspect: CGFloat = 0.62

    var body: some View {
        LoopingVideoPlayer(url: step.videoURL)
            .aspectRatio(videoAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FlowTheme.hairline, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: step.videoURL) {
                let asset = AVURLAsset(url: step.videoURL)
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let size = try? await track.load(.naturalSize),
                      size.height > 0
                else { return }
                videoAspect = size.width / size.height
            }
    }
}

private struct LoopingVideoPlayer: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var player: AVQueuePlayer?
        // AVPlayerLooper must stay retained or looping silently stops after
        // the first pass.
        var looper: AVPlayerLooper?
        var currentURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        // Fill the frame instead of letterboxing — no black bars when the
        // clip's aspect doesn't exactly match the panel's.
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.currentURL != url else {
            coordinator.player?.play()
            return
        }
        coordinator.currentURL = url
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        coordinator.looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        coordinator.player = queuePlayer
        view.player = queuePlayer
        queuePlayer.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper = nil
        coordinator.player = nil
        view.player = nil
    }
}
