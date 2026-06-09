import AppKit
import AVKit
import Foundation

extension NSColor {
    /// Nugumi brand accent (#11766E) — replaces the system blue selection
    /// tint across the setup window.
    static let nugumiAccent = NSColor(
        red: 0x11 / 255.0,
        green: 0x76 / 255.0,
        blue: 0x6E / 255.0,
        alpha: 1
    )
}

enum CloudTestResult {
    case success(preview: String)
    case failure(String)
}

enum BootstrapStepStatus: Equatable {
    case unknown
    case checking
    case ok
    case needsAction(String)
    case working(String)
    case failed(String)

    var isTerminalOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

struct BootstrapState: Equatable {
    var ollamaInstalled: BootstrapStepStatus = .unknown
    var serverRunning: BootstrapStepStatus = .unknown
    var ollamaSignedIn: BootstrapStepStatus = .unknown
    var modelReady: [String: BootstrapStepStatus] = [:]
    var cloudKeys: [CloudProvider: BootstrapStepStatus] = [:]

    func modelReady(for modelID: String) -> BootstrapStepStatus {
        modelReady[modelID] ?? .unknown
    }

    func cloudKey(for provider: CloudProvider) -> BootstrapStepStatus {
        cloudKeys[provider] ?? .unknown
    }

    func isReady(for modelID: String, requiresAccount: Bool) -> Bool {
        guard ollamaInstalled.isTerminalOK, serverRunning.isTerminalOK else { return false }
        if requiresAccount, !ollamaSignedIn.isTerminalOK { return false }
        return modelReady(for: modelID).isTerminalOK
    }

    func isCloudReady(for provider: CloudProvider) -> Bool {
        cloudKey(for: provider).isTerminalOK
    }
}

@MainActor
final class OllamaBootstrap {
    let baseURL: URL
    let models: [OllamaModelOption]

    var requiresOllamaAccount: Bool {
        models.contains(where: { $0.isCloud })
    }

    private(set) var state = BootstrapState()
    var onChange: ((BootstrapState) -> Void)?

    private let downloadPageURL = URL(string: "https://ollama.com/download/mac")!
    private let knownBundleIDs = [
        "com.electron.ollama",
        "com.ollama.ollama",
        "ai.ollama.app",
        "ai.ollama.Ollama"
    ]

    private var refreshTask: Task<Void, Never>?
    private var pullTasks: [String: Task<Void, Never>] = [:]

    init(baseURL: URL, models: [OllamaModelOption]) {
        self.baseURL = baseURL
        self.models = models
    }

    func isReady(for modelID: String) -> Bool {
        let model = LLMModel.option(id: modelID)
        if let provider = model.cloudProvider {
            return state.isCloudReady(for: provider)
        }
        let requiresAccount = model.isCloud
        return state.isReady(for: modelID, requiresAccount: requiresAccount)
    }

    func setCloudAPIKey(_ key: String?, for provider: CloudProvider) {
        KeychainStore.setAPIKey(key, for: provider)
        refresh()
    }

