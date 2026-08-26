import AppKit
import SwiftUI

struct StyleCard: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let category: AppCategory
    @Binding var selection: WritingStyle

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.displayName)
                        .font(FlowTheme.serif(19))
                        .foregroundStyle(FlowTheme.ink)
                    Spacer()
                    PillPicker(options: WritingStyle.allCases, selection: $selection, label: { $0.displayName })
                }

                Divider().background(FlowTheme.hairline)

                // Left: how messages read in this style. Right: where it applies.
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Preview")
                        ChatBubble(text: sample(for: selection))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(FlowTheme.hairline)
                        .frame(width: 1)

                    if category == .other {
                        // "Other" is the catch-all every unmatched app/site falls
                        // into, so there's nothing to assign — explain instead.
                        VStack(alignment: .leading, spacing: 10) {
                            fieldLabel("Scope")
                            Text("Apps and sites that don't match the categories above land here automatically - nothing to assign.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(FlowTheme.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            fieldLabel("Apps")
                            AppIconStrip(category: category, apps: bridge.settings.apps(for: category))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowTheme.inkSecondary)
    }

    /// Preview text per category × style, so each card reads in its own context
    /// (a friend lunch ping vs a work sync vs an email) instead of one shared line.
    private func sample(for style: WritingStyle) -> String {
        switch category {
        case .personalMessages:
            switch style {
            case .formal: return "Hello! Are you free for lunch tomorrow? Noon works well for me."
            case .polite: return "Hi! Are you free for lunch tomorrow? Let's do 12 if that works for you."
            case .casual: return "hey are you free for lunch tmrw? let's do 12 if that works"
            }
        case .workMessages:
            switch style {
            case .formal: return "Could we find time tomorrow to review the Q3 report? Noon would work on my end."
            case .polite: return "Hey, do you have time tomorrow to go over the Q3 report? Does noon work?"
            case .casual: return "yo can we sync tmrw on the q3 report? noon good?"
            }
        case .email:
            switch style {
            case .formal: return "Dear Alex, would you be available for a call next week to discuss the proposal? Best, Sam"
            case .polite: return "Hi Alex! Any time next week for a quick call about the proposal? Thanks, Sam"
            case .casual: return "hey alex! free next week for a quick call about the proposal?"
            }
        case .other:
            switch style {
            case .formal: return "Hello, could you let me know the best time to reach you?"
            case .polite: return "Hi! When's a good time to reach you?"
            case .casual: return "hey whats a good time to reach you?"
            }
        }
    }
}

