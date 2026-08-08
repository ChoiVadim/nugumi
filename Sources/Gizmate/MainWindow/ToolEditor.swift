import AppKit
import CryptoKit
import GizmateToolAgentCore
import SwiftUI

/// Draft-based tool editor: nothing reaches the store until Save, so Cancel and
/// Escape are always safe. Three modes behind one panel — a prompt the model
/// runs, a macOS action from a fixed catalog, or a Python script uv runs.
struct ToolEditorPanel: View {
    /// Where this panel is being shown.
    ///
    /// It was a modal and nothing else, which is why building or changing a
    /// gizmo meant opening a sheet, doing one thing, and closing it again. The
    /// panel itself was never the problem: it holds the whole build-and-test
    /// loop and works. What made it a sheet was fifteen points of chrome — a
    /// fixed 640×620, its own card fill, a shadow — so that is all this
    /// switches. Nothing inside changes, and the sheet path is byte-for-byte
    /// what it was.
    enum Chrome {
        /// A modal over the window: fixed size, its own card, a shadow.
        case sheet
        /// A pane inside a page: fills what it is given, and lets the page
        /// underneath supply the surface.
        case inline
    }

    private enum EditorStage {
        case new
        case ready
    }

    private enum EditorPage: CaseIterable, Hashable {
        case overview
        case details

        var title: String {
            switch self {
            case .overview: return "Chat"
            case .details: return "Details"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "bubble.left.and.bubble.right"
            case .details: return "slider.horizontal.3"
            }
        }
    }

    @EnvironmentObject var bridge: GizmateSettingsBridge
    let toolID: UUID?
    var chrome: Chrome = .sheet
    /// Opens on the fields and shows no chat tab.
    ///
    /// What clicking a gizmo does. A saved gizmo has a name, an icon, a kind
    /// and a trigger to look at, and that is the same thing a built-in's editor
    /// shows — so the two behave alike. Changing what a gizmo *does* is a
    /// conversation, and conversations belong in the one chat rather than in a
    /// second one that opens per gizmo.
    var opensOnDetails = false
    /// What closing means here. `nil` closes the ring sheet, which is the only
    /// answer a modal has; a page hosting this inline passes its own, because
    /// there is no sheet to close and "back to no tool" is the page's state.
    var onClose: (() -> Void)?

    @State private var draft = GizmateTool()
    @State private var script = ""
    @State private var loaded = false
    @State private var test: ToolTestState = .idle
    /// Output arriving while the test is still running.
    @State private var liveOutput = ""
    @State private var elapsed = 0
    @State private var ticker: Task<Void, Never>?
    /// Cancelling this kills the tool's whole process tree — see `ToolRunner`.
    @State private var runTask: Task<Void, Never>?
    @State private var runningTestFingerprint: String?
    @State private var passedTestFingerprint: String?
    /// The plain-language request the model turns into a tool. Kept around after
    /// generation so a repair knows what the tool was supposed to do.
    @State private var brief = ""
    @State private var generating = false
    @State private var generatedSummary: String?
    /// Set only for a generated Python tool, where "did Gizmate actually run
    /// this?" has more than one possible answer.
    @State private var generatedAssurance: ToolAgentAssuranceV1?
    /// A draft Gizmate itself executed while building it. Carries exactly the
    /// standing a passed Install & test does: this precise code has already run
    /// once, with the user watching the build, so the first-run gate has nothing
    /// left to ask them. Compared against the current fingerprint at save time,
    /// so editing the draft afterwards silently drops it.
    @State private var builtAndRanFingerprint: String?
    @State private var generateTask: Task<Void, Never>?
    @State private var chatComposer = ""
    @StateObject private var chat = ToolBuilderChatSession()
    @FocusState private var nameFocused: Bool
    @State private var stage: EditorStage = .new
    @State private var page: EditorPage = .overview
    /// Set once, from `opensOnDetails`, because `page` is `@State` and cannot
    /// be initialised from another property at declaration.
    @State private var didChoosePage = false
    /// Which detail row is expanded, keyed by its title. One at a time: the
    /// closed rows are the only thing that keeps the whole configuration on one
    /// screen, so opening a second by closing the first is the point, not a
    /// restriction.
    @State private var openRow: String?
    @State private var readyDraftFingerprint: String?
    /// Mirrors `draft.options` with stable per-row identity for `optionsEditor`.
    /// See `OptionRow` for why an array index can't serve as that identity.
    @State private var optionRows: [OptionRow] = []

