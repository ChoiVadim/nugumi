import AppKit

/// The result panel for a script or agent gizmo whose output is `.panel`.
///
/// These used to end in an alert: an `NSTextField` that showed a markdown
/// report as its own source, grew taller than the screen, and ignored the
/// edge the tool's editor had placed it on. Prompt gizmos never did, because
/// they went through `translate(...)` and the one panel every built-in answer
/// uses. This is that panel for the other kinds, so all four say the same
/// thing the same way: glass, block markdown once the answer is final, docked
/// where the placement says, and the agent's steps shimmering where the
/// answer is about to be instead of a bare pill at the cursor.
extension GizmateApp {
    @MainActor
    func presentGizmoResultPanel(for tool: GizmateTool, near screenPoint: NSPoint) -> TranslationPanelController {
        let controller = TranslationPanelController(
            anchor: .point(screenPoint, panelSide: .right),
            sourceText: "",
            targetLanguage: targetLanguage,
            resultLabel: tool.name,
            showsSource: false,
            showsFollowUp: true,
            // The same follow-up every built-in answer takes: `.revise`
            // answers a question about the result as readily as it edits it.
            onFollowUp: { [weak self] instruction in
                self?.reviseCurrentPanel(instruction: instruction)
            },
            dockHost: resultHost(for: .generated(tool.id)),
            onClose: { [weak self] in self?.translationPanelController = nil }
        )
        translationPanelController?.close()
        translationPanelController = controller
        controller.showLoading()
        return controller
    }
}