/// Plain multi-line editor backed by `NSTextView` so we fully own the scroll view.
/// SwiftUI's `TextEditor` re-applies its own scroller config on every update, so
/// `autohidesScrollers` never sticks there — owning the `NSScrollView` makes the
/// track auto-hide when the text fits. Mirrors the app's other NSTextView editors.
/// Hands the scroll wheel back to whatever this editor sits in — a note card
/// inside a list — unless it is actually being edited.
///
/// An `NSScrollView` swallows `scrollWheel` even with nothing to scroll, so an
/// editor embedded in a card would stop the list dead wherever the pointer
/// happened to rest. Editing is the one case where the editor has a claim on it,
/// because that is when a long note needs scrolling on its own.
final class PassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard window?.firstResponder === documentView else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// `paste(_:)` is what ⌘V reaches through the Edit menu, so overriding it is
/// the one place a paste can be seen before the field editor decides it means
/// text — a monitor is only needed where the text view is not yours.
final class PlainTextView: NSTextView {
    /// Returns true to have taken the paste, in which case the text view never
    /// sees it.
    var pasteHook: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if pasteHook?(.general) == true { return }
        super.paste(sender)
    }

    /// This editor takes nothing by drag. A text view registers for file drops
    /// and inserts the path, and being the deepest registered view it takes the
    /// drop before any SwiftUI target wrapped around it is asked. Registering
    /// for strings alone was not enough: a screenshot dragged off the floating
    /// thumbnail carries its path as plain text beside the file, and any type
    /// the editor takes is a type it takes before the card. Text is typed or
    /// pasted here; a picture, dropped anywhere on the card, reaches the card.
    ///
    /// Overridden rather than set once after init: AppKit calls this again
    /// whenever editability or the window changes, and the first attempt — an
    /// `unregisterDraggedTypes` in `makeNSView` — was undone by exactly that
    /// before the first drop landed.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    /// The same rule for every field editor in the app — the shared text view
    /// an `NSTextField` edits through, a note's title included. It registers
    /// for file drops like any text view, so a picture dropped on a title
    /// arrived as a path in the title.
    ///
    /// Not a field editor of our own: SwiftUI's `TextField` force-casts the
    /// window's editor to a private subclass of its own and aborts on anything
    /// else. Instead, the editor is trimmed the moment it goes live. Setup runs
    /// `updateDragTypeRegistration` and then places the caret, so the selection
    /// notification is the first one after the registration is final; the
    /// check on `registeredDraggedTypes` keeps every later caret move free.
    static func trimFieldEditorDrops() {
        NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
        ) { note in
            guard let editor = note.object as? NSTextView, editor.isFieldEditor,
                  !editor.registeredDraggedTypes.isEmpty
            else { return }
            editor.unregisterDraggedTypes()
        }
    }
}

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// How tall the laid-out text actually is, for a caller that wants to size
    /// itself to its content. Defaults to a sink so every existing caller — all
    /// of which live in fixed-height cards — is unchanged.
    var measuredHeight: Binding<CGFloat> = .constant(0)
    /// First look at a paste, see `PlainTextView.pasteHook`.
    var pasteHook: ((NSPasteboard) -> Bool)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlainTextView()
        textView.pasteHook = pasteHook
        textView.updateDragTypeRegistration()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let scroll = PassthroughScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PlainTextView else { return }
        if textView.string != text { textView.string = text }
        textView.pasteHook = pasteHook
        textView.textColor = .white
        context.coordinator.report(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // In the same turn as the text, so a card that follows its content
            // grows in the layout pass that lays out the new line. Reported a
            // turn later, the text first scrolls itself up inside the old
            // frame to show the caret, then snaps back when the frame catches
            // up: one visible jump per Return.
            report(textView, deferred: false)
        }

        /// TextKit 2 first, TextKit 1 as the fallback. Reaching for
        /// `layoutManager` on a TextKit 2 view silently downgrades it to
        /// compatibility mode, so it is only touched when there is no TextKit 2
        /// layout manager to ask.
        ///
        /// `deferred` is for callers inside a SwiftUI update pass, where writing
        /// a binding is "Modifying state during view update"; a text view's own
        /// change notification is outside one and writes straight through.
        func report(_ textView: NSTextView, deferred: Bool = true) {
            let height: CGFloat
            if let tlm = textView.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
                height = tlm.usageBoundsForTextContainer.height
            } else if let lm = textView.layoutManager, let container = textView.textContainer {
                lm.ensureLayout(for: container)
                height = lm.usedRect(for: container).height
            } else {
                return
            }
            guard abs(height - parent.measuredHeight.wrappedValue) > 0.5 else { return }
            guard deferred else { return parent.measuredHeight.wrappedValue = height }
            DispatchQueue.main.async { [parent] in parent.measuredHeight.wrappedValue = height }
        }
    }
}

private struct ChatBubble: View {
    let text: String
    /// Accent-tinted bubble for the "Gizmate's rewrite" side of the preview.
    var accent: Bool = false
    /// Right-aligned (outgoing) bubble — the "tail" corner flattens bottom-right.
    var trailing: Bool = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 15,
            bottomLeadingRadius: trailing ? 15 : 4,
            bottomTrailingRadius: trailing ? 4 : 15,
            topTrailingRadius: 15,
            style: .continuous
        )
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(FlowTheme.ink)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(shape.fill(accent ? FlowTheme.accent.opacity(0.30) : Color.white.opacity(0.09)))
            .overlay(shape.strokeBorder(accent ? FlowTheme.accent.opacity(0.35) : FlowTheme.hairline, lineWidth: 1))
    }
}
