import AppKit
import Carbon.HIToolbox
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
    @ObservedObject var tools: ToolsStore
    /// Held, not fetched.
    ///
    /// This was `bridge.host?.homeChat`, read through a computed property — and
    /// reading an `ObservableObject` that way subscribes to nothing. Every
    /// `@Published` change fired `objectWillChange` into a room with nobody in
    /// it, so an answer only appeared when something unrelated forced a redraw:
    /// a click, or leaving the section and coming back. The state was right the
    /// whole time; nothing was telling SwiftUI so.
    @ObservedObject var conversation: ToolChatConversation
    /// The build, in the same transcript. Home used to swap the whole pane for
    /// the gizmo editor, which is what "being thrown into a window" was: one
    /// chat that sometimes stopped being a chat.
    @ObservedObject var builder: GizmoBuilder

    @State private var draft = ""
    /// Pictures waiting to go with the next message.
    @State private var attachments: [ChatImage] = []
    @State private var isDropTarget = false
    /// The composer's key watcher, alive only while the composer has the
    /// keyboard. Two keys reach it: ⌘V, and ⇧Return.
    @State private var composerKeys: Any?
    @FocusState private var composerFocused: Bool

    private static let bottomAnchor = "home.chat.bottom"
    /// How wide a conversation is allowed to get.
    ///
    /// A line of prose running the full width of a maximised window is a line
    /// nobody finishes: the eye loses the start of the next one on the way
    /// back. Every chat caps this, and the cap is also what makes the empty
    /// state and the transcript the same object growing rather than two
    /// layouts — they share the number.
    /// Measured for reading, not for the window. At 640 a line ran past a
    /// hundred characters, which is roughly twice what the eye tracks back
    /// from comfortably; this is about seventy-five at 13pt.
    static let column: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    opening
                    composer
                    starters
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    transcript
                    composer
                }
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole conversation takes a dropped picture, not just the box at
        // the bottom of it. Someone dragging a screenshot in aims at the chat,
        // and a target the size of one control is a target you can miss; the
        // composer is where the highlight shows up, so the aim is still told
        // where the picture lands.
        //
        // `URL` is a system type, so this needs no exported UTI in an
        // Info.plist the `swift run` build does not have — the trap that made
        // the Edges figure carry its own drag (DESIGN.md, `EdgesDiagram`).
        .dropDestination(for: URL.self) { urls, _ in
            let pictures = urls.compactMap(ChatImage.init(contentsOf:))
            guard !pictures.isEmpty else { return false }
            attachments.append(contentsOf: pictures)
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    // MARK: - Talking

    private var transcript: some View {
        ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.turns) { turn in
                            finishedTurn(turn)
                        }
                        if let pending = conversation.pending {
                            pendingTurn(pending)
                        }
                        buildTranscript
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
                // The streaming answer grows the transcript continuously, and
                // following only finished turns pins the view a screen above
                // the words being written.
                .onChange(of: conversation.pending) { _, _ in
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
        }
    }

    /// A turn that is over. Two functions rather than one with flags, because
    /// the one with flags read pane state alongside the turn's own — and pane
    /// state belongs to no single row, so every finished exchange in the
    /// transcript turned back into "Thinking" the moment a new message was
    /// sent. State that describes one row cannot be reachable from the code
    /// drawing the others.
    private func finishedTurn(_ turn: ToolChatConversation.Turn) -> some View {
        exchange(question: turn.question, images: turn.images) {
            if let failure = turn.failure {
                ChatProblemText(message: failure)
            } else {
                ChatAnswerText(markdown: turn.answer)
            }
        }
    }

    /// The turn being answered right now.
    private func pendingTurn(_ turn: ToolChatConversation.Turn) -> some View {
        exchange(question: turn.question, images: turn.images) {
            if let failure = turn.failure {
                ChatProblemText(message: failure)
            } else if turn.answer.isEmpty || ToolChatRouter.mayBeDirective(turn.answer) {
                // A reply that turns out to be a directive is machinery, and
                // machinery must never be seen typing itself out. Six
                // characters settle which this is, so an ordinary answer is
                // held back for a chunk or two and never for a whole reply.
                ChatThinkingText(text: "Thinking")
            } else {
                ChatAnswerText(markdown: turn.answer)
            }
        }
    }

    /// One question and whatever stands in for its answer. No mark beside the
    /// answer here, unlike the builder's chat: the question is already a pill
    /// pushed to the right edge, so the two sides read apart on their own and a
    /// repeated logo down the left is decoration paying no rent.
    private func exchange<Answer: View>(
        question: String,
        images: [ChatImage] = [],
        @ViewBuilder answer: @escaping () -> Answer
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ChatQuestionBubble(text: question, images: images)
            answer()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isEmpty: Bool {
        conversation.turns.isEmpty
            && conversation.pending == nil
            && builder.chat.messages.isEmpty
    }

    /// The build, rendered as the same kind of exchange as everything else.
    ///
    /// It is one transcript on purpose. A build used to happen in a second
    /// conversation inside a panel that replaced this one, so asking a question
    /// and building a tool looked like two different applications.
    @ViewBuilder
    private var buildTranscript: some View {
        ForEach(builder.chat.messages) { message in
            if message.role == .user {
                ChatQuestionBubble(text: message.text, images: message.images)
            } else {
                ChatAssistantTurn(trailingGutter: 0) {
                    ChatAnswerText(markdown: message.text)
                }
            }
        }
        if builder.isBuilding, !builder.chat.isAwaitingAnswer {
            ChatAssistantTurn(trailingGutter: 0) {
                ChatThinkingText(text: builder.chat.currentActivity ?? "Building")
            }
        }
        if let secret = builder.chat.pendingSecret {
            secretRow(secret)
        }
        if let ready = builder.chat.readyMessage, !builder.isBuilding {
            readyCard(ready)
        }
    }

    /// The build is blocked on a key. Answering it here is what keeps the
    /// continuation from being stranded — a build waiting on a question nobody
    /// can see waits forever.
    private func secretRow(_ name: String) -> some View {
        ChatAssistantTurn(trailingGutter: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This needs \(name). Add it in Settings, then carry on.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecondaryButton(title: "I added it") { builder.chat.resolveSecret(true) }
                    SecondaryButton(title: "Skip") { builder.chat.resolveSecret(false) }
                }
            }
        }
    }

    /// Saving happens here, and nothing closes: the chat is where this
    /// happened and the chat stays where it is. The rail updates from
    /// `ToolsStore` on its own.
    private func readyCard(_ text: String) -> some View {
        ChatAssistantTurn(trailingGutter: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ChatAnswerText(markdown: text)
                HStack(spacing: 8) {
                    SecondaryButton(title: "Save") {
                        guard builder.saveLive() != nil else { return }
                        // Both halves, or the screen is left in neither state:
                        // the build gone and an old question still sitting
                        // above an empty composer. Saving finishes a piece of
                        // work, so the chat opens again the way it opened.
                        conversation.clear()
                    }
                    if builder.live?.canSave == true, builder.live?.draft.kind == .python {
                        SecondaryButton(title: "Try it") {
                            Task { await builder.live?.runTest() }
                        }
                    }
                }
            }
        }
    }

    /// The invitation, sized like a title because on an empty screen it is one.
    private var opening: some View {
        VStack(spacing: 6) {
            // About the tool, not about the person. "What do you want to do?"
            // asks someone to describe their own afternoon; what this box needs
            // is a job for a gizmo to do, and the question that gets one names
            // the gizmo as the thing doing it.
            Text("What should a gizmo do for you?")
                .font(FlowTheme.serif(26))
                .foregroundStyle(FlowTheme.ink)
            Text("Describe the tool you want. Or ask a question, or type @ to change one you have.")
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
    /// Three gizmos somebody could have, not three chores somebody has.
    ///
    /// The chips used to name what the pane is for: ask about Gizmate, build
    /// one, change one. Somebody who has never seen a gizmo learns nothing from
    /// that — "Build me a gizmo" is the same sentence as the title above it and
    /// the placeholder below it, said a third time. An example teaches the shape
    /// of a request by being one.
    ///
    /// Named as things you would own, and phrased as builds. Written as jobs
    /// ("Fix my grammar") they read as errands for the assistant to run once,
    /// which is what this chat is *not* for, and `ToolChatRouter` reads them the
    /// same way a person does: an errand is answered, not built. A noun is a
    /// tool you keep, and "Make a gizmo that…" leaves the router nothing to
    /// weigh.
    ///
    /// One per kind of thing a gizmo can work on, which is the actual breadth:
    /// the text you have selected, what is on your screen, the files you picked
    /// in Finder. Three chips cannot list the whole surface, so they should at
    /// least not all point at the same corner of it. All three are drawn from
    /// `ToolEvalSuite.all`, so a first click lands on something the builder is
    /// known to finish.
    ///
    /// They send rather than fill the field: a chip that quietly types for you
    /// and then waits reads as broken, and the answer to "what can this do" is
    /// watching it build one.
    private var starters: some View {
        HStack(spacing: 8) {
            starter("Grammar fixer") {
                build("fixes the grammar in the text I select, in place")
            }
            starter("Error explainer") {
                build("explains the error message that is on my screen")
            }
            starter("Photo renamer") {
                build("renames the photos I select in Finder by the date they were taken")
            }
        }
    }

    /// Sends an example as what it is: a request to build something.
    private func build(_ job: String) {
        draft = "Make a gizmo that \(job)."
        send()
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
                if !attachments.isEmpty {
                    attachmentStrip
                }
                TextField("Ask, or describe a gizmo", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    // Hidden while a build owns the composer: the next message
                    // is an answer to the builder's own question, and a picture
                    // has nowhere to go from there. A clip that quietly drops
                    // what it accepted is worse than no clip.
                    if !builderOwnsComposer {
                        attachButton
                    }
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
                .stroke(
                    isDropTarget ? FlowTheme.ink.opacity(0.5) : FlowTheme.hairline,
                    lineWidth: 1
                )
        )
        .padding(20)
        // ⌘V and ⇧Return both have to be caught before the responder chain,
        // because by the time either reaches the field editor it has already
        // decided what the key means — a paste is text, and Return is submit —
        // and swallowed the event.
        //
        // The monitor exists exactly while the composer holds the keyboard, and
        // reads no focus of its own. It used to be installed once and gated on
        // `composerFocused` from inside the handler, which asks a closure
        // holding a copy of this view made at `onAppear` — when focus was
        // false — what focus is now. The install itself is the gate instead,
        // and `onAppear` covers coming back to the pane still focused, which is
        // the one case an `onChange` alone would never see.
        .onAppear { if composerFocused { startWatchingComposerKeys() } }
        .onChange(of: composerFocused) { _, focused in
            if focused { startWatchingComposerKeys() } else { stopWatchingComposerKeys() }
        }
        .onDisappear(perform: stopWatchingComposerKeys)
    }

    private var builderOwnsComposer: Bool {
        builder.chat.isAwaitingAnswer || builder.isBuilding
    }

    /// What is going with the next message, and the way to change your mind.
    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { image in
                ChatImageThumb(image: image, side: 56) {
                    attachments.removeAll { $0.id == image.id }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var attachButton: some View {
        Button {
            attachments.append(contentsOf: ChatImage.pick())
            composerFocused = true
        } label: {
            // Leading, not centred. The send button's disc fills its 22pt frame
            // and lands flush on the right margin; a glyph centred in the same
            // frame keeps the click area but starts a few points inside the
            // margin, so the clip read as indented from the line of text above
            // it. Aligning the glyph and not shrinking the frame is what keeps
            // both true at once.
            Image(systemName: "paperclip")
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 22, height: 22, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show Gizmate a picture. Drag one in, or paste it.")
    }

    private func startWatchingComposerKeys() {
        guard composerKeys == nil else { return }
        composerKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch HomeComposerKey.of(event) {
            case .newline: return insertNewline() ? nil : event
            case .pastePicture: return takePastedPictures() ? nil : event
            case .passThrough: return event
            }
        }
    }

    private func stopWatchingComposerKeys() {
        guard let monitor = composerKeys else { return }
        NSEvent.removeMonitor(monitor)
        composerKeys = nil
    }

    /// A line break at the caret, which is what every chat composer means by
    /// ⇧Return. SwiftUI's own vertical `TextField` binds that to ⌥Return and
    /// leaves ⇧Return unbound, so this is not an override of anything — it is
    /// the second, expected way in.
    ///
    /// Handed to the field editor rather than appended to `draft`: the caret
    /// is not always at the end, and a string edit would also lose the undo
    /// step. `insertNewlineIgnoringFieldEditor` is the same selector ⌥Return
    /// already reaches, so both keys produce one identical edit.
    ///
    /// False when the responder isn't a text view after all — no window at
    /// all, or focus moved between the install and the keystroke — and the
    /// caller then lets the event continue rather than swallowing it.
    private func insertNewline() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Whether the composer took the whole paste, and the field editor should
    /// therefore never see the event. False when the board held no pictures,
    /// and also when it held words as well as pixels: that one is taking the
    /// picture *and* letting the field editor have the event, rather than
    /// choosing which half of somebody's paste they meant.
    private func takePastedPictures() -> Bool {
        let paste = ChatImage.pasted()
        guard !paste.pictures.isEmpty else { return false }
        attachments.append(contentsOf: paste.pictures)
        return !paste.keepsText
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
        // A picture on its own is a message: "look at this" is what dropping one
        // in already said.
        let idle = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
        return Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(idle ? FlowTheme.ink.opacity(0.22) : FlowTheme.ink))
        }
        .buttonStyle(.plain)
        .disabled(idle)
        .help("Send")
    }

    // MARK: - Routing

    /// One message, one agent, one decision.
    ///
    /// This used to send the message twice: once to be answered and once to be
    /// classified, in parallel, on the theory that answering is what a message
    /// usually wants and the classifier only had to arrive first. Two models
    /// reading the same sentence do not have to agree, and when they disagreed
    /// both outcomes happened — Gizmate asked which shortcut the gizmo should
    /// use while the builder, told the same message was a build, finished one
    /// underneath the question. Worse, a build already running was cancelled and
    /// restarted by the second verdict, which is what put a bare "cancelled" in
    /// the transcript.
    ///
    /// Now Gizmate decides by replying. A directive is not a reading of the
    /// answer, it *is* the answer, so there is nothing left to disagree with.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictures = attachments
        guard !text.isEmpty || !pictures.isEmpty, !conversation.isRunning else { return }
        let usable = tools.usableTools()
        draft = ""
        attachments = []

        // A build already open owns the composer. Sending a message that is an
        // answer to the agent's own question anywhere else would strand the
        // continuation it is waiting on, and start a second build besides.
        if builder.chat.isAwaitingAnswer || builder.isBuilding {
            Task { await builder.send(text, showing: pictures) }
            return
        }

        // A mention is certain, so it costs no call at all — and it takes the
        // pictures with it. This used to drop them: the builder took an
        // instruction and not a payload, so "@Mac Usage make it look like
        // this" arrived as words with the reference silently gone, and the
        // transcript showed a message nobody had sent.
        if let mentioned = ToolChatRouter.mentioned(in: text, among: usable) {
            builder.startEdit(mentioned, instruction: text, asking: text, showing: pictures)
            return
        }

        conversation.send(text, images: pictures) { reply in
            guard let directive = ToolChatRouter.directive(in: reply, tools: usable) else {
                return false
            }
            // `asking:` still carries the question, because a directive makes
            // the conversation drop its own turn — see `ToolBuilderChatSession
            // .record(request:)`. `showing:` carries what went with it, so the
            // picture survives the same hand-over the words already did.
            switch directive {
            case .build(let brief):
                builder.startNew(brief ?? text, asking: text, showing: pictures)
            case .edit(let id):
                builder.startEdit(id, instruction: text, asking: text, showing: pictures)
            }
            return true
        }
    }
}