    // MARK: - Public actions

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.runRefresh()
        }
    }

    func openInstallPage() {
        NSWorkspace.shared.open(downloadPageURL)
    }

    func revealOllamaApp() {
        if let url = ollamaAppURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(downloadPageURL)
        }
    }

    func launchOllamaApp() {
        guard let url = ollamaAppURL() else {
            NSWorkspace.shared.open(downloadPageURL)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refresh()
            }
        }
    }

    func openOllamaForSignIn() {
        launchOllamaApp()
    }

    func startModelPull(for modelID: String) {
        guard pullTasks[modelID] == nil else { return }
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        if model.isCloud {
            update(\.ollamaSignedIn, .working("Checking sign-in…"))
        }
        setModelReady(modelID, .working(model.isCloud
            ? "Setting up the translator…"
            : "Downloading translator (this can take several minutes)…"))
        pullTasks[modelID] = Task { [weak self] in
            await self?.runPull(for: model)
            await MainActor.run { self?.pullTasks[modelID] = nil }
        }
    }

    func cancelPull(for modelID: String) {
        pullTasks[modelID]?.cancel()
        pullTasks[modelID] = nil
    }

    func cancelAllPulls() {
        for (_, task) in pullTasks {
            task.cancel()
        }
        pullTasks.removeAll()
    }

    // MARK: - Detection

    private func runRefresh() async {
        refreshCloudKeys()
        update(\.ollamaInstalled, .checking)
        update(\.serverRunning, .checking)
        update(\.ollamaSignedIn, .checking)
        for model in models {
            // Don't clobber an in-flight pull's progress text.
            if pullTasks[model.id] == nil {
                setModelReady(model.id, .checking)
            }
        }

        let appPresent = ollamaAppURL() != nil
        let serverAlive = await pingServer()

        // A live server on localhost:11434 is sufficient evidence that Ollama
        // is installed — covers Homebrew and other non-.app installs.
        if appPresent || serverAlive {
            update(\.ollamaInstalled, .ok)
        } else {
            update(\.ollamaInstalled, .needsAction("Ollama isn't installed yet."))
            update(\.serverRunning, .needsAction("Install Ollama first."))
            update(\.ollamaSignedIn, .needsAction("Install Ollama first."))
            for model in models {
                if pullTasks[model.id] == nil {
                    setModelReady(model.id, .needsAction("Install Ollama first."))
                }
            }
            return
        }

        if serverAlive {
            update(\.serverRunning, .ok)
        } else {
            update(\.serverRunning, .needsAction("Ollama isn't running. Open it to start."))
            update(\.ollamaSignedIn, .needsAction("Start Ollama first."))
            for model in models {
                if pullTasks[model.id] == nil {
                    setModelReady(model.id, .needsAction("Start Ollama first."))
                }
            }
            return
        }

        let presentIDs: Set<String>
        do {
            presentIDs = try await modelsPresent()
        } catch {
            for model in models where pullTasks[model.id] == nil {
                setModelReady(model.id, .failed(error.localizedDescription))
            }
            return
        }

        let anyCloudPresent = models.contains { $0.isCloud && presentIDs.contains($0.id) }
        if anyCloudPresent {
            update(\.ollamaSignedIn, .ok)
        } else {
            update(\.ollamaSignedIn, requiresOllamaAccount
                ? .needsAction("Open Ollama and sign in (free).")
                : .ok)
        }

        for model in models where pullTasks[model.id] == nil {
            if presentIDs.contains(model.id) {
                setModelReady(model.id, .ok)
            } else {
                setModelReady(model.id, .needsAction(model.isCloud
                    ? "Free and instant. Needs internet to translate."
                    : "Free and private. Several GB download, then works without internet."))
            }
        }
    }

    private func refreshCloudKeys() {
        var keys: [CloudProvider: BootstrapStepStatus] = [:]
        for provider in CloudProvider.cloudOnboardingCases {
            let needsAction = provider.usesOAuth
                ? "Sign in to \(provider.displayName) to use it."
                : "Paste your \(provider.displayName) API key."
            keys[provider] = provider.hasCredentials ? .ok : .needsAction(needsAction)
        }
        update(\.cloudKeys, keys)
    }

    private func pingServer() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<500).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }

    private func modelsPresent() async throws -> Set<String> {
        let url = baseURL.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(TagsResponse.self, from: data)
        var found: Set<String> = []
        var allNames: [String] = []
        for entry in payload.models {
            let candidates = [entry.name, entry.model].compactMap { $0 }
            if let name = candidates.first { allNames.append(name) }
            for model in models where candidates.contains(model.id) {
                found.insert(model.id)
            }
        }
        // Surface every installed model in the picker, not just the curated
        // set, and record which are vision-capable so Ask Nugumi can offer them.
        let vision = await visionCapableModels(among: allNames)
        OllamaModelCache.update(names: allNames, vision: vision)
        return found
    }

    /// Query `/api/show` concurrently for each model and collect the ones whose
    /// capabilities include "vision". Best-effort: a model that errors or times
    /// out is treated as text-only.
    private nonisolated func visionCapableModels(among names: [String]) async -> Set<String> {
        await withTaskGroup(of: (String, Bool).self) { group in
            for name in names {
                group.addTask { (name, await self.modelSupportsVision(name)) }
            }
            var result: Set<String> = []
            for await (name, isVision) in group where isVision { result.insert(name) }
            return result
        }
    }

    private nonisolated func modelSupportsVision(_ name: String) async -> Bool {
        let url = baseURL.appending(path: "api/show")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONEncoder().encode(ShowRequest(model: name))
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(ShowResponse.self, from: data)
        else { return false }
        return payload.capabilities?.contains("vision") ?? false
    }

    private struct ShowRequest: Encodable { let model: String }
    private struct ShowResponse: Decodable { let capabilities: [String]? }

    private func ollamaAppURL() -> URL? {
        let candidates = [
            "/Applications/Ollama.app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Ollama.app")
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        for bundleID in knownBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        return nil
    }

    // MARK: - Pull streaming

    private func runPull(for model: OllamaModelOption) async {
        let modelID = model.id
        let url = baseURL.appending(path: "api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                setModelReady(modelID, .failed("Download failed: invalid response."))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                update(\.ollamaSignedIn, .needsAction("Open Ollama and sign in (free)."))
                setModelReady(modelID, .needsAction("Sign in to Ollama first, then tap Set up."))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                setModelReady(modelID, .failed("Download failed (HTTP \(http.statusCode))."))
                return
            }

            let decoder = JSONDecoder()
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

                if let streamError = try? decoder.decode(StreamError.self, from: data),
                   let message = streamError.error {
                    let classified = OllamaClient.classifyStreamError(message: message, model: modelID)
                    if case .signInRequired = classified {
                        update(\.ollamaSignedIn, .needsAction("Open Ollama and sign in (free)."))
                        setModelReady(modelID, .needsAction("Sign in to Ollama first, then tap Set up."))
                    } else {
                        setModelReady(modelID, .failed(message))
                    }
                    return
                }

                if let progress = try? decoder.decode(PullProgress.self, from: data) {
                    let label = progress.humanReadableStatus()
                    setModelReady(modelID, .working(label))
                }
            }
            // Re-check tags to confirm.
            do {
                let presentIDs = try await modelsPresent()
                let present = presentIDs.contains(modelID)
                if present, model.isCloud {
                    update(\.ollamaSignedIn, .ok)
                }
                setModelReady(modelID, present
                    ? .ok
                    : .failed("Download finished but the translator isn't visible. Try Re-check."))
            } catch {
                setModelReady(modelID, .failed(error.localizedDescription))
            }
        } catch is CancellationError {
            setModelReady(modelID, .needsAction("Download cancelled."))
        } catch {
            setModelReady(modelID, .failed(error.localizedDescription))
        }
    }

    // MARK: - State plumbing

    private func update<V>(_ keyPath: WritableKeyPath<BootstrapState, V>, _ value: V) where V: Equatable {
        if state[keyPath: keyPath] == value { return }
        state[keyPath: keyPath] = value
        onChange?(state)
    }

    private func setModelReady(_ modelID: String, _ value: BootstrapStepStatus) {
        if state.modelReady[modelID] == value { return }
        state.modelReady[modelID] = value
        onChange?(state)
    }
}

private struct TagsResponse: Decodable {
    let models: [Entry]

    struct Entry: Decodable {
        let name: String?
        let model: String?
    }
}

private struct PullProgress: Decodable {
    let status: String?
    let total: Int64?
    let completed: Int64?

