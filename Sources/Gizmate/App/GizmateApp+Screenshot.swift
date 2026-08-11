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
    func startScreenshotTranslation() {
        guard !isScreenshotTranslationRunning else {
            return
        }

        isScreenshotTranslationRunning = true
        startScreenshotDragTracking()
        updateMenuState()
        translateButtonController?.close()
        translateButtonController = nil
        translationPanelController?.close()
        translationPanelController = nil

        Task { [weak self] in
            do {
                // Gizmate's own UI must never end up in the OCR shot — the
                // annotation layer is deliberately screenshot-capturable now,
                // and its text labels would pollute recognition. sharingType
                // only affects captures, so nothing visibly changes on screen.
                let sharingSnapshot = await MainActor.run {
                    Self.hideAppWindowsFromScreenCapture()
                }
                let screenshotURL: URL
                do {
                    screenshotURL = try await ScreenshotCapture.captureInteractiveArea()
                } catch {
                    await MainActor.run {
                        Self.restoreAppWindowSharing(sharingSnapshot)
                    }
                    throw error
                }
                await MainActor.run {
                    Self.restoreAppWindowSharing(sharingSnapshot)
                }
                defer {
                    try? FileManager.default.removeItem(at: screenshotURL)
                }

                let recognizedText = try await ImageTextRecognizer.recognizeText(in: screenshotURL)
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.updateMenuState()

                    let sourceText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !TextNormalizer.cleanedSelection(sourceText).isEmpty else {
                        self.resetScreenshotDragTracking()
                        self.presentScreenshotTranslationError(ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let panelSide = self.panelSideForScreenshotEnding(at: mouseLocation)
                    self.resetScreenshotDragTracking()
                    let mode = self.floatingDefaultMode.translationMode
                    let usageKind: UsageStatsEventKind
                    let language: TranslationLanguage
                    switch mode {
                    case .smartReply:
                        usageKind = .smartReply
                        language = self.draftTargetLanguage
                    case .selection, .draftMessage, .genZ, .revise, .reviseMessage,
                         .summarizeChat, .summarizePage, .custom:
                        // `.custom` is unreachable here — a prompt tool is never a
                        // floating-button default mode — but the switch is exhaustive.
                        usageKind = .screenArea
                        language = self.targetLanguage
                    }
                    self.translate(
                        sourceText,
                        near: mouseLocation,
                        targetLanguage: language,
                        mode: mode,
                        useCache: mode == .selection,
                        usageKind: usageKind,
                        panelSide: panelSide
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.resetScreenshotDragTracking()
                    self.updateMenuState()
                    guard !ScreenshotTranslationError.isCancellation(error) else {
                        return
                    }
                    self.presentScreenshotTranslationError(error)
                }
            }
        }
    }

    /// Relaunch Gizmate reliably without depending on macOS's TCC "Quit &
    /// Reopen" — that path is flaky for LSUIElement agent apps (it quits but
    /// doesn't reopen) and gets confused when more than one copy of
    /// com.gizmate.app is registered. Detach a helper that waits for us to fully
    /// exit, then reopens our exact bundle. Falls back to a plain quit in dev
    /// (`swift run`), where there is no .app to reopen.
    @MainActor
    private func relaunchApp() {
        guard isRunningFromAppBundle else {
            NSApp.terminate(nil)
            return
        }
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @MainActor
    func presentScreenshotTranslationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            // First time: surface macOS's native Screen Recording prompt — this
            // call also registers Gizmate in the Privacy list. It's a no-op once
            // the user has answered, so only then fall back to the guide-to-
            // Settings alert. Shared flag keeps this in sync with onboarding.
            let requestedKey = "permissionsOnboarding.screenCaptureRequested"
            if !CGPreflightScreenCaptureAccess(),
               !UserDefaults.standard.bool(forKey: requestedKey) {
                UserDefaults.standard.set(true, forKey: requestedKey)
                _ = CGRequestScreenCaptureAccess()
                startScreenRecordingTrustWatcher()
                return
            }
            let response = GizmateAlertController(
                title: "Screen recording required",
                message: screenshotError.localizedDescription,
                primaryButtonTitle: "Open settings",
                secondaryButtonTitle: "Quit & Reopen"
            ).showModal()
            switch response {
            case .alertFirstButtonReturn:
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            case .alertSecondButtonReturn:
                relaunchApp()
            default:
                break
            }
            return
        }

        _ = GizmateAlertController(
            title: "Screenshot translation failed",
            message: error.localizedDescription,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    func presentSelectionTranslationError(_ message: String, title: String = "No text selected") {
        NSApp.activate(ignoringOtherApps: true)
        _ = GizmateAlertController(
            title: title,
            message: message,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    /// Takes the screen area a `.screenshot` or `.screenshotText` tool runs on.
    ///
    /// Same drag and the same window-hiding as screen reading, for the same
    /// reason: Gizmate's own panels are capturable, and their labels would end
    /// up in the shot and in whatever Vision reads out of it. Vision runs only
    /// when the tool actually asked for text — a tool that wants the PNG should
    /// not pay for recognition it will never look at.
    @MainActor
    func captureToolScreenshot(readingText: Bool) async throws -> ToolScreenshot {
        let sharingSnapshot = Self.hideAppWindowsFromScreenCapture()
        let imageURL: URL
        do {
            imageURL = try await ScreenshotCapture.captureInteractiveArea()
        } catch {
            Self.restoreAppWindowSharing(sharingSnapshot)
            throw error
        }
        Self.restoreAppWindowSharing(sharingSnapshot)

        guard readingText else {
            return ToolScreenshot(imageURL: imageURL, text: "")
        }
        do {
            let text = try await ImageTextRecognizer.recognizeText(in: imageURL)
            return ToolScreenshot(
                imageURL: imageURL,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
    }

}
