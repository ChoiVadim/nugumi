import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit

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

// MARK: - Dictation

/// WebSocket session against OpenAI's realtime transcription intent
/// (`/v1/realtime?intent=transcription`). Speech-to-text only — no
/// translation, language auto-detected. Emits one callback per completed
/// utterance (server VAD decides the phrase boundaries).
final class RealtimeTranscriptionSession: NSObject, URLSessionWebSocketDelegate {
    var onPhrase: ((String) -> Void)?
    var onFailed: ((String) -> Void)?

    private let apiKey: String
    private let safetyIdentifier: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private lazy var batcher = AudioBatcher(thresholdBytes: 4800) { [weak self] chunk in
        self?.sendJSON(["type": "input_audio_buffer.append",
                        "audio": chunk.base64EncodedString()])
    }
    private var isClosing = false
    private var reconnectAttempts = 0
    private let taskLock = NSLock()
    private var reconnectScheduled = false

    init(apiKey: String, safetyIdentifier: String) {
        self.apiKey = apiKey
        self.safetyIdentifier = safetyIdentifier
    }

    func connect() {
        session?.invalidateAndCancel()
        isClosing = false
        reconnectScheduled = false
        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        )
        // GA protocol only — an `OpenAI-Beta: realtime=v1` header now gets the
        // socket killed with `beta_api_shape_disabled` before any event flows.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let newTask = session.webSocketTask(with: request)
        self.session = session
        setTask(newTask)
        newTask.resume()
        receiveNext()
    }

    /// Feed raw 24 kHz mono PCM16 bytes; batched and sent as base64.
    func append(pcm: Data) {
        batcher.add(pcm)
    }

    func close() {
        isClosing = true
        batcher.flush()
        let closingTask = currentTask()
        let closingSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            closingTask?.cancel(with: .normalClosure, reason: nil)
            closingSession?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectAttempts = 0
            self.reconnectScheduled = false
            // GA session shape (verified live 2026-07-24): the beta
            // `transcription_session.update` flat form is rejected.
            self.sendJSON([
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": ["input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-4o-transcribe"],
                        "turn_detection": ["type": "server_vad", "silence_duration_ms": 600]
                    ]]
                ]
            ])
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosing, !self.reconnectScheduled else { return }
            self.scheduleReconnect()
        }
    }

    private func receiveNext() {
        currentTask()?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosing, !self.reconnectScheduled else { return }
                    self.scheduleReconnect()
                }
            case .success(let message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async { [weak self] in self?.handle(object) }
                }
                self.receiveNext()
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String { onPhrase?(transcript) }
        case "error":
            // Server error events are non-fatal (mirrors the translations
            // session) — the socket-level failure path handles dead sessions.
            break
        default:
            break
        }
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        taskLock.lock(); defer { taskLock.unlock() }
        return task
    }

    private func setTask(_ newTask: URLSessionWebSocketTask?) {
        taskLock.lock(); defer { taskLock.unlock() }
        task = newTask
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        currentTask()?.send(.string(string)) { _ in }
    }

    private func scheduleReconnect() {
        reconnectScheduled = true
        reconnectAttempts += 1
        guard reconnectAttempts <= 5 else {
            onFailed?("Connection lost")
            return
        }
        let delay = min(pow(2.0, Double(reconnectAttempts)), 16.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosing else { return }
            self.connect()
        }
    }
}

/// Plain dictation: mic → realtime STT → each completed phrase is typed into
/// whatever field holds the caret (⌘V paste, like the rewrite/replace flow).
/// A small floating REC pill shows elapsed time; clicking it stops. The
/// user's clipboard is snapshotted once at start and restored after stop.
@MainActor
final class DictationController: NSObject {
    private(set) var isRunning = false

    var onMissingAPIKey: (() -> Void)?
    var onMicrophonePermissionDenied: (() -> Void)?

    private var mic: MicrophoneCapture?
    private var session: RealtimeTranscriptionSession?
    private var pill: NSPanel?
    private var indicator: RecordIndicatorView?
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var clipboardSnapshot: PasteboardSnapshot?
    private var lastPasteChangeCount: Int?

    func toggle(apiKey: String?) {
        if isRunning { stop() } else { start(apiKey: apiKey) }
    }

    func start(apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning else { return }
        Task { @MainActor in
            guard await MicrophoneCapture.requestAuthorization() else {
                onMicrophonePermissionDenied?()
                return
            }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.clipboardSnapshot = PasteboardSnapshot.capture(from: .general)
            self.lastPasteChangeCount = nil

            let session = RealtimeTranscriptionSession(
                apiKey: apiKey,
                safetyIdentifier: Self.safetyIdentifier()
            )
            session.onPhrase = { [weak self] phrase in self?.insert(phrase) }
            session.onFailed = { [weak self] _ in self?.stop() }
            self.session = session
            session.connect()

            let mic = MicrophoneCapture()
            mic.onPCM = { [weak session] pcm in session?.append(pcm: pcm) }
            mic.onError = { [weak self] _ in Task { @MainActor in self?.stop() } }
            self.mic = mic
            mic.start()

            self.showPill()
            self.startedAt = Date()
            self.elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickElapsed() }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mic?.stop()
        mic = nil
        session?.close()
        session = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        pill?.orderOut(nil)
        pill = nil
        indicator = nil

        // Give the last ⌘V time to land in the target app, then put the
        // user's clipboard back — unless something else claimed it since.
        if let snapshot = clipboardSnapshot, let lastPaste = lastPasteChangeCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if NSPasteboard.general.changeCount == lastPaste {
                    snapshot.restore(to: NSPasteboard.general)
                }
            }
        }
        clipboardSnapshot = nil
        lastPasteChangeCount = nil
    }

    private func insert(_ phrase: String) {
        guard isRunning else { return }
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // ponytail: naive spacing — every phrase gets one trailing space;
        // smart spacing around punctuation if it ever grates.
        pasteboard.setString(text + " ", forType: .string)
        lastPasteChangeCount = pasteboard.changeCount
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        indicator?.setTime(String(format: "%02d:%02d", seconds / 60, seconds % 60))
    }

    /// Same glass pill the live captions collapse into, bottom-right of the
    /// main screen; any click on it stops the dictation.
    private func showPill() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false

        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizingMask = [.width, .height]
        let glass = GlassHostView(frame: root.bounds, cornerRadius: 20, tintColor: nil, style: .regular)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        let chrome = GlassChromeOverlayView(frame: root.bounds)
        chrome.cornerRadius = 20
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)
        panel.contentView = root

        let indicator = RecordIndicatorView(frame: glass.contentView.bounds)
        indicator.autoresizingMask = [.width, .height]
        indicator.onClick = { [weak self] in self?.stop() }
        indicator.onToggleRecord = { [weak self] in self?.stop() }
        glass.contentView.addSubview(indicator)

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 20
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - inset,
            y: visible.minY + inset + 56   // above the live pill's default spot
        ))
        panel.orderFrontRegardless()
        self.pill = panel
        self.indicator = indicator
        indicator.setTime("00:00")
    }

    /// Same per-install id (and UserDefaults key) the live captions use.
    private static func safetyIdentifier() -> String {
        let key = "liveTranslationSafetyID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
