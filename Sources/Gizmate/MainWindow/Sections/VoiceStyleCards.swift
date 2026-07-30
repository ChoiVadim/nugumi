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

                if category == .email {
                    Divider().background(FlowTheme.hairline)
                    EmailVoiceSampleEditor(sample: bridge.settings.emailVoiceSample)
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
        case .other, .custom:
            switch style {
            case .formal: return "Hello, could you let me know the best time to reach you?"
            case .polite: return "Hi! When's a good time to reach you?"
            case .casual: return "hey whats a good time to reach you?"
            }
        }
    }
}

/// The single user-authored style: a free-text instruction that replaces the
/// register, plus the apps it applies to. Sits at the bottom of the Style page.
struct CustomStyleCard: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        SubCard {
            // Two columns: the description + apps on the left, the instruction
            // editor on the right where it gets the full column height.
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Custom style")
                        .font(FlowTheme.serif(19))
                        .foregroundStyle(FlowTheme.ink)

                    Text("Write your own instruction and pick the apps it applies to. It replaces the register (Formal/Polite/Casual) for those apps.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Pins the apps to the bottom so they line up with the
                    // editor's foot; the editor's minHeight sets the column height.
                    // No label — the description already explains the apps.
                    Spacer(minLength: 16)

                    AppIconStrip(category: .custom, apps: bridge.settings.apps(for: .custom))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(FlowTheme.hairline)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("Instruction")
                    CustomInstructionEditor(text: bridge.settings.customStyleInstruction)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowTheme.inkSecondary)
    }
}

/// Multi-line editor for the custom style instruction. Mirrors
/// `EmailVoiceSampleEditor`: a local draft persisted on every change.
private struct CustomInstructionEditor: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    @State private var draft: String

    init(text: String) {
        _draft = State(initialValue: text)
    }

    var body: some View {
        PlainTextEditor(text: $draft)
            .frame(minHeight: 150, maxHeight: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("e.g. Reply in lowercase, keep it short, no emojis - like texting a close friend.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkTertiary.opacity(0.55))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 11)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: draft) { _, newValue in
                bridge.perform(.setCustomStyleInstruction(newValue))
            }
    }
}

/// Plain multi-line editor backed by `NSTextView` so we fully own the scroll view.
/// SwiftUI's `TextEditor` re-applies its own scroller config on every update, so
/// `autohidesScrollers` never sticks there — owning the `NSScrollView` makes the
/// track auto-hide when the text fits. Mirrors the app's other NSTextView editors.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
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

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.textColor = .white
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
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
