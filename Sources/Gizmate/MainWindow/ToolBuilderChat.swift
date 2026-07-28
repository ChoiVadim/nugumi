import Combine
import GizmateToolAgentCore
import SwiftUI

enum ToolBuilderChatRole: Equatable {
    case assistant
    case user
}

struct ToolBuilderChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ToolBuilderChatRole
    let text: String
}

enum ToolBuilderSubmission: Equatable {
    case buildRequest(String)
    case answeredClarification
}

@MainActor
final class ToolBuilderChatSession: ObservableObject {
    @Published private(set) var messages: [ToolBuilderChatMessage]
    @Published private(set) var activity: [String] = []
    @Published private(set) var isAwaitingAnswer = false
    @Published private(set) var readyMessage: String?
    @Published private(set) var hasError = false

    private let answers: ToolBuilderAnswerBroker
    private let activityLimit: Int
    private var answerGeneration: ToolBuilderAnswerBroker.Generation?

    init(activityLimit: Int = 8, beforeAnswerWaitRegistration:
         @escaping @Sendable () async -> Void = {}) {
        answers = ToolBuilderAnswerBroker(
            beforeWaitRegistration: beforeAnswerWaitRegistration
        )
        self.activityLimit = max(1, activityLimit)
        messages = [
            ToolBuilderChatMessage(
                role: .assistant,
                text: "You can describe the outcome you want. I may ask a few questions, and nothing is saved until you press Save."
            )
        ]
    }

    var currentActivity: String? { activity.last }

