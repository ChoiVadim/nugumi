import AppKit
import Foundation

/// What a ring presenter can actually run. A `nil` closure means "unavailable
/// right now" and its slot is skipped — that is what reproduces the contextual
/// Summarize button (present only in a chat or browser) with no special-casing
/// anywhere else.
struct RingActionHandlers {
    var explain: (() -> Void)?
    var rewrite: (() -> Void)?
    var reply: (() -> Void)?
    var ask: (() -> Void)?
    var capture: (() -> Void)?
    var dictate: (() -> Void)?
    var live: (() -> Void)?
    /// Summarize carries its own sub-orbit structure, so it arrives as the
    /// option rather than a plain closure.
    var summarize: RingSummarizeOption?
    var tool: ((NugumiTool) -> Void)?
}

/// Turns a saved layout into the positioned slots the radial menu renders. The
/// one place that knows what the ring contains — both presenters (the selection
/// bar and the pet) go through here.
enum RingBuilder {
    /// One entry per layout slot, in slot order, `nil` wherever the slot is
    /// empty or its action is unavailable. Deliberately NOT compacted: the ring
    /// draws slot *i* at position *i*, so removing an action leaves a gap rather
    /// than shuffling every button after it — which is also what makes the Ring
    /// tab's diagram a truthful preview. `dismiss` runs before every action,
    /// which is the teardown each ring closure used to do inline.
    @MainActor
    static func slots(
        configuration: RingConfiguration,
        handlers: RingActionHandlers,
        dismiss: @escaping () -> Void
    ) -> [RingItem?] {
        configuration.layout.slots.map { slot in
            switch slot {
            case .empty:
                return nil
            case .builtIn(let id):
                return builtInItem(id, handlers: handlers, dismiss: dismiss)
            case .tool(let id):
                guard let tool = configuration.tools.first(where: { $0.id == id }),
                      // A tool whose trigger doesn't fit the moment leaves its slot
                      // as a gap — the same rule the contextual Summarize follows.
                      tool.trigger.matches(configuration.context),
                      let run = handlers.tool
                else { return nil }
                return RingItem.symbol(tool.resolvedSymbolName, label: tool.name) {
                    dismiss()
                    run(tool)
                }
            }
        }
    }

    @MainActor
    private static func builtInItem(
        _ id: RingActionID,
        handlers: RingActionHandlers,
        dismiss: @escaping () -> Void
    ) -> RingItem? {
        // Summarize builds its own item: an app icon plus the time-range or
        // app-picker orbits behind it.
        if id == .summarize {
            guard let option = handlers.summarize else { return nil }
            return summarizeRingItem(option, dismiss: dismiss)
        }
        let handler: (() -> Void)?
        switch id {
        case .explain:   handler = handlers.explain
        case .rewrite:   handler = handlers.rewrite
        case .reply:     handler = handlers.reply
        case .ask:       handler = handlers.ask
        case .capture:   handler = handlers.capture
        case .dictate:   handler = handlers.dictate
        case .live:      handler = handlers.live
        case .summarize: handler = nil
        }
        guard let handler else { return nil }
        return RingItem(label: id.label, image: id.icon.image()) {
            dismiss()
            handler()
        }
    }
}
