import AppKit
import Foundation

/// Global-shortcut trigger for a multi-finger trackpad tap.
///
/// macOS has no public API for gestures outside your own windows, so this
/// reads raw touches the way Hammerspoon's eventtap does: a CGEvent tap on the
/// gesture event type (`NSEvent.EventType.gesture`, 29, undocumented as a tap
/// mask) and `NSEvent(cgEvent:)` to get the touch set. The tap is listen-only.
/// Unlike a spare mouse button a tap cannot be swallowed: whatever the system
/// binds to it fires as well, which is why `GlobalShortcut` refuses one and
/// two fingers (click and secondary click).
///
/// Falls back to NSEvent monitors when the tap can't be created (no
/// Accessibility permission yet).
final class TrackpadTapShortcutMonitor {
    private let onTap: @MainActor (Int) -> Void
    private var state = TrackpadTapState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// `onTap` receives the finger count of every clean tap; the caller
    /// decides which count it wants.
    init(onTap: @escaping @MainActor (Int) -> Void) {
        self.onTap = onTap
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
        let mask = CGEventMask(1 << NSEvent.EventType.gesture.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<TrackpadTapShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                if let nsEvent = NSEvent(cgEvent: event) {
                    monitor.handle(nsEvent)
                }
                return Unmanaged.passUnretained(event)
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
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .gesture) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .gesture) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let touches = event.touches(matching: .any, in: nil).map { touch in
            TrackpadTapState.Touch(
                id: AnyHashable(touch.identity as? NSObject ?? NSNull()),
                position: touch.normalizedPosition,
                down: touch.phase != .ended && touch.phase != .cancelled
            )
        }
        guard let count = state.step(touches: touches, now: Date()) else { return }
        let handler = onTap
        Task { @MainActor in handler(count) }
    }
}

/// Tap recognition on its own, free of AppKit so a test can drive it one
/// touch frame at a time. A tap is: fingers land, none travels, all leave
/// within `maxDuration`. The count reported is the most fingers that were
/// down at once, so fingers lifting one after another still read as one tap.
struct TrackpadTapState {
    struct Touch {
        let id: AnyHashable
        let position: CGPoint
        let down: Bool
    }

    static let maxDuration: TimeInterval = 0.3
    /// In the trackpad's normalized (0...1) coordinates.
    static let maxTravel: CGFloat = 0.04

    private var began: Date?
    private var origins: [AnyHashable: CGPoint] = [:]
    private var peak = 0
    private var moved = false

    /// Feed every touch the trackpad currently reports. Returns the finger
    /// count when a clean tap just finished, nil otherwise.
    mutating func step(touches: [Touch], now: Date) -> Int? {
        let down = touches.filter(\.down)
        guard !down.isEmpty else {
            defer { self = TrackpadTapState() }
            guard let began, !moved, now.timeIntervalSince(began) <= Self.maxDuration else {
                return nil
            }
            return peak
        }
        if began == nil { began = now }
        peak = max(peak, down.count)
        for touch in down {
            guard let origin = origins[touch.id] else {
                origins[touch.id] = touch.position
                continue
            }
            if hypot(touch.position.x - origin.x, touch.position.y - origin.y) > Self.maxTravel {
                moved = true
            }
        }
        return nil
    }
}
