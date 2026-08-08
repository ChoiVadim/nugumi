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

/// An answer, with Gizmate's mark beside it.
///
/// The mark is what makes a transcript read as two people rather than as
/// alternating paragraphs, and it is the thing the builder's chat has always
/// had. Extracted here when Home grew a chat too — the third place this pattern
/// came up is where copying it stops being cheaper than sharing it.
struct ChatAssistantTurn<Content: View>: View {
    /// How much room is kept clear on the right. The builder's chat is a narrow
    /// panel and wants a wide gutter so an answer never runs to its own edge;
    /// a capped column has that already.
    var trailingGutter: CGFloat = 60
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(nsImage: ChatAvatar.image)
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)
            content()
            Spacer(minLength: trailingGutter)
        }
        .frame(maxWidth: .infinity)
    }

}

/// The tinted silhouette, not the artwork: the mark is a black body and would
/// disappear into these panels. Same treatment as the menu bar, and outside
/// `ChatAssistantTurn` because a generic type cannot hold a stored static.
enum ChatAvatar {
    static let image: NSImage =
        BrandMark.templateImage(height: 17) ?? NSApp.applicationIconImage
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
/// `NSTextField` rather than the `NSTextView` the floating panel uses: this one
/// never scrolls or edits, and a label reports its own height, which is what a
/// stack of them in a transcript needs.
struct MarkdownLabel: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = text
    }

    /// Height comes from the width SwiftUI is offering. Without this the field
    /// measures itself as one very long line and the answer is clipped to its
    /// first row.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextField,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        nsView.preferredMaxLayoutWidth = width
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }
}
