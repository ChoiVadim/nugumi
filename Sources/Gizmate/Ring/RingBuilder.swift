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
    /// Note fans out into the user's tags, so like Summarize it arrives as an
    /// option rather than a plain closure.
    var saveNote: RingSaveNoteOption?
    /// Summarize carries its own sub-orbit structure, so it arrives as the
    /// option rather than a plain closure.
    var summarize: RingSummarizeOption?
    var tool: ((GizmateTool) -> Void)?
}

/// Turns a saved layout into the positioned slots the radial menu renders. The
/// one place that knows what the ring contains — both presenters (the selection
/// bar and the quick menu) go through here.
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
                return builtInItem(
                    id,
                    override: configuration.overrides[id],
                    handlers: handlers,
                    dismiss: dismiss
                )
            case .tool(let id):
                // Every gizmo the user placed stays where they put it, whatever
                // is on the clipboard: a slot that comes and goes is a slot
                // nobody can aim at. A gizmo run without its input says so
                // instead (`ToolRunError.noInput`).
                guard let tool = configuration.tools.first(where: { $0.id == id }),
                      let run = handlers.tool
                else { return nil }
                guard tool.options.isEmpty else {
                    // The choice rides inside the value: a copy with
                    // `chosenOption` set is still the same gizmo by id, so the
                    // script, its approval and its usage count all resolve
                    // exactly as they did before options existed.
                    let subItems: [RingItem?] = tool.options.map { option in
                        RingItem(label: option, image: RingTextBadge.image(option)) {
                            dismiss()
                            var picked = tool
                            picked.chosenOption = option
                            run(picked)
                        }
                    }
                    return RingItem(
                        label: tool.name,
                        image: RingIconKind.symbol(tool.resolvedSymbolName).image(),
                        // Unused, as for any expandable parent — hovering opens
                        // the orbit instead.
                        handler: {},
                        subItems: subItems,
                        subLayout: .fan
                    )
                }
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
        override: BuiltInOverride?,
        handlers: RingActionHandlers,
        dismiss: @escaping () -> Void
    ) -> RingItem? {
        // Switched off in the built-in's editor. Returning nil reuses the gap
        // the ring already draws for an unavailable action rather than adding a
        // path of its own — and it leaves the slot where it is, so the buttons
        // after it keep their positions.
        guard override?.isEnabled ?? true else { return nil }
        // Summarize builds its own item: an app icon plus the time-range or
        // app-picker orbits behind it.
        if id == .summarize {
            guard let option = handlers.summarize else { return nil }
            return summarizeRingItem(option, dismiss: dismiss)
        }
        // Same story as Summarize: the button carries its own orbit, so it is
        // built rather than wrapped around a bare closure.
        if id == .saveNote {
            guard let option = handlers.saveNote else { return nil }
            return saveNoteRingItem(option, dismiss: dismiss)
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
        case .saveNote, .summarize: handler = nil
        }
        guard let handler else { return nil }
        // Summarize and Note wear bespoke buttons (an app icon, their own
        // orbits), so a renamed label or swapped glyph only reaches the plain
        // ones — which is every built-in that returns a handler here.
        let label = override?.name ?? id.label
        let icon = override?.symbol.map { RingIconKind.symbol($0) } ?? id.icon
        return RingItem(label: label, image: icon.image()) {
            dismiss()
            handler()
        }
    }
}