/// What a keystroke means to the composer, decided from the modifiers and the
/// physical key alone.
///
/// Separate from the monitor that acts on it because the acting half needs a
/// key window, a first responder and a pasteboard, and the deciding half is
/// where the mistakes live: an exact modifier match rather than `.contains`,
/// so ⇧⌘Return keeps whatever it means elsewhere instead of quietly becoming
/// a line break here.
enum HomeComposerKey {
    case newline
    case pastePicture
    case passThrough

    static func of(_ event: NSEvent) -> Self {
        of(modifiers: event.modifierFlags, keyCode: Int(event.keyCode))
    }

    /// The physical key, not the letter printed on it.
    /// `charactersIgnoringModifiers` ignores the modifiers and not the layout,
    /// so with a Russian layout active ⌘V arrives as "м" and with a Korean one
    /// as a jamo — and this watcher, keyed to "v", did nothing at all for
    /// anyone not typing in English.
    static func of(modifiers: NSEvent.ModifierFlags, keyCode: Int) -> Self {
        // The four keys a person presses on purpose, and not
        // `deviceIndependentFlagsMask` — that mask also carries `capsLock`,
        // `numericPad` and `function`, none of which anyone means as part of a
        // chord. Comparing against the whole mask is why ⌘V quietly stopped
        // taking pictures with caps lock left on.
        switch modifiers.intersection([.command, .control, .option, .shift]) {
        case .command where keyCode == kVK_ANSI_V: return .pastePicture
        case .shift where keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter: return .newline
        default: return .passThrough
        }
    }
}
