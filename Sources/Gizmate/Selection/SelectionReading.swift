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

struct SelectedTextContext {
    let text: String
    let selectionRect: NSRect?
}

final class SelectionReader {
    func readSelectedText(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (String?) -> Void
    ) {
        readSelectedTextContext(
            preferClipboard: preferClipboard,
            allowClipboardFallback: allowClipboardFallback
        ) { selection in
            completion(selection?.text)
        }
    }

    func readSelectedTextContext(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        pasteboardBaseline: Int? = nil,
        completion: @escaping (SelectedTextContext?) -> Void
    ) {
        // A dock of our own has key focus: the selection is right there in the
        // responder chain, and neither AX nor a synthesized ⌘C would find it.
        // First, not last — a clipboard-preferring read would otherwise post a
        // ⌘C the frontmost app answers with *its* selection.
        if let dockSelection = DockSelection.current() {
            completion(dockSelection)
            return
        }

        if preferClipboard {
            ClipboardSelectionReader.readSelectedText(pasteboardBaseline: pasteboardBaseline) { [weak self] clipboardText in
                if let clipboardText, !clipboardText.isEmpty {
                    completion(SelectedTextContext(text: clipboardText, selectionRect: nil))
                    return
                }
                completion(self?.readSelectedTextContext())
            }
            return
        }

        if let selection = readSelectedTextContext() {
            completion(selection)
            return
        }

        guard allowClipboardFallback else {
            completion(nil)
            return
        }

        ClipboardSelectionReader.readSelectedText(pasteboardBaseline: pasteboardBaseline) { selectedText in
            guard let selectedText else {
                completion(nil)
                return
            }

            completion(SelectedTextContext(text: selectedText, selectionRect: nil))
        }
    }

    enum FocusedEditability {
        case editable
        case notEditable
        /// AX gave us nothing usable (no focused element, or no readable
        /// roles anywhere in the chain) — the KakaoTalk case. Callers must
        /// not treat this as "not editable": rewrite keeps its blind paste
        /// there, reply keeps its panel.
        case unknown
    }

    /// Editability of the element a synthesized Cmd+V would paste into.
    /// Focus, not mouse position, decides the paste target — chat apps keep
    /// keyboard focus in the compose box even while text elsewhere is
    /// mouse-selected.
    func focusedElementEditability() -> FocusedEditability {
        guard let element = focusedElement() else {
            return .unknown
        }

        var sawAnyRole = false
        var currentElement: AXUIElement? = element
        for _ in 0..<6 {
            guard let element = currentElement else { break }

            if let role = role(of: element) {
                sawAnyRole = true
                if Self.editableTextRoles.contains(role) {
                    return .editable
                }
            }

            currentElement = parent(of: element)
        }

        return sawAnyRole ? .notEditable : .unknown
    }

    /// Reply's insert gate. Rewrite can trust the focused element (the
    /// selection lives inside the field being rewritten), but for reply the
    /// user selects the *incoming* message, which drags AX focus onto the
    /// message list. So when focus isn't editable, hunt for the compose
    /// field in the focused window and focus it so a synthesized Cmd+V
    /// lands there. False = no field could be found and focused.
    func focusEditableComposeField() -> Bool {
        if focusedElementEditability() == .editable {
            return true
        }

        guard let field = bottomMostEditableField() else {
            return false
        }

        return AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Bounded breadth-first hunt for a writable text field in the frontmost
    /// app's focused window. Among candidates the bottom-most wins: compose
    /// boxes sit at the bottom of every chat window, and this keeps a top
    /// search bar (Slack) from swallowing the paste.
    private func bottomMostEditableField() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        )
        guard windowResult == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        // ponytail: 250-node budget — every attribute read is an IPC
        // roundtrip, and compose fields sit shallow in the tree; deep
        // message lists don't deserve a full walk.
        var queue: [AXUIElement] = [windowValue as! AXUIElement]
        var visited = 0
        var best: (element: AXUIElement, y: CGFloat)?
        while !queue.isEmpty, visited < 250 {
            let element = queue.removeFirst()
            visited += 1

            let role = role(of: element)
            if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
                // NSSearchField reports AXTextField + this subrole.
                if subrole(of: element) != "AXSearchField" {
                    // AX coordinates are top-left origin: bottom-most = max y.
                    let y = position(of: element)?.y ?? -.greatestFiniteMagnitude
                    if best == nil || y > best!.y {
                        best = (element, y)
                    }
                }
                continue
            }

            // Never descend into toolbars: a browser's URL bar is an
            // AXTextField too, and a reply must not land there.
            if role == kAXToolbarRole as String {
                continue
            }

