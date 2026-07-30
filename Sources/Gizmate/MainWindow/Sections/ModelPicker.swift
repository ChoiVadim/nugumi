import SwiftUI

/// The "Model" field — opens the searchable picker sheet. Mirrors
/// `MenuFieldLabel` but carries its own chevron (no native Menu to draw one).
struct ModelTriggerLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FlowTheme.inkTertiary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

/// Where a model comes from, shown on Ready-section rows so same-named models
/// from different providers (e.g. GPT-5.5 via ChatGPT vs OpenAI) are tellable
/// apart.
private func modelSourceLabel(_ model: LLMModel) -> String {
    switch model.backend {
    case .ollama(let requiresAccount):
        return requiresAccount ? "Ollama Cloud" : "Ollama"
    case .cloud(let provider):
        return provider.displayName
    }
}

/// Whether a model can serve a request right now, for the picker's status tags.
@MainActor
private func modelIsUsable(_ model: LLMModel, bridge: GizmateSettingsBridge) -> Bool {
    if let provider = model.cloudProvider {
        return bridge.hasCredentials(provider)
    }
    return bridge.bootstrap.isReady(for: model.id, requiresAccount: model.isCloud)
}

enum ModelAvailability {
    case ready       // keyed / signed in / installed — usable right now
    case needsSetup  // provider not keyed, or local model not installed
    case paidPlan    // Ollama cloud model that needs a paid Ollama plan

    @MainActor
    static func of(_ model: LLMModel, bridge: GizmateSettingsBridge) -> ModelAvailability {
        // Paid wins over sign-in: it holds even once signed in (a free account
        // won't run these), so it's the more important signal.
        if model.requiresPaidOllamaPlan { return .paidPlan }
        return modelIsUsable(model, bridge: bridge) ? .ready : .needsSetup
    }

    var tag: String? {
        switch self {
        case .ready: return nil
        case .needsSetup: return "needs setup"
        case .paidPlan: return "paid plan"
        }
    }
}

/// Pure layout helper: usable models float up into one flat "Ready" list; the
/// rest stay grouped by provider. Pulled out of the view so the partitioning is
/// unit-testable without a live bridge.
enum ModelGrouping {
    struct Group: Equatable { let title: String; let models: [LLMModel] }
    struct Result: Equatable { let ready: [LLMModel]; let rest: [Group] }

    static func partition(groups: [Group], readyIDs: Set<String>) -> Result {
        var ready: [LLMModel] = []
        var seen = Set<String>()
        for group in groups {
            for model in group.models where readyIDs.contains(model.id) && seen.insert(model.id).inserted {
                ready.append(model)
            }
        }
        let rest = groups.compactMap { group -> Group? in
            let leftover = group.models.filter { !readyIDs.contains($0.id) }
            return leftover.isEmpty ? nil : Group(title: group.title, models: leftover)
        }
        return Result(ready: ready, rest: rest)
    }
}

/// Dims the whole window and centers the picker panel. Rendered at the window
/// root (see `MainWindowRootView`) so the scrim reaches the sidebar too.
/// Clicking the scrim — anywhere outside the panel — closes it.
struct ModelPickerOverlay: View {
    let scope: ModelUseScope
    let onDismiss: () -> Void
    let onChoose: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            ModelPickerPanel(scope: scope, onDismiss: onDismiss, onChoose: onChoose)
        }
        .onExitCommand(perform: onDismiss)
    }
}

