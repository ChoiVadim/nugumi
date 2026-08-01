import AppKit
import Foundation

/// Pure double-tap state machine, decoupled from `NSEvent` so it can be
/// unit-tested by feeding modifier-set transitions directly.
struct DoubleTapState {
    private var lastSupportedWasEmpty = true
    private var lastTapDate: Date?

    /// Feed the supported-modifier set from each `flagsChanged`, in order.
    /// A genuine double-tap is the target modifier and NOTHING ELSE: two clean
    /// presses of `modifier` alone, back to back. Two guards enforce that:
    ///   • A tap must start from a clean state (no supported modifier held just
    ///     before), so releasing a second modifier can't masquerade as a press.
    ///   • The instant any OTHER supported modifier joins (e.g. Shift during
    ///     ⌃⇧Tab), the pending first tap is cancelled — so double-tapping a
    ///     *combo* like ⌃⇧Tab never completes.
    /// - Returns: true when this transition completes a double-tap.
    mutating func step(
        supportedActive: NSEvent.ModifierFlags,
        modifier: NSEvent.ModifierFlags,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        let cameFromClean = lastSupportedWasEmpty
        defer { lastSupportedWasEmpty = supportedActive.isEmpty }

        // Any modifier beyond the target contaminates the gesture — drop the
        // pending tap so a combo (⌃⇧, ⌃⌘, …) can't build a double-tap.
        if !supportedActive.subtracting(modifier).isEmpty {
            lastTapDate = nil
            return false
        }
        guard cameFromClean, supportedActive == modifier else { return false }

        if let last = lastTapDate, now.timeIntervalSince(last) <= interval {
            lastTapDate = nil
            return true
        }
        lastTapDate = now
        return false
    }

    /// Any non-modifier key press (Tab, a letter, …) cancels a pending tap:
    /// a real double-tap of `modifier` involves no other keys. Catches combos
    /// whose extra key isn't a modifier, e.g. double ⌃Tab.
    mutating func noteOtherKeyPressed() {
        lastTapDate = nil
    }

    mutating func reset() {
        lastSupportedWasEmpty = true
        lastTapDate = nil
    }
}

@MainActor
final class DoubleModifierPressDetector {
    private let modifier: NSEvent.ModifierFlags
    private let interval: TimeInterval
    private let onDetected: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var state = DoubleTapState()
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                resetState()
            }
        }
    }

    init(
        modifier: NSEvent.ModifierFlags,
        interval: TimeInterval = 0.30,
        onDetected: @escaping @MainActor () -> Void
    ) {
        self.modifier = modifier.intersection(GlobalShortcut.supportedModifiers)
        self.interval = interval
        self.onDetected = onDetected
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        // Watch keyDown too, so any real key pressed mid-gesture cancels a
        // pending double-tap (a genuine double-tap is the modifier alone).
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        // Global monitor: fires only while ANOTHER app is frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        // Local monitor: fires while Gizmate itself is the active app (e.g.
        // right after the Ask prompt was shown and clicked). Without this the
        // detector goes deaf once the app activates and never recovers until
        // another app regains focus. Must return the event unmodified.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        resetState()
    }

    private func resetState() {
        state.reset()
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }

        if event.type == .keyDown {
            state.noteOtherKeyPressed()
            return
        }

        let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let supportedActive = active.intersection(GlobalShortcut.supportedModifiers)
        if state.step(supportedActive: supportedActive, modifier: modifier, now: Date(), interval: interval) {
            onDetected()
        }
    }
}
