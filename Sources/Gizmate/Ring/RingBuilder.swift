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
    var tool: ((GizmateTool) -> Void)?
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
        items(
            in: configuration.layout,
            depth: 0,
            configuration: configuration,
            handlers: handlers,
            dismiss: dismiss
        )
    }

    /// One entry per slot of `ring`. `depth` counts how many folders deep this
    /// ring already sits, which is what caps nesting at the three orbits the
    /// radial menu can actually draw.
    @MainActor
    private static func items(
        in ring: RingLayout,
        depth: Int,
        configuration: RingConfiguration,
        handlers: RingActionHandlers,
        dismiss: @escaping () -> Void
    ) -> [RingItem?] {
        // Driven by the depth's capacity, not by how long the stored array
        // happens to be: an orbit has more positions than the ring, and a
        // folder only ever stores as far as its last filled slot.
        (0..<RingLayout.capacity(atDepth: depth)).map { index -> RingItem? in
            switch ring.content(at: index) {
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
            case .folder(let id):
                return folderItem(
                    id,
                    depth: depth,
                    configuration: configuration,
                    handlers: handlers,
                    dismiss: dismiss
                )
            }
        }
    }

    /// A folder becomes a hover-expandable button carrying its ring as
    /// `subItems`. Sub-orbits are fanned, not positioned, so gaps are dropped
    /// here rather than preserved the way the first ring preserves them.
    @MainActor
    private static func folderItem(
        _ id: UUID,
        depth: Int,
        configuration: RingConfiguration,
        handlers: RingActionHandlers,
        dismiss: @escaping () -> Void
    ) -> RingItem? {
        guard depth < RingFolderDepth.maxNesting,
              let folder = configuration.folders.first(where: { $0.id == id })
        else { return nil }
        let subItems = items(
            in: folder.layout,
            depth: depth + 1,
            configuration: configuration,
            handlers: handlers,
            dismiss: dismiss
        )
        return RingItem(
            label: folder.name,
            image: RingIconKind.symbol(folder.resolvedSymbolName).image(),
            // An empty folder still gets its button — vanishing from the ring
            // is how a folder you just made looks like a bug. With nothing to
            // open the menu treats it as an ordinary button, so give it the one
            // sensible action: close, rather than swallow the click.
            handler: { dismiss() },
            // Gaps are kept: a folder's orbit is a ring, and slot 3 stays at
            // slot 3's angle whether or not slots 1 and 2 are filled.
            subItems: subItems,
            subLayout: .slots
        )
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
