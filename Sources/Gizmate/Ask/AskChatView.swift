import AppKit
import SwiftUI

/// Ask as a chat that stays on screen, for a dock rather than a capsule.
///
/// The capsule at the cursor is one question and one answer: it appears, it is
/// answered, it goes away. This is the same conversation with the transcript
/// left standing, which is the only difference that matters — both surfaces
/// drive one `AskConversationStore`, so what you asked from the capsule is
/// above what you type here.
///
/// Laid out against Copilot, Fireflies, Fabric and ClickUp's assistant panels,
/// which agree on two things this did not do. A turn is one group: its question
/// and its answer sit close, and the gap to the *next* turn is what tells you
/// where one exchange ended. And the composer is a card with its controls
/// inside it, not a bare field with buttons loose underneath — the camera and
/// the pencil say what this message will carry, so they belong to the message,
/// not to the panel.
struct AskChatView: View {
    @ObservedObject var conversation: AskConversationStore

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    /// Inside a turn. Its question and its answer are one thought.
    private static let withinTurn: CGFloat = 7
    /// Between turns. Deliberately about three times `withinTurn`: spacing is
    /// what groups and separates, and at one gap for both there was no visible
    /// boundary between one exchange and the next.
    private static let betweenTurns: CGFloat = 22

    /// Anchors the scroll-to-bottom. A constant id rather than the last turn's,
    /// because the thing scrolled to is the end of the transcript, which
    /// outlives whichever message is currently last.
    private static let bottomAnchor = "ask.chat.bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .overlay(alignment: .topTrailing) { newChatButton }
            composer
        }
        .foregroundStyle(FlowTheme.ink)
        .onAppear { composerFocused = true }
    }

    /// Starts over: empties the transcript and, with it, the context the model
    /// is answering against. "New chat" rather than "Clear" because both of
    /// those happen and only one of them is visible — a cleared panel that
    /// still carried twenty turns of history into the next question would be
    /// the worse surprise.
    ///
    /// Floated over the transcript instead of sitting in a header row of its
    /// own. A dock is 360pt wide and this is a once-a-day action; a permanent
    /// strip above the first message costs every reading of the chat to pay for
    /// it. It rides in the top fade, where content is dissolving anyway, and it
    /// is absent until there is something to clear. It also cannot go in the
    /// composer: the camera and the pencil are there to say what *this message*
    /// carries, and this is about the whole conversation.
    @ViewBuilder
    private var newChatButton: some View {
        if !conversation.turns.isEmpty {
            ResetDiscButton(
                symbol: "square.and.pencil",
                label: "",
                accessibilityTitle: "New chat"
            ) {
                conversation.clear()
                composerFocused = true
            }
            .help("New chat")
            .padding(.trailing, 6)
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.betweenTurns) {
                    if conversation.turns.isEmpty && conversation.pending == nil {
                        emptyState
                    }
                    ForEach(Array(conversation.turns.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: Self.withinTurn) {
                            question(turn.question)
                            answer(turn.answer)
                        }
                    }
                    if let pending = conversation.pending {
                        VStack(alignment: .leading, spacing: Self.withinTurn) {
                            question(pending.question)
                            if let failure = pending.failure {
                                problem(failure)
                            } else if pending.answer.isEmpty {
                                waiting(pending)
                            } else {
                                answer(pending.answer)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 4)
                // DESIGN.md §8: thin, overlay, auto-hiding, light knob — a
                // user set to "always show scroll bars" would otherwise get a
                // permanent legacy track down the side of a narrow dock.
                .background(ScrollerConfigurator())
            }
            // Opens where the conversation left off, not at its beginning: a
            // transcript that survives every close is read from the end, and
            // scrolling back down was the price of every reopen. A scroll
            // anchor rather than an `onAppear` jump — the rows are lazy, so
            // the bottom one does not exist yet at the moment `onAppear` runs.
            .defaultScrollAnchor(.bottom)
            // The dock has no scrollbar of its own and the transcript is long,
            // so with indicators off there was nothing at all to say how far
            // back the history went. `.automatic` is macOS's overlay bar: it
            // appears while scrolling and fades out after.
            .scrollIndicators(.automatic)
            .mask(Self.topFade)
            // Both, not just the turn count: an answer streaming in grows the
            // transcript continuously, and following only completed turns would
            // pin the view a screen above the words being written.
            .onChange(of: conversation.turns.count) { _, _ in scroll(proxy) }
            .onChange(of: conversation.pending) { _, _ in scroll(proxy) }
        }
    }

    /// Scrolled text has to stop at the panel's top edge somehow, and padding
    /// is not it: padding inside a `ScrollView` travels with the content, so
    /// the first line ends up sliced in half by the bezel the moment anything
    /// scrolls past. This dissolves it instead. A mask rather than a gradient
    /// laid over the top, because the dock is translucent glass — an opaque
    /// band matching "the background" would be a stripe of the wrong colour
    /// over whatever is behind the panel.
    static var topFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 20)
            Rectangle().fill(.black)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// Names the two controls rather than saying the list is empty. They are
    /// the whole difference between this and any other chat, and an empty
    /// transcript is the one moment there is room to say so.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about what's on your screen.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(FlowTheme.inkSecondary)
            Text("The camera sends a screenshot with each question. "
                + "The pencil pins the screen so you can circle something first.")
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func question(_ text: String) -> some View { ChatQuestionBubble(text: text) }

    private func answer(_ text: String) -> some View { ChatAnswerText(markdown: text) }

    /// Names the wait instead of spinning at it. The two waits are genuinely
    /// different lengths, and saying which one you are in is what buys patience.
    private func waiting(_ pending: AskConversationStore.Pending) -> some View {
        Text(pending.usesScreen ? "Reading your screen…" : "Thinking…")
            .font(.system(size: 12))
            .foregroundStyle(FlowTheme.inkTertiary)
    }

    private func problem(_ message: String) -> some View { ChatProblemText(message: message) }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if conversation.armed != nil { armedNote }
            TextField("Ask Gizmate", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit(send)
            HStack(spacing: 2) {
                cameraToggle
                pencilToggle
                Spacer(minLength: 8)
                sendButton
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

    /// The one piece of state a person cannot see from the panel: a frame is
    /// pinned and the canvas is live on a screen the panel is only a corner of.
    private var armedNote: some View {
        HStack(spacing: 5) {
            Image(systemName: "scribble")
                .font(.system(size: 10))
            Text("Screen pinned. Draw on it, then send.")
                .font(.system(size: 11))
        }
        .foregroundStyle(FlowTheme.inkSecondary)
    }

    private var cameraToggle: some View {
        tool(
            conversation.attachesScreen ? "camera.fill" : "camera",
            on: conversation.attachesScreen,
            help: conversation.attachesScreen
                ? "Sending a screenshot with each question"
                : "Text only"
        ) {
            conversation.attachesScreen.toggle()
        }
    }

    /// Lit while a frame is pinned. Pressing it is what takes the screenshot,
    /// not sending — see `AskConversationStore.toggleDrawing`.
    private var pencilToggle: some View {
        tool(
            "scribble",
            on: conversation.armed != nil,
            help: conversation.armed != nil
                ? "Drawing on the pinned screen. Press again to drop it."
                : "Pin the screen now and draw on it"
        ) {
            Task { await conversation.toggleDrawing() }
        }
    }

    /// One button in two states rather than two buttons that swap places. It
    /// occupies the same spot either way, so stopping a long answer is where
    /// the hand already is.
    private var sendButton: some View {
        let idle = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: { conversation.isRunning ? conversation.cancel() : send() }) {
            Image(systemName: conversation.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        conversation.isRunning || !idle
                            ? FlowTheme.ink
                            : FlowTheme.ink.opacity(0.22)
                    )
                )
        }
        .plainButton()
        .disabled(idle && !conversation.isRunning)
        .help(conversation.isRunning ? "Stop" : "Send")
    }

    private func tool(
        _ symbol: String,
        on: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(on ? FlowTheme.ink : FlowTheme.inkTertiary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? FlowTheme.accentSoft : Color.clear)
                )
        }
        .plainButton()
        .help(help)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        conversation.send(text)
        composerFocused = true
    }
}
