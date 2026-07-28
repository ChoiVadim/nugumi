import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreServices
import CoreText
import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications
import Vision

extension GizmateApp {
    @MainActor
    func makeSummarizeOption(
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) -> RingSummarizeOption? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Browsers: summarize the open page. No time-range sub-ring — a page
        // has no time axis, so the button fires immediately.
        if BrowserPageReader.isBrowser(app.bundleIdentifier) {
            let pid = app.processIdentifier
            let pageTitle = focusedWindowTitle(pid: pid)
            let icon = app.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
            return RingSummarizeOption(
                appLabel: app.localizedName ?? "browser",
                appIcon: icon,
                runDirect: { [weak self] in
                    self?.runPageSummary(
                        pid: pid,
                        pageTitle: pageTitle,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide
                    )
                }
            )
        }
        guard let open = ChatArchiveFactory.archive(forFrontmostBundleID: app.bundleIdentifier) else {
            // Frontmost isn't a summarizable app — offer an app picker so a
            // summary can be started from anywhere.
            let choices = summarizeAppChoices(near: screenPoint, selectionRect: selectionRect, panelSide: panelSide)
            guard !choices.isEmpty else { return nil }
            let icon = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Summarize") ?? NSImage()
            return RingSummarizeOption(appLabel: "Summarize", appIcon: icon, appChoices: choices)
        }
        let title = focusedWindowTitle(pid: app.processIdentifier)
        let icon = app.icon ?? NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil) ?? NSImage()
        let label = app.localizedName ?? "chat"
        // Warm the cached KakaoTalk userId recovery now, off the click path, so
        // the first summary isn't blocked on the multi-second SHA-512 search.
        if app.bundleIdentifier == "com.kakao.KakaoTalkMac" {
            Task.detached(priority: .utility) { KakaoArchive.prewarmUserId() }
        }
        // Telegram's window title is the account name and its chat DB has no
        // reliable open-chat pointer, so read the open chat off the screen
        // (OCR the header) at summary time. Other messengers use the AX title.
        let ocrProvider: (() async -> [String])? =
            app.bundleIdentifier == TelegramChatDetector.bundleID
            ? { await TelegramChatDetector.openChatTitleCandidates() }
            : nil
        return RingSummarizeOption(appLabel: label, appIcon: icon, run: { [weak self] range in
            self?.runChatSummary(
                open: open,
                windowTitle: title,
                ocrProvider: ocrProvider,
                range: range,
                near: screenPoint,
                selectionRect: selectionRect,
                panelSide: panelSide
            )
        })
    }

    /// Summarize sources for the "from anywhere" picker. Messengers read their
    /// local DB regardless of whether they're running; the browser entry needs a
    /// running browser. Each fires directly — most-recent chat over the last
    /// week for messengers, the page for a browser — since there's no open-chat
    /// context and (for browsers) no time axis.
    @MainActor
    private func summarizeAppChoices(
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) -> [RingSummarizeOption] {
        var choices: [RingSummarizeOption] = []
        let ws = NSWorkspace.shared
        for (bundleID, label) in [("com.kakao.KakaoTalkMac", "KakaoTalk"), (TelegramChatDetector.bundleID, "Telegram")] {
            guard let open = ChatArchiveFactory.archive(forFrontmostBundleID: bundleID),
                  let appURL = ws.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            if bundleID == "com.kakao.KakaoTalkMac" {
                Task.detached(priority: .utility) { KakaoArchive.prewarmUserId() }
            }
            let icon = ws.icon(forFile: appURL.path)
            choices.append(RingSummarizeOption(appLabel: label, appIcon: icon, run: { [weak self] range in
                self?.runChatSummary(
                    open: open, windowTitle: nil, ocrProvider: nil, range: range,
                    near: screenPoint, selectionRect: selectionRect, panelSide: panelSide
                )
            }))
        }
        if let browser = ws.runningApplications.first(where: {
            BrowserPageReader.isBrowser($0.bundleIdentifier) && !$0.isTerminated
        }) {
            let pid = browser.processIdentifier
            let icon = browser.icon ?? (NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage())
            choices.append(RingSummarizeOption(appLabel: browser.localizedName ?? "Browser", appIcon: icon, runDirect: { [weak self] in
                self?.runPageSummary(
                    pid: pid, pageTitle: nil,
                    near: screenPoint, selectionRect: selectionRect, panelSide: panelSide
                )
            }))
        }
        return choices
    }

    /// Opens the chat archive, matches the frontmost chat by window title
    /// (falling back to the most-recently active chat), keeps the messages
    /// within the chosen time `range`, and panels the summary through the
    /// existing `translate(...)` path with `.summarizeChat`. Never crashes — any
    /// `ChatArchiveError` (or other failure) is surfaced via
    /// `presentChatSummaryError`.
    ///
    /// `open()` (ioreg + PBKDF2 + SQLCipher's own KDF) and the SQL reads can
    /// take several hundred ms to ~1s on a real KakaoTalk DB, so that whole
    /// local pipeline runs off the main thread in a detached task. Only the
    /// consent alert, `translate(...)`, and error presentation stay on the
    /// main actor.
    @MainActor
    private func runChatSummary(
        open: @escaping () throws -> ChatArchive,
        windowTitle: String?,
        ocrProvider: (() async -> [String])? = nil,
        range: SummaryTimeRange,
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) {
        let cutoff = range.cutoff()
        Task { [weak self] in
            guard let self else { return }
            do {
                // Read the on-screen chat (Telegram) before the DB work; empty
                // for messengers that don't need it (Kakao uses the AX title).
                let ocrCandidates = await ocrProvider?() ?? []
                let transcript = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    let archive = try open()
                    let (chat, _) = try archive.chat(forWindowTitle: windowTitle, ocrCandidates: ocrCandidates)
                    // Pull a generous recent window, then keep only the chosen
                    // time range; the token-budget trim caps the final output.
                    let recent = try archive.messages(chatID: chat.id, limit: 3000)
                    let inRange = recent.filter { $0.date >= cutoff }
                    guard !inRange.isEmpty else { throw ChatArchiveError.emptyChat }
                    return ChatTranscript.format(inRange, maxMessages: inRange.count, tokenBudget: 12_000)
                }.value

                // Nothing leaves the device only when running a genuinely local
                // Ollama model — an Ollama-hosted cloud model (e.g.
                // gpt-oss:120b-cloud) still routes through OllamaClient but
                // executes on Ollama's cloud infra, so it needs the gate too.
                let runsTrulyLocally = (self.currentBackend is OllamaClient) && !LLMModel.option(id: self.textModelID).isCloud
                if !runsTrulyLocally, !SummaryConsent.accepted {
                    guard self.presentSummaryCloudConsentAlert() else { return }
                    SummaryConsent.accepted = true
                }

                // The summary is a terminal action, not tied to the armed
                // selection — dismiss the floating bar/pet as the panel opens
                // instead of keeping it "ready" behind the Summary window.
                self.translateButtonController?.close()
                self.translateButtonController = nil
                self.petController?.clearReady()
                self.translate(
                    transcript,
                    near: screenPoint,
                    mode: .summarizeChat,
                    useCache: false,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    keepPetReadyUntilPanelCloses: false,
                    restoresReadyOnUserDismiss: false
                )
            } catch {
                self.presentChatSummaryError(error)
            }
        }
    }

    /// Browser twin of `runChatSummary`: reads the frontmost page's text off
    /// the AX tree (blocking mach IPC — runs in a detached task), then panels
    /// the summary through the existing `translate(...)` path with
    /// `.summarizePage`. Same cloud-consent gate and error surface as chats.
    @MainActor
    private func runPageSummary(
        pid: pid_t,
        pageTitle: String?,
        near screenPoint: NSPoint,
        selectionRect: NSRect?,
        panelSide: TranslationPanelController.Side
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try BrowserPageReader.pageText(pid: pid)
                }.value
                let page = pageTitle.map { "\($0)\n\n\(text)" } ?? text

                let runsTrulyLocally = (self.currentBackend is OllamaClient) && !LLMModel.option(id: self.textModelID).isCloud
                if !runsTrulyLocally, !SummaryConsent.accepted {
                    guard self.presentSummaryCloudConsentAlert(forPage: true) else { return }
                    SummaryConsent.accepted = true
                }

                self.translateButtonController?.close()
                self.translateButtonController = nil
                self.petController?.clearReady()
                self.translate(
                    page,
                    near: screenPoint,
                    mode: .summarizePage,
                    useCache: false,
                    selectionRect: selectionRect,
                    panelSide: panelSide,
                    keepPetReadyUntilPanelCloses: false,
                    restoresReadyOnUserDismiss: false
                )
            } catch {
                self.presentChatSummaryError(error, title: "Couldn't summarize the page")
            }
        }
    }

    /// One-time modal consent gate shown before the first cloud-backend chat
    /// summary. Returns `true` if the user chose to continue (caller
    /// proceeds and persists the choice); `false` means abort — the caller
    /// must not run the summary. Blocking `runModal()` on the main thread
    /// mirrors the existing `contactSupport()` alert pattern.
    @MainActor
    private func presentSummaryCloudConsentAlert(forPage: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = forPage ? "Send this page to your AI provider?" : "Send this chat to your AI provider?"
        alert.informativeText = forPage
            ? "The page contents will be sent to your selected AI provider to generate this summary."
            : "Chat contents — including messages from other people — will be sent to your selected AI provider to generate this summary."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Surfaces a chat-summary failure. `handleTranslationFailure` only
    /// recognizes `TranslationError` (it's the setup/auth-recovery path for
    /// the translation backends), so a `ChatArchiveError` here falls through
    /// to the same plain-message alert the rest of the app already uses for
    /// "nothing to act on" failures (`presentSelectionTranslationError`).
    @MainActor
    private func presentChatSummaryError(_ error: Error, title: String = "Couldn't summarize chat") {
        let message = (error as? ChatArchiveError)?.description
            ?? (error as? BrowserPageReader.PageError)?.description
            ?? error.localizedDescription
        presentSelectionTranslationError(message, title: title)
    }

}
