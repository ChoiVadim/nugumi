import AppKit

/// Tells the docks where the pointer is.
///
/// One monitor shared by all three docks rather than one each: `.mouseMoved`
/// fires on every pixel of every pointer move, and three closures on that is
/// three times the work for the same answer.
///
/// Deliberately not a transparent catcher window along each edge — that would
/// swallow clicks meant for scrollbars and other apps' window frames. While a
/// dock is hidden there is no window on its edge at all.
@MainActor
final class DockHoverMonitor {
    static let shared = DockHoverMonitor()

    var onMove: ((NSPoint) -> Void)?

    private var monitors: [Any] = []
    private var lastFire: TimeInterval = 0
    /// ~30Hz. Fine enough that a reveal feels immediate, coarse enough that a
    /// fast diagonal drag isn't hit-testing three rects a hundred times.
    private let minimumInterval: TimeInterval = 1.0 / 30.0

    private init() {}

    func start() {
        guard monitors.isEmpty else { return }
        // Global sees other apps; local sees our own windows. Global monitors
        // do not fire while Gizmate is frontmost, so both are needed.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: {
            [weak self] _ in
            self?.fire()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: {
            [weak self] event in
            self?.fire()
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func fire() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFire >= minimumInterval else { return }
        lastFire = now
        // Screen coordinates, not window coordinates — the docks reason about
        // `NSScreen.frame`.
        onMove?(NSEvent.mouseLocation)
    }
}
