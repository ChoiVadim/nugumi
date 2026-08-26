import Foundation
import GizmateToolAgentCore

/// The gizmos Gizmate ships with. Not a feature beside the tool system — each
/// one is an ordinary `GizmateTool` seeded into the same store a built one
/// lands in, so the user can edit it in chat, retune it in its editor, move
/// it between edges, or delete it, and nothing anywhere special-cases it
/// after this file runs once.
enum DefaultTools {
    /// Stable across every install, so "already there" is an id lookup. The
    /// value is the machine-of-origin's generated id on purpose: the Mac this
    /// tool was built and tuned on already holds it under this id, and
    /// seeding there must be a no-op, not a duplicate.
    static let macUsageID = UUID(uuidString: "EA1AADBF-BD35-4043-BBB6-E3E955B613D6")!

    /// Seed-once, not ensure-always: a user who deletes a default tool has
    /// answered "do I want this" and a launch must not re-ask.
    static let seededDefaultsKey = "defaultToolsSeededV1"

    /// Installs the shipped gizmos on the first launch that knows about them.
    ///
    /// The seeded tool is approved here too. The approval gate exists for
    /// scripts that changed behind the user's back; this script ships inside
    /// the app the user installed, which is the same consent that covers all
    /// the app's own code. It is also docked, because a surface that lives
    /// nowhere never runs — a default the user has to excavate is not a
    /// default.
    @MainActor
    static func seed(into store: ToolsStore, dock: DockStore, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: seededDefaultsKey) else { return }
        defaults.set(true, forKey: seededDefaultsKey)
        guard store.tool(id: macUsageID) == nil else { return }
        guard let url = GizmateResources.bundle.url(forResource: "MacUsage", withExtension: "py"),
              let script = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        let tool = GizmateTool(
            id: macUsageID,
            name: "Mac Usage",
            symbolName: "gauge",
            kind: .python,
            input: .none,
            output: .surface,
            timeoutSeconds: 10,
            layout: macUsageLayout,
            refreshSeconds: 1,
            brief: "Shows live CPU, memory, storage, battery, and network "
                + "readings, refreshing every second while the panel is open."
        )
        store.save(tool, script: script)
        ToolApprovals.approve(macUsageID, hash: store.approvalHash(for: tool))
        let dockID = ToolRef.generated(macUsageID).storageID
        if dock.edge(of: dockID) == nil {
            dock.dock(dockID, to: .right)
        }
    }

    /// The same tree the builder composed for the original: one list, one
    /// card per reading, glyph bound per row so a CPU card and a battery card
    /// carry their own. Four detail slots even though the script currently
    /// prints one — a line whose key a row lacks simply isn't drawn, so the
    /// slots cost nothing and survive the script growing a line back.
    static let macUsageLayout = ToolAgentLayoutV1.list(
        row: .card(.init(
            title: .key("name"),
            icon: .symbolKey(key: "icon"),
            details: [.key("detail1"), .key("detail2"), .key("detail3"), .key("detail4")],
            meter: "meter",
            chart: "chart"
        )),
        empty: "Usage data is unavailable"
    )
}
