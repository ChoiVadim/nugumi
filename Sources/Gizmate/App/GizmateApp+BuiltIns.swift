import Foundation

extension GizmateApp {
    /// Runs a shipped ring action from anywhere — the dock today, and whatever
    /// surface comes next.
    ///
    /// The ring assembles these as closures in `FloatingButton` and the global
    /// keys as a table in `setupGlobalHotKeys`; both predate there being a third
    /// caller. This is the one list, and those two should fold into it when they
    /// are next touched rather than growing a fourth.
    ///
    /// `summarize` does nothing here on purpose: its action is built from the
    /// frontmost app — an app icon and a time-range orbit — so there is no
    /// app-independent way to run it, and `DockCatalog` leaves it out for the
    /// same reason.
    @MainActor
    func performBuiltIn(_ id: RingActionID) {
        switch id {
        case .explain: startSelectionTranslateOrReply(forcing: .translate)
        case .rewrite: startSelectedTextTranslationForReplacement()
        case .genZ: startSelectedTextTranslationForReplacement(mode: .genZ)
        case .reply: startSelectionTranslateOrReply(forcing: .smartReply)
        case .ask: startAskGizmatePrompt()
        case .capture: startScreenshotTranslation()
        case .dictate: toggleDictation()
        case .live: toggleLiveTranslation()
        // The empty string routes through the read-the-selection-now branch in
        // `saveSelectionToNote`, the same way the quick menu does.
        case .saveNote: saveSelectionToNote("")
        case .summarize: break
        }
    }
}
