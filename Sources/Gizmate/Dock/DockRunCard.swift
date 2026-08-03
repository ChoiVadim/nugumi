import SwiftUI

/// What a docked tool shows when it has no surface of its own yet.
///
/// Name, what pressing it will do, and a button per option — or one Run when the
/// tool does one thing. The result goes wherever that tool already sends it, so
/// this adds a place to press from and changes nothing about what pressing does.
///
/// Used by both kinds of tool on purpose: a shipped action and a generated gizmo
/// with nothing to render are the same problem, and were two views until the
/// built-ins became dockable.
///
// ponytail: no result rendered here. That is the block-schema feature, and a
// half version of it now would be something to delete rather than build on.
struct DockRunCard: View {
    let title: String
    let icon: RingIconKind
    /// What pressing it does with the result — "Show panel", "Save to notes".
    let subtitle: String
    /// What it works on. Empty hides the line.
    let footnote: String
    /// One button per entry, the label being the value handed to the run. Empty
    /// means a single Run button.
    let options: [String]
    let onRun: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().background(FlowTheme.hairline)
            if options.isEmpty {
                runButton(title: "Run", option: nil)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        runButton(title: option, option: option)
                    }
                }
            }
            Spacer(minLength: 0)
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(FlowTheme.ink)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: icon.image(pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(FlowTheme.subtleFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func runButton(title: String, option: String?) -> some View {
        Button {
            onRun(option)
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
