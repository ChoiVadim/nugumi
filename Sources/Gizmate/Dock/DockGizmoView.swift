import SwiftUI

/// What a docked gizmo shows until gizmos can describe their own output.
///
/// A run card, not a placeholder: name, what it works on, and a button per
/// option (or one Run button when the gizmo does one thing). The result goes
/// wherever the gizmo's `output` already sends it — panel, clipboard, notes —
/// so this adds a place to press it from, and changes nothing about what
/// pressing it does.
///
// ponytail: no result rendered here. `ToolOutput.view` is the feature that
// makes that meaningful, and inventing a half version of it now would be
// something to delete rather than build on.
struct DockGizmoView: View {
    let tool: GizmateTool
    let run: (GizmateTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().background(FlowTheme.hairline)
            if tool.options.isEmpty {
                runButton(title: "Run", option: nil)
            } else {
                optionButtons
            }
            Spacer(minLength: 0)
            Text(tool.input.displayName)
                .font(.system(size: 10))
                .foregroundStyle(FlowTheme.inkTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(FlowTheme.ink)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: tool.resolvedSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(FlowTheme.subtleFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(tool.output.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// One button per option, the same second layer the Ring gives a gizmo —
    /// the label IS the value handed to the run.
    private var optionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tool.options, id: \.self) { option in
                runButton(title: option, option: option)
            }
        }
    }

    private func runButton(title: String, option: String?) -> some View {
        Button {
            var chosen = tool
            chosen.chosenOption = option
            run(chosen)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
