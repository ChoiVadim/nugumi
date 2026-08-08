import Foundation

/// Keeps App Nap off work somebody is waiting for.
///
/// Gizmate is an `LSUIElement` app, which makes it a prime App Nap candidate
/// the moment it stops being frontmost — and a chat answer is exactly the kind
/// of work that keeps running while you go and do something else. Nap throttles
/// timers and lowers priority, so a request that took two seconds in front can
/// take noticeably longer behind, which reads as the app having stopped.
///
/// `userInitiatedAllowingIdleSystemSleep` rather than `.userInitiated`: the
/// difference between them is whether the Mac may fall asleep, and a chat
/// answer has no business holding a laptop awake. Nap is what we are declining,
/// not sleep.
///
/// This does not make an occluded window redraw, and nothing should: macOS
/// stops drawing windows nobody can see on purpose, the state underneath stays
/// correct, and forcing pixels nobody is looking at is a battery bill with no
/// buyer.
enum UserActivity {
    static func run<T>(_ reason: String, _ work: () async throws -> T) async rethrows -> T {
        let token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: reason
        )
        defer { ProcessInfo.processInfo.endActivity(token) }
        return try await work()
    }
}
