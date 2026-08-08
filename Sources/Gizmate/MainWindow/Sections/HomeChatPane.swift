import AppKit
import SwiftUI

/// Home's chat: one place to talk, to build a gizmo, or to change one.
///
/// It replaces a sheet you had to open and close for every single change. The
/// gizmo editor is the same panel it always was — it holds the whole
/// build-and-test loop and it works — it just runs inline now
/// (`ToolEditorPanel.Chrome.inline`), and what it is editing is this view's
/// state rather than a modal's identity. Changing subject is therefore a
/// `.id()` away, not an open-and-close.
///
/// Which of the three a message means is `ToolChatRouter`'s call, and the order
/// matters: a mention is answered here, without a model, because `@Prices`
/// names a tool outright and asking a classifier to confirm it would add
/// latency to the one case that has none.
struct HomeChatPane: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    @ObservedObject var tools: ToolsStore
    /// Set from outside when a tool is clicked in the rail, so the rail does
    /// not need to know what the pane does with it.
    @Binding var subject: Subject

    /// What the pane is currently about.
    enum Subject: Equatable {
        /// Nothing. Messages are routed.
        case none
        /// A gizmo being built from scratch.
        case newTool
        /// One that exists.
        case tool(UUID)
    }

    @State private var draft = ""
    @State private var routing = false
    @FocusState private var composerFocused: Bool

    private static let bottomAnchor = "home.chat.bottom"

    private var conversation: ToolChatConversation? { bridge.host?.homeChat }

    var body: some View {
        VStack(spacing: 0) {
            switch subject {
            case .none:
                if isEmpty {
                    // Greeting and composer together, centred, the way WRITER
                    // and Otter open a chat. A one-line invitation in the top
                    // corner and the field pinned to the bottom of an empty
                    // column are two halves of one thing separated by the whole
                    // pane, and neither reads as the place to start.
                    VStack(spacing: 18) {
                        Spacer(minLength: 0)
                        opening
                        composer
                        starters
                        Spacer(minLength: 0)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                } else {
                    transcript
                    composer
                }
            case .newTool:
                editor(toolID: nil)
            case .tool(let id):
                editor(toolID: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The panel, keyed by what it is editing.
    ///
    /// `.id` is the whole switching mechanism: a different subject is a
    /// different panel, so its draft, its script and its build state start
    /// clean rather than being reset field by field. The cost is that the
    /// conversation inside it is per gizmo, which is the right answer anyway —
    /// a conversation about one tool is about that tool.
    private func editor(toolID: UUID?) -> some View {
        ToolEditorPanel(
            toolID: toolID,
            chrome: .inline,
            onClose: { subject = .none }
        )
        .id(toolID)
    }

    // MARK: - Talking

    @ViewBuilder
    private var transcript: some View {
        if let conversation {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.turns) { turn in
                            turnView(turn)
                        }
                        if let pending = conversation.pending {
                            turnView(pending, streaming: true)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.never)
                .onChange(of: conversation.turns.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func turnView(_ turn: ToolChatConversation.Turn, streaming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ChatQuestionBubble(text: turn.question)
            if let failure = turn.failure {
                ChatProblemText(message: failure)
            } else if turn.answer.isEmpty {
                Text(routing ? "Reading that…" : "Thinking…")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkTertiary)
            } else {
                ChatAnswerText(markdown: turn.answer)
            }
        }
    }

    private var isEmpty: Bool {
        guard let conversation else { return true }
        return conversation.turns.isEmpty && conversation.pending == nil
    }

    /// The invitation, sized like a title because on an empty screen it is one.
    private var opening: some View {
        VStack(spacing: 6) {
            Text("What do you want to do?")
                .font(FlowTheme.serif(26))
                .foregroundStyle(FlowTheme.ink)
            Text("Ask a question, describe a gizmo to build, or type @ to change one.")
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Three things this box can do, as things you can press.
    ///
    /// An empty field asks a person to guess what it accepts, and this one
    /// accepts three different kinds of message. The corpus is blunt about
    /// empty states: they are the case where more is unambiguously better,
    /// because context is what makes them usable.
    private var starters: some View {
        HStack(spacing: 8) {
            starter("What can Gizmate do?") { draft = "What can Gizmate do?"; send() }
            starter("Build me a gizmo") { draft = "Build me a gizmo that "; composerFocused = true }
            // Not the gizmo's own name. A long one wrapped its chip to two
            // lines, which made one of three neighbours taller than the others
            // for a reason that was about that gizmo rather than about the
            // action — and the whole point of a row of chips is that they read
            // as one set of choices.
            if !tools.usableTools().isEmpty {
                starter("Change a gizmo") { draft = "@"; composerFocused = true }
            }
        }
    }

    private func starter(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 30)
                .padding(.horizontal, 13)
                .background(
                    Capsule().fill(FlowTheme.subtleFill)
                )
                .overlay(Capsule().stroke(FlowTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fragment = ToolMentionCompletion.activeFragment(in: draft) {
                mentionList(for: fragment)
            }
            // Text at the top and the send button on its own row underneath,
            // which is the shape ChatGPT's own composer uses. A tall box whose
            // one line of text is vertically centred reads as misaligned no
            // matter where the centre is, because the box is sized for growth
            // the text has not done yet — so the text starts where it will
            // stay, and the box grows downward under it.
            VStack(alignment: .leading, spacing: 8) {
                TextField("Ask, or describe a gizmo", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer(minLength: 0)
                    sendButton
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .padding(20)
    }

    /// The names an `@` is currently offering, above the field it completes.
    @ViewBuilder
    private func mentionList(for fragment: String) -> some View {
        let matches = ToolMentionCompletion.matches(for: fragment, among: tools.usableTools())
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.id) { tool in
                    Button {
                        draft = ToolMentionCompletion.completing(draft, with: tool)
                        composerFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tool.resolvedSymbolName)
                                .font(.system(size: 11))
                                .foregroundStyle(FlowTheme.inkSecondary)
                                .frame(width: 16)
                            Text(tool.name)
                                .font(.system(size: 12))
                                .foregroundStyle(FlowTheme.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            Divider().background(FlowTheme.hairline)
        }
    }

    private var sendButton: some View {
        let idle = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(idle ? FlowTheme.ink.opacity(0.22) : FlowTheme.ink))
        }
        .buttonStyle(.plain)
        .disabled(idle || routing)
        .help("Send")
    }

    // MARK: - Routing

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !routing else { return }
        let usable = tools.usableTools()

        // A mention is certain, so it never waits on the network.
        if let mentioned = ToolChatRouter.mentioned(in: text, among: usable) {
            draft = ""
            subject = .tool(mentioned)
            return
        }

        draft = ""
        routing = true
        Task { @MainActor in
            let intent = await bridge.host?.routeHomeChat(text, tools: usable) ?? .talk
            routing = false
            switch intent {
            case .talk:
                conversation?.send(text)
            case .build:
                subject = .newTool
            case .edit(let id):
                subject = .tool(id)
            }
        }
    }
}
