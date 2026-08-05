import GizmateToolAgentCore
import SwiftUI

/// Owns a `.surface` gizmo's whole life inside the dock: draw whatever the
/// last run produced, kick off a fresh run in the background, and swap the
/// rows in once it replies — or keep what's on screen and say so if it fails.
///
/// `EdgeDockController.expandedView` calls `DockItem.makeView()` fresh every
/// time the panel reveals, so a new `SurfaceHostView` — and a fresh `.task`
/// — is exactly "one refresh per reveal". Nothing here needs to key or cancel
/// anything itself.
struct SurfaceHostView: View {
    let tool: GizmateTool
    let host: any SettingsHost

    /// Seeded from the cache in `init`, not from `.task`. That ordering is
    /// the entire point of `SurfaceRowsCache`: the first frame this view
    /// draws must already show something, rather than sitting empty through
    /// the ~300 ms `uv` + Python cold start a fresh run costs.
    @State private var rows: [SurfaceRow]
    @State private var stale: String?

    init(tool: GizmateTool, host: any SettingsHost) {
        self.tool = tool
        self.host = host
        _rows = State(initialValue: host.surfaceRows.rows(for: tool.id))
    }

    var body: some View {
        Group {
            // `DockCatalog.gizmos` only lists tools `GizmateTool.isUsable`
            // already required to carry a layout for `.surface` output — a
            // nil here means that invariant broke somewhere upstream, not
            // that this is a real gizmo. Drawing nothing makes the bug
            // visible instead of crashing the whole dock over it.
            if let layout = tool.layout {
                SurfaceView(layout: layout, rows: rows, stale: stale)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let outcome = await host.refreshSurface(tool)
        // Leave `rows` exactly as cached on `.failed` —
        // `SurfaceRefreshOutcome.failed` promises "the dock keeps showing
        // its cached rows either way" — so `rows.isEmpty` here is exactly
        // "is there a 'what was here last' to fall back to".
        if case .refreshed(let fresh) = outcome {
            rows = fresh
        }
        stale = SurfaceRefresh.caption(for: outcome, rowsAreEmpty: rows.isEmpty)
    }
}
