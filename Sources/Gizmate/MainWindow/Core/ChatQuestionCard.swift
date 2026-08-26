import GizmateToolAgentCore
import SwiftUI

/// The builder's questions, asked as something you answer rather than something
/// you read.
///
/// A clarification used to arrive as an ordinary assistant message and be
/// answered in the main composer, which had two costs. The cheap one is typing:
/// "Safari" is a word somebody has to spell to a machine that already knew the
/// three apps worth naming. The expensive one is that a question drawn as prose
/// is a question that scrolls away, and a build waiting on an answer nobody can
/// see any more waits forever.
///
/// So the card is a stop, not a paragraph: it owns the bottom of the transcript,
/// it says how many questions are left, and it cannot be scrolled past without
/// noticing. `options` are a shortcut and never a constraint, which is why the
/// free-text field is always there, and why ✕ skips rather than cancels. A
/// question the user cannot answer must not be the reason the gizmo is never
/// made.
struct ChatQuestionCard: View {
    let questions: ToolBuilderQuestions
    let onAnswer: (String) -> Void
    let onSkip: () -> Void

    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let question = questions.current {
                Text(question.question)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Divider().background(FlowTheme.hairline)
                    OptionRow(number: index + 1, label: option) { answer(option) }
                }
                Divider().background(FlowTheme.hairline)
                freeText
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        // The step is the identity, so moving to the next question rebuilds the
        // field rather than carrying the last answer's text into it.
        .id(questions.answers.count)
        .onAppear { typing = true }
    }

    private var header: some View {
        HStack(alignment: .top) {
            // Silent for a single question: "1 of 1" is a progress bar for a
            // journey of one step, and it makes one question look like a form.
            if questions.total > 1 {
                Text("\(questions.step) of \(questions.total)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer(minLength: 8)
            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .plainButton()
            .help(
                questions.total > 1
                    ? "Skip these and let Gizmate decide"
                    : "Skip this and let Gizmate decide"
            )
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var freeText: some View {
        HStack(spacing: 8) {
            TextField("Type your own answer...", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)
                .focused($typing)
                .onSubmit { answer(typed) }
            ChatSendDisc(idle: isBlank(typed)) { answer(typed) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func answer(_ text: String) {
        guard !isBlank(text) else { return }
        typed = ""
        onAnswer(text)
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One tappable answer.
///
/// The whole row is the target, not the label: a 24pt-tall strip of card that
/// looks like a list item and only responds on the words is the kind of miss
/// people blame on themselves.
private struct OptionRow: View {
    let number: Int
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(FlowTheme.recess))
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? FlowTheme.selected : .clear)
        }
        .plainButton()
        .onHover { hovering = $0 }
    }
}
