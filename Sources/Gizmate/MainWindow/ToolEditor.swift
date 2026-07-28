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
    let assignTo: Int?

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
    @State private var generateTask: Task<Void, Never>?
    @State private var chatComposer = ""
    @StateObject private var chat = ToolBuilderChatSession()
    @FocusState private var nameFocused: Bool
    @State private var stage: EditorStage = .new
    @State private var page: EditorPage = .overview
    @State private var showIconPicker = false
    @State private var readyDraftFingerprint: String?

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
                    onSave: save
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
        .onChange(of: currentDraftFingerprint) { _, fingerprint in
            draftDidChange(to: fingerprint)
        }
    }

    /// The one way out of this panel. Hands the first responder back to the window
    /// and kills anything still in flight — a running test (which also kills its
    /// process tree), a generation, and the elapsed-time ticker, which would
    /// otherwise loop for the rest of the session.
    private func dismiss() {
        nameFocused = false
        cancelInFlightWork()
        NSApp.windows.first { $0 is MainWindow }?.makeFirstResponder(nil)
        bridge.ringSheet = nil
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
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New tool" : "Edit tool")
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
            .accessibilityLabel("Close tool editor")
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
                            .fill(FlowTheme.accent)
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
                Text(draft.name.isEmpty ? "Untitled tool" : draft.name)
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
        var parts = [draft.trigger.summary]
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
                subtitle: "How this tool appears in your Ring."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    nameAndIcon
                }
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
                    "Availability and result",
                    subtitle: "Choose when the tool appears and where its answer goes."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        triggerPicker
                        resultPicker
                    }
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
                editorSection(
                    "Availability and input",
                    subtitle: "Choose when the action appears and what it receives."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        triggerPicker
                        if draft.nativeAction.usesInput {
                            inputPicker
                        }
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
                    "Availability and result",
                    subtitle: "Choose when the script appears, its input, and its output."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        triggerPicker
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
                    "Test before saving",
                    subtitle: "Run this exact version once and inspect its output."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        consentNotice
                        testSection
                    }
                }
            }
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
        bridge.tools.save(tool, script: tool.kind == .python ? script : nil)
        if tool.kind == .python {
            // A script that just passed Install & test needs no second consent:
            // the user pressed a button that ran this exact code and read the
            // result. Saving it is the approval. Anything else — saved without
            // testing, or a script edited outside the editor — still has to pass
            // the run gate the first time, because nobody has run it yet.
            if case .passed = test,
               passedTestFingerprint == currentDraftFingerprint {
                ToolApprovals.approve(tool.id, hash: bridge.tools.scriptHash(for: tool.id))
            } else {
                ToolApprovals.revoke(tool.id)
            }
        } else {
            ToolApprovals.revoke(tool.id)
        }
        if let assignTo {
            bridge.ringLayout.assign(.tool(tool.id), to: assignTo)
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
                    Text(draft.symbolName)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(FlowTheme.inkSecondary)
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

    private var resultPicker: some View {
        SettingRow("Result", subtitle: draft.output.explanation) {
            PillPicker(
                options: draft.kind == .prompt ? Self.promptOutputs : ToolOutput.allCases,
                selection: $draft.output,
                label: { $0.displayName }
            )
        }
    }

    /// A prompt tool only ever produces text, so `files` and `notify` aren't offered.
    private static let promptOutputs: [ToolOutput] = [.panel, .replace, .clipboard]

    // MARK: - Action mode

    private var actionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Action", hint: draft.nativeAction.explanation)
            // A wrapping grid rather than a pill row: six actions don't fit on
            // one line at the panel's width.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(NativeAction.allCases, id: \.self) { action in
                    let isSelected = draft.nativeAction == action
                    Button { draft.nativeAction = action } label: {
                        Text(action.displayName)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : FlowTheme.inkSecondary)
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
            subtitle: "Leave this off for tools that transform text rather than translate it."
        ) {
            Toggle("", isOn: $draft.appliesTargetLanguage)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
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
        stage = .ready
        page = .overview
        test = .idle
        passedTestFingerprint = nil
        runningTestFingerprint = nil
        liveOutput = ""
    }

    private func candidateReady(_ name: String) {
        readyDraftFingerprint = currentDraftFingerprint
        chat.candidateReady(name, note: generatedAssurance?.explanation)
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

    private var triggerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Shows up", subtitle: draft.trigger.summary) {
                PillPicker(
                    options: TriggerChoice.allCases,
                    selection: Binding(
                        get: { TriggerChoice(draft.trigger) },
                        set: { draft.trigger = $0.trigger(keeping: draft.trigger) }
                    ),
                    label: { $0.displayName }
                )
            }
            switch draft.trigger {
            case .clipboardURL(let hosts):
                filterField(
                    placeholder: "youtube.com, youtu.be — blank for any link",
                    values: hosts,
                    onChange: { draft.trigger = .clipboardURL(hosts: $0) }
                )
            case .files(let extensions):
                filterField(
                    placeholder: "heic, png — blank for any file",
                    values: extensions,
                    onChange: { draft.trigger = .files(extensions: $0) }
                )
            case .always, .selectionNotEmpty:
                EmptyView()
            }
        }
    }

    private var inputPicker: some View {
        SettingRow("Input", subtitle: "What the script is handed when it runs.") {
            PillPicker(
                options: ToolInput.allCases,
                selection: $draft.input,
                label: { $0.displayName }
            )
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

    private var consentNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.42))
            Text("A script tool runs real code with your account's access. What you set above is shown to you before each new version runs — it is not a restriction Gizmate enforces. Read the code before you allow it.")
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
            if case .passed = outcome {
                passedTestFingerprint = fingerprint
            } else {
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

    /// Comma-separated list bound to a `[String]`, for host and extension filters.
    private func filterField(
        placeholder: String,
        values: [String],
        onChange: @escaping ([String]) -> Void
    ) -> some View {
        TextField(placeholder, text: Binding(
            get: { values.joined(separator: ", ") },
            set: { raw in
                onChange(
                    raw.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
            }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(FlowTheme.ink)
        .padding(.vertical, 7)
        .padding(.horizontal, 11)
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

/// Flat, pill-friendly view of `ToolTrigger`, which carries lists the picker
/// can't express. Switching keeps whatever filter the previous case held.
private enum TriggerChoice: String, CaseIterable {
    case always, selection, link, files

    init(_ trigger: ToolTrigger) {
        switch trigger {
        case .always: self = .always
        case .selectionNotEmpty: self = .selection
        case .clipboardURL: self = .link
        case .files: self = .files
        }
    }

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .selection: return "Selection"
        case .link: return "Copied link"
        case .files: return "Copied files"
        }
    }

    func trigger(keeping previous: ToolTrigger) -> ToolTrigger {
        switch self {
        case .always:
            return .always
        case .selection:
            return .selectionNotEmpty
        case .link:
            if case .clipboardURL = previous { return previous }
            return .clipboardURL(hosts: [])
        case .files:
            if case .files = previous { return previous }
            return .files(extensions: [])
        }
    }
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 12)

    private var results: [String] {
        // Capped so a one-letter query doesn't try to lay out thousands of cells.
        Array(ToolIcons.matching(query).prefix(600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))

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
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        }
    }
}
