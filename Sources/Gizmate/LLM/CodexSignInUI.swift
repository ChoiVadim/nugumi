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
/// Gizmate on every click, yanking the main window in front of the browser
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

        // Open the browser WITHOUT activating Gizmate — the sign-in page must
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


    private var settingImage: NSImage? {
        GizmateResources.bundle.url(forResource: "codex-device-code-setting", withExtension: "png")
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
                    .foregroundStyle(FlowTheme.accentBright)
                }
                .plainButton()

                Spacer(minLength: 12)

                Button(action: cancel) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(height: 28)
                        .padding(.horizontal, 16)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .plainButton()

                Button(action: done) {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(height: 28)
                        .padding(.horizontal, 20)
                        .background(Capsule().fill(FlowTheme.accentBright))
                }
                .plainButton()
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
                    .foregroundStyle(FlowTheme.accentBright)
                    .textSelection(.enabled)
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied ? FlowTheme.accentBright : Color.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .plainButton()
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

            Text("Gizmate finishes the rest automatically once you continue.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: openPage) {
                    Text("Open page again")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.accentBright)
                }
                .plainButton()

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
                .plainButton()
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
                .background(Circle().fill(FlowTheme.accentBright))
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

