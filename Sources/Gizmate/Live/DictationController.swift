import AppKit
import Carbon.HIToolbox
import Foundation

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
    /// Set while a `.dictation` gizmo is waiting on its input: phrases are
    /// collected instead of typed, and handed over when the run ends.
    private var collect: ((String?) -> Void)?
    private var heard: [String] = []

    func toggle(apiKey: String?) {
        if isRunning { stop() } else { start(apiKey: apiKey) }
    }

    /// Records into a string rather than into whatever app holds the caret, and
    /// returns everything heard once the user clicks the pill. This is the
    /// `.dictation` tool input: from here down a spoken gizmo looks exactly like
    /// an `.ask` one, and nil means the same thing a dismissed capsule does —
    /// a cancelled tool, not an error.
    func dictate(apiKey: String?) async -> String? {
        guard !isRunning, collect == nil else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            heard = []
            collect = { cont.resume(returning: $0) }
            start(apiKey: apiKey)
        }
    }

    func start(apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty else {
            onMissingAPIKey?()
            finishCollecting()
            return
        }
        guard !isRunning else { finishCollecting(); return }
        Task { @MainActor in
            guard await MicrophoneCapture.requestAuthorization() else {
                onMicrophonePermissionDenied?()
                self.finishCollecting()
                return
            }
            guard !self.isRunning else { self.finishCollecting(); return }
            self.isRunning = true
            // Nothing is pasted while collecting, so there is nothing to put back.
            self.clipboardSnapshot = self.collect == nil
                ? PasteboardSnapshot.capture(from: .general)
                : nil
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
        finishCollecting()
    }

    /// Hands the transcript to whoever called `dictate`. Called from every exit
    /// `start` has as well as from `stop`, because a continuation nobody resumes
    /// is a gizmo that never runs and a ring that never comes back.
    private func finishCollecting() {
        guard let collect else { return }
        self.collect = nil
        let text = heard.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        heard = []
        collect(text.isEmpty ? nil : text)
    }

    private func insert(_ phrase: String) {
        guard isRunning else { return }
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard collect == nil else { heard.append(text); return }
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
