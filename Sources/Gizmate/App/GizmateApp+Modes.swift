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
    @objc func toggleInvisibilityMode() {
        let now = !invisibilityModeEnabled
        invisibilityModeEnabled = now
        statusItem?.isVisible = !now
        InvisibilityState.applyToAllOpenWindows()
        updateMenuState()
        if now && !UserDefaults.standard.bool(forKey: InvisibilityState.firstRunShownKey) {
            showInvisibilityFirstRunDialog()
            UserDefaults.standard.set(true, forKey: InvisibilityState.firstRunShownKey)
        }
    }

    private func showInvisibilityFirstRunDialog() {
        let chord = shortcut(for: .toggleInvisibility).displayString
        NSApp.activate(ignoringOtherApps: true)
        _ = GizmateAlertController(
            title: "Invisibility mode is on",
            message: "Gizmate is now hidden from screenshots and screen sharing, and the menu-bar icon is gone. Press \(chord) anywhere to bring it back.",
            primaryButtonTitle: "Got it"
        ).showModal()
    }

    /// Flips the writing (draft) language with the configured alternate, swapping
    /// the two so the pair {writing language, alternate} is preserved each toggle.
    @objc func toggleWritingLanguageAction() {
        let previous = draftTargetLanguage
        let next = writingToggleAlternate
        draftTargetLanguage = next
        writingToggleAlternate = previous
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
        ToastHUD.shared.show(text: "Writing in \(next.displayName)")
    }

    @MainActor
    @objc private func toggleLiveTranslationFromMenu() {
        toggleLiveTranslation()
    }

    /// Live translation runs exclusively on OpenAI's realtime model, so it is
    /// gated on an OpenAI API key regardless of which provider the rest of the
    /// app uses. A missing/empty key surfaces `presentLiveTranslationAPIKeyAlert`
    /// via the controller's `onMissingAPIKey` hook before any capture starts.
    @MainActor
    func toggleLiveTranslation() {
        liveTranslationController.toggle(
            apiKey: KeychainStore.apiKey(for: .openAI),
            targetLanguage: targetLanguage
        )
    }

    /// Dictation shares live translation's OpenAI realtime dependency (and
    /// its key gate + mic-permission alerts).
    @MainActor
    func toggleDictation() {
        dictationController.toggle(apiKey: KeychainStore.apiKey(for: .openAI))
    }

    /// The same mic, collected into a string instead of typed into the front
    /// app: a `.dictation` gizmo's one input. nil when nothing was said, or when
    /// the key or the mic permission is missing — the controller's own alerts
    /// have already explained which.
    @MainActor
    func dictateToolInput() async -> String? {
        await dictationController.dictate(apiKey: KeychainStore.apiKey(for: .openAI))
    }

    @MainActor
    func presentLiveTranslationAPIKeyAlert(feature: String = "Live translation") {
        NSApp.activate(ignoringOtherApps: true)
        let response = GizmateAlertController(
            title: "OpenAI API key required",
            message: "\(feature) runs on OpenAI's realtime model. Add an OpenAI API key under Settings → Providers, then try again.",
            primaryButtonTitle: "Open Settings",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else { return }
        presentEngineSetup()
    }

    @MainActor
    func presentMicrophonePermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let response = GizmateAlertController(
            title: "Microphone access needed",
            message: "Live captions listen to your microphone. Allow access under System Settings → Privacy & Security → Microphone, then start again.",
            primaryButtonTitle: "Open Settings",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
