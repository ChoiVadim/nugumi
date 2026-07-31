import AppKit
import AVKit
import Combine
import SwiftUI

// MARK: - Root view

struct OnboardingRootView: View {
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
