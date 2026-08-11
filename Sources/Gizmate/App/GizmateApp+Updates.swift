import Foundation
import Sparkle

extension GizmateApp {
    var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

/// The feed is named once, in `Resources/Info.plist` (`SUFeedURL`). This used to
/// also hardcode it here, which silently won: a delegate's `feedURLString` beats
/// the plist, so changing the plist alone moved nothing. With the legacy
/// `appcast.xml` frozen for the old com.nugumi.app and `appcast-gizmate.xml` live for
/// com.gizmate.app, a second copy of the URL is a way to ship the wrong one.
extension GizmateApp: SPUUpdaterDelegate {}

extension GizmateApp: SPUStandardUserDriverDelegate {
    // Opt into gentle reminders: scheduled checks surface our own badge instead
    // of Sparkle's modal. User-initiated "Check for updates..." is unaffected.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Sparkle is *not* showing it (gentle path) → light up our own badge.
        guard !handleShowingUpdate else { return }
        MainActor.assumeIsolated { setAvailableUpdate(update) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setAvailableUpdate(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setAvailableUpdate(nil) }
    }
}