    private var isNew: Bool { toolID == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isNew, !opensOnDetails {
                editorTabs
            }
            Divider().background(FlowTheme.hairline)
            if page == .overview {
                ToolBuilderChat(
                    session: chat,
                    composer: $chatComposer,
                    isBuilding: generating || test.isRunning,
                    preview: hasTool ? AnyView(summaryCard) : nil,
                    onSend: sendChatMessage,
                    onStop: stopBuilding,
                    onSave: save,
                    onTry: runTest,
                    onFix: repairScript
                )
            } else {
                ScrollView {
                    detailsContent
                        .disabled(generating)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                }
                Divider().background(FlowTheme.hairline)
                footer
            }
        }
        .modifier(ToolEditorChrome(chrome: chrome))
        .onAppear {
            loadOnce()
            if opensOnDetails, !didChoosePage {
                didChoosePage = true
                page = .details
            }
        }
        .onDisappear(perform: cancelInFlightWork)
        // Closer to the focused field than the overlay's own handler, so this
        // one gets Escape first.
        .onExitCommand(perform: escapePressed)
        .onChange(of: currentDraftFingerprint) { _, fingerprint in
            draftDidChange(to: fingerprint)
        }
    }

    /// The one way out of this panel. Kills anything still in flight — a running
    /// test (which also kills its process tree), a generation, and the
    /// elapsed-time ticker, which would otherwise loop for the rest of the
    /// session — then closes through the bridge like every other Ring panel.
    private func dismiss() {
        nameFocused = false
        cancelInFlightWork()
        if let onClose {
            onClose()
        } else {
            bridge.closeRingSheet()
        }
    }

    /// Escape stops the work first and closes second. A build runs for minutes
    /// and the panel is the only place its result exists, so spending the same
    /// key on both means one reflex press throws the whole thing away. Nothing
    /// is in flight — the press closes, as it always did.
    private func escapePressed() {
        guard generating || test.isRunning else {
            dismiss()
            return
        }
        stopBuilding()
    }

    /// Both cancellations reach real work: the generation unwinds through the
    /// agent supervisor, the test kills the tool's process tree. Each task
    /// reports its own stop into the chat when it lands, so nothing is said here
    /// that the outcome might contradict.
    private func stopBuilding() {
        generateTask?.cancel()
        runTask?.cancel()
    }

    /// Escape and click-outside dismiss the overlay without calling `dismiss()`.
    /// Keep cleanup in the view lifecycle as well, and make it safe to call twice.
    private func cancelInFlightWork() {
        ticker?.cancel()
        ticker = nil
        runTask?.cancel()
        runTask = nil
        runningTestFingerprint = nil
        generateTask?.cancel()
        generateTask = nil
        let session = chat
        Task { await session.cancel() }
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        if let toolID, let existing = bridge.tools.tool(id: toolID) {
            draft = existing
            script = bridge.tools.script(for: toolID) ?? ""
            brief = existing.brief
            stage = .ready
            // So the summary card explains the tool right away instead of waiting
            // for a round-trip.
            generatedSummary = existing.brief
            page = .overview
            chat.greetForEditing(existing.name)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            if showsIdentity {
                Image(systemName: draft.resolvedSymbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(headerTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowTheme.ink)
                        .lineLimit(1)
                    if showsIdentity {
                        RingTag(text: draft.kind.displayName, accent: true)
                    }
                }
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close gizmo editor")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var editorTabs: some View {
        HStack(spacing: 4) {
            ForEach(EditorPage.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        page = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 12, weight: page == item ? .semibold : .medium))
                    }
                    .foregroundStyle(page == item ? FlowTheme.ink : FlowTheme.inkTertiary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(page == item ? FlowTheme.subtleFill : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(generating && item == .details)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let toolID {
                SecondaryButton(title: "Delete", destructive: true) {
                    bridge.ringLayout.removeTool(toolID)
                    bridge.tools.delete(toolID)
                    ToolApprovals.revoke(toolID)
                    dismiss()
                }
            }
            Spacer(minLength: 0)
            // Only as a sheet. A modal's Cancel is the way out that is not
            // Save; inline, the ✕ above already is that, and two controls for
            // one action makes a person read both to find the difference.
            if chrome == .sheet {
                SecondaryButton(title: "Cancel") { dismiss() }
            }
            Button(action: save) {
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 18)
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
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    /// True once there is something to show: a generated tool, or an existing one
    /// opened for editing.
    private var hasTool: Bool { stage == .ready }

    /// Whether the header names the gizmo rather than the job.
    ///
    /// Details is the only page with nothing else that says what this thing is:
    /// the chat page already carries `summaryCard` inline in its transcript, and
    /// a header restating the same name and the same behaviour line 40pt above it
    /// is where this panel's "everything is said three times" reading came from.
    private var showsIdentity: Bool { page == .details && hasTool }

    private var headerTitle: String {
        guard showsIdentity else { return isNew ? "New gizmo" : "Edit gizmo" }
        return draft.name.isEmpty ? "Untitled gizmo" : draft.name
    }

    private var headerSubtitle: String {
        guard showsIdentity else {
            return isNew ? "Build it with Gizmate" : "Edit it with Gizmate"
        }
        return behaviourLine
    }

    /// What the model decided, in one readable block. This is the only thing the
    /// user has to look at before saving.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: draft.resolvedSymbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text(draft.name.isEmpty ? "Untitled gizmo" : draft.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                RingTag(text: draft.kind.displayName, accent: true)
                if let generatedAssurance {
                    RingTag(text: generatedAssurance.badge, accent: false)
                }
                Spacer(minLength: 0)
            }
            if let generatedSummary, !generatedSummary.isEmpty {
                Text(generatedSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(behaviourLine)
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }

    /// Trigger · input · result, spelled out rather than shown as three pickers.
    private var behaviourLine: String {
        var parts: [String] = []
        if draft.kind != .native || draft.nativeAction.usesInput {
            parts.append("takes \(draft.input.displayName.lowercased())")
        }
        if draft.kind == .native {
            parts.append(draft.nativeAction.displayName.lowercased()
                + (draft.target.isEmpty ? "" : " — \(draft.target)"))
        } else {
            parts.append(draft.output.displayName.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    /// Every setting states its current value on a closed row, and opens to the
    /// control that changes it.
    ///
    /// This page used to be every section expanded at once — seven of them for a
    /// script gizmo, each a heading, a paragraph of grey explanation, and its
    /// fields, in a panel 620pt tall. Two things followed and neither was
    /// fixable by spacing. Nothing could be *found*: about a screen and a half
    /// of the config existed below the fold with nothing saying what was down
    /// there. And nothing could be *read*: a section paragraph plus a hint under
    /// every field is a uniform grey texture, and uniform is the one thing
    /// hierarchy cannot be.
    ///
    /// Collapsing to values fixes both at once, and the reason it can is that
    /// every setting here has a short answer — a name, an icon, one of eight
    /// inputs, a timeout. So the closed list is not a table of contents that
    /// hides the settings; it *is* the settings, all of them, legible at a
    /// glance for the first time. Opening one is how you change it, not how you
    /// see it.
    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            detailGroup("General") {
                detailRow("Name", value: draft.name.isEmpty ? "Not set" : draft.name) {
                    nameField
                }
                rowDivider
                detailRow(
                    "Icon",
                    value: ToolIcons.displayName(for: draft.resolvedSymbolName)
                ) {
                    IconGrid(selection: $draft.symbolName, height: 108)
                }
                rowDivider
                // Out of "General", which called itself "how this gizmo appears
                // in your Ring" — the kind is the one choice on this page that
                // rewrites every row below it, and appearance is the one thing
                // it does not touch.
                detailRow(
                    "Kind",
                    value: draft.kind.displayName,
                    hint: Self.subtitle(for: draft.kind)
                ) {
                    PillPicker(
                        options: ToolKind.allCases,
                        selection: $draft.kind,
                        label: { $0.displayName }
                    )
                }
                rowDivider
                detailRow(
                    "Options",
                    value: optionsValue,
                    hint: "Variants this gizmo offers. The Ring shows them as a "
                        + "second orbit behind its button, and the first one is used "
                        + "when you run the gizmo from a shortcut."
                ) {
                    optionsEditor
                }
            }

            switch draft.kind {
            case .prompt:
                detailGroup("Behaviour") {
                    detailRow(
                        "Instruction",
                        value: promptValue,
                        hint: "The exact prompt Gizmate sends to your current model."
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            promptField
                            languageToggle
                        }
                    }
                    rowDivider
                    detailRow(
                        "Result",
                        value: resultValue,
                        hint: draft.output.explanation
                    ) {
                        resultPicker
                    }
                    rowDivider
                    detailRow(
                        "Your context",
                        value: contextValue,
                        hint: "What this gizmo knows about you before it starts."
                    ) {
                        contextToggles
                    }
                }
            case .native:
                detailGroup("Action") {
                    detailRow(
                        "Action",
                        value: actionValue,
                        hint: draft.nativeAction.explanation
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            actionPicker
                            if draft.nativeAction.targetLabel != nil {
                                targetField
                            }
                        }
                    }
                    if draft.nativeAction.usesInput {
                        rowDivider
                        detailRow("Input", value: draft.input.displayName, hint: inputHint) {
                            inputPicker
                        }
                    }
                }
            case .python:
                detailGroup("Script") {
                    detailRow(
                        "Python script",
                        value: scriptValue,
                        hint: "A PEP 723 header declares the dependencies; the input "
                            + "arrives as command-line arguments."
                    ) {
                        scriptField
                    }
                    rowDivider
                    detailRow("Input", value: draft.input.displayName, hint: inputHint) {
                        inputPicker
                    }
                    rowDivider
                    detailRow("Result", value: resultValue, hint: draft.output.explanation) {
                        VStack(alignment: .leading, spacing: 16) {
                            resultPicker
                            if draft.output == .files {
                                outputDirectoryField
                            }
                        }
                    }
                }
                detailGroup("Running it") {
                    detailRow(
                        "Runtime",
                        value: runtimeValue,
                        hint: "Set the time limit and declare network use."
                    ) {
                        scriptSettings
                    }
                    rowDivider
                    detailRow(
                        "Secrets",
                        value: secretsValue,
                        hint: "Keys this script may read from its environment. "
                            + "It gets the ones ticked here and nothing else."
                    ) {
                        ToolSecretsPicker(selection: $draft.secretNames)
                    }
                    rowDivider
                    detailRow(
                        "Test",
                        value: testValue,
                        valueTint: test.isFailure ? Self.warning : nil,
                        hint: "Run this exact version once and inspect its output."
                    ) {
                        testSection
                    }
                }
                consentNotice
            case .agent:
                detailGroup("Behaviour") {
                    detailRow(
                        "Instruction",
                        value: promptValue,
                        hint: "What the agent should accomplish. It decides how, "
                            + "one step at a time."
                    ) {
                        promptField
                    }
                    rowDivider
                    detailRow("Input", value: draft.input.displayName, hint: inputHint) {
                        inputPicker
                    }
                    rowDivider
                    detailRow("Result", value: resultValue, hint: draft.output.explanation) {
                        resultPicker
                    }
                    rowDivider
                    detailRow(
                        "Your context",
                        value: contextValue,
                        hint: "What this gizmo knows about you before it starts."
                    ) {
                        contextToggles
                    }
                }
                detailGroup("Running it") {
                    detailRow(
                        "Limits",
                        value: limitsValue,
                        hint: "The only bound on a gizmo whose steps nobody can "
                            + "read in advance."
                    ) {
                        agentSettings
                    }
                    rowDivider
                    detailRow(
                        "Secrets",
                        value: secretsValue,
                        hint: "Keys the agent's scripts may read from their environment. "
                            + "They get the ones ticked here and nothing else."
                    ) {
                        ToolSecretsPicker(selection: $draft.secretNames)
                    }
                }
                agentConsentNotice
            }
        }
    }

    // MARK: - Detail rows

    /// A titled set of rows in one panel. The caption carries the grouping that
    /// per-section paragraphs used to carry at four times the height.
    private func detailGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowTheme.inkTertiary)
                .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(FlowTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(FlowTheme.hairline, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inset on the leading edge only, so the group's own outline stays the
    /// outer shape and the dividers read as inside it.
    private var rowDivider: some View {
        Rectangle()
            .fill(FlowTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 12)
    }

    /// One setting: its name, its current value, and — only once you ask — the
    /// control and the sentence explaining it.
    ///
    /// The hint lives here rather than above the whole group because it is the
    /// thing you want *while deciding*, and nowhere else. Printed permanently it
    /// was the grey texture that flattened this page; printed on open it is the
    /// answer to the question you just asked.
    @ViewBuilder
    private func detailRow<Content: View>(
        _ title: String,
        value: String,
        valueTint: Color? = nil,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = openRow == title
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    openRow = isOpen ? nil : title
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(FlowTheme.ink)
                        .fixedSize()
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(valueTint ?? FlowTheme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(value)")
            .accessibilityHint(isOpen ? "Collapse" : "Expand")

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    if let hint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
    }

    // MARK: - Row values

    /// What each closed row says. Every one of these has to be true of the draft
    /// at a glance — a row that shrugs ("Configured") would put the page back
    /// where it started, since the only way to check would be opening it.

    private var optionsValue: String {
        let live = draft.options.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return live.isEmpty ? "None" : live.joined(separator: ", ")
    }

    private var promptValue: String {
        let first = draft.prompt
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Not set" : first
    }

    private var scriptValue: String {
        guard !scriptIsEmpty else { return "Empty" }
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    private var resultValue: String {
        guard draft.output == .files, let directory = draft.outputDirectory,
              !directory.isEmpty else {
            return draft.output.displayName
        }
        return "\(draft.output.displayName) → \(directory)"
    }

    private var runtimeValue: String {
        "\(draft.timeoutSeconds)s" + (draft.declaresNetwork ? " · network" : "")
    }

    private var limitsValue: String {
        "\(draft.maxSteps) steps · \(draft.timeoutSeconds)s"
    }

    private var secretsValue: String {
        draft.secretNames.isEmpty ? "None" : draft.secretNames.joined(separator: ", ")
    }

    private var contextValue: String {
        var sources: [String] = []
        if draft.usesVoice { sources.append("Voice") }
        if draft.usesNotes { sources.append("Notes") }
        return sources.isEmpty ? "None" : sources.joined(separator: " · ")
    }

    private var actionValue: String {
        draft.target.isEmpty
            ? draft.nativeAction.displayName
            : "\(draft.nativeAction.displayName) — \(draft.target)"
    }

    /// The one row whose value is a result rather than a setting, which is why
    /// it is also the one that tints: a failed test collapsed into a grey line
    /// reading "Failed" is exactly as invisible as no line at all.
    private var testValue: String {
        switch test {
        case .idle: return "Not run"
        case .running: return "Running — \(elapsed)s"
        case .passed: return "Passed"
        case .failed: return "Failed"
        }
    }

    /// A row of `optionsEditor`, identified by a `UUID` rather than its
    /// position in the list. `ForEach` diffs by identity, not position: keying
    /// rows by array index makes removing row *k* look, to the diff, like the
    /// *last* row disappeared, since the id set just shrinks by one from the
    /// top. Every row below `k` then keeps its on-screen identity — and any
    /// keyboard focus in it — while silently starting to display and edit the
    /// next row's text. A `UUID` per row survives a sibling's removal intact.
    private struct OptionRow: Identifiable {
        let id = UUID()
        var value: String
    }

    private func bindingForOption(_ row: OptionRow) -> Binding<String> {
        Binding(
            get: { optionRows.first(where: { $0.id == row.id })?.value ?? "" },
            set: { newValue in
                guard let index = optionRows.firstIndex(where: { $0.id == row.id }) else { return }
                optionRows[index].value = newValue
                draft.options = optionRows.map(\.value)
            }
        )
    }

    /// A plain list of variant labels. Rows are edited in place and sanitized
    /// on the way into the draft, so a blank or duplicate row simply doesn't
    /// become an option rather than becoming a broken button. `optionRows`
    /// holds the editable, identity-stable copy; `draft.options` is written
    /// back on every edit and re-read whenever something outside this view
    /// (loading a tool, the builder chat regenerating one) replaces it wholesale.
    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(optionRows) { row in
                HStack(spacing: 8) {
                    TextField("720p", text: bindingForOption(row))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        optionRows.removeAll { $0.id == row.id }
                        draft.options = optionRows.map(\.value)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(row.value)")
                }
            }
            if optionRows.count < 5 {
                Button {
                    // Two at a time from nothing: one option is not a choice, so
                    // a list that starts at one can never be saved.
                    optionRows += optionRows.isEmpty
                        ? [OptionRow(value: ""), OptionRow(value: "")]
                        : [OptionRow(value: "")]
                    draft.options = optionRows.map(\.value)
                } label: {
                    Label("Add an option", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlowTheme.inkTertiary)
            }
        }
        .onAppear {
            optionRows = draft.options.map { OptionRow(value: $0) }
        }
        .onChange(of: draft.options) { _, latest in
            guard latest != optionRows.map(\.value) else { return }
            optionRows = latest.map { OptionRow(value: $0) }
        }
    }

    /// Amber, for the two things on this page that are a warning rather than a
    /// state: a failed test and the consent notices.
    private static let warning = Color(red: 1.0, green: 0.78, blue: 0.42)

    private static func subtitle(for kind: ToolKind) -> String {
        switch kind {
        case .prompt:
            return "Your prompt runs over the selected text. Gizmate adds nothing else to it."
        case .native:
            return "One macOS action from a fixed list. No code, nothing to install."
        case .python:
            return "A Python script, run by uv with its own dependencies."
        case .agent:
            return "An instruction carried out step by step, writing and running its own code."
        }
    }

    private var canSave: Bool {
        guard draft.isUsable else { return false }
        guard draft.kind == .python else { return true }
        return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentDraftFingerprint: String {
        ToolEditorDraftVerification.fingerprint(tool: draft, script: script, brief: brief)
    }

    private func draftDidChange(to fingerprint: String) {
        if let readyDraftFingerprint, fingerprint != readyDraftFingerprint {
            self.readyDraftFingerprint = nil
            chat.markCandidateStale()
        }

        if let passedTestFingerprint, fingerprint != passedTestFingerprint {
            self.passedTestFingerprint = nil
            test = .idle
            liveOutput = ""
        }

        if let runningTestFingerprint, fingerprint != runningTestFingerprint {
            self.runningTestFingerprint = nil
            runTask?.cancel()
            runTask = nil
            ticker?.cancel()
            ticker = nil
            test = .idle
            liveOutput = ""
        }
    }

    private func save() {
        guard canSave else { return }
        var tool = draft
        tool.name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.prompt = tool.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.options = GizmateTool.sanitizedOptions(tool.options)
        bridge.tools.save(tool, script: tool.kind == .python ? script : nil)
        let ran: String? = {
            if case .passed = test, let passedTestFingerprint { return passedTestFingerprint }
            return builtAndRanFingerprint
        }()
        if ToolEditorDraftVerification.savingApproves(
            kind: tool.kind,
            ranFingerprint: ran,
            current: currentDraftFingerprint
        ) {
            ToolApprovals.approve(tool.id, hash: bridge.tools.approvalHash(for: tool))
        } else {
            ToolApprovals.revoke(tool.id)
        }
        // Saving never places the tool: a gizmo is built on Home and given a
        // home from the Ring or Edges section afterwards.
        dismiss()
    }

    // MARK: - Shared fields

    private var nameField: some View {
        TextField(draft.kind == .prompt ? "To JSON" : "Download video", text: $draft.name)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowTheme.ink)
            .focused($nameFocused)
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }

    /// Same story as `inputPicker`: a row of pills wide enough for "Save to
    /// notes" leaves `SettingRow`'s label column about one word wide, so the
    /// explanation next to it wraps into a ransom note. A grid takes the full
    /// width, and the row it opens inside already carries the explanation.
    private var resultPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            choiceGrid(
                options: resultOptions,
                selection: $draft.output,
                label: { $0.displayName }
            )
            // Folded in here rather than added to each of the three sections
            // that show a result picker: it is a detail of one result, and it
            // has to disappear with it.
            if Self.outputsWithPlacementControl.contains(draft.output) {
                placementPointer
            }
        }
    }

    /// The two results that are an arrangement of the screen rather than
    /// something that happens: `.panel` opens somewhere, `.surface` runs (or
    /// doesn't) depending on where it's docked. Internal, like `outputs(for:)`,
    /// so `DockPlacementParityTests` can hold this against
    /// `DockCatalog.dockableGizmoOutputs` — a gizmo that catalog is willing to
    /// list has to be one this set says something about, or nobody editing it
    /// can ever discover it's dockable at all. `PanelPlacement` splits this set
    /// in two: the half outside `dockableGizmoOutputs` gets a real
    /// `DockPlacementPicker` right here, the half inside it gets a pointer to
    /// the Edges figure instead — a resident's edge is chosen there, beside the
    /// neighbours it shares that edge with.
    static let outputsWithPlacementControl: Set<ToolOutput> = [.panel, .surface]

    @ViewBuilder
    private var placementPointer: some View {
        if PanelPlacement.offersPicker(for: draft.output) {
            panelPlacementPicker
        } else {
            surfacePlacementPointer
        }
    }

    /// This gizmo's own placement in `DockStore`.
    private var dockedEdge: DockEdge? {
        bridge.dock.edge(of: ToolRef.generated(draft.id).storageID)
    }

    /// Where this gizmo's result panel opens. Chosen here rather than in Edges:
    /// a panel draws nothing until the gizmo runs, so it never shares an edge
    /// with anything and there is no tab order to arrange it in — the two
    /// things Edges exists to decide. A `.panel` gizmo also works fine left
    /// floating, which is why its `nil` pill keeps `DockPlacementPicker`'s
    /// default "Floating" rather than the surface's "Off". See DESIGN.md §11.
    private var panelPlacementPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(
                "Panel",
                hint: "Floating opens the answer at the cursor. An edge opens it flush to "
                    + "that side of the screen instead."
            )
            DockPlacementPicker(store: bridge.dock, itemID: ToolRef.generated(draft.id).storageID)
        }
    }

    /// Whether this surface gizmo exists at all. A surface has no floating
    /// form — it draws nothing until its dock opens, and its dock only opens
    /// on an edge — so undocked says it never runs rather than "Floating",
    /// which would claim a working mode that doesn't exist.
    ///
    /// Still a pointer, not a picker, and for the opposite reason to the panel
    /// above: a surface is a resident, it shares its edge with other residents,
    /// and the order they sit in is a thing only the Edges figure can show.
    ///
    /// The consent line DESIGN.md §11 requires is back in this hint, and this
    /// is where it belongs. It was briefly a footnote under the Edges figure,
    /// which said it about every resident drawn there — but Note and the folder
    /// hub run no script at all, so most of that page was reading a warning
    /// about something it wasn't doing. The claim is only ever true of one
    /// gizmo at a time, and this is the screen about one gizmo.
    private var surfacePlacementPointer: some View {
        fieldLabel(
            "Edge",
            hint: dockedEdge.map {
                "On the \($0.displayName) edge, so it runs on its own every time that edge "
                    + "opens. Change it in Edges."
            } ?? "Not on an edge, so it never runs. Change it in Edges."
        )
    }

    /// Every kind with something to say may say it any way it likes — a prompt
    /// gizmo that only wants a toast, or a script that reads its answer aloud,
    /// are both real shapes, and guessing which pairings are silly on the
    /// user's behalf was the only thing keeping them apart.
    ///
    /// Action and Agent are the exceptions, and neither list is a taste call:
    /// each is exactly what that kind's runner can deliver, read from the same
    /// constant the builder protocol validates against. Offering more gave the
    /// user a pill that silently did nothing and a gizmo the chat builder then
    /// refused to open; offering less rejected a tool they could legitimately
    /// build. Both have now happened, which is why there is one list rather
    /// than one per file.
    ///
    /// Internal rather than private so the parity test can hold the sides
    /// together.
    static func outputs(for kind: ToolKind) -> [ToolOutput] {
        switch kind {
        // A surface needs a layout tree, and nothing in this editor writes
        // one — that's composed by the build-time agent alone (Task 10),
        // never typed in by hand. Offering the pill here would let someone
        // save a `.surface` gizmo with `layout == nil`, which `isUsable`
        // then makes permanently dead: no ring slot, no dock tab, nothing
        // said about why it went nowhere.
        case .python:
            return ToolOutput.allCases.filter { $0 != .surface }
        // A surface renders rows a script printed. A prompt gizmo has a model
        // where the script would be, and a dock reveal cannot wait for one.
        case .prompt:
            return ToolOutput.allCases.filter { $0 != .surface }
        case .native:
            return deliverable(ToolAgentCandidateOutputV1.nativeDeliverable)
        case .agent:
            return deliverable(ToolAgentCandidateOutputV1.agentDeliverable)
        }
    }

    private static func deliverable(
        _ allowed: Set<ToolAgentCandidateOutputV1>
    ) -> [ToolOutput] {
        ToolOutput.allCases.filter { output in
            ToolAgentCandidateOutputV1(rawValue: output.rawValue)
                .map(allowed.contains) ?? false
        }
    }

    /// What the picker shows: the deliverable set, plus whatever this gizmo is
    /// already set to. A native tool saved while the list was wider would
    /// otherwise render with no pill lit, which reads as data loss.
    private var resultOptions: [ToolOutput] {
        let offered = Self.outputs(for: draft.kind)
        return offered.contains(draft.output) ? offered : offered + [draft.output]
    }

    // MARK: - Wrapping picker

    /// A wrapping grid of choices, for pickers with more entries than a pill row
    /// can hold.
    ///
    /// `PillPicker` is deliberately incapable of this: its pills are
    /// `.fixedSize()` so a label like "Text on screen" keeps its full width and
    /// never truncates. That is right for three or four choices and impossible
    /// for eight — the row simply demands more than the 640pt panel has, and
    /// what overflows is not the picker but the entire panel's content, clipped
    /// at both edges. Anything past about five options belongs here instead.
    private func choiceGrid<Option: Hashable>(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection.wrappedValue
                Button { selection.wrappedValue = option } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : FlowTheme.inkSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? FlowTheme.accent : Color.white.opacity(0.05))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action mode

    private var actionPicker: some View {
        choiceGrid(
            options: NativeAction.allCases,
            selection: $draft.nativeAction,
            label: { $0.displayName }
        )
    }

    private var targetField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(draft.nativeAction.targetLabel ?? "Target")
            TextField(draft.nativeAction.targetPlaceholder, text: $draft.target)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: draft.nativeAction == .openURL ? .monospaced : .default))
                .foregroundStyle(FlowTheme.ink)
                .padding(.vertical, 8)
                .padding(.horizontal, 11)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        }
    }

    // MARK: - Prompt mode

    private var promptField: some View {
        codeEditor(text: $draft.prompt, lines: 7, monospaced: false)
    }

    private var languageToggle: some View {
        SettingRow(
            "Write the answer in the target language",
            subtitle: "Leave this off for gizmos that transform text rather than translate it."
        ) {
            Toggle("", isOn: $draft.appliesTargetLanguage)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
        }
    }

    /// The two context toggles, offered to `.prompt` and `.agent` gizmos only —
    /// a script or a macOS action has no model in the loop to hand context to.
    private var contextToggles: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingRow(
                "Use my Voice",
                subtitle: "Writes in your register, with your dictionary and snippets."
            ) {
                Toggle("", isOn: $draft.usesVoice)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }
            SettingRow(
                "Use my notes",
                subtitle: "Hands it the notes you ticked in the Notes tab as background."
            ) {
                Toggle("", isOn: $draft.usesNotes)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }
        }
    }

    // MARK: - Script mode

    /// Applies one change to the tool that's already in the draft.
    private func revise(_ instruction: String) {
        let tool = draft
        let code = script
        generating = true
        generateTask = Task { @MainActor in
            let outcome = await bridge.reviseScriptTool(
                tool: tool,
                script: code,
                instruction: instruction
            ) { partial in
                Task { @MainActor in
                    chat.recordActivity(partial)
                }
            } clarification: { request in
                await MainActor.run { page = .overview }
                return try await chat.ask(request)
            } clarificationCancellation: {
                await chat.cancel()
            } secretRequest: { name in
                await MainActor.run { page = .overview }
                return await chat.requestSecret(name)
            }
            generating = false
            generateTask = nil
            switch outcome {
            case .success(let revised):
                apply(revised)
                candidateReady(revised.tool.name)
            case .failure(let error):
                page = .overview
                chat.appendError(error.localizedDescription)
            }
        }
    }

    /// Shared landing for a generated or revised tool.
    private func apply(_ generated: GeneratedTool) {
        draft = generated.tool
        script = generated.script
        brief = generated.brief.isEmpty ? brief : generated.brief
        generatedSummary = generated.summary
        generatedAssurance = generated.tool.kind == .python
            ? generated.assurance
            : nil
        // "unverified" is the one build outcome where nothing ran — a tool whose
        // real effects Gizmate refused to cause during a build is exactly the
        // one the user should still be asked about.
        builtAndRanFingerprint = generated.assurance == .unverified
            ? nil
            : currentDraftFingerprint
        stage = .ready
        page = .overview
        test = .idle
        passedTestFingerprint = nil
        runningTestFingerprint = nil
        liveOutput = ""
    }

    private func candidateReady(_ name: String) {
        readyDraftFingerprint = currentDraftFingerprint
        chat.candidateReady(
            name,
            note: generatedAssurance?.explanation,
            // Only `.verified` means Gizmate saw the right answer come out.
            // `.smoke` proves the tool survives, `.unverified` proves it starts
            // — for both, the one check left is the user running it.
            trial: generatedAssurance == nil || generatedAssurance == .verified
                ? .notNeeded
                : .untried
        )
    }

    private func generate(_ requestedTool: String? = nil) {
        let request = requestedTool ?? brief
        generating = true
        generatedSummary = nil
        generateTask = Task { @MainActor in
            let outcome = await bridge.generateScriptTool(description: request) { partial in
                Task { @MainActor in
                    chat.recordActivity(partial)
                }
            } clarification: { clarification in
                await MainActor.run { page = .overview }
                return try await chat.ask(clarification)
            } clarificationCancellation: {
                await chat.cancel()
            } secretRequest: { name in
                await MainActor.run { page = .overview }
                return await chat.requestSecret(name)
            }
            generating = false
            generateTask = nil
            switch outcome {
            case .success(let generated):
                apply(generated)
                candidateReady(generated.tool.name)
            case .failure(let error):
                page = .overview
                chat.appendError(error.localizedDescription)
            }
        }
    }

    private func repairScript() {
        guard case .failed(let failure) = test else { return }
        let tool = draft
        let current = script
        chat.markCandidateStale()
        generating = true
        generateTask = Task { @MainActor in
            let outcome = await bridge.repairScriptTool(
                tool: tool,
                script: current,
                failure: failure
            ) { partial in
                Task { @MainActor in chat.recordActivity(partial) }
            } clarification: { clarification in
                await MainActor.run { page = .overview }
                return try await chat.ask(clarification)
            } clarificationCancellation: {
                await chat.cancel()
            } secretRequest: { name in
                await MainActor.run { page = .overview }
                return await chat.requestSecret(name)
            }
            generating = false
            generateTask = nil
            switch outcome {
            case .success(let fixed):
                apply(fixed)
                candidateReady(fixed.tool.name)
            case .failure(let error):
                script = current
                page = .overview
                chat.appendError(error.localizedDescription)
            }
        }
    }

    private func sendChatMessage() {
        let text = chatComposer
        chatComposer = ""
        Task { @MainActor in
            guard let submission = await chat.submit(text) else { return }
            switch submission {
            case .answeredClarification:
                return
            case .buildRequest(let request):
                chat.markCandidateStale()
                if hasTool {
                    revise(request)
                } else {
                    brief = request
                    generate(request)
                }
            }
        }
    }

    private var scriptField: some View {
        VStack(alignment: .leading, spacing: 10) {
            codeEditor(text: $script, lines: 14, monospaced: true)
            // Always available, not just on an empty field: a correct starting
            // point should be one click away even after a bad paste. Nothing is
            // saved until Save, so replacing a draft is harmless.
            Button(scriptIsEmpty ? "Insert template" : "Replace with template") {
                script = Self.scriptTemplate
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(FlowTheme.accent)
            .fixedSize()
            if !scriptIsEmpty, !script.contains("# /// script") {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("No `# /// script` header, so uv won't install any dependencies. This field takes Python, not a shell command.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(Self.warning)
            }
        }
    }

    private var scriptIsEmpty: Bool {
        script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Eight inputs, with labels as long as "Screen you mark up" — far past what
    /// a pill row fits, which is what pushed the whole panel wider than itself.
    private var inputPicker: some View {
        choiceGrid(
            options: ToolInput.allCases,
            selection: $draft.input,
            label: { $0.displayName }
        )
    }

    /// Only a Prompt hands its model the picture. Everything else gets the file
    /// path, which is not a smaller version of the same thing — an Agent asked
    /// to describe what it sees is being asked to read a filename, and it fails
    /// somewhere far from here with nothing to explain why.
    private var inputHint: String {
        let base = "What the gizmo is handed when it runs."
        guard draft.input.isImage else { return base }
        switch draft.kind {
        case .prompt:
            return base + " The picture goes to the model, so pick a model that can see."
        case .agent, .python, .native:
            return base + " A \(draft.kind.displayName) receives the file path, not the "
                + "picture — nothing looks at it for you. Use Prompt for that."
        }
    }

    private var outputDirectoryField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Save to", hint: "Where the files the script writes end up.")
            TextField("~/Downloads", text: Binding(
                get: { draft.outputDirectory ?? "" },
                set: { draft.outputDirectory = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(FlowTheme.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        }
    }

    private var scriptSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingRow("Time limit", subtitle: "The run is stopped after this many seconds.") {
                Stepper(
                    value: Binding(
                        get: { draft.timeoutSeconds },
                        set: { draft.timeoutSeconds = max(5, min(1800, $0)) }
                    ),
                    in: 5...1800,
                    step: 15
                ) {
                    Text("\(draft.timeoutSeconds)s")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(FlowTheme.ink)
                }
                .fixedSize()
            }
            SettingRow("Uses the network", subtitle: "Recorded so it shows up in the run prompt.") {
                Toggle("", isOn: $draft.declaresNetwork)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }
        }
    }

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingRow(
                "Steps",
                subtitle: "How many scripts it may run before it has to answer."
            ) {
                Stepper(
                    value: Binding(
                        get: { draft.maxSteps },
                        set: { draft.maxSteps = max(1, min(24, $0)) }
                    ),
                    in: 1...24
                ) {
                    Text("\(draft.maxSteps)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(FlowTheme.ink)
                }
                .fixedSize()
            }
            SettingRow(
                "Time limit",
                subtitle: "The whole run is stopped after this many seconds."
            ) {
                Stepper(
                    value: Binding(
                        get: { draft.timeoutSeconds },
                        set: { draft.timeoutSeconds = max(15, min(900, $0)) }
                    ),
                    in: 15...900,
                    step: 15
                ) {
                    Text("\(draft.timeoutSeconds)s")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(FlowTheme.ink)
                }
                .fixedSize()
            }
        }
    }

    private var agentConsentNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.warning)
            Text("An agent gizmo writes its own code and runs it, deciding what to do as it "
                + "goes. There is no code to read before you allow it, because none exists "
                + "until you press the button. What you approve is this instruction, the "
                + "step budget and the secrets — change any of them and Gizmate asks again. "
                + "Give it work you would be comfortable doing yourself without checking.")
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }

    private var consentNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.warning)
            Text("A script gizmo runs real code with your account's access. What you set above is shown to you before each new version runs — it is not a restriction Gizmate enforces. Read the code before you allow it.")
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }

    // MARK: - Install & test

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if test.isRunning {
                    SecondaryButton(title: "Stop (\(elapsed)s)", destructive: true) {
                        runTask?.cancel()
                    }
                } else {
                    SecondaryButton(title: "Install & test") { runTest() }
                        .disabled(scriptIsEmpty || generating)
                        .opacity(scriptIsEmpty || generating ? 0.45 : 1)
                    if test.isFailure, !brief.trimmingCharacters(in: .whitespaces).isEmpty {
                        SecondaryButton(title: generating ? "Fixing…" : "Fix it") { repairScript() }
                            .disabled(generating)
                            .opacity(generating ? 0.45 : 1)
                    }
                }
                Text(runHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = reportText {
                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(test.isFailure ? Color(red: 1.0, green: 0.62, blue: 0.62) : FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.30)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
            }
        }
    }

    /// While running, show what the tool is actually printing; afterwards, the
    /// finished report.
    private var reportText: String? {
        if test.isRunning {
            return liveOutput.isEmpty
                ? "Waiting for the first output… dependencies download on the first run."
                : liveOutput
        }
        return test.report
    }

    private var runHint: String {
        if test.isRunning {
            return "Stops itself at the \(draft.timeoutSeconds)s limit."
        }
        return bridge.uvReady
            ? "Runs the script once, right now, on your real input."
            : "First run also downloads the uv runtime (about 35 MB)."
    }

    private func runTest() {
        let tool = draft
        let code = script
        let fingerprint = currentDraftFingerprint
        liveOutput = ""
        elapsed = 0
        test = .running
        // The ready card hides while this runs, so without a line here the chat
        // shows a spinner over whatever internal step happened to run last.
        chat.recordActivity("Running it once, for real…")
        passedTestFingerprint = nil
        runningTestFingerprint = fingerprint
        // A visible clock, because "Running…" on its own can't tell a 3-second
        // script from a stalled one.
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                elapsed += 1
            }
        }
        runTask = Task { @MainActor in
            let outcome = await bridge.testScriptTool(tool, script: code) { chunk in
                Task { @MainActor in
                    // Keep the tail: uv's progress bars redraw with \r and would
                    // otherwise grow the buffer without bound.
                    liveOutput = String((liveOutput + chunk).suffix(4000))
                }
            }
            ticker?.cancel()
            ticker = nil
            runTask = nil
            guard runningTestFingerprint == fingerprint,
                  currentDraftFingerprint == fingerprint else {
                return
            }
            runningTestFingerprint = nil
            test = outcome
            let trialing = chat.trial != .notNeeded
            switch outcome {
            case .passed:
                passedTestFingerprint = fingerprint
                if trialing { chat.trialFinished(passed: true) }
            case .failed(let report) where trialing:
                // Keep the card up: a failed trial is where "Fix it" belongs,
                // and it hands the agent the real diagnostics instead of making
                // the user retype them.
                chat.trialFinished(passed: false, report: report)
            default:
                readyDraftFingerprint = nil
                chat.markCandidateStale()
            }
        }
    }

    // MARK: - Small pieces

    /// Multi-line text input, built on `TextField(axis: .vertical)` rather than
    /// `TextEditor`.
    ///
    /// Not a style preference: `TextEditor` was the only thing this panel had that
    /// the slot picker (which closes cleanly) did not, and presenting then
    /// dismissing it leaves the window's SwiftUI content ignoring clicks — every
    /// click still arrives at the window, AppKit stays healthy, and no view is left
    /// behind, but nothing responds. A vertical `TextField` is an NSTextField
    /// underneath, the same control the picker uses, and it grows with its content
    /// inside the panel's own ScrollView.
    private func codeEditor(text: Binding<String>, lines: Int, monospaced: Bool) -> some View {
        TextField("", text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(lines, reservesSpace: true)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundStyle(FlowTheme.ink)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }

    private func fieldLabel(_ title: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
        }
    }

    /// Shows the contract a tool script has to satisfy: dependencies in the PEP 723
    /// header, input from argv, results written into the working directory.
    private static let scriptTemplate = """
        # /// script
        # requires-python = ">=3.12"
        # dependencies = []
        # ///
        \"\"\"Gizmate tool.

        Input arrives as command-line arguments, one per item.
        Anything written into the current directory is collected as the output.
        \"\"\"
        import sys
        from pathlib import Path

        for value in sys.argv[1:]:
            print(value)
        """
}

