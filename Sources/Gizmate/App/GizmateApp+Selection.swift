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
    func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            if event.type == .leftMouseDown {
                self.lastLeftMouseDownLocation = mouseLocation
                self.lastMouseDownPasteboardChangeCount = NSPasteboard.general.changeCount
                self.lastMouseDownDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
                self.lastMouseDownWindowNumber = event.windowNumber
                self.lastMouseDownWindowBounds = Self.windowBounds(forWindowNumber: event.windowNumber)
                if self.isScreenshotTranslationRunning {
                    self.screenshotDragStartLocation = mouseLocation
                    self.screenshotDragEndLocation = nil
                    return
                }
                // This click is already dropping any live selection in the
                // target app — dismiss the selection UI now instead of after
                // the mouse-up read (80ms gate + AX + up to 0.5s clipboard
                // poll). If this same gesture makes a new selection, the
                // mouse-up pipeline re-shows it.
                if let controller = self.translationPanelController,
                   controller.isVisible,
                   controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
                    return
                }
                self.translateButtonController?.close()
                self.translateButtonController = nil
                return
            }

            if event.type == .leftMouseDragged {
                if self.isScreenshotTranslationRunning {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            if self.isScreenshotTranslationRunning {
                if event.type == .leftMouseUp {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            self.handleMouseUp(event)
        }
    }

    /// The selection pipeline for Gizmate's own edge docks.
    ///
    /// `startMouseMonitor` is a global monitor, so it is blind to this app's
    /// own mouse — a drag across a note on an edge produced no mouse-up here at
    /// all, which is why the ring never armed over one. The text view announces
    /// its own selection instead, so there is no gesture to reconstruct: what
    /// fires is what was selected, by drag or by ⇧-arrow or by ⌘A alike.
    ///
    /// The tail delay is not a debounce for looks. The notification fires per
    /// character while a drag is in progress, so arming on the first one would
    /// pop the button under the pointer that is still selecting.
    func startDockSelectionMonitor() {
        dockSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let view = note.object as? NSTextView, view.window is EdgeDockPanel else {
                return
            }
            MainActor.assumeIsolated { self?.dockSelectionChanged() }
        }
    }

    private func dockSelectionChanged() {
        dockSelectionTimer?.invalidate()
        dockSelectionTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.armDockSelection() }
        }
    }

    private func armDockSelection() {
        guard selectionDisplayMode != .off, !isCloudSignInActive else { return }
        // Still dragging. Ask again rather than arming mid-gesture.
        guard NSEvent.pressedMouseButtons == 0 else {
            dockSelectionChanged()
            return
        }

        guard let selection = DockSelection.current() else {
            // The selection collapsed — typing over it, or a click elsewhere in
            // the note. Whatever the button was offering is about text that no
            // longer exists.
            translateButtonController?.close()
            translateButtonController = nil
            return
        }

        let cleaned = TextNormalizer.cleanedSelection(selection.text)
        guard !cleaned.isEmpty, TextNormalizer.looksMeaningful(cleaned) else { return }
        let anchor = selectAllAnchorPoint(from: selection.selectionRect)
        showTranslateButton(
            for: cleaned,
            near: anchor,
            selectionRect: selection.selectionRect,
            panelSide: .right
        )
    }

    func startKeyboardMonitor() {
        // Global, listen-only — Cmd+A still propagates to the focused app so
        // its native select-all fires. We just want to know when it happened
        // so we can read the resulting selection and show the translate UI.
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command, event.keyCode == UInt16(kVK_ANSI_A) else {
                return
            }
            self.handleSelectAll()
        }
    }

    private func handleSelectAll() {
        guard selectionDisplayMode != .off else { return }
        guard accessibilityIsTrusted() else { return }
        guard !isCloudSignInActive else { return }

        // Cmd+A inside Gizmate's own panels means "select the prompt input",
        // not "translate everything" — drop those events.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        if frontmostBundleID == Bundle.main.bundleIdentifier {
            return
        }
        let frontmostAppName = frontmostApp?.localizedName ?? frontmostBundleID ?? "this app"
        let pasteboardBaseline = NSPasteboard.general.changeCount

        // The target app updates its AX selection state after macOS dispatches
        // the Cmd+A keystroke. Mirror the mouse-up gating delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            // ⌘A in Finder selects files, not text — a synthesized ⌘C would
            // copy the files themselves. AX-only read there (silent, no-op).
            // Same for open/save panels in any app: ⌘A selects file rows.
            let allowsClipboard = frontmostBundleID != "com.apple.finder"
                && !self.selectionReader.isInsideOpenSavePanel()
            let preferClipboard = allowsClipboard
                && !self.selectionReader.isLikelyEditableElementAtMouseLocation()
            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: allowsClipboard,
                pasteboardBaseline: pasteboardBaseline
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    self.noteUnreadableSelection(
                        bundleID: frontmostBundleID,
                        appName: frontmostAppName
                    )
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    return
                }

                self.clearUnreadableSelectionCounter(bundleID: frontmostBundleID)

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    return
                }

                let anchor = self.selectAllAnchorPoint(from: selection.selectionRect)
                self.showTranslateButton(
                    for: cleanedSelection,
                    near: anchor,
                    selectionRect: selection.selectionRect,
                    panelSide: .right
                )
            }
        }
    }

    private func selectAllAnchorPoint(from rect: NSRect?) -> NSPoint {
        // Cmd+A has no mouse-based anchor. Prefer the bottom-right corner of
        // the reported selection rect; fall back to current pointer position.
        if let rect, rect.width > 0, rect.height > 0 {
            return NSPoint(x: rect.maxX, y: rect.minY)
        }
        return NSEvent.mouseLocation
    }

    @MainActor
    func applySelectionDisplayMode() {
        if selectionDisplayMode == .off {
            translateButtonController?.close()
            translateButtonController = nil
        }

        updateMenuState()
    }


    private func handleMouseUp(_ event: NSEvent) {
        guard accessibilityIsTrusted() else {
            // Reading the highlighted text needs Accessibility, so without it a
            // drag-select would silently do nothing. When the user clearly made
            // a selection gesture, surface the permission request — throttled so
            // we never spam System Settings on repeated drags / stray gestures.
            if selectionDisplayMode != .off,
               isDragSelectionGesture(event, upLocation: NSEvent.mouseLocation),
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                let now = Date()
                if lastAccessibilitySelectionPromptAt.map({ now.timeIntervalSince($0) > 15 }) ?? true {
                    lastAccessibilitySelectionPromptAt = now
                    requestAccessibilityPermissionInteractively()
                }
            }
            return
        }

        // A cloud sign-in panel (ChatGPT/Claude) is up. Clicking around its page
        // would otherwise post a synthetic ⌘+C on every mouse-up (clipboard
        // fallback) and beep when there's no selection. Skip until sign-in ends.
        if isCloudSignInActive {
            return
        }

        // The shortcut recorder is up. Any synthesized ⌘+C we'd post during
        // the clipboard fallback below would land in Gizmate (now frontmost)
        // and the recorder field would capture it as the user's shortcut —
        // see KeyboardShortcutPoster.postCommandShortcut. Hard-skip while the
        // recorder is open.
        if shortcutRecorderWindowController != nil {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if let controller = translationPanelController,
           controller.isVisible,
           controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
            return
        }

        // A stationary double-click does nothing. It selects a word in text
        // but *activates* rows/folders/chats everywhere else, and there is no
        // pre-flight signal to tell those apart — so it popped the button on
        // every word lookup and beeped through the synthesized ⌘C on every
        // navigation. Vadim asked for it gone on 2026-08-22, after having
        // asked for it back on 2026-07-16 (which reversed 2026-07-03). Drag
        // to select; the shortcut still reads whatever is selected.
        if event.clickCount >= 2, !isDragSelectionGesture(event, upLocation: mouseLocation) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                translateButtonController?.close()
                translateButtonController = nil
            }
            return
        }

        // Capture the frontmost app at gesture time, not at completion time —
        // the user may have switched apps during the 80ms+AX-read window, and
        // we want to attribute the unreadable-selection signal to the app
        // where the drag actually happened.
        let isSelectionGesture = isDragSelectionGesture(event, upLocation: mouseLocation)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        let frontmostAppName = frontmostApp?.localizedName ?? frontmostBundleID ?? "this app"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            // The async window is long enough for the user to have brought
            // Gizmate to the front (e.g. opened the menu to set a shortcut).
            // Re-check before posting any synthetic keystrokes.
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                return
            }
            if self.shortcutRecorderWindowController != nil {
                return
            }
            // A drag in Finder (desktop included) is a marquee selecting
            // files, not text. Never synthesize ⌘C there: with nothing
            // selected Finder beeps, and with icons selected it clobbers the
            // clipboard with the files and "translates" their names.
            // Open/save panels in ANY app are the same file-browsing surface
            // (double-clicking a folder to enter it counts as a selection
            // gesture and would beep on every navigation).
            let allowsClipboard = frontmostBundleID != "com.apple.finder"
                && !self.selectionReader.isInsideOpenSavePanel()
            let preferClipboard = allowsClipboard
                && self.shouldAttemptClipboardSelectionFallback(for: event, upLocation: mouseLocation)

            // Clipboard fallback after a failed AX read covers apps that
            // expose a text-area-ish AX role (so `preferClipboard` is false)
            // but don't actually publish `kAXSelectedTextAttribute` —
            // KakaoTalk chat bubbles being the canonical example. Only allow
            // it when the user clearly meant to select something; otherwise
            // a stray click would synthesize Cmd+C for nothing.
            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: isSelectionGesture && allowsClipboard,
                pasteboardBaseline: self.lastMouseDownPasteboardChangeCount
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    // Don't count Finder marquee drags as "app blocks text
                    // access" — they never had text to begin with.
                    if isSelectionGesture && allowsClipboard {
                        self.noteUnreadableSelection(
                            bundleID: frontmostBundleID,
                            appName: frontmostAppName
                        )
                    }
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    return
                }

                // The app exposed *some* selection text — even if we end up
                // discarding it as not meaningful below, that's a "user
                // selected garbage" case, not an "app blocks access" case.
                if isSelectionGesture {
                    self.clearUnreadableSelectionCounter(bundleID: frontmostBundleID)
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    return
                }

                self.showTranslateButton(
                    for: cleanedSelection,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation)
                )
            }
        }
    }

    func panelSideForSelectionEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        panelSideForDrag(from: lastLeftMouseDownLocation, to: mouseLocation)
    }

    func panelSideForScreenshotEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        screenshotPanelSide ?? panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    private func panelSideForDrag(from startLocation: NSPoint?, to endLocation: NSPoint) -> TranslationPanelController.Side {
        guard let startLocation else { return .right }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        // Need a meaningful horizontal drag — vertical or tiny drags
        // give no reliable direction signal, so default to .right.
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return .right }
        return dx > 0 ? .right : .left
    }

    private func updateScreenshotDrag(to mouseLocation: NSPoint) {
        screenshotDragEndLocation = mouseLocation
        screenshotPanelSide = panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    @MainActor
    func startScreenshotDragTracking() {
        resetScreenshotDragTracking()
        let tracker = ScreenshotDragTracker { [weak self] startLocation, endLocation, panelSide in
            guard let self else { return }
            if let startLocation {
                self.screenshotDragStartLocation = startLocation
            }
            if let endLocation {
                self.screenshotDragEndLocation = endLocation
            }
            if let panelSide {
                self.screenshotPanelSide = panelSide
            }
        }
        screenshotDragTracker = tracker
        tracker.enable()
    }

    @MainActor
    func resetScreenshotDragTracking() {
        screenshotDragTracker?.disable()
        screenshotDragTracker = nil
        screenshotDragStartLocation = nil
        screenshotDragEndLocation = nil
        screenshotPanelSide = nil
    }

    private func shouldAttemptClipboardSelectionFallback(for event: NSEvent, upLocation: NSPoint) -> Bool {
        guard isDragSelectionGesture(event, upLocation: upLocation) else {
            return false
        }

        return !selectionReader.isLikelyEditableElementAtMouseLocation()
    }

    /// A real drag: ≥15pt of travel with no refuting signal (drag-and-drop
    /// session, window move/resize).
    /// `upLocation` must be the pointer position captured AT the mouse-up
    /// event. This runs again inside the 80ms-delayed read, and reading
    /// `NSEvent.mouseLocation` there instead measured wherever the cursor
    /// had flicked to after the click — a stationary double-click followed
    /// by a quick mouse move read as a ≥15pt "drag" and beeped via the
    /// clipboard fallback's ⌘C.
    private func isDragSelectionGesture(_ event: NSEvent, upLocation: NSPoint) -> Bool {
        guard event.type == .leftMouseUp else {
            return false
        }

        guard let downLocation = lastLeftMouseDownLocation else {
            return false
        }

        // A real drag-and-drop session (files, photos, dragged text) always
        // writes to the drag pasteboard when the session starts; a
        // drag-to-select never does. Dropping a photo into a browser input
        // used to read as a selection drag here, and the clipboard fallback's
        // synthesized ⌘C then beeped with nothing to copy.
        if let baseline = lastMouseDownDragPasteboardChangeCount,
           NSPasteboard(name: .drag).changeCount != baseline {
            return false
        }

        // Moving or resizing a window travels ≥15pt too, but never selects
        // text — the synthesized ⌘C after dropping a window beeped just like
        // the drag-and-drop case. During a genuine text-selection drag the
        // window under the gesture keeps its frame; if it moved or resized,
        // this was window manipulation.
        if let windowNumber = lastMouseDownWindowNumber,
           let startBounds = lastMouseDownWindowBounds,
           Self.windowBounds(forWindowNumber: windowNumber) != startBounds {
            return false
        }

        let distance = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
        return distance >= 15
    }

    /// Frame of any on-screen window (any app) by window number, in CG
    /// screen coordinates. Bounds are readable without Screen Recording
    /// permission — only window *names* are gated.
    private static func windowBounds(forWindowNumber windowNumber: Int) -> CGRect? {
        guard let windowID = CGWindowID(exactly: windowNumber), windowID > 0 else {
            return nil
        }
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let boundsDict = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }
        return bounds
    }

    private func clearUnreadableSelectionCounter(bundleID: String?) {
        guard let bundleID else { return }
        unreadableSelectionFailureCounts[bundleID] = 0
    }

    private func noteUnreadableSelection(bundleID: String?, appName: String) {
        guard selectionDisplayMode != .off else { return }
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        // UNUserNotificationCenter.current() aborts in non-bundle contexts
        // (`swift run`). Skipping here also avoids polluting the persistent
        // "already shown" set with bundles seen only during dev, which would
        // suppress the hint forever in the user-facing .app build.
        guard isRunningFromAppBundle else { return }

        let next = (unreadableSelectionFailureCounts[bundleID] ?? 0) + 1
        unreadableSelectionFailureCounts[bundleID] = next

        guard next >= Self.unreadableSelectionFailureThreshold else { return }

        let defaults = UserDefaults.standard
        let key = Self.unreadableSelectionHintShownDefaultsKey
        var shown = Set(defaults.stringArray(forKey: key) ?? [])
        guard !shown.contains(bundleID) else { return }
        shown.insert(bundleID)
        defaults.set(Array(shown).sorted(), forKey: key)

        Self.deliverUnreadableSelectionHint(appName: appName)
    }

    nonisolated private static func deliverUnreadableSelectionHint(appName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Gizmate can't read text in \(appName)"
            content.body = "This app doesn't expose its selection to other apps. Try Screenshot Translation instead."
            let request = UNNotificationRequest(
                identifier: "gizmate.selection.unreadable.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

}