    func humanReadableStatus() -> String {
        let base = friendlyStatus(status)
        guard let total, total > 0, let completed else {
            return base
        }
        let percent = Int(Double(completed) / Double(total) * 100)
        return "\(base) \(percent)%"
    }

    private func friendlyStatus(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Downloading translator…" }
        let lower = raw.lowercased()
        if lower.contains("downloading") || lower.contains("pulling") {
            return "Downloading translator…"
        }
        if lower.contains("verifying") {
            return "Verifying download…"
        }
        if lower.contains("writing") || lower.contains("manifest") {
            return "Finishing setup…"
        }
        if lower.contains("success") {
            return "Ready."
        }
        return "Setting up the translator…"
    }
}

@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
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

    private enum Page {
        case permissions
        case feature(Int)
    }

    fileprivate struct FeatureTourStep {
        let eyebrow: String
        let title: String
        let body: String
        let actionTitle: String
        let actionDetail: String
        let shortcutLabel: String
        let shortcutDetail: String
        let symbolName: String
        let videoURL: URL

        static var all: [FeatureTourStep] {
            let translateShortcut = GlobalShortcutStore.shortcut(for: .translateOrReply).displayString
            let rewriteShortcut = GlobalShortcutStore.shortcut(for: .translateSelection).displayString
            let askShortcut = GlobalShortcutStore.shortcut(for: .askNugumi)

            return [
                FeatureTourStep(
                    eyebrow: "Understand",
                    title: "Read any language without leaving work",
                    body: "Use Nugumi where the text already is: Slack, Gmail, Notion, PDFs, websites, or any Mac app with selectable text.",
                    actionTitle: "Select text, then left-click",
                    actionDetail: "Highlight the text and left-click the Nugumi button that appears near the selection.",
                    shortcutLabel: "Left click",
                    shortcutDetail: "\(translateShortcut) also translates selected text.",
                    symbolName: "text.viewfinder",
                    videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/translate.mp4")!
                ),
                FeatureTourStep(
                    eyebrow: "Sound native",
                    title: "Write naturally. Send like a native",
                    body: "Draft in the language that feels natural, then let Nugumi polish it into your target language with better grammar, tone, and phrasing.",
                    actionTitle: "Select your draft, then right-click",
                    actionDetail: "Highlight your draft and right-click the Nugumi button to rewrite it into the target language.",
                    shortcutLabel: "Right click",
                    shortcutDetail: "\(rewriteShortcut) also rewrites selected text.",
                    symbolName: "text.insert",
                    videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/make-native.mp4")!
                ),
                FeatureTourStep(
                    eyebrow: "Reply",
                    title: "Reply across languages",
                    body: "When you need an answer instead of a translation, Nugumi can draft a reply from the incoming message.",
                    actionTitle: "Draft a reply",
                    actionDetail: "Select an incoming message. Press Tab on the Nugumi button to switch to reply, then click.",
                    shortcutLabel: "Tab",
                    shortcutDetail: "Or set Menu -> Main mode: reply, then use \(translateShortcut).",
                    symbolName: "bubble.left.and.text.bubble.right",
                    videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/reply.mp4")!
                ),
                FeatureTourStep(
                    eyebrow: "Ask Nugumi",
                    title: "Ask what to click",
                    body: "Nugumi can look at the current screen when you ask, explain what is happening, and point you to the next button or field.",
                    actionTitle: "Open the prompt near your cursor",
                    actionDetail: askActionDetail(for: askShortcut),
                    shortcutLabel: askShortcutLabel(for: askShortcut),
                    shortcutDetail: "Use it on websites, forms, dialogs, and apps.",
                    symbolName: "cursorarrow.click.2",
                    videoURL: URL(string: "https://df41nzkzrv2ws.cloudfront.net/nugumi/demo.mp4")!
                )
            ]
        }

        private static func askShortcutLabel(for shortcut: GlobalShortcut) -> String {
            switch shortcut.kind {
            case .doubleTap:
                let glyph = shortcut.displayString
                // displayString for doubleTap repeats the modifier glyph twice
                // (e.g. "⌃⌃"). Convert into a friendlier "Control x2" form.
                let single = String(glyph.prefix(glyph.count / 2))
                let name = modifierName(forGlyph: single)
                return "\(name) x2"
            case .combo:
                return shortcut.displayString
            }
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

    static let featureTourCompletedKey = "permissionsOnboarding.featureTourCompleted"

    static var hasCompletedFeatureTour: Bool {
        UserDefaults.standard.bool(forKey: featureTourCompletedKey)
    }

    private let onClose: () -> Void
    private let allowsCompletedReview: Bool
    private var page: Page = .permissions
    private var accessibilityCard: PermissionCardView!
    private var screenRecordingCard: PermissionCardView!
    private var featureInstructionView: FeatureInstructionView!
    private var stageLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var privacyNote: NSTextField!
    private var primaryButton: NSButton!
    private var skipButton: NSButton!
    private var previewView: PermissionPreviewView!
    private var featureVideoView: FeatureTourVideoView!
    private var pollTimer: Timer?

    init(allowsCompletedReview: Bool = false, onClose: @escaping () -> Void) {
        self.allowsCompletedReview = allowsCompletedReview
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Nugumi"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()

        super.init(window: window)
        window.delegate = self
        page = initialPage()
        buildUI()
        refreshState()
        startPolling()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func buildUI() {
        guard let rootView = window?.contentView else { return }
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let glass = GlassHostView(
            frame: rootView.bounds,
            cornerRadius: 18,
            tintColor: nil,
            style: .regular
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let backdrop = PermissionBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let stageLabel = NSTextField(labelWithString: "Step 1 of 2")
        stageLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        stageLabel.textColor = NSColor(calibratedRed: 0.67, green: 0.93, blue: 0.88, alpha: 1)
        stageLabel.translatesAutoresizingMaskIntoConstraints = false
        self.stageLabel = stageLabel

        let titleLabel = NSTextField(wrappingLabelWithString: "Give Nugumi the access it needs")
        titleLabel.font = NSFont.systemFont(ofSize: 31, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = 300
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel = titleLabel

        let subtitleLabel = NSTextField(wrappingLabelWithString:
            "Selected-text translation needs Accessibility. Screen-area OCR needs Screen Recording. Nugumi only reads what you explicitly select or capture.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        subtitleLabel.maximumNumberOfLines = 4
        subtitleLabel.preferredMaxLayoutWidth = 310
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.subtitleLabel = subtitleLabel

        let accessibilityCard = PermissionCardView(
            symbolName: "keyboard.badge.eye",
            fallbackSymbolName: "keyboard",
            title: "Translate selected text anywhere",
            detail: "Lets Nugumi read your current selection and run your shortcuts in other apps."
        )
        self.accessibilityCard = accessibilityCard

        let screenRecordingCard = PermissionCardView(
            symbolName: "rectangle.dashed.badge.record",
            fallbackSymbolName: "rectangle.dashed",
            title: "Translate text from the screen",
            detail: "Only used when you capture a screen area for OCR or ask about what you see."
        )
        self.screenRecordingCard = screenRecordingCard

        let featureInstructionView = FeatureInstructionView()
        featureInstructionView.translatesAutoresizingMaskIntoConstraints = false
        self.featureInstructionView = featureInstructionView

        let privacyNote = NSTextField(wrappingLabelWithString:
            "No continuous recording. No background reading. You can revoke either permission in System Settings.")
        privacyNote.font = NSFont.systemFont(ofSize: 11)
        privacyNote.textColor = NSColor.white.withAlphaComponent(0.45)
        privacyNote.preferredMaxLayoutWidth = 310
        privacyNote.translatesAutoresizingMaskIntoConstraints = false
        self.privacyNote = privacyNote

        let primaryButton = NSButton(title: "", target: self, action: #selector(primaryTapped))
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.bezelColor = .nugumiAccent
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        self.primaryButton = primaryButton

        let skipButton = NSButton(title: "Set up later", target: self, action: #selector(skipTapped))
        skipButton.bezelStyle = .regularSquare
        skipButton.isBordered = false
        skipButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        skipButton.contentTintColor = NSColor.white.withAlphaComponent(0.56)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        self.skipButton = skipButton

        let previewView = PermissionPreviewView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        self.previewView = previewView

        let featureVideoView = FeatureTourVideoView()
        featureVideoView.translatesAutoresizingMaskIntoConstraints = false
        self.featureVideoView = featureVideoView

        contentView.addSubview(backdrop)
        contentView.addSubview(stageLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(accessibilityCard)
        contentView.addSubview(screenRecordingCard)
        contentView.addSubview(featureInstructionView)
        contentView.addSubview(privacyNote)
        contentView.addSubview(primaryButton)
        contentView.addSubview(skipButton)
        contentView.addSubview(previewView)
        contentView.addSubview(featureVideoView)

        let leading: CGFloat = 36
        let rightColumnLeading: CGFloat = 388
        let top: CGFloat = 62

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            stageLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: top),
            stageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            stageLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.leadingAnchor, constant: rightColumnLeading - 24),

            titleLabel.topAnchor.constraint(equalTo: stageLabel.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            titleLabel.widthAnchor.constraint(equalToConstant: 312),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.widthAnchor.constraint(equalToConstant: 312),

            accessibilityCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            accessibilityCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            accessibilityCard.widthAnchor.constraint(equalToConstant: 312),
            accessibilityCard.heightAnchor.constraint(equalToConstant: 104),

            screenRecordingCard.topAnchor.constraint(equalTo: accessibilityCard.bottomAnchor, constant: 12),
            screenRecordingCard.leadingAnchor.constraint(equalTo: accessibilityCard.leadingAnchor),
            screenRecordingCard.widthAnchor.constraint(equalTo: accessibilityCard.widthAnchor),
            screenRecordingCard.heightAnchor.constraint(equalTo: accessibilityCard.heightAnchor),

            featureInstructionView.topAnchor.constraint(equalTo: accessibilityCard.topAnchor),
            featureInstructionView.leadingAnchor.constraint(equalTo: accessibilityCard.leadingAnchor),
            featureInstructionView.widthAnchor.constraint(equalTo: accessibilityCard.widthAnchor),
            featureInstructionView.bottomAnchor.constraint(equalTo: screenRecordingCard.bottomAnchor),

            privacyNote.topAnchor.constraint(equalTo: screenRecordingCard.bottomAnchor, constant: 18),
            privacyNote.leadingAnchor.constraint(equalTo: accessibilityCard.leadingAnchor),
            privacyNote.widthAnchor.constraint(equalTo: accessibilityCard.widthAnchor),

            primaryButton.topAnchor.constraint(greaterThanOrEqualTo: privacyNote.bottomAnchor, constant: 18),
            primaryButton.leadingAnchor.constraint(equalTo: accessibilityCard.leadingAnchor),
            primaryButton.widthAnchor.constraint(equalTo: accessibilityCard.widthAnchor),
            primaryButton.heightAnchor.constraint(equalToConstant: 44),
            primaryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -56),

            skipButton.topAnchor.constraint(equalTo: primaryButton.bottomAnchor, constant: 10),
            skipButton.centerXAnchor.constraint(equalTo: primaryButton.centerXAnchor),

            previewView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 48),
            previewView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: rightColumnLeading),
            previewView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            previewView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -36),

            featureVideoView.topAnchor.constraint(equalTo: previewView.topAnchor),
            featureVideoView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            featureVideoView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            featureVideoView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor)
        ])
    }

    private func initialPage() -> Page {
        if AXIsProcessTrusted(),
           CGPreflightScreenCaptureAccess(),
           shouldShowFeatureTour {
            return .feature(0)
        }
        return .permissions
    }

    private var shouldShowFeatureTour: Bool {
        allowsCompletedReview || !Self.hasCompletedFeatureTour
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
    }

    private func refreshState() {
        switch page {
        case .permissions:
            refreshPermissionState()
        case .feature(let index):
            renderFeature(index)
        }
    }

    private func refreshPermissionState() {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()
        let activePermission = nextPermission(accessibilityTrusted: axTrusted, screenRecordingTrusted: scrTrusted)

        titleLabel.stringValue = "Give Nugumi the access it needs"
        subtitleLabel.stringValue = "Selected-text translation needs Accessibility. Screen-area OCR needs Screen Recording. Nugumi only reads what you explicitly select or capture."
        privacyNote.stringValue = "No continuous recording. No background reading. You can revoke either permission in System Settings."
        skipButton.title = "Set up later"
        accessibilityCard.isHidden = false
        screenRecordingCard.isHidden = false
        featureInstructionView.isHidden = true
        previewView.isHidden = false
        featureVideoView.isHidden = true
        featureVideoView.stop()

        if activePermission == nil {
            stageLabel.stringValue = "Ready"
        } else {
            stageLabel.stringValue = activePermission == .screenRecording ? "Step 2 of 2" : "Step 1 of 2"
        }

        accessibilityCard.apply(
            axTrusted ? .granted : (activePermission == .accessibility ? .active : .waiting)
        )
        screenRecordingCard.apply(
            scrTrusted ? .granted : (activePermission == .screenRecording ? .active : .waiting)
        )
        previewView.configure(
            activePermission: activePermission ?? .screenRecording,
            accessibilityTrusted: axTrusted,
            screenRecordingTrusted: scrTrusted
        )

        switch activePermission {
        case .accessibility:
            setPrimaryButtonTitle("Open Accessibility Settings")
            primaryButton.isEnabled = true
        case .screenRecording:
            setPrimaryButtonTitle(scrTrusted ? "Open Screen Settings" : "Allow Screen Capture")
            primaryButton.isEnabled = true
        case nil:
            setPrimaryButtonTitle("Continue")
            primaryButton.isEnabled = true
        }

        if axTrusted && scrTrusted {
            if shouldShowFeatureTour {
                showFeature(at: 0)
                return
            }
            close()
        }
    }

    private func showFeature(at index: Int) {
        let clampedIndex = max(0, min(index, Self.FeatureTourStep.all.count - 1))
        page = .feature(clampedIndex)
        renderFeature(clampedIndex)
    }

    private func renderFeature(_ index: Int) {
        let steps = Self.FeatureTourStep.all
        guard steps.indices.contains(index) else { return }
        let step = steps[index]

        stageLabel.stringValue = "Feature \(index + 1) of \(steps.count)"
        titleLabel.stringValue = step.title
        subtitleLabel.stringValue = step.body
        accessibilityCard.isHidden = true
        screenRecordingCard.isHidden = true
        featureInstructionView.isHidden = false
        featureInstructionView.configure(step)
        privacyNote.stringValue = "You can reopen this tour anytime from the Nugumi menu."
        previewView.isHidden = true
        featureVideoView.isHidden = false
        featureVideoView.configure(step)
        setPrimaryButtonTitle(index == steps.count - 1 ? "Done" : "Next")
        primaryButton.isEnabled = true
        skipButton.title = "Skip tour"
    }

    private func nextPermission(accessibilityTrusted: Bool, screenRecordingTrusted: Bool) -> PermissionKind? {
        if !accessibilityTrusted { return .accessibility }
        if !screenRecordingTrusted { return .screenRecording }
        return nil
    }

    private func setPrimaryButtonTitle(_ title: String) {
        primaryButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]
        )
    }

    @objc private func primaryTapped() {
        if case .feature(let index) = page {
            advanceFeature(from: index)
            return
        }

        if allowsCompletedReview,
           AXIsProcessTrusted(),
           CGPreflightScreenCaptureAccess() {
            showFeature(at: 0)
            return
        }

        switch nextPermission(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingTrusted: CGPreflightScreenCaptureAccess()
        ) {
        case .accessibility:
            openAccessibilitySettings()
        case .screenRecording:
            openScreenRecordingSettings()
        case nil:
            close()
        }
    }

    @objc private func skipTapped() {
        if case .feature = page {
            markFeatureTourComplete()
        }
        close()
    }

    private func advanceFeature(from index: Int) {
        let nextIndex = index + 1
        if nextIndex < Self.FeatureTourStep.all.count {
            showFeature(at: nextIndex)
            return
        }
        markFeatureTourComplete()
        close()
    }

    private func markFeatureTourComplete() {
        UserDefaults.standard.set(true, forKey: Self.featureTourCompletedKey)
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        closeBeforeOpeningSystemPermissionUI()
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecordingSettings() {
        // First click registers Nugumi in TCC so it appears in the Screen
        // Recording list. Apple's stock dialog is unavoidable, but Nugumi's
        // own permissions window must be gone before that modal appears.
        let needsSystemPrompt = !CGPreflightScreenCaptureAccess()
        closeBeforeOpeningSystemPermissionUI()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if needsSystemPrompt {
                _ = CGRequestScreenCaptureAccess()
            } else {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func closeBeforeOpeningSystemPermissionUI() {
        pollTimer?.invalidate()
        pollTimer = nil
        featureVideoView?.stop()
        window?.orderOut(nil)
        close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if case .feature = self.page {
                self.markFeatureTourComplete()
            }
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.featureVideoView?.stop()
            self.onClose()
        }
    }
}

@MainActor
private final class PermissionBackdropView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.04, alpha: 0.96).setFill()
        bounds.fill()

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 360, y: 0))
        divider.line(to: NSPoint(x: 360, y: bounds.height))
        NSColor.white.withAlphaComponent(0.08).setStroke()
        divider.lineWidth = 1
        divider.stroke()

        let gridPath = NSBezierPath()
        let spacing: CGFloat = 34
        var x = CGFloat(360)
        while x < bounds.maxX {
            gridPath.move(to: NSPoint(x: x, y: 0))
            gridPath.line(to: NSPoint(x: x, y: bounds.maxY))
            x += spacing
        }
        var y = CGFloat(18)
        while y < bounds.maxY {
            gridPath.move(to: NSPoint(x: 360, y: y))
            gridPath.line(to: NSPoint(x: bounds.maxX, y: y))
            y += spacing
        }
        NSColor.white.withAlphaComponent(0.035).setStroke()
        gridPath.lineWidth = 1
        gridPath.stroke()
    }
}

