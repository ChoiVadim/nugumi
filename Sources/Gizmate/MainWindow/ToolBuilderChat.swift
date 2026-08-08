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

/// What is still missing before saving would be an honest thing to offer.
///
/// Gizmate grades its own validation, and two of the three grades do not prove
/// the tool produces the right answer — only that it compiles, or that it exits
/// cleanly. For those the last check available is the person who asked for the
/// tool running it once, so the chat asks for that instead of putting Save up
/// as if the tool were proven.
enum ToolBuilderTrial: Equatable {
    /// Gizmate ran it and the output matched, or the kind has nothing to run.
    case notNeeded
    case untried
    case passed
    case failed
}

@MainActor
final class ToolBuilderChatSession: ObservableObject {
    @Published private(set) var messages: [ToolBuilderChatMessage]
    @Published private(set) var activity: [String] = []
    @Published private(set) var isAwaitingAnswer = false
    @Published private(set) var readyMessage: String?
    @Published private(set) var hasError = false
    @Published private(set) var trial: ToolBuilderTrial = .notNeeded
    /// The secret a candidate declared that the user has not stored. Non-nil
    /// means the build is parked in front of a key field.
    @Published private(set) var pendingSecret: String?

    private let answers: ToolBuilderAnswerBroker
    private let activityLimit: Int
    private var answerGeneration: ToolBuilderAnswerBroker.Generation?
    private var secretContinuation: CheckedContinuation<Bool, Never>?

    /// The line this opens with, or `nil` to open with nothing.
    ///
    /// A panel that exists only to build something has to say so the moment it
    /// appears. Home's chat is not that: it opens on its own invitation, and a
    /// second greeting sitting in the transcript from launch would mean the
    /// screen is never empty and the invitation is never shown.
    static let defaultGreeting = """
        Hey! 👋 Tell me what you want to happen, in your own words. \
        Something like "open Terminal and run my deploy command".

        I'll ask if anything's unclear, build it, and you can try it \
        right here. Nothing is saved until you press Save.
        """

    init(
        activityLimit: Int = 8,
        greeting: String? = ToolBuilderChatSession.defaultGreeting,
        beforeAnswerWaitRegistration: @escaping @Sendable () async -> Void = {}
    ) {
        answers = ToolBuilderAnswerBroker(
            beforeWaitRegistration: beforeAnswerWaitRegistration
        )
        self.activityLimit = max(1, activityLimit)
        messages = greeting.map { [ToolBuilderChatMessage(role: .assistant, text: $0)] } ?? []
    }

    var currentActivity: String? { activity.last }

    /// Swaps the opening line once an existing tool has loaded. The greeting is
    /// built in `init`, before the panel knows whether this is a new tool or one
    /// being edited — and "tell me what you want to happen" is a strange thing
    /// to hear about a tool that already works.
    func greetForEditing(_ name: String) {
        guard let first = messages.first, first.role == .assistant else { return }
        messages[0] = .init(
            role: .assistant,
            text: """
            Hey! 👋 This is \(name.isEmpty ? "your gizmo" : name). Tell me what \
            to change and I'll rebuild it.

            You can try it here first if you want to see what it does now. \
            Nothing changes until you press Save.
            """
        )
    }

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

    /// Parks the build in front of a key field and waits.
    ///
    /// Not an `ask_user` clarification: those are capped at three and are only
    /// allowed before the first candidate is written, and a missing credential
    /// is usually discovered exactly when the code that reads it gets written.
    /// It also asks for the wrong thing — the user is holding a value, and being
    /// asked to name it first is a step that does nothing.
    ///
    /// - Returns: whether the key is now on disk. `false` is a real answer: the
    ///   validation run then fails on the missing key, which is the truth about
    ///   a tool that cannot authenticate.
    func requestSecret(_ name: String) async -> Bool {
        // Never strand an earlier waiter: a candidate may declare two keys.
        resolveSecret(false)
        messages.append(.init(
            role: .assistant,
            text: "This gizmo needs \(name). Paste it below — it stays on your "
                + "Mac, and only the name is ever sent to the model."
        ))
        pendingSecret = name
        return await withCheckedContinuation { secretContinuation = $0 }
    }