    func submit(_ text: String) async -> ToolBuilderSubmission? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        messages.append(.init(role: .user, text: value))
        guard isAwaitingAnswer, let answerGeneration else {
            return .buildRequest(value)
        }
        await answers.answer(value, for: answerGeneration)
        return .answeredClarification
    }

    func ask(_ request: ToolAgentAskUserRequestV1) async throws
        -> ToolAgentAskUserResponseV1 {
        let generation = try await answers.begin()
        if Task.isCancelled {
            await answers.cancel(generation)
            throw CancellationError()
        }
        answerGeneration = generation
        messages.append(.init(role: .assistant, text: request.question))
        isAwaitingAnswer = true
        defer {
            if answerGeneration == generation {
                answerGeneration = nil
                isAwaitingAnswer = false
            }
        }
        let answer = try await answers.wait(for: generation)
        return try ToolAgentAskUserResponseV1(answer: answer)
    }

    func recordActivity(_ status: String) {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, activity.last != value else { return }
        activity.append(value)
        if activity.count > activityLimit {
            activity.removeFirst(activity.count - activityLimit)
        }
    }

    /// - Parameter note: what running the candidate actually proved, when that
    ///   is a question worth answering. Saying "ready" about a tool Gizmate only
    ///   compiled would be the same overclaim the old validator made by
    ///   refusing to build anything it could not run.
    func candidateReady(_ name: String, note: String? = nil) {
        hasError = false
        readyMessage = [
            "\(name) is ready.",
            note,
            "Review it, ask for a change, or save the tool.",
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    func markCandidateStale() {
        hasError = false
        readyMessage = nil
    }

    func appendError(_ message: String) {
        hasError = true
        messages.append(.init(role: .assistant, text: message))
        recordActivity("Stopped before a verified tool was ready.")
    }

    func cancel() async {
        isAwaitingAnswer = false
        guard let answerGeneration else { return }
        self.answerGeneration = nil
        await answers.cancel(answerGeneration)
    }
}

actor ToolBuilderAnswerBroker {
    struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private enum State {
        case idle
        case accepting(Generation, buffered: String?)
        case waiting(Generation, CheckedContinuation<String, Error>)
        case cancelledBeforeRegistration(Generation)
    }

    private let beforeWaitRegistration: @Sendable () async -> Void
    private let onWaitRegistered: @Sendable () -> Void
    private var state: State = .idle
    private var nextGeneration: UInt64 = 0

    init(beforeWaitRegistration: @escaping @Sendable () async -> Void,
         onWaitRegistered: @escaping @Sendable () -> Void = {}) {
        self.beforeWaitRegistration = beforeWaitRegistration
        self.onWaitRegistered = onWaitRegistered
    }

    func begin() throws -> Generation {
        guard case .idle = state else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        nextGeneration &+= 1
        let generation = Generation(value: nextGeneration)
        state = .accepting(generation, buffered: nil)
        return generation
    }

    func wait(for generation: Generation) async throws -> String {
        await beforeWaitRegistration()
        switch state {
        case .cancelledBeforeRegistration(let active) where active == generation:
            state = .idle
            throw CancellationError()
        case .accepting(let active, let buffered) where active == generation:
            if let buffered {
                state = .idle
                return buffered
            }
            return try await withCheckedThrowingContinuation {
                state = .waiting(generation, $0)
                onWaitRegistered()
            }
        default:
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
    }

    func answer(_ value: String, for generation: Generation) {
        switch state {
        case .accepting(let active, buffered: nil) where active == generation:
            state = .accepting(generation, buffered: value)
        case .waiting(let active, let continuation) where active == generation:
            state = .idle
            continuation.resume(returning: value)
        default:
            break
        }
    }

    func cancel(_ generation: Generation) {
        switch state {
        case .accepting(let active, _) where active == generation:
            state = .cancelledBeforeRegistration(generation)
        case .waiting(let active, let continuation) where active == generation:
            state = .idle
            continuation.resume(throwing: CancellationError())
        default:
            break
        }
    }
}

struct ToolBuilderChat: View {
    @ObservedObject var session: ToolBuilderChatSession
    @Binding var composer: String
    let isBuilding: Bool
    let preview: AnyView?
    let onSend: () -> Void
    let onSave: () -> Void

    @State private var activityExpanded = false
    @FocusState private var composerFocused: Bool
    private let bottomAnchor = "tool-builder-chat-bottom"

    private var canSend: Bool {
        !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isBuilding || session.isAwaitingAnswer)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(session.messages) { message in
                            messageBubble(message)
                        }
                        activityView
                        readyView
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                }
                .onAppear {
                    composerFocused = true
                    scrollToBottom(proxy)
                }
                .onChange(of: session.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: session.activity.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: session.readyMessage) { _, _ in scrollToBottom(proxy) }
            }
            Divider().background(FlowTheme.hairline)
            composerView
        }
    }

    private func messageBubble(_ message: ToolBuilderChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    // Your turn sits one step above the assistant's, so the
                    // conversation reads as two heights rather than two colours.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            message.role == .user
                                ? FlowTheme.raised
                                : FlowTheme.subtleFill
                        )
                )
            if message.role == .assistant { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity)
    }

    /// While a question is on screen the build is stopped on the user, not
    /// working. Leaving the spinner and the last technical status up says the
    /// opposite, and the last status is whatever internal step happened to run
    /// before the question — so it reads as a hang and people wait it out.
    @ViewBuilder
    private var activityView: some View {
        if let current = session.isAwaitingAnswer ? "Waiting for your answer" : session.currentActivity {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if session.isAwaitingAnswer {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(FlowTheme.accent)
                    } else if isBuilding {
                        ProgressView().controlSize(.small)
                    } else if session.hasError {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.62))
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text(current)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    Spacer()
                    Button("Activity") { activityExpanded.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(FlowTheme.accent)
                        .accessibilityLabel(activityExpanded ? "Hide activity" : "Show activity")
                }
                if activityExpanded {
                    ForEach(Array(session.activity.enumerated()), id: \.offset) {
                        _, item in
                        Text(item)
                            .font(.system(size: 10.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                    }
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    /// Built on `TextField(axis: .vertical)` rather than `TextEditor`, for the
    /// same reason `ToolEditorPanel.codeEditor` is: presenting a SwiftUI
    /// `TextEditor` inside this panel and then dismissing the panel leaves the
    /// whole main window ignoring clicks. Every click still reaches the window
    /// and AppKit stays healthy — SwiftUI just swallows them, with the sidebar
    /// and every control dead until the window is closed and reopened. A
    /// vertical `TextField` is an NSTextField underneath, like every other
    /// input in this window, and does not do that.
    private var composerView: some View {
        TextField(
            session.isAwaitingAnswer
                ? "Type your answer…"
                : "Describe the tool or request a change…",
            text: $composer,
            axis: .vertical
        )
            .textFieldStyle(.plain)
            .lineLimit(3, reservesSpace: true)
            .onKeyPress(.return, phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    return .ignored
                }
                guard canSend else { return .handled }
                onSend()
                return .handled
            }
            .font(.system(size: 12.5))
            .foregroundStyle(FlowTheme.ink)
            .padding(.leading, 7)
            .padding(.vertical, 6)
            .padding(.trailing, 48)
            .frame(minHeight: 76, alignment: .topLeading)
            .focused($composerFocused)
            .accessibilityLabel("Tool request")
            .overlay(alignment: .bottomTrailing) {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(FlowTheme.raisedStrong)
                                .overlay(Circle().strokeBorder(FlowTheme.edge, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .padding(8)
                .accessibilityLabel(
                    session.isAwaitingAnswer ? "Send answer" : "Send tool request"
                )
            }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var readyView: some View {
        if let readyMessage = session.readyMessage,
           let preview,
           !isBuilding {
            HStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(readyMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(FlowTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    preview
                    Button(action: onSave) {
                        Text("Save tool")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(FlowTheme.raisedStrong)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(FlowTheme.edge, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save tool")
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(FlowTheme.subtleFill)
                )
                Spacer(minLength: 80)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }
}