@MainActor
private final class PermissionCardView: NSView {
    enum State {
        case active
        case waiting
        case granted
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(symbolName: String, fallbackSymbolName: String, title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: title)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = detail
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        detailLabel.preferredMaxLayoutWidth = 218
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 8
        statusLabel.layer?.masksToBounds = true

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            statusLabel.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -10),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])

        apply(.waiting)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ state: State) {
        switch state {
        case .active:
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.105).cgColor
            layer?.borderColor = NSColor.nugumiAccent.withAlphaComponent(0.92).cgColor
            iconView.contentTintColor = .white
            titleLabel.textColor = .white
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.68)
            statusLabel.stringValue = "Next"
            statusLabel.textColor = NSColor(calibratedRed: 0.67, green: 0.93, blue: 0.88, alpha: 1)
            statusLabel.layer?.backgroundColor = NSColor.clear.cgColor
        case .waiting:
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.095).cgColor
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.44)
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.76)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.43)
            statusLabel.stringValue = "Later"
            statusLabel.textColor = NSColor.white.withAlphaComponent(0.48)
            statusLabel.layer?.backgroundColor = NSColor.clear.cgColor
        case .granted:
            layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.25, alpha: 0.34).cgColor
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.42).cgColor
            iconView.contentTintColor = .systemGreen
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.92)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            statusLabel.stringValue = "Done"
            statusLabel.textColor = .systemGreen
            statusLabel.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

