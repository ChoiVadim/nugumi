import Combine
import Foundation
import GizmateToolAgentCore
import SwiftUI

// MARK: - Bridge (ObservableObject the SwiftUI tree binds to)

@MainActor
final class GizmateSettingsBridge: ObservableObject {
    weak var host: (any SettingsHost)?
    let usageStats: UsageStatsStore
    let snippets: SnippetsStore
    let tools: ToolsStore
    let ringLayout: RingLayoutStore
    let builtInOverrides: BuiltInOverridesStore
    let history: TranslationHistoryStore

    @Published var section: MainWindowSection = .home
    /// Active tab inside the AI Engine section (0 = Models, 1 = Providers).
    /// Programmatic "go set up a provider" deep links set this to 1.
    @Published var aiEngineTab: Int = 0
    /// Active tab inside Voice (0 = Style, 1 = Languages, 2 = About you,
    /// 3 = Dictionary, 4 = Snippets).
    @Published var voiceTab: Int = 0
    /// Active tab inside Settings (0 = General, 1 = Shortcuts).
    @Published var settingsTab: Int = 0
    /// Engine picked on the onboarding finale — that group's card leads the
    /// Providers tab. `nil` keeps the default order.
    @Published var engineSetupFocus: EngineSetupFocus?
    /// Non-nil while the "Choose a model" picker is open. Lives here (not in the
    /// section view) so the scrim is rendered at the window root and dims the
    /// sidebar too — a panel-scoped overlay can't paint past the detail column.
    @Published var modelPickerScope: ModelUseScope?
    /// Non-nil while the Ring tab's slot picker or prompt-tool editor is open.
    /// Same reason as `modelPickerScope`: the scrim belongs at the window root.
    @Published var ringSheet: RingSheet?
    @Published private(set) var settings: SettingsSnapshot
    @Published private(set) var bootstrap: BootstrapState
    /// True when a background check has found an update — drives the sidebar
    /// download badge. Mirrors `host.availableUpdateVersion != nil`.
    @Published private(set) var updateAvailable: Bool

    let ollamaModels: [OllamaModelOption]

    private var modelListObservers: [NSObjectProtocol] = []

    init(host: any SettingsHost) {
        self.host = host
        self.usageStats = host.usageStats
        self.snippets = host.snippets
        self.tools = host.tools
        self.ringLayout = host.ringLayout
        self.builtInOverrides = host.builtInOverrides
        self.history = host.history
        self.settings = host.makeSettingsSnapshot()
        self.bootstrap = host.bootstrapState
        self.ollamaModels = host.ollamaModels
        self.updateAvailable = host.availableUpdateVersion != nil

        // Re-render the model picker when live discovery updates either catalog.
        for name in [Notification.Name.ollamaModelsUpdated, .codexModelsUpdated, .cloudModelsUpdated] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.objectWillChange.send()
            }
            modelListObservers.append(token)
        }

        let updateToken = NotificationCenter.default.addObserver(
            forName: .updateAvailabilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Posted on the main queue, so we're already on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateAvailable = self.host?.availableUpdateVersion != nil
            }
        }
        modelListObservers.append(updateToken)
    }

    deinit {
        modelListObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Re-read from the host. Called after every `perform`, and externally by the
    /// host when settings change from elsewhere (async credential save, reset,
    /// bootstrap readiness).
    func refreshFromHost() {
        guard let host else { return }
        settings = host.makeSettingsSnapshot()
        bootstrap = host.bootstrapState
    }

    /// Run a connectivity test for a cloud provider and return the result so the
    /// caller can surface it inline.
    func testCloud(_ provider: CloudProvider) async -> CloudTestResult {
        guard let host else { return .failure("Not available.") }
        return await host.runCloudTest(for: provider)
    }

    func perform(_ intent: SettingsIntent) {
        host?.performSettingsIntent(intent)
        refreshFromHost()
    }

    // Convenience bindings -----------------------------------------------------

    func binding<T: Equatable>(
        _ keyPath: KeyPath<SettingsSnapshot, T>,
        _ intent: @escaping (T) -> SettingsIntent
    ) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                guard newValue != self.settings[keyPath: keyPath] else { return }
                self.perform(intent(newValue))
            }
        )
    }

    func writingStyleBinding(_ category: AppCategory) -> Binding<WritingStyle> {
        Binding(
            get: { self.settings.writingStyle(for: category) },
            set: { self.perform(.setWritingStyle($0, category)) }
        )
    }

    func thinkingBinding(_ scope: ModelUseScope) -> Binding<ThinkingLevel> {
        Binding(
            get: { self.settings.thinkingLevel(for: scope) },
            set: { self.perform(.setThinkingLevel($0, scope)) }
        )
    }

    func hasCredentials(_ provider: CloudProvider) -> Bool {
        host?.cloudProviderHasCredentials(provider) ?? false
    }
    var uvReady: Bool { host?.uvIsReady ?? false }
    func testScriptTool(
        _ tool: GizmateTool,
        script: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState {
        guard let host else { return .failed("Not available.") }
        return await host.testScriptTool(tool, script: script, onOutput: onOutput)
    }
    func generateScriptTool(
        description: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        guard let host else { return .failure(ToolGeneratorError.emptyDescription) }
        return await host.generateScriptTool(
            description: description,
            onPartial: onPartial,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )
    }
    func reviseScriptTool(
        tool: GizmateTool,
        script: String,
        instruction: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        guard let host else { return .failure(ToolGeneratorError.emptyDescription) }
        return await host.reviseScriptTool(
            tool: tool,
            script: script,
            instruction: instruction,
            onPartial: onPartial,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )
    }
    func repairScriptTool(
        tool: GizmateTool,
        script: String,
        failure: String,
        onPartial: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping @Sendable () async -> Void
    ) async -> Result<GeneratedTool, Error> {
        guard let host else { return .failure(ToolGeneratorError.emptyDescription) }
        return await host.repairScriptTool(
            tool: tool,
            script: script,
            failure: failure,
            onPartial: onPartial,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )
    }
    var appVersion: String { host?.appVersionString ?? "" }
    var isAppBundle: Bool { host?.isAppBundle ?? false }
    func installUpdate() { host?.installAvailableUpdate() }
}
