import AppKit
import SwiftUI

/// The leaves every chat in Gizmate is built from.
///
/// Extracted when Home grew a chat of its own. Two transcripts drawing a
/// question pill and a markdown answer from two copies of the same code is
/// exactly the drift DESIGN.md §12 is about — and the answer half is where it
/// would hurt, because it carries a real fix (see `MarkdownLabel`) that a copy
/// would not have.

/// Sized to its own text and pushed right, with a hard gap on its left so a
/// long question never becomes a full-width slab indistinguishable from the
/// answer under it.
struct ChatQuestionBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 28)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
                .padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(FlowTheme.subtleFill)
                )
        }
    }
}

/// Markdown through `TranslationContentView.renderedMarkdownText`, the same
/// renderer the floating answer panel uses rather than a second one that would
/// drift from it, and shown in AppKit so its work survives.
struct ChatAnswerText: View {
    let markdown: String

    var body: some View {
        MarkdownLabel(
            text: TranslationContentView.renderedMarkdownText(
                markdown,
                font: .systemFont(ofSize: 12.5),
                color: NSColor(calibratedWhite: 1, alpha: 0.9)
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An answer, held clear of the right edge.
///
/// It used to carry Gizmate's mark down the left, on the argument that a mark is
/// what makes a transcript read as two people. It is not: the question is a
/// filled pill pushed to the right edge and the answer is bare text on the left,
/// which separates them at a glance and keeps doing so with the mark gone. What
/// the mark did instead was indent every answer by 29pt while Home's own turns
/// stayed flush left, so one transcript had two left margins — and it repeated
/// the same logo down the page for a conversation with one participant on each
/// side. Decoration paying no rent.
struct ChatAssistantTurn<Content: View>: View {
    /// How much room is kept clear on the right. The builder's chat is a narrow
    /// panel and wants a wide gutter so an answer never runs to its own edge;
    /// a capped column has that already.
    var trailingGutter: CGFloat = 60
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content()
            Spacer(minLength: trailingGutter)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One line that breathes while work is in flight.
///
/// Scoped to the opacity with `value:` rather than driven by `withAnimation` at
/// `onAppear`: a `repeatForever` curve opened as a transaction also catches the
/// layout settling in that same pass, and then the row's height oscillates
/// forever and the scroller breathes with it.
struct ChatThinkingText: View {
    let text: String

    @State private var pulse = false

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(FlowTheme.inkSecondary)
            .opacity(pulse ? 0.45 : 1)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

struct ChatProblemText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An answer, drawn by AppKit.
///
/// SwiftUI's `Text(AttributedString(nsAttributed))` drops paragraph styles, and
/// paragraph styles are most of what `renderedMarkdownText` produces: the space
/// between blocks, and the hanging indent that keeps a wrapped bullet aligned
/// under its own text instead of back at the margin. Both were silently
/// missing, so a list arrived as a bullet, a wide tab from an unhandled tab
/// stop, and every following line flush left — the renderer was working and
/// SwiftUI was throwing half of it away.
///
/// `NSTextView`, like the floating panel, and *not* the `NSTextField` label this
/// used to be. A selectable label has no text of its own to click: the first
/// click hands it to the window's shared field editor, which lays the answer out
/// again with its own 2pt line fragment padding on each side. Four points
/// narrower is a different set of line breaks and, often, one line more — so an
/// answer visibly resized under the pointer the moment you tried to select it.
/// Measured: 60pt tall before the click, 64pt after. A text view is its own
/// editor, so there is no second layout to disagree with the first.
struct MarkdownLabel: NSViewRepresentable {
    let text: NSAttributedString

    /// The width the column last offered, for the measuring passes that arrive
    /// with no width proposed at all. Answering those with `nil` would hand the
    /// layout to the view's intrinsic size, which for wrapped text is the whole
    /// answer on one line.
    final class Coordinator {
        var width: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        // Both zeroed so the view lays the text out on exactly the geometry
        // `boundingRect` measures below. Any inset here and the height is
        // computed for a wider line than the one drawn.
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textStorage?.setAttributedString(text)
        return view
    }

    /// Only when the answer really changed. A streamed reply changes on every
    /// chunk and must be written through, but an unrelated redraw must not —
    /// rewriting the storage drops whatever the reader had selected.
    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.textStorage?.isEqual(to: text) != true else { return }
        view.textStorage?.setAttributedString(text)
    }

    /// Height comes from the width SwiftUI is offering. Without this the view
    /// measures itself as one very long line and the answer is clipped to its
    /// first row.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let offered = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = offered ?? context.coordinator.width
        guard width > 0 else { return nil }
        context.coordinator.width = width
        let height = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        return CGSize(width: width, height: ceil(height))
    }
}
