import SwiftUI

// MARK: - Settings: Models & Providers tabs

/// Which model does the thinking, per use scope.
struct ModelsTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        Group {
            ModelScopeCard(scope: .textActions,
                           title: "Everyday text",
                           subtitle: "Translate, rewrite, and smart replies.",
                           onOpenPicker: { bridge.modelPickerScope = .textActions })
            ModelScopeCard(scope: .askGizmate,
                           title: "Ask Gizmate",
                           subtitle: "Screenshot questions. Vision-capable models only.",
                           onOpenPicker: { bridge.modelPickerScope = .askGizmate })
        }
    }
}

/// Where those models come from. Signing in with a plan you already pay for is
/// the path almost everyone wants, so it stands alone; running Ollama locally or
/// pasting raw API keys is the escape hatch, folded behind "Advanced".
struct ProvidersTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    @State private var showAdvanced = false

    var body: some View {
        Group {
            providerGroupCard(for: .subscription)

            AdvancedToggle(isOn: $showAdvanced)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if showAdvanced {
                ForEach(advancedGroups, id: \.self) { group in
                    providerGroupCard(for: group)
                }
            }
        }
        // Someone who picked local or API keys on the onboarding finale meant it
        // — open the drawer for them rather than hiding what they just chose.
        .onAppear {
            if let focus = bridge.engineSetupFocus, focus != .subscription {
                showAdvanced = true
            }
        }
    }

    /// Default order, except the engine picked during onboarding leads.
    private var advancedGroups: [EngineSetupFocus] {
        let base: [EngineSetupFocus] = [.local, .apiKeys]
        guard let focus = bridge.engineSetupFocus, base.contains(focus) else { return base }
        return [focus] + base.filter { $0 != focus }
    }

    @ViewBuilder
    private func providerGroupCard(for group: EngineSetupFocus) -> some View {
        switch group {
        case .local:
            VStack(alignment: .leading, spacing: 16) {
                OllamaSetupCard()
                if !selectedOllamaCloudModels.isEmpty {
                    OllamaCloudSetupCard(models: selectedOllamaCloudModels)
                }
            }
        case .subscription:
            ProviderGroupCard(
                title: "Subscriptions",
                subtitle: "Use a plan you already pay for - sign in with your account.",
                providers: CloudProvider.allCases.filter { $0.usesOAuth }
            )
        case .apiKeys:
            ProviderGroupCard(
                title: "API keys",
                subtitle: "Pay-as-you-go with your own keys. Stored locally on this Mac.",
                providers: CloudProvider.allCases.filter { !$0.usesOAuth }
            )
        }
    }

    private var selectedOllamaCloudModels: [LLMModel] {
        var seen = Set<String>()
        return ModelUseScope.allCases.compactMap { scope in
            let model = LLMModel.option(id: bridge.settings.modelID(for: scope))
            guard model.isOllama, model.isCloud else { return nil }
            return seen.insert(model.id).inserted ? model : nil
        }
    }
}

/// Quiet text link under the Subscriptions card. Deliberately not a
/// `SecondaryButton`: a filled pill reads as an equal option to signing in,
/// which is the opposite of what this is.
private struct AdvancedToggle: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(isOn ? "Hide advanced" : "Advanced")
                .font(.system(size: 12.5))
                .foregroundStyle(hovering ? FlowTheme.ink : FlowTheme.inkTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ProviderGroupCard: View {
    let title: String
    let subtitle: String
    let providers: [CloudProvider]

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                ForEach(providers, id: \.self) { provider in
                    ProviderRow(provider: provider)
                    if provider != providers.last {
                        Divider().background(FlowTheme.hairline)
                    }
                }
            }
        }
    }
}

private struct ModelScopeCard: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let scope: ModelUseScope
    let title: String
    let subtitle: String
    let onOpenPicker: () -> Void

    private var currentID: String { bridge.settings.modelID(for: scope) }
    private var currentModel: LLMModel { LLMModel.option(id: currentID) }

    private var ollamaCloudSignInNotice: String? {
        AIEngineStatusCopy.ollamaCloudSignInNotice(
            for: currentModel,
            signInStatus: bridge.bootstrap.ollamaSignedIn
        )
    }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(FlowTheme.inkSecondary)
                }
                SettingRow("Model") {
                    Button(action: onOpenPicker) {
                        ModelTriggerLabel(text: currentModel.shortName)
                    }
                    .buttonStyle(.plain)
                }
                if let ollamaCloudSignInNotice {
                    InlineInfoRow(text: ollamaCloudSignInNotice)
                }
                SettingRow("Thinking") {
                    PillPicker(options: ThinkingLevel.allCases,
                               selection: bridge.thinkingBinding(scope),
                               label: { $0.menuTitle })
                }
            }
        }
    }
}
