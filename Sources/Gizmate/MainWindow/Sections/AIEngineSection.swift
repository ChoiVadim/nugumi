import SwiftUI

struct AIEngineSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailContainer(
            "AI Engine",
            subtitle: "Which model does the thinking - and how hard.",
            pinned: FlowTabBar(tabs: ["Models", "Providers"], selection: $bridge.aiEngineTab)
        ) {
            if bridge.aiEngineTab == 0 {
                ModelScopeCard(scope: .textActions,
                               title: "Everyday text",
                               subtitle: "Translate, rewrite, and smart replies.",
                               onOpenPicker: { bridge.modelPickerScope = .textActions })
                ModelScopeCard(scope: .askGizmate,
                               title: "Ask Gizmate",
                               subtitle: "Screenshot questions. Vision-capable models only.",
                               onOpenPicker: { bridge.modelPickerScope = .askGizmate })
            } else {
                ForEach(orderedProviderGroups, id: \.self) { group in
                    providerGroupCard(for: group)
                }
            }
        }
    }

    /// Default order, except the engine picked during onboarding leads.
    private var orderedProviderGroups: [EngineSetupFocus] {
        let base = EngineSetupFocus.allCases
        guard let focus = bridge.engineSetupFocus else { return base }
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
