import AppKit
import Foundation

extension NSColor {
    /// Gizmo brand accent (#11766E) — replaces the system blue selection
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
    /// Key authenticated but the request couldn't run (out of credits /
    /// rate-limited). Not a broken key — shown with a ✓, not a ✕.
    case info(String)
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

/// Detects when a model *newly* reaches a ready state across bootstrap polls, so
/// the engine preset only re-applies on a genuine install — not on the
/// `.checking` blip that `refresh()` stamps on every model each poll. Without
/// the blip filter, an already-installed model's `.ok → .checking → .ok`
/// round-trip reads as a fresh install and re-fires the preset, stomping a
/// user's not-yet-installed model pick (e.g. Gemma 4) back to the default.
enum ModelReadyTransition {
    static func anyBecameReady(
        previous: [String: BootstrapStepStatus],
        current: [String: BootstrapStepStatus]
    ) -> Bool {
        current.contains { id, status in
            status.isTerminalOK && !(previous[id]?.isTerminalOK ?? false)
        }
    }

    /// Fold `current` into `previous`, ignoring transient `.checking` so a poll
    /// never erases the prior terminal memory of an installed model.
    static func merge(
        into previous: [String: BootstrapStepStatus],
        current: [String: BootstrapStepStatus]
    ) -> [String: BootstrapStepStatus] {
        var out = previous
        for (id, status) in current {
            if case .checking = status { continue }
            out[id] = status
        }
        return out
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

    private var hasOllamaCloudModels: Bool {
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

        switch await probeSignIn() {
        case .signedIn:
            update(\.ollamaSignedIn, .ok)
        case .signedOut:
            update(\.ollamaSignedIn, hasOllamaCloudModels
                ? .needsAction("Open Ollama and sign in (free).")
                : .ok)
        case .unsupported:
            // Older server without /api/me — fall back to the tags heuristic
            // (a cloud model listed implies the account worked at some point).
            let anyCloudPresent = models.contains { $0.isCloud && presentIDs.contains($0.id) }
            update(\.ollamaSignedIn, anyCloudPresent || !hasOllamaCloudModels
                ? .ok
                : .needsAction("Open Ollama and sign in (free)."))
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

    private enum SignInProbe {
        case signedIn
        case signedOut
        case unsupported
    }

    /// Asks the local server who is signed in. `POST /api/me` returns the
    /// account (200) when signed in and an auth error when not — unlike
    /// `/api/tags`, which keeps listing cloud models even after sign-out.
    private func probeSignIn() async -> SignInProbe {
        let url = baseURL.appending(path: "api/me")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unsupported }
        switch http.statusCode {
        case 200..<300: return .signedIn
        case 401, 403: return .signedOut
        default: return .unsupported  // 404/405: server predates /api/me
        }
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
            // "gemma4" is listed as "gemma4:latest" — match canonically so
            // bare-tag curated entries register as installed.
            let canonicalCandidates = Set(candidates.map(LLMModel.canonicalOllamaID))
            for model in models where canonicalCandidates.contains(LLMModel.canonicalOllamaID(model.id)) {
                found.insert(model.id)
            }
        }
        // Surface every installed model in the picker, not just the curated
        // set, and record which are vision-capable so Ask Gizmo can offer them.
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
