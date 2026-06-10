import AppKit
import AVKit
import Combine
import SwiftUI

// MARK: - Permission model

enum PermissionKind {
    case accessibility
    case screenRecording

    var analyticsValue: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "screen_recording"
        }
    }
}

// MARK: - Feature tour data

struct FeatureTourStep {
    let title: String
    let body: String
    let actionTitle: String
    let actionDetail: String
    let symbolName: String
    let videoURL: URL

    static var all: [FeatureTourStep] {
        let askShortcut = GlobalShortcutStore.shortcut(for: .askNugumi)

        return [
            FeatureTourStep(
                title: "Ask Nugumi anything",
                body: "A confusing screen, an error, or just a question — Nugumi looks at what's in front of you and answers on the spot.",
                actionTitle: "Open the prompt near your cursor",
                actionDetail: askActionDetail(for: askShortcut),
                symbolName: "cursorarrow.click.2",
                videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/demo.mp4")!
            ),
            FeatureTourStep(
                title: "Read any language without leaving work",
                body: "Slack, Gmail, Notion, PDFs, websites — wherever the text is. And if it can't be selected, just capture that part of the screen.",
                actionTitle: "Select text, then left-click",
                actionDetail: "Highlight the text and left-click the Nugumi button that appears near the selection.",
                symbolName: "text.viewfinder",
                videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/translate.mp4")!
            ),
            FeatureTourStep(
                title: "Write naturally. Send like a native",
                body: "Type in the language you think in. Nugumi turns it into your writing language — natural grammar, tone, and phrasing.",
                actionTitle: "Select your draft, then right-click",
                actionDetail: "Highlight what you wrote and right-click the Nugumi button — it comes back in your writing language.",
                symbolName: "text.insert",
                videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/make-native.mp4")!
            ),
            FeatureTourStep(
                title: "Replies that know the answer",
                body: "This one reads their message and writes the response for you — even when it takes knowledge, like a question asked in the chat.",
                actionTitle: "Draft a reply",
                actionDetail: "Select an incoming message. Press Tab on the Nugumi button to switch to reply, then click.",
                symbolName: "bubble.left.and.text.bubble.right",
                videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/reply.mp4")!
            )
        ]
    }

