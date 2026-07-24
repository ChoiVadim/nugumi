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

/// The translation panel's "Revise or ask a follow-up" field. A plain
/// `NSTextField` is editable by default; we only add Esc-to-close.
/// A non-bezeled `NSTextField` draws its text near the top of its frame, not
/// centered — so the leading icon (centered in the row) sat below the text.
/// This cell vertically centers the text in both draw and edit states.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        let dy = (rect.height - textHeight) / 2
        return NSRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: textHeight)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}

final class FollowUpTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSCell(textCell:) yields a label-style cell (not editable), so
        // re-enable editing/selection or the field can't take focus.
        cell = VerticallyCenteredTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    // The panel uses `becomesKeyOnlyIfNeeded`, so it won't grab key until a view
    // asks for it. Force key + first responder on click so typing works even
    // while the source app is frontmost.
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

