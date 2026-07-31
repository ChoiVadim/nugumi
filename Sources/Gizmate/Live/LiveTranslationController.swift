import Foundation

/// Owns the live-translation lifecycle: single switchable audio source,
/// sentence-segmented transcript, collapsible panel.
@MainActor
final class LiveTranslationController: NSObject {
    static let perMinuteCostUSD = 0.034

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isCollapsed = false
    private let panel = LiveCaptionPanelController()
    private var dialogue = LiveDialogue()
    private var showSource: Bool {
        get { UserDefaults.standard.object(forKey: "liveTranslationShowSource") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveTranslationShowSource") }
    }
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var session: RealtimeTranslationSession?
    private var elapsedTimer: Timer?
    private var pauseTimer: Timer?
    private var startGeneration = 0
    private var activeSource: LiveAudioSource = .systemAudio
    private var targetLanguage: TranslationLanguage = .defaultLanguage
    private var apiKey: String = ""
    // Last (transcript, summary) pair — re-summarizing identical text reuses it.
    private var summaryCache: (text: String, summary: String)?
    // Follow-up Q&A grounding: the summary currently on screen + prior turns.
    // Reset whenever a fresh summary is shown so questions chain within one summary.
    private var lastSummary = ""
    private var followUpHistory: [[String: Any]] = []

    // Active-time accounting. Pause freezes it, so cost/billing only count the
    // time audio is actually streaming, not wall-clock since first start.
    private var accumulatedSeconds: TimeInterval = 0
    private var segmentStart: Date?

    var onMissingAPIKey: (() -> Void)?
    var onMicrophonePermissionDenied: (() -> Void)?

    func toggle(apiKey: String?, targetLanguage: TranslationLanguage) {
        // The hotkey only shows/hides the window — it never changes pause/run state.
        // (Resume is via the pause button or the pill's record glyph.)
        if isRunning || isPaused {
            toggleCollapsed()
        } else {
            start(apiKey: apiKey, targetLanguage: targetLanguage)
        }
    }

    /// Live-update the target language (e.g. when the user changes it in the menu
    /// while a session is active), reconfiguring the running session.
    func updateTargetLanguage(_ language: TranslationLanguage) {
        guard isRunning || isPaused else { return }
        guard language != targetLanguage else { return }
        targetLanguage = language
        summaryCache = nil   // summary is written in this language — stale on change
        session?.setLanguage(LiveTranslationLanguage.apiCode(for: language))
        panel.update(status: currentStatusText())
    }

    func start(apiKey: String?, targetLanguage: TranslationLanguage) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning, !isPaused else { return }
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        dialogue = LiveDialogue()
        accumulatedSeconds = 0
        isCollapsed = false
        summaryCache = nil
        lastSummary = ""
        followUpHistory = []
        LiveAudioSource.current = .microphone   // every new session defaults to the mic
        panel.resetSummaryForNewSession()

        panel.onStop = { [weak self] in self?.stop() }
        panel.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }
        panel.onTogglePause = { [weak self] in self?.togglePauseResume() }
        panel.onToggleSource = { [weak self] in self?.toggleSource() }
        panel.onSummarize = { [weak self] in self?.summarize() }
        panel.onFollowUp = { [weak self] question in self?.askFollowUp(question) }
        panel.onRestart = { [weak self] in self?.restart() }
        panel.onSourceChange = { [weak self] newSource in self?.changeSource(to: newSource) }
        panel.setSource(LiveAudioSource.current)
        panel.setShowSource(showSource)
        renderTranscripts()
        panel.update(cost: "00:00 · ~$0.00")
        panel.showCaptions()

