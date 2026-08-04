import AppKit
import CryptoKit
import GizmateToolAgentCore
import SwiftUI

enum ToolEditorDraftVerification {
    static func fingerprint(tool: GizmateTool, script: String, brief: String) -> String {
        var effectiveTool = tool
        effectiveTool.brief = brief
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = (try? encoder.encode(effectiveTool)) ?? Data()
        payload.append(0)
        payload.append(contentsOf: script.utf8)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether saving this draft also approves it for its first run.
    ///
    /// Code that has already run once in front of the user needs no second
    /// consent, whoever pressed the button: Install & test, or the build itself,
    /// which validates a candidate by running it. Anything else — saved without
    /// testing, built without ever being run, or edited since — still meets the
    /// run gate, because nobody has run *this* code yet.
    ///
    /// Only the two kinds that execute something have a gate to skip; a prompt
    /// or a native action never had one.
    static func savingApproves(
        kind: ToolKind,
        ranFingerprint: String?,
        current: String
    ) -> Bool {
        guard kind == .python || kind == .agent else { return false }
        return ranFingerprint == current
    }
}

/// Draft-based tool editor: nothing reaches the store until Save, so Cancel and
/// Escape are always safe. Three modes behind one panel — a prompt the model
/// runs, a macOS action from a fixed catalog, or a Python script uv runs.
struct ToolEditorPanel: View {
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
    let assignTo: RingSlotAddress?

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
    @State private var showIconPicker = false
    @State private var readyDraftFingerprint: String?
    /// Mirrors `draft.options` with stable per-row identity for `optionsEditor`.
    /// See `OptionRow` for why an array index can't serve as that identity.
    @State private var optionRows: [OptionRow] = []

    private var isNew: Bool { toolID == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isNew {
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
        .frame(width: 640, height: 620)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear(perform: loadOnce)
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
        bridge.closeRingSheet()
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New gizmo" : "Edit gizmo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
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
            if page == .details {
                Text("Exact settings")
                    .font(.system(size: 10.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
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
            SecondaryButton(title: "Cancel") { dismiss() }
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

    private var headerSubtitle: String {
        if page == .overview {
            return isNew ? "Build it with Gizmate" : "Edit it with Gizmate"
        }
        return Self.subtitle(for: draft.kind)
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

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            summaryCard

            editorSection(
                "General",
                subtitle: "How this gizmo appears in your Ring."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    nameAndIcon
                    kindPicker
                }
            }

            editorSection(
                "Options",
                subtitle: "Variants this gizmo offers. The Ring shows them as a "
                    + "second orbit behind its button, and the first one is used "
                    + "when you run the gizmo from a shortcut."
            ) {
                optionsEditor
            }

            switch draft.kind {
            case .prompt:
                editorSection(
                    "Instruction",
                    subtitle: "The exact prompt Gizmate sends to your current model."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        promptField
                        languageToggle
                    }
                }
                editorSection(
                    "Result",
                    subtitle: "Where the gizmo's answer goes."
                ) {
                    resultPicker
                }
                editorSection(
                    "Your context",
                    subtitle: "What this gizmo knows about you before it starts."
                ) {
                    contextToggles
                }
            case .native:
                editorSection(
                    "Action",
                    subtitle: "A fixed macOS action. No script is executed."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        actionPicker
                        if draft.nativeAction.targetLabel != nil {
                            targetField
                        }
                    }
                }
                if draft.nativeAction.usesInput {
                    editorSection(
                        "Input",
                        subtitle: "What the action receives."
                    ) {
                        inputPicker
                    }
                }
            case .python:
                editorSection(
                    "Script",
                    subtitle: "Review the exact code that will run."
                ) {
                    scriptField
                }
                editorSection(
                    "Input and result",
                    subtitle: "What the script receives, and where its output goes."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        inputPicker
                        resultPicker
                        if draft.output == .files {
                            outputDirectoryField
                        }
                    }
                }
                editorSection(
                    "Runtime",
                    subtitle: "Set the time limit and declare network use."
                ) {
                    scriptSettings
                }
                editorSection(
                    "Secrets",
                    subtitle: "Keys this script may read from its environment. "
                        + "It gets the ones ticked here and nothing else."
                ) {
                    ToolSecretsPicker(selection: $draft.secretNames)
                }
                editorSection(
                    "Test before saving",
                    subtitle: "Run this exact version once and inspect its output."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        consentNotice
                        testSection
                    }
                }
            case .agent:
                editorSection(
                    "Instruction",
                    subtitle: "What the agent should accomplish. It decides how, "
                        + "one step at a time."
                ) {
                    promptField
                }
                editorSection(
                    "Input and result",
                    subtitle: "What it starts from, and where its answer goes."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        inputPicker
                        resultPicker
                    }
                }
                editorSection(
                    "Your context",
                    subtitle: "What this gizmo knows about you before it starts."
                ) {
                    contextToggles
                }
                editorSection(
                    "Limits",
                    subtitle: "The only bound on a gizmo whose steps nobody can "
                        + "read in advance."
                ) {
                    agentSettings
                }
                editorSection(
                    "Secrets",
                    subtitle: "Keys the agent's scripts may read from their "
                        + "environment. They get the ones ticked here and nothing else."
                ) {
                    ToolSecretsPicker(selection: $draft.secretNames)
                }
                editorSection(
                    "What you are agreeing to",
                    subtitle: "Read this before you save."
                ) {
                    agentConsentNotice
                }
            }
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