    /// - Parameter stored: whether the value reached disk. Skipping is `false`.
    func resolveSecret(_ stored: Bool) {
        guard let continuation = secretContinuation else { return }
        secretContinuation = nil
        pendingSecret = nil
        continuation.resume(returning: stored)
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
    /// - Parameter trial: `.untried` when that note is an admission rather than
    ///   a result, which turns the next step from Save into one real run.
    func candidateReady(
        _ name: String,
        note: String? = nil,
        trial: ToolBuilderTrial = .notNeeded
    ) {
        hasError = false
        self.trial = trial
        readyMessage = [
            "\(name) is ready.",
            note,
            trial == .untried
                ? "Run it once and tell me what happened — or save it as is."
                : "Review it, ask for a change, or save the gizmo.",
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    /// The user took the run. Finishing cleanly still isn't proof the answer is
    /// the one they wanted — only they can say that — so passing asks rather
    /// than declares.
    func trialFinished(passed: Bool, report: String? = nil) {
        trial = passed ? .passed : .failed
        hasError = !passed
        if passed {
            readyMessage = "It ran and finished cleanly. If the result is what "
                + "you wanted, save it — otherwise tell me what's off."
            return
        }
        readyMessage = "That run failed. I can fix it from the error, or tell "
            + "me what you saw."
        // The full report lives on the script page; the tail is what says which
        // failure this was.
        if let report, !report.isEmpty {
            messages.append(.init(role: .assistant, text: String(report.suffix(600))))
        }
    }

    func markCandidateStale() {
        hasError = false
        readyMessage = nil
        trial = .notNeeded
    }

    func appendError(_ message: String) {
        hasError = true
        messages.append(.init(role: .assistant, text: message))
        recordActivity("Stopped before a verified gizmo was ready.")
    }

    func cancel() async {
        isAwaitingAnswer = false
        // A build torn down while a key row is up would otherwise leave the
        // validation handler suspended on a continuation nobody will resume.
        resolveSecret(false)
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
    /// Cancels the build or the run in flight. Same thing Escape does.
    let onStop: () -> Void
    let onSave: () -> Void
    /// Runs the candidate for real, the same button the script page has.
    let onTry: () -> Void
    /// Hands the failed run's diagnostics back to the agent.
    let onFix: () -> Void

    @State private var activityExpanded = false
    @State private var pulse = false
    /// Set when the user opens the key row themselves, rather than the build
    /// asking for a specific name.
    @State private var addingKey = false
    @State private var keyName = ""
    @State private var keyValue = ""
    @State private var keyProblem: String?
    @FocusState private var composerFocused: Bool
    @FocusState private var keyFocused: Bool
    private let bottomAnchor = "tool-builder-chat-bottom"

    private var canSend: Bool {
        !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isBuilding || session.isAwaitingAnswer)
    }

    /// Exactly when the thinking line is up: work is in flight and nothing is
    /// waiting on the user. While a question is on screen the build is stopped on
    /// them, and the button that belongs there is Send.
    private var showsStop: Bool { isBuilding && !session.isAwaitingAnswer }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(session.messages) { message in
                            messageBubble(message)
                        }
                        thinkingLine
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
            keyArea
            composerView
        }
    }

    // MARK: - Keys

    /// A place to put an API key without leaving the build.
    ///
    /// The secrets picker in Details is not reachable from here — a new tool has
    /// no Details tab, because there is no tool yet — and the one moment a user
    /// needs to store a key is the moment the thing being built asks for one.
    /// Before this row, the only way through was to abandon the build.
    @ViewBuilder
    private var keyArea: some View {
        if let requested = session.pendingSecret {
            keyRow(name: requested, fixed: true)
        } else if addingKey {
            keyRow(name: keyName, fixed: false)
        } else if session.isAwaitingAnswer {
            HStack {
                Button {
                    addingKey = true
                    keyName = ""
                    keyValue = ""
                    keyProblem = nil
                    keyFocused = true
                } label: {
                    Label("Save an API key", systemImage: "key.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    private func keyRow(name: String, fixed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkTertiary)

                if fixed {
                    Text(name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(FlowTheme.ink)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(FlowTheme.raised)
                        )
                } else {
                    TextField("OPENAI_API_KEY", text: $keyName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(FlowTheme.ink)
                        .frame(width: 170)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(FlowTheme.subtleFill)
                        )
                }

                // SecureField: the panel this sits in is one people screen-share
                // while building a tool with someone watching.
                SecureField("Paste the key", text: $keyValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FlowTheme.ink)
                    .focused($keyFocused)
                    .onSubmit { saveKey(named: name, fixed: fixed) }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(FlowTheme.subtleFill)
                    )

                SecondaryButton(title: "Save") { saveKey(named: name, fixed: fixed) }
                SecondaryButton(title: fixed ? "Skip" : "Cancel") {
                    keyValue = ""
                    keyProblem = nil
                    if fixed {
                        session.resolveSecret(false)
                    } else {
                        addingKey = false
                    }
                }
            }

            Text(keyProblem
                ?? "Stored on this Mac as a file only you can read. The model is "
                    + "told the name, never the key.")
                .font(.system(size: 11))
                .foregroundStyle(keyProblem == nil
                    ? FlowTheme.inkTertiary
                    : Color(red: 0.92, green: 0.45, blue: 0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTheme.subtleFill.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear { keyFocused = true }
    }

    /// - Parameter fixed: whether the build asked for this exact name. When it
    ///   did, the answer goes back to the waiting validation run; when the user
    ///   opened the row themselves, it goes back as a chat reply, because what
    ///   is waiting then is a question the agent asked.
    private func saveKey(named name: String, fixed: Bool) {
        let target = (fixed ? name : keyName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ToolSecrets.isValidName(target) else {
            keyProblem = "“\(target)” isn't a usable name. Uppercase letters, "
                + "digits and underscores, starting with a letter."
            return
        }
        guard ToolSecrets.set(keyValue, for: target) else {
            keyProblem = "That value is empty, or the key couldn't be written to disk."
            return
        }
        keyValue = ""
        keyProblem = nil
        if fixed {
            session.resolveSecret(true)
            return
        }
        addingKey = false
        // Reuses the normal send path, so the answer appears in the transcript
        // like any other and unblocks the question the agent is waiting on.
        composer = "Saved it as \(target)."
        onSend()
    }

    /// Only your turn is a bubble. Gizmate's sits on the panel itself, because a
    /// reply here is often several sentences and a slab that wide reads as a
    /// dialog box rather than as someone talking back.
    @ViewBuilder
    private func messageBubble(_ message: ToolBuilderChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(FlowTheme.raised)
                    )
            }
            .frame(maxWidth: .infinity)
        } else {
            assistantTurn {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Every one of Gizmate's turns — a reply, the status while it works, the
    /// finished tool — hangs off the same mark at the same left edge. Putting
    /// the avatar only on messages would step the other two out of the column.
    private func assistantTurn<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ChatAssistantTurn(content: content)
    }

    /// The work in progress takes the slot the answer will land in, as one line
    /// of text, so the reply redraws over it instead of appearing underneath a
    /// status card that then has to be dismissed. Click it for the steps so far.
    ///
    /// Nothing shows while a question is on screen: there the build is stopped
    /// on the user, not working, and the question is already in the transcript.
    /// A spinner over the last internal status would read as a hang and people
    /// wait it out instead of answering.
    @ViewBuilder
    private var thinkingLine: some View {
        if isBuilding, !session.isAwaitingAnswer {
            assistantTurn {
            VStack(alignment: .leading, spacing: 5) {
                Button { activityExpanded.toggle() } label: {
                    ChatThinkingText(text: session.currentActivity ?? "Thinking")
                }
                .buttonStyle(.plain)
                .help(activityExpanded ? "Hide the steps so far" : "Show the steps so far")
                if activityExpanded {
                    ForEach(Array(session.activity.dropLast().enumerated()), id: \.offset) {
                        _, item in
                        Text(item)
                            .font(.system(size: 10.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                    }
                }
            }
            .onAppear { pulse = true }
            .onDisappear { pulse = false }
            }
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
                : "Describe the gizmo or request a change…",
            text: $composer,
            axis: .vertical
        )
            .textFieldStyle(.plain)
            .lineLimit(3, reservesSpace: true)
            .onKeyPress(.return, phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    // Letting AppKit have it does not insert a line: the field
                    // editor binds Shift+Return to `insertNewline:`, which ends
                    // editing in an NSTextField. Only Option+Return maps to the
                    // line-break command, so send Shift+Return there too.
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                        return .ignored
                    }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                guard canSend else { return .handled }
                onSend()
                return .handled
            }
            .font(.system(size: 12.5))
            .foregroundStyle(FlowTheme.ink)
            .padding(.leading, 14)
            .padding(.vertical, 12)
            .padding(.trailing, 52)
            .frame(minHeight: 76, alignment: .topLeading)
            .focused($composerFocused)
            .accessibilityLabel("Gizmo request")
            // One button, two jobs: while Gizmate works there is nothing to send
            // and the only thing anyone wants from that corner is a way out, so
            // Send becomes Stop rather than sitting there greyed out.
            .overlay(alignment: .bottomTrailing) {
                Button(action: showsStop ? onStop : onSend) {
                    Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: showsStop ? 10 : 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(FlowTheme.raisedStrong)
                                .overlay(Circle().strokeBorder(FlowTheme.edge, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!showsStop && !canSend)
                .opacity(showsStop || canSend ? 1 : 0.4)
                .padding(8)
                .help(showsStop ? "Stop (Esc)" : "")
                .accessibilityLabel(
                    showsStop
                        ? "Stop"
                        : (session.isAwaitingAnswer ? "Send answer" : "Send gizmo request")
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
            assistantTurn {
                VStack(alignment: .leading, spacing: 12) {
                    Text(readyMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(FlowTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    preview
                    readyActions
                }
            }
        }
    }

    /// Save is the only button when Gizmate proved the tool itself. When it
    /// could not, the run comes first and Save stays reachable but second —
    /// nobody should be blocked from keeping a tool Gizmate merely couldn't test.
    @ViewBuilder
    private var readyActions: some View {
        HStack(spacing: 8) {
            switch session.trial {
            case .untried:
                primaryButton("Try it", action: onTry)
                SecondaryButton(title: "Save anyway", action: onSave)
            case .failed:
                primaryButton("Fix it", action: onFix)
                SecondaryButton(title: "Try again", action: onTry)
            case .notNeeded, .passed:
                primaryButton("Save gizmo", action: onSave)
            }
        }
    }

    /// Deliberately `SecondaryButton`'s metrics, differing only in fill and
    /// weight: the pair sits on one row, so anything else — a taller box, a
    /// stroke the other one lacks — reads as two unrelated controls rather than
    /// as a default and its alternative.
    private func primaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(FlowTheme.raisedStrong)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }
}