/// Two-pane model picker. Left column lists providers with their available-model
/// counts; clicking one reveals that provider's models on the right. Selecting a
/// model only stages it — the Switch button commits the change (so nothing applies
/// on a stray click). Mirrors the "SET MAIN MODEL" reference layout.
private struct ModelPickerPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let scope: ModelUseScope
    let onDismiss: () -> Void
    let onChoose: (String) -> Void

    @State private var search = ""
    @State private var selectedTitle: String?
    @State private var pendingID: String?
    @FocusState private var searchFocused: Bool

    private var currentID: String { bridge.settings.modelID(for: scope) }
    private var currentModel: LLMModel { LLMModel.option(id: currentID) }

    /// Catalog order, paired with each provider's raw models. Single source for
    /// both the filtered `entries` and the un-filtered `currentTitle` lookup.
    private var rawEntries: [(String, [LLMModel])] {
        [
            ("Ollama (local)", LLMModel.localOllamaModels),
            ("Ollama (cloud)", LLMModel.ollamaCloudModels),
            (CloudProvider.openAI.displayName, LLMModel.cloudModels(for: .openAI)),
            (CloudProvider.anthropic.displayName, LLMModel.cloudModels(for: .anthropic)),
            (CloudProvider.gemini.displayName, LLMModel.cloudModels(for: .gemini)),
            (CloudProvider.openRouter.displayName, LLMModel.cloudModels(for: .openRouter)),
            (CloudProvider.anthropicClaudeCode.displayName, LLMModel.cloudModels(for: .anthropicClaudeCode)),
            (CloudProvider.openAICodex.displayName, LLMModel.codexModels)
        ]
    }

    /// Every provider, including empties — the left column shows "0 models" for
    /// providers with nothing in this scope rather than hiding them.
    private var entries: [ModelGrouping.Group] {
        rawEntries.map { title, models in
            ModelGrouping.Group(title: title, models: scope.availableModels(from: models).filter(matches))
        }
    }

    /// Provider that holds the current model — tagged CURRENT in the left column.
    private var currentTitle: String? {
        rawEntries.first { $0.1.contains { $0.id == currentID } }?.0
    }

    /// Models shown on the right. Falls back to the first matching provider while
    /// filtering so a search never leaves the right pane stuck on an empty group.
    private var shownEntry: ModelGrouping.Group? {
        let list = entries
        let selected = list.first { $0.title == selectedTitle }
        if let selected, !selected.models.isEmpty { return selected }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            return list.first { !$0.models.isEmpty } ?? selected
        }
        return selected ?? list.first
    }

    private func matches(_ model: LLMModel) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return model.displayName.lowercased().contains(q) || model.shortName.lowercased().contains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().background(FlowTheme.hairline)
            HStack(spacing: 0) {
                providerColumn
                Divider().background(FlowTheme.hairline)
                modelColumn
            }
            Divider().background(FlowTheme.hairline)
            footer
        }
        .frame(width: 640, height: 560)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear {
            searchFocused = true
            if selectedTitle == nil {
                selectedTitle = currentTitle
                    ?? entries.first { !$0.models.isEmpty }?.title
                    ?? entries.first?.title
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a model")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text("Current: \(currentModel.shortName) · \(modelSourceLabel(currentModel))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowTheme.inkTertiary)
            TextField("Filter providers and models", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var providerColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.title) { providerRow($0) }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 200)
    }

    private func providerRow(_ entry: ModelGrouping.Group) -> some View {
        let isSelected = entry.title == selectedTitle
        let isCurrent = entry.title == currentTitle
        let empty = entry.models.isEmpty
        return Button { selectedTitle = entry.title } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? FlowTheme.accent : Color.clear)
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(empty ? FlowTheme.inkTertiary : FlowTheme.ink)
                            .lineLimit(1)
                        if isCurrent {
                            Text("CURRENT")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(FlowTheme.accent)
                        }
                    }
                    Text("\(entry.models.count) model\(entry.models.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkTertiary)
                }
                // 16px from the column edge to match the header + search field
                // (the 2.5px accent bar already sits in that gap).
                .padding(.leading, 13.5)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? FlowTheme.subtleFill : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var modelColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let entry = shownEntry, !entry.models.isEmpty {
                    ForEach(entry.models, id: \.id) { modelRow($0) }
                } else {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .padding(16)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        search.trimmingCharacters(in: .whitespaces).isEmpty
            ? "No models from this provider yet. Connect it under Providers."
            : "No models match “\(search)”."
    }

    private func modelRow(_ model: LLMModel) -> some View {
        let isPending = model.id == pendingID
        let isCurrent = model.id == currentID
        let availability = ModelAvailability.of(model, bridge: bridge)
        return Button { pendingID = model.id } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FlowTheme.accent)
                    .opacity(isPending ? 1 : 0)
                    .frame(width: 14)
                Text(model.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Text("CURRENT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkTertiary)
                } else if let tag = availability.tag {
                    Text(tag)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(FlowTheme.subtleFill))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isPending ? FlowTheme.subtleFill : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        let enabled = pendingID != nil
        return HStack(spacing: 10) {
            Text("Applies right away.")
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.inkTertiary)
            Spacer()
            SecondaryButton(title: "Cancel") { onDismiss() }
            Button {
                if let pendingID { onChoose(pendingID) }
            } label: {
                Text("Switch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? Color.white : FlowTheme.inkTertiary)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(enabled ? FlowTheme.raisedStrong : FlowTheme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        enabled ? FlowTheme.edge : FlowTheme.hairline,
                                        lineWidth: 1
                                    )
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