    private func editorSection<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FlowTheme.hairline)
                .frame(height: 1)
                .offset(y: -12)
        }
    }

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
        if let assignTo {
            bridge.ringLayout.assign(.tool(tool.id), to: assignTo.index, in: assignTo.path)
        }
        dismiss()
    }

    // MARK: - Shared fields

    private var nameAndIcon: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                fieldLabel("Name", hint: "Shown when you hover over the Ring button.")
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

            VStack(alignment: .leading, spacing: 9) {
                fieldLabel("Icon")
                HStack(spacing: 10) {
                    Image(systemName: draft.resolvedSymbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlowTheme.ink)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(FlowTheme.subtleFill))
                    // The exact identifier stays reachable on hover, for the one
                    // person who wants to search for it or type it somewhere.
                    Text(ToolIcons.displayName(for: draft.resolvedSymbolName))
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(draft.resolvedSymbolName)
                    Spacer(minLength: 0)
                    Button(showIconPicker ? "Done" : "Change") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showIconPicker.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.accent)
                }
                if showIconPicker {
                    IconGrid(selection: $draft.symbolName, height: 108)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// The builder normally decides the kind, but a tool is not locked into what
    /// it was generated as — and without this there is no way to write an agent
    /// tool by hand at all.
    ///
    /// On its own line rather than in a `SettingRow`: four pills are `.fixedSize`
    /// at `minWidth: 78` each, so they demand ~320pt that they will not give
    /// back. Sharing a row with a label and a sentence pushed the panel's whole
    /// content wider than the panel and clipped it at both edges. The kind's
    /// explanation is already the panel's subtitle, so there is nothing to
    /// repeat here either.
    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Kind", hint: "What this gizmo does when you press it.")
            PillPicker(
                options: ToolKind.allCases,
                selection: $draft.kind,
                label: { $0.displayName }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Same story as `inputPicker`: a row of pills wide enough for "Save to
    /// notes" leaves `SettingRow`'s label column about one word wide, so the
    /// explanation next to it wraps into a ransom note. A grid takes the full
    /// width and puts the explanation above it, where it has room.
    private var resultPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            wrappingPicker(
                "Result",
                hint: draft.output.explanation,
                options: resultOptions,
                selection: $draft.output,
                label: { $0.displayName }
            )
            // Folded in here rather than added to each of the three sections
            // that show a result picker: it is a detail of one result, and it
            // has to disappear with it.
            if draft.output == .panel {
                panelPlacement
            }
        }
    }

    /// Where this gizmo's result panel opens.
    ///
    /// Kept on the dock rather than on the gizmo, exactly as the built-ins keep
    /// theirs: a placement is an arrangement of the user's screen, not part of
    /// what the tool does. `DockCatalog.placeableIDs` has always counted every
    /// usable gizmo, and `TranslateFlow` already routes a custom mode's panel
    /// through `resultHost(for:)` — this control was the only missing piece.
    private var panelPlacement: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(
                "Panel",
                hint: "Where the answer opens: floating at the cursor, or flush to a screen edge."
            )
            DockPlacementPicker(
                store: bridge.dock,
                itemID: ToolRef.generated(draft.id).storageID
            )
        }
    }

    /// Every kind with something to say may say it any way it likes — a prompt
    /// gizmo that only wants a toast, or a script that reads its answer aloud,
    /// are both real shapes, and guessing which pairings are silly on the
    /// user's behalf was the only thing keeping them apart.
    ///
    /// Action is the exception, and its list is not a taste call: it is exactly
    /// what `runNativeTool` delivers, which is also what the builder protocol
    /// accepts. Offering more than that gave the user a pill that silently did
    /// nothing and a gizmo the chat builder then refused to open.
    ///
    /// Internal rather than private so the parity test can hold the two sides
    /// together.
    static func outputs(for kind: ToolKind) -> [ToolOutput] {
        switch kind {
        case .prompt, .agent, .python:
            return ToolOutput.allCases
        case .native:
            return ToolOutput.allCases.filter { output in
                ToolAgentCandidateOutputV1(rawValue: output.rawValue)
                    .map(ToolAgentCandidateOutputV1.nativeDeliverable.contains) ?? false
            }
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
    private func wrappingPicker<Option: Hashable>(
        _ title: String,
        hint: String?,
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(title, hint: hint)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action mode

    private var actionPicker: some View {
        wrappingPicker(
            "Action",
            hint: draft.nativeAction.explanation,
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
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(
                "Prompt",
                hint: "Write it as an instruction to the model, the way you'd brief a person."
            )
            codeEditor(text: $draft.prompt, lines: 7, monospaced: false)
        }
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
                subtitle: "Writes in your register, with your cleanup level, dictionary, and snippets."
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
            HStack(alignment: .bottom) {
                fieldLabel(
                    "Python script",
                    hint: "A PEP 723 header declares the dependencies; the input arrives as command-line arguments."
                )
                Spacer(minLength: 12)
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
            }
            codeEditor(text: $script, lines: 16, monospaced: true)
            if !scriptIsEmpty, !script.contains("# /// script") {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("No `# /// script` header, so uv won't install any dependencies. This field takes Python, not a shell command.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.42))
            }
        }
    }

    private var scriptIsEmpty: Bool {
        script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seven inputs, with labels as long as "Text on screen" — far past what a
    /// pill row fits, which is what pushed the whole panel wider than itself.
    private var inputPicker: some View {
        wrappingPicker(
            "Input",
            hint: "What the gizmo is handed when it runs.",
            options: ToolInput.allCases,
            selection: $draft.input,
            label: { $0.displayName }
        )
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
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.42))
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
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.42))
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
enum ToolTestState {
    case idle
    case running
    case passed(String)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailure: Bool { if case .failed = self { return true }; return false }

    var report: String? {
        switch self {
        case .idle: return nil
        // The editor shows live output while running, so this is only a fallback.
        case .running: return nil
        case .passed(let text), .failed(let text): return text
        }
    }
}

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