    private static func askActionDetail(for shortcut: GlobalShortcut) -> String {
        switch shortcut.kind {
        case .doubleTap:
            let glyph = shortcut.displayString
            let single = String(glyph.prefix(glyph.count / 2))
            let name = modifierName(forGlyph: single)
            return "Press \(name) twice, type your question, then press Return."
        case .combo:
            return "Press \(shortcut.displayString), type your question, then press Return."
        }
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

// MARK: - Onboarding state machine

@MainActor
final class OnboardingModel: ObservableObject {
    /// `.firstRun` keeps the historical auto-advance/auto-close behavior;
    /// `.review` (opened from Help) always shows permission status and never
    /// closes itself — the user looks around and leaves when they want.
    enum Mode {
        case firstRun
        case review
    }

    enum Page: Equatable {
        case permissions
        case feature(Int)
    }

    static let featureTourCompletedKey = "permissionsOnboarding.featureTourCompleted"

    static var hasCompletedFeatureTour: Bool {
        UserDefaults.standard.bool(forKey: featureTourCompletedKey)
    }

    let mode: Mode
    let steps = FeatureTourStep.all

    @Published var page: Page = .permissions
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var scrTrusted = CGPreflightScreenCaptureAccess()

    /// Set by the window controller.
    var requestClose: (() -> Void)?
    var closeBeforeSystemDialog: (() -> Void)?

    init(mode: Mode) {
        self.mode = mode
        // First run with permissions already granted goes straight to the tour
        // (nothing to set up). Review mode always starts on the permissions
        // page so granted status stays visible.
        if mode == .firstRun, axTrusted, scrTrusted, !Self.hasCompletedFeatureTour {
            page = .feature(0)
        }
    }

    var nextPermission: PermissionKind? {
        if !axTrusted { return .accessibility }
        if !scrTrusted { return .screenRecording }
        return nil
    }

    private var shouldShowFeatureTour: Bool {
        mode == .review || !Self.hasCompletedFeatureTour
    }

    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        let scr = CGPreflightScreenCaptureAccess()
        if ax != axTrusted { axTrusted = ax }
        if scr != scrTrusted { scrTrusted = scr }

        // First-run auto-advance once both permissions land; review mode stays
        // put so the user can see (and revisit) the granted state.
        if mode == .firstRun, page == .permissions, ax, scr {
            if !Self.hasCompletedFeatureTour {
                page = .feature(0)
            } else {
                requestClose?()
            }
        }
    }

    func primaryAction() {
        switch page {
        case .feature(let index):
            advanceFeature(from: index)
        case .permissions:
            refreshTrustFlags()
            switch nextPermission {
            case .accessibility:
                openAccessibilitySettings()
            case .screenRecording:
                openScreenRecordingSettings()
            case nil:
                if shouldShowFeatureTour {
                    page = .feature(0)
                } else {
                    requestClose?()
                }
            }
        }
    }

    func skipAction() {
        if case .feature = page {
            markTourComplete()
        }
        requestClose?()
    }

    func markTourComplete() {
        UserDefaults.standard.set(true, forKey: Self.featureTourCompletedKey)
    }

    private func refreshTrustFlags() {
        axTrusted = AXIsProcessTrusted()
        scrTrusted = CGPreflightScreenCaptureAccess()
    }

    private func advanceFeature(from index: Int) {
        let nextIndex = index + 1
        if nextIndex < steps.count {
            page = .feature(nextIndex)
            return
        }
        markTourComplete()
        requestClose?()
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        closeBeforeSystemDialog?()
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecordingSettings() {
        // First click registers Nugumi in TCC so it appears in the Screen
        // Recording list. Apple's stock dialog is unavoidable, but Nugumi's
        // own onboarding window must be gone before that modal appears.
        let needsSystemPrompt = !CGPreflightScreenCaptureAccess()
        closeBeforeSystemDialog?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if needsSystemPrompt {
                _ = CGRequestScreenCaptureAccess()
            } else {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Display strings

    var stageText: String {
        switch page {
        case .permissions:
            switch nextPermission {
            case .accessibility: return "Step 1 of 2"
            case .screenRecording: return "Step 2 of 2"
            case nil: return "Ready"
            }
        case .feature(let index):
            return "Feature \(index + 1) of \(steps.count)"
        }
    }

    var titleText: String {
        switch page {
        case .permissions:
            return "Give Nugumi the access it needs"
        case .feature(let index):
            return steps[index].title
        }
    }

    var subtitleText: String {
        switch page {
        case .permissions:
            return "Nugumi only reads what you explicitly select or capture."
        case .feature(let index):
            return steps[index].body
        }
    }

    var primaryTitle: String {
        switch page {
        case .permissions:
            switch nextPermission {
            case .accessibility: return "Open Accessibility Settings"
            case .screenRecording: return "Allow Screen Capture"
            case nil: return "Continue"
            }
        case .feature(let index):
            return index == steps.count - 1 ? "Done" : "Next"
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

    private let model: OnboardingModel
    private let onClose: () -> Void

    init(mode: OnboardingModel.Mode, onClose: @escaping () -> Void) {
        self.model = OnboardingModel(mode: mode)
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Nugumi"
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
        // stays a fixed 900×640 and SwiftUI fills it.
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
            self?.window?.orderOut(nil)
            self?.close()
        }
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
            if case .feature = self.model.page {
                self.model.markTourComplete()
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
        HStack(spacing: 0) {
            leftColumn
                .frame(width: 360)
            Rectangle()
                .fill(FlowTheme.hairline)
                .frame(width: 1)
            rightColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(poll) { _ in model.refreshPermissions() }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.stageText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(OnboardingPalette.mint)

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
                    VStack(spacing: 12) {
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
                    }
                case .feature(let index):
                    FeatureInstructionCard(step: model.steps[index])
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 16)

            Button(action: { model.primaryAction() }) {
                Text(model.primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(FlowTheme.accent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { model.skipAction() }) {
                Text(model.skipTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
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
                    scrTrusted: model.scrTrusted
                )
            case .feature(let index):
                FeatureVideoPanel(step: model.steps[index])
            }
        }
        .padding(EdgeInsets(top: 44, leading: 24, bottom: 32, trailing: 26))
        .animation(.easeInOut(duration: 0.18), value: model.page)
    }
}

private enum OnboardingPalette {
    /// Light mint used for stage labels and eyebrows, matching the accent.
    static let mint = Color(red: 0.67, green: 0.93, blue: 0.88)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var resolvedSymbol: String {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : fallbackSymbol
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            if state == .granted {
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

    private var fillColor: Color {
        switch state {
        case .active: return Color.white.opacity(0.105)
        case .waiting, .granted: return Color.white.opacity(0.045)
        }
    }

    private var borderColor: Color {
        switch state {
        case .active: return FlowTheme.accent.opacity(0.92)
        case .waiting, .granted: return Color.white.opacity(0.095)
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

private struct FeatureInstructionCard: View {
    let step: FeatureTourStep

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: resolvedSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(OnboardingPalette.mint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(step.actionTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.actionDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }

    private var resolvedSymbol: String {
        NSImage(systemSymbolName: step.symbolName, accessibilityDescription: nil) != nil
            ? step.symbolName
            : "sparkle.magnifyingglass"
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

    private static let promptImage = loadOnboardingImage(named: "screen-recording-prompt")
    private static let settingsImage = loadOnboardingImage(named: "screen-recording-settings")

    var body: some View {
        VStack(spacing: 20) {
            if active == .screenRecording,
               let prompt = Self.promptImage,
               let settings = Self.settingsImage {
                Image(nsImage: prompt)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Image(nsImage: settings)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                FauxSystemDialog(active: active)
                FauxSettingsList(
                    active: active,
                    nugumiEnabled: active == .accessibility ? axTrusted : scrTrusted
                )
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
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
                        ? "\u{201C}Nugumi\u{201D} would like to control this computer"
                        : "\u{201C}Nugumi\u{201D} would like to record this computer's screen and audio.")
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

/// Flat mock of the System Settings privacy list with Nugumi's toggle live.
private struct FauxSettingsList: View {
    let active: PermissionKind
    let nugumiEnabled: Bool

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
                name: "Nugumi",
                iconColor: FlowTheme.accent,
                enabled: nugumiEnabled,
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

    var body: some View {
        // Just the video — no captions, no framing panel. resizeAspectFill in
        // the player (rather than letterboxing) keeps the edges clean.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LoopingVideoPlayer(url: step.videoURL)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(FlowTheme.hairline, lineWidth: 1)
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
