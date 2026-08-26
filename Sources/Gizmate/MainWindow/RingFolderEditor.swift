import AppKit
import SwiftUI

/// Names a sub-ring and picks its glyph. Deliberately small: a folder has no
/// behaviour of its own, so there is nothing else to configure here — what it
/// does is decided by what you put inside it, back on the Ring diagram.
struct RingFolderEditorPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// nil creates a folder for `assignTo`; non-nil renames an existing one.
    let folderID: UUID?
    let assignTo: RingSlotAddress?

    @State private var name = ""
    @State private var symbolName = RingFolder.defaultSymbolName
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    private var existing: RingFolder? {
        folderID.flatMap { bridge.ringLayout.folder($0) }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            Divider().background(FlowTheme.hairline)
            fields
            Divider().background(FlowTheme.hairline)
            footer
        }
        .frame(width: 560, height: 480)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear {
            // Only on the first pass: re-running this on a redraw would undo
            // whatever the user has typed since.
            guard !loaded else { return }
            loaded = true
            if let existing {
                name = existing.name
                symbolName = existing.symbolName
            }
            nameFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(existing == nil ? "New sub-ring" : "Rename sub-ring")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text("A sub-ring is a button that holds a ring of its own — hovering it fans the buttons inside out.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .plainButton()
            .help("Close")
            .accessibilityLabel("Close sub-ring editor")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The button as the ring will draw it, so the icon choice is judged at the
    /// size it actually ships at rather than in the grid.
    private var preview: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Circle().strokeBorder(FlowTheme.hairline, lineWidth: 1)
                Circle().strokeBorder(FlowTheme.hairline, lineWidth: 1).padding(-5)
                Image(systemName: resolved(symbolName))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
            }
            .frame(width: 46, height: 46)
            .padding(5)

            Text(trimmedName.isEmpty ? "Untitled sub-ring" : trimmedName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(trimmedName.isEmpty ? FlowTheme.inkTertiary : FlowTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Sub-ring name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)
                .focused($nameFocused)
                .onSubmit { if canSave { save() } }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))

            IconGrid(selection: $symbolName, height: 190)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            SecondaryButton(title: "Cancel") { dismiss() }
            Button(action: save) {
                Text(existing == nil ? "Create" : "Save")
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
            .plainButton()
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func save() {
        guard canSave else { return }
        if let existing {
            bridge.ringLayout.updateFolder(existing.id, name: trimmedName, symbolName: symbolName)
        } else if let assignTo {
            bridge.ringLayout.addFolder(
                name: trimmedName,
                symbolName: symbolName,
                to: assignTo.index,
                in: assignTo.path
            )
        }
        dismiss()
    }

    /// Same fallback the saved folder applies, so the preview can't show a
    /// glyph the ring would refuse to draw.
    private func resolved(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            ? name
            : RingFolder.defaultSymbolName
    }

    private func dismiss() {
        nameFocused = false
        bridge.closeRingSheet()
    }
}
