import SwiftUI

enum AIEngineStatusCopy {
    static let ollamaCloudSignInNoticeText = "This model runs on Ollama's cloud with a free Ollama account. Local Ollama models work without signing in."
    static let ollamaCloudPaidNoticeText = "This model runs on Ollama's cloud and needs a paid Ollama plan. Local Ollama models work for free without signing in."

    static func ollamaCloudSignInNotice(
        for model: LLMModel,
        signInStatus: BootstrapStepStatus
    ) -> String? {
        guard model.isOllama, model.isCloud else { return nil }
        switch signInStatus {
        case .needsAction, .failed:
            return model.requiresPaidOllamaPlan ? ollamaCloudPaidNoticeText : ollamaCloudSignInNoticeText
        case .unknown, .checking, .ok, .working:
            return nil
        }
    }
}

struct InlineInfoRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }
}

struct ProviderRow: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let provider: CloudProvider
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let signedIn = bridge.hasCredentials(provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Same status glyphs as the Ollama setup steps below, so both
                // cards read in one visual language.
                Group {
                    if signedIn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(FlowTheme.accent)
                    } else {
                        Circle()
                            .strokeBorder(FlowTheme.inkTertiary, lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                    }
                }
                .frame(width: 16)
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                Spacer()
                Text(signedIn ? "Connected" : "Not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                if signedIn {
                    SecondaryButton(title: testing ? "Testing…" : "Test", minWidth: 76) { runTest() }
                }
                SecondaryButton(title: buttonTitle(signedIn: signedIn), minWidth: 96) {
                    bridge.perform(.signInCloud(provider))
                }
                if signedIn {
                    SecondaryButton(title: provider.usesOAuth ? "Sign out" : "Remove", minWidth: 76) {
                        bridge.perform(.signOutCloud(provider))
                    }
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runTest() {
        guard !testing else { return }
        testing = true
        testResult = nil
        Task { @MainActor in
            let result = await bridge.testCloud(provider)
            testing = false
            switch result {
            case .success(let preview):
                testResult = "✓ Working - “\(preview)”"
            case .info(let message):
                testResult = "✓ \(message)"
            case .failure(let message):
                testResult = "✕ \(message)"
            }
        }
    }

    private func buttonTitle(signedIn: Bool) -> String {
        if provider.usesOAuth { return signedIn ? "Re-sign in" : "Sign in" }
        return signedIn ? "Update key" : "Add key"
    }
}

// MARK: - Ollama local setup (ported from the old "Gizmate Setup" window)

struct OllamaSetupCard: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    private var state: BootstrapState { bridge.bootstrap }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local models (Ollama)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowTheme.ink)
                    Text("Runs entirely on your Mac - private and free, but downloads about 12 GB. Do these steps in order.")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SetupStepRow(
                    title: "1. Install Ollama",
                    status: state.ollamaInstalled,
                    primary: StepButton(title: "Open download page") { bridge.perform(.openOllamaInstall) },
                    secondary: StepButton(title: "Re-check") { bridge.perform(.refreshBootstrap) }
                )
                Divider().background(FlowTheme.hairline)
                SetupStepRow(
                    title: "2. Start Ollama",
                    status: state.serverRunning,
                    primary: StepButton(title: "Open Ollama") { bridge.perform(.launchOllama) }
                )
                InlineInfoRow(text: "Once Ollama is running, download a model in the Ollama app, then open the Models tab and pick it.")
            }
        }
    }
}

struct OllamaCloudSetupCard: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let models: [LLMModel]

    private var title: String {
        models.count == 1
            ? "Ollama cloud model"
            : "Ollama cloud models"
    }

    private var subtitle: String {
        let names = models.map(\.shortName).joined(separator: ", ")
        let verb = models.count == 1 ? "runs" : "run"
        let plan = models.contains(where: \.requiresPaidOllamaPlan)
            ? "A free Ollama account covers gpt-oss:120b; other cloud models need a paid Ollama plan."
            : "Sign in with a free Ollama account."
        return "\(names) \(verb) on Ollama's cloud. \(plan) Local Ollama models work without an account."
    }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowTheme.ink)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupStepRow(
                    title: "Sign in to Ollama",
                    status: bridge.bootstrap.ollamaSignedIn,
                    okMessage: "Signed in to your free Ollama account.",
                    primary: StepButton(title: "Open Ollama") { bridge.perform(.openOllamaSignIn) },
                    secondary: StepButton(title: "Re-check") { bridge.perform(.refreshBootstrap) }
                )
            }
        }
    }
}

private struct StepButton {
    let title: String
    let action: () -> Void
}

/// Status dot/spinner/checkmark mirroring the AppKit StepRow visuals, driven by
/// `BootstrapStepStatus`.
private struct SetupStatusGlyph: View {
    let status: BootstrapStepStatus
    var body: some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(FlowTheme.accent)
        case .working, .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
        case .needsAction, .unknown:
            Circle()
                .strokeBorder(FlowTheme.inkTertiary, lineWidth: 1.5)
                .frame(width: 13, height: 13)
        }
    }
}

private func setupStatusMessage(_ status: BootstrapStepStatus, okMessage: String?) -> String? {
    switch status {
    case .ok: return okMessage
    case .needsAction(let m), .failed(let m), .working(let m): return m
    case .checking: return "Checking…"
    case .unknown: return nil
    }
}

private struct SetupStepRow: View {
    let title: String
    let status: BootstrapStepStatus
    var okMessage: String?
    let primary: StepButton
    var secondary: StepButton?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SetupStatusGlyph(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                if let message = setupStatusMessage(status, okMessage: okMessage) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !status.isTerminalOK {
                if let secondary {
                    SecondaryButton(title: secondary.title, action: secondary.action)
                }
                SecondaryButton(title: primary.title, action: primary.action)
            }
        }
    }
}
