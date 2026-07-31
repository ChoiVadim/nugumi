import AppKit
import Foundation

/// Global-shortcut trigger for a spare mouse button (middle or higher).
/// Carbon hotkeys are keyboard-only, so this uses a CGEvent tap that
/// CONSUMES the bound click — a pass-through middle-click also reached the
/// app under the cursor (browser autoscroll swaps/hides the pointer, some
/// apps paste or close tabs). Falls back to observe-only NSEvent monitors
/// when the tap can't be created (e.g. no Accessibility permission yet).
final class MouseButtonShortcutMonitor {
    private let buttonNumber: Int
    private let onPressed: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(buttonNumber: Int, onPressed: @escaping @MainActor () -> Void) {
        self.buttonNumber = buttonNumber
        self.onPressed = onPressed
    }

    func start() {
        guard eventTap == nil, globalMonitor == nil, localMonitor == nil else { return }
        startEventTap()
        if eventTap == nil {
            startFallbackMonitors()
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func startEventTap() {
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MouseButtonShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                // The OS disables taps it deems slow — re-arm and let the
                // event through rather than going permanently deaf.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard event.getIntegerValueField(.mouseEventButtonNumber) == Int64(monitor.buttonNumber) else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .otherMouseDown {
                    let handler = monitor.onPressed
                    Task { @MainActor in handler() }
                }
                // Swallow BOTH down and up for the bound button, so the app
                // under the cursor never sees a half-delivered click.
                return nil
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startFallbackMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            self?.handleFallback(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            self?.handleFallback(event)
            return event
        }
    }

    private func handleFallback(_ event: NSEvent) {
        guard event.buttonNumber == buttonNumber else { return }
        let handler = onPressed
        Task { @MainActor in handler() }
    }
}
