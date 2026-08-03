import SwiftUI

/// Notes, sized for a dock rather than a settings window.
///
/// `NotesSection` cannot be reused here: it is built around `DetailContainer`
/// with a title, subtitle, pinned tag bar and a `PageBanner`, which in a 360pt
/// panel is a screenful of chrome before the first note. This shows the same
/// `NotesStore` — no second source of truth — with only what fits: write one,
/// find a recent one, and a way through to the full list.
struct DockNotesView: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    /// `nil` is All. Holding the tag's id rather than an index keeps the
    /// selection pointing at the same tag when tags are added or removed —
    /// the same reasoning `NotesSection` uses.
    @State private var selectedTagID: UUID?
    @State private var draft: String = ""
    @State private var editingNoteID: UUID?

    private static let recentLimit = 20

    private var tags: [NoteTag] { bridge.notes.tags }

    private var visibleNotes: [Note] {
        bridge.notes.notes
            .filter(\.isUsable)
            .filter { selectedTagID == nil || $0.tagID == selectedTagID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.recentLimit)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            composer
            if !tags.isEmpty { tagChips }
            Divider().background(FlowTheme.hairline)
            noteList
            footer
        }
        .padding(14)
        .foregroundStyle(FlowTheme.ink)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(FlowTheme.inkTertiary)
                .font(.system(size: 12))
                .padding(.top, 2)
            TextField("Write a note", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .onSubmit(saveDraft)
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: saveDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(FlowTheme.accentBright)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
    }

    private func saveDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        bridge.notes.add(text: text, tagID: selectedTagID)
        draft = ""
    }

    // MARK: - Tags

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(symbol: "tray.full", title: "All", id: nil)
                ForEach(tags) { tag in
                    chip(symbol: tag.ringSymbol, title: tag.name, id: tag.id)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private func chip(symbol: String, title: String, id: UUID?) -> some View {
        let selected = selectedTagID == id
        return Button {
            selectedTagID = id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? FlowTheme.ink : FlowTheme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? FlowTheme.raised : FlowTheme.subtleFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var noteList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if visibleNotes.isEmpty {
                    Text("Nothing kept here yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .padding(.vertical, 8)
                }
                ForEach(visibleNotes) { note in
                    row(for: note)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(for note: Note) -> some View {
        if editingNoteID == note.id {
            TextEditor(text: Binding(
                get: { note.text },
                set: { bridge.notes.update(note.id, text: $0) }
            ))
            .font(.system(size: 12))
            .frame(minHeight: 70)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .onExitCommand { editingNoteID = nil }
        } else {
            Button {
                editingNoteID = note.id
            } label: {
                HStack(spacing: 8) {
                    Text(note.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(note.updatedAt, format: .relative(presentation: .numeric))
                        .font(.system(size: 10))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            bridge.host?.presentMainWindow(section: .notes)
        } label: {
            HStack(spacing: 4) {
                Text("All notes").font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.up.right").font(.system(size: 9))
            }
            .foregroundStyle(FlowTheme.inkSecondary)
        }
        .buttonStyle(.plain)
    }
}