/// Result of one Install & test run, as the editor shows it.
/// Icon picker over every SF Symbol the OS ships. It opens on the curated
/// shortlist because eight thousand glyphs at once is a search problem, not a
/// choice — typing anything searches the whole catalog.
struct IconGrid: View {
    @Binding var selection: String
    var height: CGFloat = 108

    @State private var query = ""
    @State private var limit = IconGrid.pageSize
    /// Held in state, not recomputed in `body`: every cell's `onAppear` reads it,
    /// so a computed property meant re-scanning 8k names a couple hundred times
    /// per page — which is exactly what made typing feel sticky.
    @State private var matches: [String] = ToolIcons.matching("")

    /// Twelve columns, so a page is ten rows — a couple of scrolls' worth.
    private static let pageSize = 120

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 12)

    /// Paged, so a one-letter query doesn't try to lay out thousands of cells.
    /// The last visible cell pulls the next page in, so the whole catalog is
    /// still reachable by scrolling.
    private var results: [String] { Array(matches.prefix(limit)) }

    var body: some View {
        // One container, search bar docked on top of its own grid — two separate
        // rounded boxes read as two text fields next to the name field above.
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.inkTertiary)
                TextField("Search \(ToolIcons.all.count) icons — “download”, “doc”, “heart”", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.ink)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)

            Rectangle().fill(FlowTheme.hairline).frame(height: 1)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(results, id: \.self) { name in
                        let isSelected = name == selection
                        Button { selection = name } label: {
                            Image(systemName: name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(isSelected ? .white : FlowTheme.inkSecondary)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? FlowTheme.accent : Color.white.opacity(0.05))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        // ponytail: last-cell onAppear instead of a scroll-offset
                        // observer — .onScrollTargetVisibilityChange is macOS 15.
                        .onAppear {
                            guard name == results.last, results.count < matches.count else { return }
                            limit += Self.pageSize
                        }
                    }
                }
                .padding(8)
                if results.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .padding(10)
                }
            }
            .frame(height: height)
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        .onChange(of: query) { _, newValue in
            matches = ToolIcons.matching(newValue)
            limit = Self.pageSize
        }
    }
}

/// The frame and surface that make this panel a modal, or let it be a pane.
///
/// Its own modifier so the switch is one place rather than five ternaries
/// threaded through the body — and so the sheet's appearance stays literally
/// the lines it always was, which is what makes un-sheeting a change to where
/// the panel is shown rather than to how it looks.
private struct ToolEditorChrome: ViewModifier {
    let chrome: ToolEditorPanel.Chrome

    func body(content: Content) -> some View {
        switch chrome {
        case .sheet:
            content
                .frame(width: 640, height: 620)
                .background(Color(white: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(FlowTheme.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        case .inline:
            // No fill, no shadow: the page underneath already is a surface, and
            // a card inside a card is DESIGN.md §4's one layout rule.
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
