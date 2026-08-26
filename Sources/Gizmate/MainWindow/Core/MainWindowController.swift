import AppKit
import SwiftUI

// MARK: - Window

@MainActor
final class MainWindow: NSWindow {
    // Transparent-titlebar windows swallow Cmd+A/C/V/X before SwiftUI TextFields
    // see them. Re-dispatch to the first responder, mirroring SnippetsWindow.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            super.sendEvent(event)
            return
        }
        let selector: Selector?
        switch key {
        case "a": selector = #selector(NSText.selectAll(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        default: selector = nil
        }
        guard let selector else {
            super.sendEvent(event)
            return
        }
        if let responder = firstResponder, responder.responds(to: selector) {
            responder.perform(selector, with: self)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let bridge: GizmateSettingsBridge
    private let onClose: () -> Void

    init(host: any SettingsHost, onClose: @escaping () -> Void) {
        self.bridge = GizmateSettingsBridge(host: host)
        self.onClose = onClose

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // Deliberately NOT movable by its background: a press anywhere in the
        // content would start dragging the window, which is the same press the
        // Ring uses to carry a button to another slot. `WindowDragStrip` puts
        // the drag back where it belongs — the header, alongside the traffic
        // lights.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 720)
        window.setFrameAutosaveName("GizmateMainWindowV5")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        // Programmatic windows don't auto-restore from the autosave name — do it
        // explicitly. Center only when there's no remembered frame (first launch).
        if !window.setFrameUsingName("GizmateMainWindowV5") {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        // Liquid-glass backdrop: everything that isn't the black settings card
        // shows this translucent material (the same look as the status-bar menu).
        let root = MainWindowRootView().environmentObject(bridge)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The window's frame is authoritative — don't let tall SwiftUI content
        // (e.g. Insights' fixed cards) push the window past its set size and off-screen.
        hosting.sizingOptions = []

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop

        // Respect invisibility mode before the window is ever shown.
        InvisibilityState.apply(to: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndFocus(section: MainWindowSection? = nil) {
        if let section { bridge.section = section }
        // Re-detect engine health (not just copy cached state) so the setup card
        // is current — e.g. Ollama uninstalled / its server stopped since launch.
        bridge.host?.refreshBootstrap()
        bridge.refreshFromHost()
        bridge.usageStats.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up changes made elsewhere (e.g. the status-bar menu, or Ollama
        // being quit/uninstalled) while away — re-detect, then sync the UI.
        bridge.host?.refreshBootstrap()
        bridge.refreshFromHost()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.onClose() }
    }
}
