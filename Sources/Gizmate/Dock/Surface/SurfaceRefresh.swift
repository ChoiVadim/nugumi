import Foundation

/// What a hover-triggered refresh of a surface gizmo can come back with.
enum SurfaceRefreshOutcome: Equatable {
    /// The script ran and printed rows that differ from what was cached.
    case refreshed([SurfaceRow])
    /// The script ran and printed exactly the rows already cached — nothing
    /// for the dock to redraw.
    case unchanged
    /// The gizmo wasn't approved, its script didn't run, or its output
    /// wasn't rows. The dock keeps showing its cached rows either way.
    case failed(String)
}

/// The decision logic behind refreshing a surface: whether it's allowed to
/// run at all, and what its output means once it has. Kept free of `uv`, the
/// worker XPC and `NSAlert` — everything that makes a script actually
/// execute — so the one rule that matters here can be tested on its own.
/// `GizmateApp+Surfaces.swift` is the thin wiring that hands `run` a real
/// `ToolRunner` call.
enum SurfaceRefresh {
    /// - Parameters:
    ///   - isApproved: whether the user has already approved this exact
    ///     script, from `ToolApprovals.isApproved`. A refresh fires on
    ///     pointer hover, with nothing in the trigger a modal could hang off
    ///     of — unlike a run started from the ring or Home, an unapproved
    ///     surface here simply does not run. `run` is never called when this
    ///     is false.
    ///   - previous: the rows currently cached for this gizmo, so a script
    ///     that printed the same thing again doesn't send the dock a redraw
    ///     of what it's already showing.
    ///   - run: executes the tool's script and returns its stdout, or throws
    ///     when the run itself failed — a timeout, a non-zero exit, uv
    ///     missing.
    static func outcome(
        for tool: GizmateTool,
        isApproved: Bool,
        previous: [SurfaceRow] = [],
        run: (GizmateTool) async throws -> String
    ) async -> SurfaceRefreshOutcome {
        guard isApproved else {
            return .failed("Not approved yet — run “\(tool.name)” once from the ring or Home first.")
        }
        do {
            let stdout = try await run(tool)
            let rows = try SurfaceRows.decode(stdout: stdout)
            return rows == previous ? .unchanged : .refreshed(rows)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