        launchSession()
    }

    private func renderTranscripts() {
        panel.render(dialogue, showSource: showSource)
    }

    private func toggleSource() {
        showSource.toggle()
        panel.setShowSource(showSource)
        renderTranscripts()
    }

    private func currentStatusText() -> String {
        if isPaused { return "Paused - press play to continue" }
        if isRunning { return "Listening → \(targetLanguage.displayName)" }
        return "Stopped"
    }

    private func summarize() {
        let text = dialogue.translationText
        guard !text.isEmpty else { panel.update(status: "Nothing to summarize yet."); return }
        // Reuse the last summary if the transcript hasn't changed — no API call.
        if let cached = summaryCache, cached.text == text {
            startFollowUpThread(with: cached.summary)
            panel.showSummary(cached.summary)
            return
        }
        guard !apiKey.isEmpty else { onMissingAPIKey?(); return }
        panel.update(status: "Summarizing…")
        panel.showSummaryLoading()
        let key = apiKey
        let language = targetLanguage.displayName   // reading language — always summarize in it
        Task { [weak self] in
            do {
                let summary = try await LiveSummarizer.summarize(text, apiKey: key, language: language)
                guard let self else { return }
                self.summaryCache = (text, summary)
                self.startFollowUpThread(with: summary)
                self.panel.showSummary(summary)
                self.panel.update(status: self.currentStatusText())
            } catch {
                guard let self else { return }
                self.panel.showSummary("⚠︎ Couldn't summarize: \(error.localizedDescription)")
                self.panel.update(status: self.currentStatusText())
            }
        }
    }

    /// A freshly shown summary starts a clean follow-up conversation grounded in it.
    private func startFollowUpThread(with summary: String) {
        lastSummary = summary
        followUpHistory = []
    }

    private func askFollowUp(_ question: String) {
        guard !lastSummary.isEmpty else { return }   // only meaningful once a summary exists
        guard !apiKey.isEmpty else { onMissingAPIKey?(); return }
        let transcript = dialogue.translationText   // grounded in the transcript as it stands now
        let summary = lastSummary
        let history = followUpHistory
        let key = apiKey
        let language = targetLanguage.displayName
        panel.showFollowUpPending()
        Task { [weak self] in
            do {
                let answer = try await LiveSummarizer.answer(
                    question: question, transcript: transcript, summary: summary,
                    history: history, apiKey: key, language: language)
                guard let self else { return }
                self.followUpHistory.append(["role": "user", "content": question])
                self.followUpHistory.append(["role": "assistant", "content": answer])
                self.panel.showFollowUpAnswer(answer)
            } catch {
                self?.panel.showFollowUpAnswer("⚠︎ Couldn't answer: \(error.localizedDescription)")
            }
        }
    }

    /// Spins up a session + capture + timers for the current source, keeping the
    /// existing transcript. Shared by start() (fresh transcript) and resume().
    private func launchSession() {
        isRunning = true
        isPaused = false
        startGeneration += 1
        segmentStart = Date()
        let source = LiveAudioSource.current
        activeSource = source
        panel.setPaused(false)
        panel.update(status: "Connecting… → \(targetLanguage.displayName)")

        let session = RealtimeTranslationSession(
            apiKey: apiKey,
            languageCode: LiveTranslationLanguage.apiCode(for: targetLanguage),
            safetyIdentifier: LiveTranslationController.safetyIdentifier()
        )
        session.onTranslatedDelta = { [weak self] delta, ms in
            guard let self else { return }
            self.dialogue.appendTranslation(delta, ms: ms)
            self.renderTranscripts()
        }
        session.onSourceDelta = { [weak self] delta, ms in
            guard let self else { return }
            self.dialogue.appendOriginal(delta, ms: ms)
            self.renderTranscripts()
        }
        session.onServerError = { [weak self] message in
            // Non-fatal: surface briefly, keep translating.
            self?.panel.update(status: "⚠︎ \(message)")
        }
        session.onStatusChange = { [weak self] status in
            guard let self else { return }
            if case .failed(let message) = status {
                self.stop(finalStatus: "Error: \(message) - stopped.", keepVisible: true)
            } else {
                self.panel.update(status: Self.statusText(status, language: self.targetLanguage))
            }
        }
        session.connect()
        self.session = session

        startCapture(source, into: session, generation: startGeneration)
        startCostTimer()
    }

    func togglePauseResume() {
        if isPaused { resume() }
        else if isRunning { pause() }
    }

    /// Clears the transcript, summary, and billing and starts a fresh session —
    /// the panel stays open (unlike Stop).
    func restart() {
        guard isRunning || isPaused else { return }
        accumulateActiveTime()
        teardownCaptureAndSession()
        dialogue = LiveDialogue()
        accumulatedSeconds = 0
        segmentStart = nil
        summaryCache = nil
        panel.resetSummaryForNewSession()
        renderTranscripts()
        panel.update(cost: "00:00 · ~$0.00")
        launchSession()
    }

    /// Stops capture + billing but keeps the transcript and panel open so the
    /// user can resume into the same history.
    func pause() {
        guard isRunning else { return }
        isRunning = false
        isPaused = true
        accumulateActiveTime()
        teardownCaptureAndSession()
        renderTranscripts()
        panel.setPaused(true)
        panel.update(status: "Paused - press play to continue")
        updateCost()
    }

    func resume() {
        guard isPaused else { return }
        panel.update(status: "Resuming…")
        launchSession()
    }

    private func teardownCaptureAndSession() {
        pauseTimer?.invalidate(); pauseTimer = nil
        elapsedTimer?.invalidate(); elapsedTimer = nil
        session?.onStatusChange = nil
        systemCapture?.stop(); systemCapture = nil
        micCapture?.stop(); micCapture = nil
        session?.close(); session = nil
    }

    private func startCapture(_ source: LiveAudioSource, into session: RealtimeTranslationSession, generation: Int) {
        switch source {
        case .systemAudio:
            let capture = SystemAudioCapture()
            capture.onPCM = { [weak session] data in session?.append(pcm: data) }
            capture.onError = { [weak self] message in self?.panel.update(status: message) }
            systemCapture = capture
            Task { await capture.start() }
        case .microphone:
            Task { [weak self] in
                guard await MicrophoneCapture.requestAuthorization() else {
                    guard let self else { return }
                    self.onMicrophonePermissionDenied?()
                    self.stop(finalStatus: "Microphone access needed", keepVisible: false)
                    return
                }
                guard let self, self.isRunning, self.startGeneration == generation else { return }
                let mic = MicrophoneCapture()
                mic.onPCM = { [weak session] data in session?.append(pcm: data) }
                mic.onError = { [weak self] message in self?.panel.update(status: message) }
                mic.start()
                self.micCapture = mic
            }
        }
    }

    private func changeSource(to newSource: LiveAudioSource) {
        LiveAudioSource.current = newSource
        guard newSource != activeSource else { return }
        activeSource = newSource
        panel.setSource(newSource)
        guard isRunning, let session else { return }
        startGeneration += 1
        systemCapture?.stop(); systemCapture = nil
        micCapture?.stop(); micCapture = nil
        panel.update(status: "Switching to \(newSource.title)…")
        startCapture(newSource, into: session, generation: startGeneration)
    }

    func toggleCollapsed() {
        guard isRunning || isPaused else { return }
        isCollapsed.toggle()
        if isCollapsed { panel.showIndicator() } else { panel.showCaptions() }
    }

    func stop(finalStatus: String = "Stopped", keepVisible: Bool = false) {
        guard isRunning || isPaused else { return }
        isRunning = false
        isPaused = false
        isCollapsed = false
        accumulateActiveTime()
        teardownCaptureAndSession()
        panel.setPaused(false)
        renderTranscripts()
        panel.update(status: finalStatus)
        if keepVisible { panel.showCaptions() } else { panel.close() }
    }

    private func startCostTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCost() }
        }
        updateCost()
    }

    private func accumulateActiveTime() {
        if let segmentStart {
            accumulatedSeconds += Date().timeIntervalSince(segmentStart)
            self.segmentStart = nil
        }
    }

    private func totalActiveSeconds() -> TimeInterval {
        accumulatedSeconds + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func updateCost() {
        let seconds = totalActiveSeconds()
        let cost = (seconds / 60.0) * Self.perMinuteCostUSD
        let elapsed = Int(seconds)
        panel.update(cost: String(format: "%02d:%02d · ~$%.2f", elapsed / 60, elapsed % 60, cost))
    }

    private static func statusText(_ status: RealtimeTranslationSession.Status,
                                   language: TranslationLanguage) -> String {
        switch status {
        case .connecting: return "Connecting… → \(language.displayName)"
        case .listening: return "Listening → \(language.displayName)"
        case .reconnecting: return "Reconnecting…"
        case .failed(let message): return "Error: \(message)"
        case .closed: return "Stopped"
        }
    }

    /// Stable, non-identifying per-install id for OpenAI-Safety-Identifier.
    private static func safetyIdentifier() -> String {
        let key = "liveTranslationSafetyID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
