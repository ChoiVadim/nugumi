import Foundation

/// Thin wiring between a dock's hover-triggered refresh and the same
/// sandboxed script runner every other gizmo uses. All of the actual
/// decision-making — the approval rule, decoding stdout, the
/// unchanged-rows comparison — lives in `SurfaceRefresh`, which is what
/// makes that logic testable without `uv`, the worker XPC, or a running app.
/// This file only resolves the three things a run needs and hands
/// `SurfaceRefresh` a closure to call them with.
extension GizmateApp {
    var surfaceRows: SurfaceRowsCache { surfaceRowsCache }

    /// Runs a surface gizmo's script because the pointer crossed a screen
    /// edge, not because the user pressed anything. `runScriptTool` resolves
    /// uv, the script and the approval hash the same way this does — the
    /// difference is what happens when the hash isn't approved: that path
    /// can show a sheet, this one can't, so `SurfaceRefresh.outcome` simply
    /// declines to run and the dock is left showing whatever it cached.
    @MainActor
    func refreshSurface(_ tool: GizmateTool) async -> SurfaceRefreshOutcome {
        guard let uv = uvBootstrap.executable else {
            return .failed(ToolRunError.uvMissing.localizedDescription)
        }
        guard let script = toolsStore.script(for: tool.id),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failed(ToolRunError.scriptMissing.localizedDescription)
        }

        let hash = toolsStore.approvalHash(for: tool)
        let outcome = await SurfaceRefresh.outcome(
            for: tool,
            isApproved: ToolApprovals.isApproved(tool.id, hash: hash),
            script: script,
            previous: surfaceRows.rows(for: tool.id)
        ) { tool in
            // A surface candidate's input is always `.none` — enforced when
            // it was built, see `ToolAgentCandidateV1.validate` — so there is
            // no selection or file context to resolve into argv here.
            let result = try await ToolRunner.run(tool: tool, script: script, arguments: [], uv: uv)
            guard result.isSuccess else {
                throw ToolRunError.launchFailed(
                    result.stderr.isEmpty ? "Exited with code \(result.exitCode)." : result.stderr
                )
            }
            return result.stdout
        }

        if case .refreshed(let rows) = outcome {
            surfaceRows.store(rows, for: tool.id)
        }
        return outcome
    }
}