            queue.append(contentsOf: children(of: element))
        }

        return best?.element
    }

    private func subrole(of element: AXUIElement) -> String? {
        var subroleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )

        guard result == .success else {
            return nil
        }

        return subroleValue as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )

        guard result == .success, let children = childrenValue as? [AXUIElement] else {
            return []
        }

        return children
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        )

        guard result == .success,
              let positionValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    func isLikelyEditableElementAtMouseLocation() -> Bool {
        guard let element = elementAtMouseLocation() ?? focusedElement() else {
            return false
        }

        var currentElement: AXUIElement? = element
        for _ in 0..<6 {
            guard let element = currentElement else {
                return false
            }

            if let role = role(of: element), Self.editableTextRoles.contains(role) {
                return true
            }

            currentElement = parent(of: element)
        }

        return false
    }

    /// The gesture landed inside an open/save panel (any host app). Rows
    /// there are files, not text — a synthesized ⌘C beeps with nothing
    /// copyable, or clobbers the clipboard with file items, exactly like
    /// Finder. AppKit tags the panel window with a stable AXIdentifier
    /// that survives localization and sheet presentation.
    func isInsideOpenSavePanel() -> Bool {
        for element in [elementAtMouseLocation(), focusedElement()].compactMap({ $0 }) {
            var currentElement: AXUIElement? = element
            for _ in 0..<10 {
                guard let element = currentElement else { break }

                if let identifier = identifier(of: element),
                   identifier == "open-panel" || identifier == "save-panel" {
                    return true
                }

                currentElement = parent(of: element)
            }
        }

        return false
    }

    func readSelectedText() -> String? {
        readSelectedTextContext()?.text
    }

    func readSelectedTextContext() -> SelectedTextContext? {
        guard let focusedElement = focusedElement() else {
            return nil
        }

        guard let text = selectedText(from: focusedElement) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let rect = selectedTextRange(from: focusedElement)
            .flatMap { selectionBounds(from: focusedElement, range: $0) }

        return SelectedTextContext(
            text: trimmed,
            selectionRect: rect
        )
    }

    private static let editableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func elementAtMouseLocation() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let mouseLocation = NSEvent.mouseLocation
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(mouseLocation.x),
            Float(mouseLocation.y),
            &element
        )

        guard result == .success else {
            return nil
        }

        return element
    }

    private func identifier(of element: AXUIElement) -> String? {
        var identifierValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXIdentifierAttribute as CFString,
            &identifierValue
        )

        guard result == .success else {
            return nil
        }

        return identifierValue as? String
    }

    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard result == .success else {
            return nil
        }

        return roleValue as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        )

        guard result == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (parentValue as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        if selectedTextResult == .success, let selectedText = selectedTextValue as? String {
            return selectedText
        }

        return selectedTextViaRange(from: element)
    }

    private func selectedTextViaRange(from element: AXUIElement) -> String? {
        guard let range = selectedTextRange(from: element) else {
            return nil
        }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &textValue
        )

        guard textResult == .success, let fullText = textValue as? String else {
            return nil
        }

        let utf16 = fullText.utf16
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= utf16.count
        else {
            return nil
        }

        let utf16Start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let utf16End = utf16.index(utf16.startIndex, offsetBy: range.location + range.length)
        guard let start = utf16Start.samePosition(in: fullText),
              let end = utf16End.samePosition(in: fullText)
        else {
            return nil
        }

        return String(fullText[start..<end])
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axRangeValue = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(axRangeValue) == .cfRange,
              AXValueGetValue(axRangeValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0
        else {
            return nil
        }

        return range
    }

    private func selectionBounds(from element: AXUIElement, range: CFRange) -> NSRect? {
        var mutableRange = range
        guard let rangeAXValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAXValue,
            &boundsValue
        )

        guard result == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect,
              AXValueGetValue(axValue, .cgRect, &rect),
              rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite
        else {
            return nil
        }

        return SelectionReader.convertAXRectToCocoa(rect)
    }

    // AX uses top-left global coordinates; NSScreen uses bottom-left.
    // Build an AX-space frame for each display so selection panels stay near
    // the selected text on horizontal and vertical multi-monitor layouts.
    private static func convertAXRectToCocoa(_ axRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
        else {
            return nil
        }

        let axMidPoint = CGPoint(x: axRect.midX, y: axRect.midY)
        let containingScreen = NSScreen.screens.first { screen in
            axFrame(for: screen, primaryScreen: primary).contains(axMidPoint)
        } ?? primary
        let containingAXFrame = axFrame(for: containingScreen, primaryScreen: primary)
        let flippedY = containingScreen.frame.maxY - (axRect.maxY - containingAXFrame.minY)
        return NSRect(x: axRect.origin.x, y: flippedY, width: axRect.width, height: axRect.height)
    }

    private static func axFrame(for screen: NSScreen, primaryScreen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: primaryScreen.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

}

