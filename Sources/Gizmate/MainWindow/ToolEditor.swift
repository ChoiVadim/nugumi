import AppKit
import CryptoKit
import GizmateToolAgentCore
import SwiftUI

/// What a gizmo *is*, as a modal: its name, icon, kind, trigger, script and
/// the fields each kind needs. Draft-based, so nothing reaches the store until
/// Save and both Cancel and Escape are always safe.
///
/// What a gizmo *does* is not here. This panel used to carry a builder chat of
/// its own on a "Chat" tab, opened by a `+` in Home's rail, and it said "tell me
/// what you want to happen" beside a chat that was already asking exactly that.
/// Two builders meant two transcripts, two clarification paths and two places a
/// half-built gizmo could be lost. There is one, and it is Home's.
struct ToolEditorPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// The gizmo this panel is editing, owned by `GizmoBuilder` rather than by
    /// this view. Handed in for the reason every store here is: a view's own
    /// state dies with the view, and this one has to survive the panel closing
    /// and be the same object the chat is editing.
    @ObservedObject var gizmo: GizmoDraft
    /// Observed, not reached for through `bridge`: "Fix it" hands the repair to
    /// the one builder, and this panel has to redraw while that build runs.
    @ObservedObject var builder: GizmoBuilder

    private var toolID: UUID? {
        if case .existing(let id) = gizmo.subject { return id }
        return nil
    }

    @FocusState private var nameFocused: Bool
    /// Which detail row is expanded, keyed by its title. One at a time: the
    /// closed rows are the only thing that keeps the whole configuration on one
    /// screen, so opening a second by closing the first is the point, not a
    /// restriction.
    @State private var openRow: String?
    /// Mirrors `draft.options` with stable per-row identity for `optionsEditor`.
    /// See `OptionRow` for why an array index can't serve as that identity.
    @State private var optionRows: [OptionRow] = []

    // The draft's fields under the names the form already uses, so six hundred
    // lines of controls below did not have to move to follow it.
    private var draft: GizmateTool {
        get { gizmo.draft }
        nonmutating set { gizmo.draft = newValue }
    }
    private var script: String {
        get { gizmo.script }
        nonmutating set { gizmo.script = newValue }
    }
    private var brief: String {
        get { gizmo.brief }
        nonmutating set { gizmo.brief = newValue }
    }
    private var test: ToolTestState { gizmo.test }
    private var liveOutput: String { gizmo.liveOutput }
    private var elapsed: Int { gizmo.elapsed }
    private var generatedSummary: String? { gizmo.summary }
    private var generatedAssurance: ToolAgentAssuranceV1? { gizmo.assurance }

    // A computed property has no `$`, so the fifteen bindings below name these
    // instead. Dynamic member lookup gives `draftBinding.name` the same
    // `Binding<String>` `draftBinding.name` did.
    private var draftBinding: Binding<GizmateTool> {
        Binding(get: { gizmo.draft }, set: { gizmo.draft = $0 })
    }
    private var scriptBinding: Binding<String> {
        Binding(get: { gizmo.script }, set: { gizmo.script = $0 })
    }

    /// Whether the one builder is working on *this* gizmo. A build on another
    /// one must not grey this panel's fields out.
    private var generating: Bool { builder.isBuilding && builder.live === gizmo }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(FlowTheme.hairline)
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
        .frame(width: 640, height: 620)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        // Closer to the focused field than the overlay's own handler, so this
        // one gets Escape first.
        .onExitCommand(perform: escapePressed)
        .onChange(of: currentDraftFingerprint) { _, fingerprint in
            draftDidChange(to: fingerprint)
        }
    }

    /// The one way out of this panel, which no longer stops anything.
    ///
    /// A repair belongs to the builder and a test belongs to the draft, and both
    /// outlive this view on purpose: closing the fields to go and read the chat
    /// must not throw away work that takes minutes.
    private func dismiss() {
        nameFocused = false
        bridge.closeRingSheet()
    }

    /// Escape stops the work first and closes second. A repair runs for minutes,
    /// so spending the same key on both means one reflex press throws it away.
    /// Nothing in flight, and the press closes, as it always did.
    private func escapePressed() {
        guard generating || test.isRunning else {
            dismiss()
            return
        }
        stopBuilding()
    }

    /// Both cancellations reach real work: the repair unwinds through the agent
    /// supervisor, the test kills the tool's process tree. Each reports its own
    /// stop into the chat when it lands, so nothing is said here that the
    /// outcome might contradict.
    private func stopBuilding() {
        builder.stop()
        gizmo.cancelRun()
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

    private var hasTool: Bool { gizmo.hasTool }

    /// The header names the gizmo, always. It used to say "Edit gizmo" while a
    /// chat tab existed to be edited *in*; this panel only ever opens on one
    /// that exists, so the name and what it does are the two things worth the
    /// space.
    private var showsIdentity: Bool { hasTool }

    private var headerTitle: String {
        guard hasTool else { return "Gizmo" }
        return draft.name.isEmpty ? "Untitled gizmo" : draft.name
    }

    private var headerSubtitle: String {
        hasTool ? behaviourLine : "Nothing to edit yet."
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
                    IconGrid(selection: draftBinding.symbolName, height: 108)
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
                        selection: draftBinding.kind,
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
                rowDivider
                detailRow(
                    "Shortcut",
                    value: toolShortcut?.displayString ?? "None",
                    hint: draft.output == .surface
                        ? "A global key that opens this gizmo on its edge."
                        : "A global key that runs this gizmo from anywhere, no Ring needed."
                ) {
                    shortcutControls
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
                        ToolSecretsPicker(selection: draftBinding.secretNames)
                    }
                    rowDivider
                    detailRow(
                        "Your context",
                        value: contextValue,
                        hint: "What this script is handed about you when it runs."
                    ) {
                        notesToggle(subtitle: "Hands the script the notes you ticked, as a JSON file it can read.")
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
                        ToolSecretsPicker(selection: draftBinding.secretNames)
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

    private var canSave: Bool { gizmo.canSave }

    private var currentDraftFingerprint: String { gizmo.fingerprint }

    /// The chat's half of invalidation. Everything about the draft itself —
    /// a passed test, a run in flight, the standing a build earned — is
    /// `GizmoDraft.invalidate`, where an edit cannot route around it.
    private func draftDidChange(to fingerprint: String) {
        guard !gizmo.candidateIsFresh else { return }
        builder.chat.markCandidateStale()
    }

    private func save() {
        guard gizmo.save() != nil else { return }
        // The saved gizmo reopens from the store rather than from what was
        // typed before it, which is what discarding buys.
        bridge.host?.gizmoBuilder.discard(gizmo.subject)
        dismiss()
    }

    // MARK: - Shared fields

    /// Sparse on purpose: unlike a built-in there is no default to fall back
    /// to, so nil honestly means "no key".
    private var toolShortcut: GlobalShortcut? {
        bridge.settings.toolShortcuts[draft.id]
    }

    /// Mirrors `BuiltInEditorPanel.shortcutRow`, plus the Remove a built-in
    /// never needs — a built-in's key can only be changed, a gizmo's can also
    /// not exist.
    private var shortcutControls: some View {
        HStack(spacing: 8) {
            if let shortcut = toolShortcut {
                KeyCap(text: shortcut.displayString)
                SecondaryButton(title: "Change") {
                    bridge.perform(.recordToolShortcut(draft.id))
                }
                .padding(.leading, 4)
                SecondaryButton(title: "Remove") {
                    bridge.perform(.clearToolShortcut(draft.id))
                }
            } else {
                SecondaryButton(title: "Set shortcut") {
                    bridge.perform(.recordToolShortcut(draft.id))
                }
            }
        }
    }

    private var nameField: some View {
        TextField(draft.kind == .prompt ? "To JSON" : "Download video", text: draftBinding.name)
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
                selection: draftBinding.output,
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
            selection: draftBinding.nativeAction,
            label: { $0.displayName }
        )
    }

    private var targetField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(draft.nativeAction.targetLabel ?? "Target")
            TextField(draft.nativeAction.targetPlaceholder, text: draftBinding.target)
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
        codeEditor(text: draftBinding.prompt, lines: 7, monospaced: false)
    }

    private var languageToggle: some View {
        SettingRow(
            "Write the answer in the target language",
            subtitle: "Leave this off for gizmos that transform text rather than translate it."
        ) {
            Toggle("", isOn: draftBinding.appliesTargetLanguage)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
        }
    }

    /// The two context toggles, offered to `.prompt` and `.agent` gizmos. A
    /// script gets only the notes one (`notesToggle`): it has no model to
    /// style, and a macOS action has nothing to hand context to at all.
    private var contextToggles: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingRow(
                "Use my Voice",
                subtitle: "Writes in your register, with your dictionary and snippets."
            ) {
                Toggle("", isOn: draftBinding.usesVoice)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }
            notesToggle(subtitle: "Hands it the notes you ticked in the Notes tab as background.")
        }
    }

    private func notesToggle(subtitle: String) -> some View {
        SettingRow("Use my notes", subtitle: subtitle) {
            Toggle("", isOn: draftBinding.usesNotes)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
        }
    }

    // MARK: - Script mode

    /// "Fix it" hands the failure to the one builder.
    ///
    /// This panel used to run its own repair, with its own agent call, its own
    /// generation task and its own chat session to narrate into. That session
    /// was the second transcript, and it was the one nobody could answer: a
    /// repair that stopped to ask a question posted it into a chat this panel
    /// no longer draws, and waited forever.
    ///
    /// Through the builder, the same question lands in Home's chat, where there
    /// is a composer to answer it, and the result applies to this very draft
    /// because the builder is the one that made it.
    private func repairScript() {
        guard case .failed(let failure) = test else { return }
        builder.startRepair(gizmo, failure: failure)
    }

    private var scriptField: some View {
        VStack(alignment: .leading, spacing: 10) {
            codeEditor(text: scriptBinding, lines: 14, monospaced: true)
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
            selection: draftBinding.input,
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
                Toggle("", isOn: draftBinding.declaresNetwork)
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
                        gizmo.cancelRun()
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
    private var reportText: String? { gizmo.reportText }

    private var runHint: String {
        if test.isRunning {
            return "Stops itself at the \(draft.timeoutSeconds)s limit."
        }
        return bridge.uvReady
            ? "Runs the script once, right now, on your real input."
            : "First run also downloads the uv runtime (about 35 MB)."
    }

    /// Runs the draft and tells the chat what happened. The run itself is the
    /// draft's, including the guard that discards a verdict about code that has
    /// since changed; what is left here is the half that speaks.
    private func runTest() {
        let chat = builder.chat
        // The ready card hides while this runs, so without a line here the chat
        // shows a spinner over whatever internal step happened to run last.
        chat.recordActivity("Running it once, for real…")
        Task { @MainActor in
            guard let outcome = await gizmo.runTest() else { return }
            let trialing = chat.trial != .notNeeded
            switch outcome {
            case .passed:
                if trialing { chat.trialFinished(passed: true) }
            case .failed(let report) where trialing:
                // Keep the card up: a failed trial is where "Fix it" belongs,
                // and it hands the agent the real diagnostics instead of making
                // the user retype them.
                chat.trialFinished(passed: false, report: report)
            default:
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

