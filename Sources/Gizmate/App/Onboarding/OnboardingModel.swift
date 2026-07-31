import AppKit
import Combine
import Foundation

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