enum ClipboardSelectionReader {
    private static let pollingInterval: TimeInterval = 0.02
    private static let pollingTimeout: TimeInterval = 0.5

    static func readSelectedText(
        pasteboardBaseline: Int? = nil,
        completion: @escaping (String?) -> Void
    ) {
        let pasteboard = NSPasteboard.general

        // The frontmost app already copied during this gesture (copy-on-select
        // TUIs, click-to-copy sites with a "copied!" toast). That copy IS the
        // selection: use it, skip the synthetic ⌘C, and leave the clipboard
        // alone — the app copied intentionally, so restoring an older snapshot
        // over it would silently break the copy the app just announced.
        if let pasteboardBaseline, pasteboard.changeCount != pasteboardBaseline {
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(copiedText.flatMap { TextNormalizer.looksMeaningful($0) ? $0 : nil })
            return
        }

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        postCommandC()

        let deadline = Date().addingTimeInterval(pollingTimeout)
        pollForPasteboardChange(
            pasteboard: pasteboard,
            originalChangeCount: originalChangeCount,
            deadline: deadline,
            snapshot: snapshot,
            completion: completion
        )
    }

    private static func pollForPasteboardChange(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        deadline: Date,
        snapshot: PasteboardSnapshot,
        completion: @escaping (String?) -> Void
    ) {
        if pasteboard.changeCount != originalChangeCount {
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.restore(to: pasteboard)
            let meaningful = copiedText.flatMap { TextNormalizer.looksMeaningful($0) ? $0 : nil }
            completion(meaningful)
            return
        }

        if Date() >= deadline {
            // No late-restore pass here: reverting whatever lands on the
            // clipboard next used to eat genuine copies the user (or the app's
            // own copy button) made right after a failed fallback. If the app
            // answers the synthetic ⌘C late, the selection stays on the
            // clipboard — mild, and far better than clobbering a real copy.
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollingInterval) {
            pollForPasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: deadline,
                snapshot: snapshot,
                completion: completion
            )
        }
    }

    private static func postCommandC() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_C))
    }
}

enum KeyboardShortcutPoster {
    static func postCommandShortcut(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        postKey(CGKeyCode(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: false, flags: .maskCommand, source: source)
        postKey(CGKeyCode(kVK_Command), keyDown: false, flags: [], source: source)
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems = (pasteboard.pasteboardItems ?? []).map { item in
            var capturedTypes: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    capturedTypes[type] = data
                }
            }
            return capturedTypes
        }

        return PasteboardSnapshot(items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { capturedTypes in
            let item = NSPasteboardItem()
            for (type, data) in capturedTypes {
                item.setData(data, forType: type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

enum PasteboardTextInserter {
    static func replaceCurrentSelection(with text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard pasteboard.changeCount == replacementChangeCount else {
                return
            }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func postCommandV() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))
    }
}


/// The text selected inside one of Gizmate's own edge docks.
///
/// Every other read in this file goes out through AX or a synthesized ⌘C, and
/// neither can reach a note on an edge. AX asked about our own process from the
/// main thread waits on the run loop that would have to answer it, and the
/// selection monitor is a *global* event monitor, which by definition never
/// sees this app's own mouse. So a drag-select in a docked note read as "no
/// selection anywhere", and the ring never armed over the one surface Gizmate
/// draws itself.
///
/// The responder chain has the answer already, exactly, with no permission and
/// no clipboard involved.
///
/// Scoped to the docks on purpose, twice over. `keyWindow` rather than any
/// window, because an `NSTextView` keeps its selection after it stops being
/// key — without that a note selected on an edge an hour ago would shadow the
/// live selection in whatever app the user is actually in. And `EdgeDockPanel`
/// rather than any window of ours, because a selection in the main window is a
/// field being typed into or a transcript being read, and a ring popping over
/// those is noise.
enum DockSelection {
    static func current() -> SelectedTextContext? {
        guard let panel = NSApp.keyWindow as? EdgeDockPanel,
              let view = panel.firstResponder as? NSTextView
        else { return nil }
        return selection(in: view)
    }

    /// Split out from `current()` so it can be tested against a text view alone:
    /// the window half needs a key window, which a test process has no way to
    /// hand out, while the range arithmetic is the half that can actually be
    /// wrong. `selectedRange` is a UTF-16 range, so it is read with `NSString`
    /// and bounds-checked — a `String` index would be a different unit and a
    /// stale range from a text view mid-edit would trap rather than return nil.
    static func selection(in view: NSTextView) -> SelectedTextContext? {
        let text = view.string as NSString
        let range = view.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let rect = view.firstRect(forCharacterRange: range, actualRange: nil)
        return SelectedTextContext(
            text: text.substring(with: range),
            selectionRect: rect.width > 0 || rect.height > 0 ? rect : nil
        )
    }
}