@MainActor
private final class FeatureInstructionView: NSView {
    private let iconView = NSImageView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let actionTitleLabel = NSTextField(wrappingLabelWithString: "")
    private let actionDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutChip = CenteredPillLabel()
    private let shortcutDetailLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.masksToBounds = true

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = NSColor(calibratedRed: 0.67, green: 0.93, blue: 0.88, alpha: 1)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        eyebrowLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrowLabel.textColor = NSColor(calibratedRed: 0.67, green: 0.93, blue: 0.88, alpha: 1)
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false

        actionTitleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        actionTitleLabel.textColor = .white
        actionTitleLabel.maximumNumberOfLines = 2
        actionTitleLabel.lineBreakMode = .byWordWrapping
        actionTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionDetailLabel.font = NSFont.systemFont(ofSize: 12)
        actionDetailLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        actionDetailLabel.maximumNumberOfLines = 3
        actionDetailLabel.preferredMaxLayoutWidth = 246
        actionDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutChip.translatesAutoresizingMaskIntoConstraints = false

        shortcutDetailLabel.font = NSFont.systemFont(ofSize: 11)
        shortcutDetailLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        shortcutDetailLabel.maximumNumberOfLines = 2
        shortcutDetailLabel.preferredMaxLayoutWidth = 190
        shortcutDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(eyebrowLabel)
        addSubview(actionTitleLabel)
        addSubview(actionDetailLabel)
        addSubview(shortcutChip)
        addSubview(shortcutDetailLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),

            eyebrowLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            eyebrowLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            actionTitleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            actionTitleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 8),
            actionTitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            actionDetailLabel.leadingAnchor.constraint(equalTo: actionTitleLabel.leadingAnchor),
            actionDetailLabel.topAnchor.constraint(equalTo: actionTitleLabel.bottomAnchor, constant: 10),
            actionDetailLabel.trailingAnchor.constraint(equalTo: actionTitleLabel.trailingAnchor),

            shortcutChip.leadingAnchor.constraint(equalTo: actionTitleLabel.leadingAnchor),
            shortcutChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            shortcutChip.heightAnchor.constraint(equalToConstant: 28),
            shortcutChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            shortcutChip.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            shortcutDetailLabel.leadingAnchor.constraint(equalTo: shortcutChip.trailingAnchor, constant: 12),
            shortcutDetailLabel.centerYAnchor.constraint(equalTo: shortcutChip.centerYAnchor),
            shortcutDetailLabel.trailingAnchor.constraint(equalTo: actionTitleLabel.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ step: PermissionsWindowController.FeatureTourStep) {
        iconView.image = NSImage(systemSymbolName: step.symbolName, accessibilityDescription: step.eyebrow)
            ?? NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: step.eyebrow)
        eyebrowLabel.stringValue = step.eyebrow.uppercased()
        actionTitleLabel.stringValue = step.actionTitle
        actionDetailLabel.stringValue = step.actionDetail
        shortcutChip.text = step.shortcutLabel
        shortcutDetailLabel.stringValue = step.shortcutDetail
    }
}

@MainActor
private final class CenteredPillLabel: NSView {
    var text = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: max(72, ceil(size.width) + 32), height: 28)
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let pillRect = bounds.insetBy(dx: 0, dy: 0)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
        NSColor.nugumiAccent.withAlphaComponent(0.72).setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        string.draw(in: textRect, withAttributes: attributes)
    }
}

