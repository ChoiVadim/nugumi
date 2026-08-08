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
                transcript
                composer
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
                        if conversation.turns.isEmpty && conversation.pending == nil {
                            emptyState
                        }
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

    /// Says what this box does, which is three things and not obviously any of
    /// them from an empty field.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask something, or describe a gizmo you want.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.inkSecondary)
            Text("Type @ and a gizmo's name to change one, or click it on the right.")
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fragment = ToolMentionCompletion.activeFragment(in: draft) {
                mentionList(for: fragment)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask, or describe a gizmo", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                sendButton
            }
            .padding(10)
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
