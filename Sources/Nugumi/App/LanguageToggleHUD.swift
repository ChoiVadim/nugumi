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

/// Small auto-fading toast shown when the writing language flips via the
/// global shortcut — without it the toggle is invisible to the user. One
/// shared instance so rapid toggles replace the text instead of stacking.
@MainActor
final class LanguageToggleHUD {
    static let shared = LanguageToggleHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(text: String) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()

        let padding = NSSize(width: 22, height: 12)
        let size = NSSize(
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2
        )
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 60,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        (panel.contentView?.layer)?.cornerRadius = size.height / 2

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    if self?.dismissTask?.isCancelled == false {
                        self?.panel?.orderOut(nil)
                    }
                }
            })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // Same liquid-glass material as the main window, so the toast reads
        // as part of the same family.
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        content.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        content.addSubview(label)

        panel.contentView = content
        InvisibilityState.apply(to: panel)
        self.panel = panel
        self.label = label
        return panel
    }
}