@MainActor
private final class FeatureTourVideoView: NSView {
    private let playerView = AVPlayerView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.03, green: 0.045, blue: 0.05, alpha: 0.92).cgColor
        layer?.masksToBounds = true

        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 20
        playerView.layer?.masksToBounds = true
        playerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        playerView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = NSFont.systemFont(ofSize: 11)
        captionLabel.textColor = NSColor.white.withAlphaComponent(0.50)
        captionLabel.maximumNumberOfLines = 2
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(playerView)
        addSubview(titleLabel)
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            playerView.heightAnchor.constraint(equalTo: playerView.widthAnchor, multiplier: 0.64),
            playerView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),

            titleLabel.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),

            captionLabel.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            captionLabel.trailingAnchor.constraint(equalTo: playerView.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ step: PermissionsWindowController.FeatureTourStep) {
        titleLabel.stringValue = step.eyebrow
        captionLabel.stringValue = "Watch the gesture, then try the shortcut on the left."

        guard currentURL != step.videoURL else {
            player?.play()
            return
        }

        currentURL = step.videoURL
        let item = AVPlayerItem(url: step.videoURL)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        playerView.player = queuePlayer
        player = queuePlayer
        queuePlayer.play()
    }

    func stop() {
        player?.pause()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            player?.play()
        }
    }
}

@MainActor
private final class PermissionPreviewView: NSView {
    private static let screenRecordingPromptImage = loadOnboardingImage(named: "screen-recording-prompt")
    private static let screenRecordingSettingsImage = loadOnboardingImage(named: "screen-recording-settings")

    private var activePermission: PermissionsWindowController.PermissionKind = .accessibility
    private var accessibilityTrusted = false
    private var screenRecordingTrusted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(
        activePermission: PermissionsWindowController.PermissionKind,
        accessibilityTrusted: Bool,
        screenRecordingTrusted: Bool
    ) {
        self.activePermission = activePermission
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingTrusted = screenRecordingTrusted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPanelBackground()
        if activePermission == .screenRecording, drawScreenRecordingAssetPreview() {
            return
        }
        drawSystemPromptScreenshot()
        drawSystemSettingsScreenshot()
    }

    private static func loadOnboardingImage(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Onboarding"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func drawPanelBackground() {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20)
        NSColor(calibratedRed: 0.03, green: 0.045, blue: 0.05, alpha: 0.9).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.11).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawScreenRecordingAssetPreview() -> Bool {
        guard let promptImage = Self.screenRecordingPromptImage,
              let settingsImage = Self.screenRecordingSettingsImage else {
            return false
        }

        let horizontalInset: CGFloat = 24
        let promptWidth = bounds.width - horizontalInset * 2
        let promptHeight = promptWidth / aspectRatio(of: promptImage)
        let promptRect = NSRect(
            x: horizontalInset,
            y: bounds.maxY - 56 - promptHeight,
            width: promptWidth,
            height: promptHeight
        )

        let settingsWidth = promptWidth
        let settingsHeight = settingsWidth / aspectRatio(of: settingsImage)
        let settingsRect = NSRect(
            x: horizontalInset,
            y: promptRect.minY - 68 - settingsHeight,
            width: settingsWidth,
            height: settingsHeight
        )

        drawImage(promptImage, in: promptRect, cornerRadius: 22)
        drawImage(settingsImage, in: settingsRect, cornerRadius: 18)
        return true
    }

