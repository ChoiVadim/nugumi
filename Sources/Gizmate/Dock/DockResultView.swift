import AppKit
import SwiftUI

/// What a docked result is showing: what the tool did so far, the line it is
/// on now, its answer or its failure, and every follow-up asked about it.
///
/// Driven from `TranslationPanelController`, on the main thread like it. An
/// answer is rendered to an attributed string once, here, so the view's body
/// never re-parses a long report: the same `NSAttributedString` instance is
/// what lets `MarkdownLabel` reuse its measured height across scroll frames.
final class DockResultModel: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var rendered: NSAttributedString?
        var failure: String?
    }

    let title: String
    /// Settled lines of the agent's trace, in order: each step it ran.
    @Published private(set) var trace: [String] = []
    /// The line breathing right now, nil once the run is over.
    @Published private(set) var working: String?
    @Published private(set) var failure: String?
    @Published private(set) var rendered: NSAttributedString?
    /// Follow-ups, each answered in place under its question.
    @Published private(set) var turns: [Turn] = []
    /// The latest answer shown, which is what the next follow-up builds on.
    private(set) var text = ""
    /// The turn a reply is streaming into, if a follow-up is being answered.
    private var answering: Int?

    /// A generic wait is not part of the trace; a step's purpose is.
    static let thinking = "Thinking"

    init(title: String) {
        self.title = title
    }

    /// A fresh run starts over; a follow-up keeps everything and waits under
    /// its own question.
    func beginLoading(_ line: String) {
        if answering != nil {
            working = Self.thinking
            return
        }
        trace = []
        failure = nil
        rendered = nil
        turns = []
        text = ""
        working = line
    }

    func updateLoading(_ line: String) {
        settleWorking()
        working = line
    }

    func ask(_ question: String) {
        turns.append(Turn(question: question))
        answering = turns.count - 1
    }

    func finish(answer: String) {
        settleWorking()
        working = nil
        text = answer
        let rendered = Self.render(answer)
        if let answering, turns.indices.contains(answering) {
            turns[answering].rendered = rendered
            turns[answering].failure = nil
        } else {
            self.rendered = rendered
        }
    }

    func fail(_ message: String) {
        settleWorking()
        working = nil
        if let answering, turns.indices.contains(answering) {
            turns[answering].failure = message
        } else {
            failure = message
        }
    }

    private func settleWorking() {
        guard let working, working != Self.thinking else { return }
        trace.append(working)
    }

    private static func render(_ markdown: String) -> NSAttributedString {
        TranslationContentView.renderedMarkdownText(
            markdown,
            font: .systemFont(ofSize: 12.5),
            color: NSColor(calibratedWhite: 1, alpha: 0.9)
        )
    }
}

/// A result on an edge, as its own component: the Ask dock's transcript. The
/// first bubble is the gizmo that was asked, the trace under it is what the
/// agent did (each script it ran, by its own one-line purpose), the breathing
/// line is where it is now, and the answer follows in the chat's markdown at
/// the chat's size. Every follow-up typed below is one more exchange.
///
/// No title row and no close button: the dock already has both ways out (the
/// handle and Escape), and a row of chrome above the first line costs every
/// reading of the answer. Copy rides in the top fade the way Ask's new-chat
/// disc does, and only once there is something to copy.
struct DockResultView: View {
    @ObservedObject var model: DockResultModel
    let onCopy: () -> Void
    /// nil when the result cannot take a question, in which case there is no
    /// composer rather than one that swallows what is typed.
    let onFollowUp: ((String) -> Void)?

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private static let withinTurn: CGFloat = 7
    private static let betweenTurns: CGFloat = 22
    private static let bottomAnchor = "dock.result.bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .overlay(alignment: .topTrailing) { copyDisc }
            if onFollowUp != nil {
                composer
            }
        }
        .foregroundStyle(FlowTheme.ink)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.betweenTurns) {
                    exchange
                    ForEach(model.turns) { turn in
                        VStack(alignment: .leading, spacing: Self.withinTurn) {
                            ChatQuestionBubble(text: turn.question)
                            if let failure = turn.failure {
                                ChatProblemText(message: failure)
                            } else if let rendered = turn.rendered {
                                answer(rendered)
                            } else if let working = model.working {
                                ChatThinkingText(text: working)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 4)
                // DESIGN.md §8: thin overlay scroller, never a legacy track.
                .background(ScrollerConfigurator())
            }
            .scrollIndicators(.automatic)
            .mask(AskChatView.topFade)
            .onChange(of: model.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// The run itself: the gizmo, what it did, and what it answered.
    private var exchange: some View {
        VStack(alignment: .leading, spacing: Self.withinTurn) {
            ChatQuestionBubble(text: model.title)
            ForEach(Array(model.trace.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let working = model.working, model.turns.isEmpty {
                ChatThinkingText(text: working)
            }
            if let failure = model.failure {
                ChatProblemText(message: failure)
            }
            if let rendered = model.rendered {
                answer(rendered).padding(.top, 8)
            }
        }
    }

    private func answer(_ rendered: NSAttributedString) -> some View {
        MarkdownLabel(text: rendered)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var copyDisc: some View {
        if !model.text.isEmpty {
            ResetDiscButton(symbol: "doc.on.doc", label: "", accessibilityTitle: "Copy", action: onCopy)
                .help("Copy")
                .padding(.trailing, 6)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Ask a follow-up", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit(send)
            HStack(spacing: 2) {
                Spacer(minLength: 8)
                ChatSendDisc(idle: idle, action: send)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .padding(10)
    }

    /// Nothing to ask about until the first answer has landed, and one
    /// question at a time.
    private var idle: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.text.isEmpty
            || model.working != nil
    }

    private func send() {
        guard !idle, let onFollowUp else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        onFollowUp(question)
    }
}
