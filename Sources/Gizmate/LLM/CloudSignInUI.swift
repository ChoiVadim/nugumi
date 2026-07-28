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

/// Builds the borderless dark HUD panel that floats above the browser without
/// stealing focus. Shared so the ChatGPT and Claude sign-in flows look identical.
enum SignInHUD {

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

    /// Numbered step bullet + label, shared by both sign-in panels.
    @ViewBuilder
    static func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 15, height: 15)
                .background(Circle().fill(FlowTheme.accentBright))
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
                        .foregroundStyle(FlowTheme.accentBright)
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
                        .background(Capsule().fill(FlowTheme.accentBright.opacity(model.code.isEmpty || isWorking ? 0.4 : 1)))
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
                        .foregroundStyle(FlowTheme.accentBright)
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
                        .background(Capsule().fill(FlowTheme.accentBright.opacity(model.key.isEmpty || isWorking ? 0.4 : 1)))
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