    private func aspectRatio(of image: NSImage) -> CGFloat {
        if let representation = image.representations.first,
           representation.pixelsWide > 0,
           representation.pixelsHigh > 0 {
            return CGFloat(representation.pixelsWide) / CGFloat(representation.pixelsHigh)
        }
        guard image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    private func drawImage(_ image: NSImage, in rect: NSRect, cornerRadius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high

        let clipPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        clipPath.addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSystemPromptScreenshot() {
        let promptRect = NSRect(
            x: 26,
            y: bounds.maxY - 186,
            width: bounds.width - 52,
            height: 144
        )
        fillRounded(
            promptRect,
            radius: 18,
            fill: NSColor(calibratedWhite: 0.17, alpha: 1),
            stroke: NSColor.white.withAlphaComponent(0.16)
        )

        let titleBar = NSRect(x: promptRect.minX, y: promptRect.maxY - 28, width: promptRect.width, height: 28)
        NSColor(calibratedWhite: 0.12, alpha: 0.85).setFill()
        titleBar.fill()
        drawText(
            activePermission == .screenRecording ? "Screen Recording" : "Accessibility",
            in: NSRect(x: promptRect.minX + 18, y: promptRect.maxY - 23, width: 180, height: 18),
            font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.42)
        )

        drawLockBadge(in: NSRect(x: promptRect.minX + 28, y: promptRect.minY + 42, width: 68, height: 68))

        let title = activePermission == .accessibility
            ? "\"Nugumi\" would like to control this computer"
            : "\"Nugumi\" would like to record this computer's\nscreen and audio."
        let message = activePermission == .accessibility
            ? "Grant access to this application in Privacy & Security\nsettings, located in System Settings."
            : "Grant access to this application in Privacy & Security\nsettings, located in System Settings."

        drawText(
            title,
            in: NSRect(x: promptRect.minX + 126, y: promptRect.maxY - 76, width: promptRect.width - 170, height: 48),
            font: NSFont.systemFont(ofSize: 14.5, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.93)
        )
        drawText(
            message,
            in: NSRect(x: promptRect.minX + 126, y: promptRect.maxY - 119, width: promptRect.width - 170, height: 42),
            font: NSFont.systemFont(ofSize: 13, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.86)
        )

        let settingsButton = NSRect(x: promptRect.maxX - 240, y: promptRect.minY + 20, width: 156, height: 30)
        let denyButton = NSRect(x: promptRect.maxX - 72, y: promptRect.minY + 20, width: 52, height: 30)
        fillRounded(settingsButton, radius: 8, fill: NSColor(calibratedWhite: 0.28, alpha: 1), stroke: nil)
        fillRounded(denyButton, radius: 8, fill: NSColor(calibratedWhite: 0.28, alpha: 1), stroke: nil)
        drawText(
            "Open System Settings",
            in: settingsButton.insetBy(dx: 8, dy: 6),
            font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.90),
            alignment: .center
        )
        drawText(
            "Deny",
            in: denyButton.insetBy(dx: 6, dy: 6),
            font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.88),
            alignment: .center
        )
    }

    private func drawSystemSettingsScreenshot() {
        let panelRect = NSRect(
            x: 46,
            y: 50,
            width: bounds.width - 92,
            height: bounds.height - 270
        )
        fillRounded(panelRect, radius: 16, fill: NSColor(calibratedWhite: 0.16, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.15))

        let separator = NSBezierPath()
        for rowIndex in 1...3 {
            let y = panelRect.maxY - CGFloat(rowIndex) * 54
            separator.move(to: NSPoint(x: panelRect.minX + 36, y: y))
            separator.line(to: NSPoint(x: panelRect.maxX - 24, y: y))
        }
        NSColor.white.withAlphaComponent(0.075).setStroke()
        separator.lineWidth = 1
        separator.stroke()

        let rowHeight: CGFloat = 54
        let firstRowY = panelRect.maxY - rowHeight
        drawDarkSettingsRow(
            name: activePermission == .screenRecording ? "Loom" : "Slack",
            rect: NSRect(x: panelRect.minX + 10, y: firstRowY, width: panelRect.width - 20, height: rowHeight),
            iconFill: NSColor.systemBlue,
            enabled: true,
            highlighted: false
        )
        let nugumiTrusted = activePermission == .accessibility ? accessibilityTrusted : screenRecordingTrusted
        let nugumiRow = NSRect(x: panelRect.minX + 10, y: firstRowY - rowHeight, width: panelRect.width - 20, height: rowHeight)
        drawDarkSettingsRow(
            name: "Nugumi",
            rect: nugumiRow,
            iconFill: NSColor(calibratedRed: 0.03, green: 0.12, blue: 0.13, alpha: 1),
            enabled: nugumiTrusted,
            highlighted: true
        )
        drawDarkSettingsRow(
            name: activePermission == .screenRecording ? "Raycast" : "Notes",
            rect: NSRect(x: panelRect.minX + 10, y: firstRowY - rowHeight * 2, width: panelRect.width - 20, height: rowHeight),
            iconFill: activePermission == .screenRecording ? NSColor.systemRed : NSColor(calibratedWhite: 0.34, alpha: 1),
            enabled: true,
            highlighted: false
        )

        let toggleCenter = NSPoint(x: nugumiRow.maxX - 38, y: nugumiRow.midY)
        drawArrow(
            from: NSPoint(x: toggleCenter.x - 116, y: toggleCenter.y - 1),
            to: NSPoint(x: toggleCenter.x - 28, y: toggleCenter.y),
            color: NSColor.systemRed
        )
    }

    private func drawDarkSettingsRow(
        name: String,
        rect: NSRect,
        iconFill: NSColor,
        enabled: Bool,
        highlighted: Bool
    ) {
        let iconRect = NSRect(x: rect.minX + 16, y: rect.midY - 13, width: 26, height: 26)
        fillRounded(iconRect, radius: 6, fill: iconFill, stroke: NSColor.white.withAlphaComponent(0.18))
        if highlighted {
            drawText("⌘", in: iconRect.insetBy(dx: 5, dy: 4), font: NSFont.systemFont(ofSize: 13, weight: .bold), color: .white, alignment: .center)
        }

        drawText(
            name,
            in: NSRect(x: iconRect.maxX + 18, y: rect.midY - 11, width: 180, height: 24),
            font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            color: NSColor.white.withAlphaComponent(highlighted ? 0.92 : 0.84)
        )

        let toggleRect = NSRect(x: rect.maxX - 58, y: rect.midY - 11, width: 44, height: 24)
        fillRounded(
            toggleRect,
            radius: 12,
            fill: enabled ? NSColor.systemBlue : NSColor(calibratedWhite: 0.31, alpha: 1),
            stroke: nil
        )
        let knobX = enabled ? toggleRect.maxX - 22 : toggleRect.minX + 2
        fillRounded(
            NSRect(x: knobX, y: toggleRect.minY + 2, width: 20, height: 20),
            radius: 10,
            fill: NSColor(calibratedWhite: 0.92, alpha: 1),
            stroke: NSColor.black.withAlphaComponent(0.12)
        )
    }

    private func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        color.setStroke()
        path.lineWidth = 2
        path.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - 12, y: end.y + 6))
        head.line(to: NSPoint(x: end.x - 12, y: end.y - 6))
        head.close()
        color.setFill()
        head.fill()
    }

    private func drawLockBadge(in rect: NSRect) {
        let body = NSRect(x: rect.minX + 10, y: rect.minY + 6, width: rect.width - 20, height: rect.height - 28)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6)
        NSColor(calibratedRed: 0.95, green: 0.59, blue: 0.15, alpha: 1).setFill()
        bodyPath.fill()

        let shackle = NSBezierPath()
        shackle.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.minY + 39),
            radius: 17,
            startAngle: 0,
            endAngle: 180,
            clockwise: false
        )
        shackle.lineWidth = 6
        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        shackle.stroke()

        let badgeRect = NSRect(x: rect.maxX - 23, y: rect.minY + 6, width: 30, height: 30)
        fillRounded(
            badgeRect,
            radius: 15,
            fill: activePermission == .accessibility ? NSColor.systemBlue : NSColor.systemRed,
            stroke: NSColor.white.withAlphaComponent(0.85)
        )
    }

    private func fillRounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor?) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

