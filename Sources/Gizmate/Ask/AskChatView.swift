import AppKit
import SwiftUI

/// Ask as a chat that stays on screen, for a dock rather than a capsule.
///
/// The capsule at the cursor is one question and one answer: it appears, it is
/// answered, it goes away. This is the same conversation with the transcript
/// left standing, which is the only difference that matters — both surfaces
/// drive one `AskConversationStore`, so what you asked from the capsule is
/// above what you type here.
struct AskChatView: View {
    @ObservedObject var conversation: AskConversationStore

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    /// Anchors the scroll-to-bottom. A constant id rather than the last turn's,
    /// because the thing being scrolled to is the end of the transcript, which
    /// outlives whichever message is currently last.
    private static let bottomAnchor = "ask.chat.bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider().background(FlowTheme.hairline)
            composer
        }
        .foregroundStyle(FlowTheme.ink)
        .onAppear { composerFocused = true }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.turns.isEmpty && conversation.pending == nil {
                        emptyState
                    }
                    ForEach(Array(conversation.turns.enumerated()), id: \.offset) { _, turn in
                        question(turn.question)
                        answer(turn.answer)
                    }
                    if let pending = conversation.pending {
                        question(pending.question)
                        if let failure = pending.failure {
                            problem(failure)
                        } else {
                            answer(pending.answer, waiting: pending.answer.isEmpty)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            // Both, not just the turn count: an answer streaming in grows the
            // transcript continuously, and following only completed turns would
            // pin the view a screen above the words being written.
            .onChange(of: conversation.turns.count) { _, _ in scroll(proxy) }
            .onChange(of: conversation.pending) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    private var emptyState: some View {
        Text("Ask about what's on your screen.")
            .font(.system(size: 12))
            .foregroundStyle(FlowTheme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
    }

    private func question(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(FlowTheme.ink)
            .textSelection(.enabled)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Markdown through `TranslationContentView.renderedMarkdownText`, the same
    /// renderer the floating answer panel uses, rather than a second one that
    /// would drift from it — DESIGN.md §12. The model is told markdown is
    /// welcome, so tables and lists have to survive here too.
    private func answer(_ text: String, waiting: Bool = false) -> some View {
        Group {
            if waiting {
                Text("Looking...")
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            } else {
                Text(AttributedString(TranslationContentView.renderedMarkdownText(
                    text,
                    font: .systemFont(ofSize: 12.5),
                    color: NSColor(calibratedWhite: 1, alpha: 0.92)
                )))
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func problem(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask Gizmate", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit(send)
            HStack(spacing: 6) {
                cameraToggle
                pencilToggle
                Spacer(minLength: 0)
                if conversation.isRunning {
                    tool("stop.circle", on: false, help: "Stop") { conversation.cancel() }
                } else {
                    tool("arrow.up.circle.fill", on: false, help: "Send", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
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
            "pencil.tip",
            on: conversation.armed != nil,
            help: conversation.armed != nil
                ? "Drawing on the pinned screen. Press again to drop it."
                : "Pin the screen now and draw on it"
        ) {
            Task { await conversation.toggleDrawing() }
        }
    }

    private func tool(
        _ symbol: String,
        on: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(on ? FlowTheme.ink : FlowTheme.inkTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? FlowTheme.accentSoft : Color.clear)
                )
        }
        .buttonStyle(.plain)
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
