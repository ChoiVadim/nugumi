import AppKit
import GizmateToolAgentCore
import SwiftUI

/// The built-in edge dock item for dragging a file straight out of a folder.
///
/// Deliberately not a gizmo: a folder listing is `FileManager`, not an
/// arbitrary data source, so the script/agent/approval machinery a gizmo
/// carries would buy nothing here and would cost a cold start every time the
/// pointer nears the edge. This view is a sibling of `DockNotesView` — same
/// chip row, same `+`, same reuse of `SurfaceView` a `.surface` gizmo already
/// draws through, per `DESIGN.md` §12.
struct FolderHubView: View {
    @ObservedObject var store: FolderHubStore

    /// The chip in the header — the folder the user added, and the root of
    /// whatever is being browsed under it.
    @State private var selected: URL?
    /// The folder actually listed: `selected`, or a descendant of it after a
    /// double-click walked in. Separate from `selected` so back has a floor —
    /// you can only ever descend from a chip, so trimming one path component
    /// at a time can never climb above the folder that was added, and there is
    /// no trail to keep in step with anything.
    @State private var current: URL?
    @State private var rows: [SurfaceRow]
    /// The chip a double-click armed for removal, by path. At most one: arming
    /// a second disarms the first for free, since one string can only hold one.
    @State private var armedChip: String?
    /// The chip under the pointer, by path — the only thing that gives an
    /// unselected chip a background. Shared by chips and crumbs; a path
    /// identifies either one, and only one of the two rows is ever on screen.
    @State private var hoveredChip: String?
    /// The cards lit for a drag, by row id. Cleared whenever the listing
    /// changes: an id that is no longer on screen would keep contributing a
    /// file to every drag from a folder it isn't even in.
    @State private var selectedFiles: Set<String> = []
    /// Why the last thing the user did to a file did not work. Cleared by the
    /// next one that does, so a stale complaint never outlives what it was
    /// about. Shared by dropping in and trashing: both act on the same files
    /// and fail for the same reasons, and two lines saying "that did not work"
    /// in the same place would be one line too many.
    @State private var problem: String?
    @State private var isDropTargeted = false
    /// Watches for ⌘⌫ while this hub's dock holds the keyboard. A monitor
    /// rather than `.onKeyPress`, which needs focus, and a grid of cards that
    /// takes focus is a grid whose clicks start fighting the focus ring.
    @State private var trashKeyMonitor: KeyMonitorBox = KeyMonitorBox()
    /// Notices what the folder does on its own. A dock rebuilds this view every
    /// time it opens, so an unpinned hub was always current by accident; a
    /// pinned one sat there showing a download that had finished ten minutes
    /// ago.
    @State private var watch: FolderWatch = FolderWatch()

    /// The one layout this hub ever draws — declared once rather than built
    /// per render, the same way a gizmo's candidate layout is decoded once
    /// and reused across refreshes.
    /// No size line, deliberately. A cell is square and roughly 110pt wide, so
    /// the two lines it can spend go to the preview or to the metadata, not
    /// both — and you pick a file out of a shelf by recognising it, not by its
    /// byte count. The rows still carry `size` for anything that wants it.
    private static let layout: ToolAgentLayoutV1 = .grid(
        cell: .card(.init(
            title: .key("name"),
            icon: .file(key: "path"),
            drag: .file(key: "path")
            // No layout tap: what a click does here depends on what was
            // clicked — a file opens, a folder is walked into — and a layout
            // action is bound to a row, not to the hub's own position in a
            // tree. `activate` below does both, on double-click.
        )),
        minimumWidth: 96,
        empty: "Nothing here yet."
    )

    /// Rounded, not a capsule: fully round ends read as a tag — something the
    /// content is labelled with — and these are buttons you press. Continuous
    /// curvature and 8pt keeps them the same family as the 10pt cards below,
    /// a notch tighter for a control two-thirds their height.
    private static let chipShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    /// Seeded synchronously, the same reasoning `SurfaceHostView` gives for
    /// seeding `rows` from its cache in `init`: a folder listing costs
    /// milliseconds, so there is no reason to show an empty grid for even one
    /// frame before the real contents land.
    init(store: FolderHubStore) {
        self.store = store
        let initial = store.folders.first
        _selected = State(initialValue: initial)
        // Every open builds a fresh view (`EdgeDockController.expandedView`
        // calls `makeView()` each time it expands), so a hub always opens at
        // the chip's own folder rather than wherever the last visit wandered.
        _current = State(initialValue: initial)
        _rows = State(initialValue: initial.map { FolderHubRows.rows(in: $0, limit: FolderHubRows.defaultLimit) } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A folder listing never fails to refresh — it's a synchronous
            // `FileManager` read, not a script that can be unapproved, throw,
            // or exit non-zero — so there is no failure caption to show.
            SurfaceView(layout: Self.layout, rows: rows, stale: nil, selectedIDs: selectedFiles)
                .environment(\.surfaceActivate, activate)
                .environment(\.surfaceSelection, SurfaceSelection(
                    isSelected: { selectedFiles.contains($0.id) },
                    click: { row, command in
                        if command {
                            // The only way back to nothing selected — there is
                            // no empty space to click in a grid that fills its
                            // panel, and a shelf you have to close and reopen
                            // to deselect is a shelf with a mode.
                            if selectedFiles.contains(row.id) {
                                selectedFiles.remove(row.id)
                            } else {
                                selectedFiles.insert(row.id)
                            }
                        } else {
                            selectedFiles = [row.id]
                        }
                    },
                    onTrashed: { error in
                        problem = error?.localizedDescription
                        refresh(in: current)
                    },
                    dragURLs: dragURLs
                ))
                // The listing fills the panel, so this is the whole body: a
                // drop anywhere below the chips lands where you are standing,
                // which is `current` rather than `selected` — having walked
                // into a subfolder, that is the folder you are looking at.
                .dropTarget(isTargeted: $isDropTargeted) { accept($0, into: current) }
                // Says where it will land, which a grid that already fills the
                // panel cannot say by highlighting a row: there is no row yet.
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(isDropTargeted ? FlowTheme.ink.opacity(0.5) : .clear)
                        .padding(-4)
                        .allowsHitTesting(false)
                )
                .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        }
        // No padding of its own: the panel holds every resident off the glass
        // by `DockGeometry.contentMargin`, so one here would be doubled.
        .foregroundStyle(FlowTheme.ink)
        // Moving `current` is what loads and re-watches, rather than each
        // caller remembering to. The crumb trail is why: it set `current`
        // directly, and the moment loading lived in `show` instead of here,
        // walking back up the trail moved the crumbs and left the grid showing
        // the folder you had just left.
        .onChange(of: current) { _, folder in
            guard let folder else {
                rows = []
                selectedFiles = []
                watch.stop()
                return
            }
            load(folder, keepingSelection: false)
            watch.start(folder) { reload(folder) }
        }
        .onDisappear { watch.stop() }
        .onAppear {
            trashKeyMonitor.start(trashSelection)
            // `.onChange(of: current)` only fires on a change, and the folder a
            // hub opens on is set in `init`. Without this the very folder you
            // are looking at is the one nobody is watching.
            watch.start(current) { if let folder = current { reload(folder) } }
        }
        .onDisappear { trashKeyMonitor.stop() }
        .onChange(of: store.folders) { _, folders in
            // The selected folder itself may have just been removed by its own
            // armed ✕ — fall back the same way a fresh open would rather than
            // keep rendering a chip that no longer exists.
            guard selected == nil || !folders.contains(where: { $0.path == selected?.path }) else { return }
            // Through the same door as every other move, or the chips fall back
            // to a folder the grid is not showing. `selected` alone moves
            // nothing now: `current` is what loads.
            if let next = folders.first {
                show(next, asRoot: true)
            } else {
                selected = nil
                current = nil
            }
        }
    }

    // MARK: - Header

    /// Folder chips, then the `+` that adds one — the same shape
    /// `DockNotesView.header` uses for tags and its own add button.
    private var header: some View {
        HStack(spacing: 8) {
            if !store.folders.isEmpty { folderChips }
            Spacer(minLength: 0)
            ResetDiscButton(symbol: "plus", label: "", accessibilityTitle: "Add folder") {
                addFolder()
            }
        }
    }

    /// One row, two jobs, never both at once: the folders you added, or the
    /// path you are standing in. Showing the roots beside a trail asks the row
    /// to mean "pick a folder" and "you are here" in the same six chips, and
    /// the trail is the only one of the two that answers a question you have
    /// while you're deep in a folder. The roots come back the moment the trail
    /// collapses to its first crumb.
    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isBrowsingDeeper {
                    ForEach(Array(trail.enumerated()), id: \.element.path) { index, folder in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(FlowTheme.inkTertiary)
                        }
                        crumb(for: folder)
                    }
                } else {
                    ForEach(store.folders, id: \.path) { folder in
                        chip(for: folder)
                            // Straight into that folder, without switching to
                            // it first. Two steps for one intention is what a
                            // shelf exists to remove.
                            .dropTarget { accept($0, into: folder) }
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private var isBrowsingDeeper: Bool { current?.path != selected?.path }

    // MARK: - Throwing out

    /// ⌘⌫ on the selection, Finder's own shortcut for this.
    ///
    /// Nothing happens with an empty selection rather than falling back to
    /// "whatever the pointer is over": a destructive key that acts on something
    /// you did not choose is the one kind of miss the Trash does not excuse.
    private func trashSelection() {
        let urls = rows
            .filter { selectedFiles.contains($0.id) }
            .compactMap { SurfaceCard.path(for: "path", in: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            Task { @MainActor in
                problem = error?.localizedDescription
                refresh(in: current)
            }
        }
    }

    // MARK: - Dropping in

    /// Takes files dropped from anywhere and reports what went wrong if it did.
    ///
    /// Off the main actor because copying a folder is unbounded work, and this
    /// panel is what the drop landed on: a dropped 5GB directory must not
    /// freeze the thing that accepted it. `Option` is read here rather than
    /// passed in — SwiftUI's drop callback carries no modifiers, and the flag
    /// is live for as long as the drag is.
    private func accept(_ urls: [URL], into folder: URL?) {
        guard let folder, !urls.isEmpty else { return }
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try FolderHubDrop.perform(urls, into: folder, optionHeld: optionHeld)
                }.value
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            // Whatever happened, the folder on screen may no longer match the
            // folder on disk — a partial batch lands some of its files.
            refresh(in: current)
        }
    }

    /// The root chip, then every folder walked into on the way here.
    ///
    /// Built by trimming components off `current` rather than by keeping a
    /// stack: a stack is a second copy of where you are, and the two disagree
    /// the first time anything else moves `current`. The loop terminates on
    /// the root's own path because descending is the only way `current` is
    /// ever set — the length guard is what keeps a mismatch from walking to
    /// the volume root instead of hanging.
    private var trail: [URL] {
        guard let root = selected, var url = current else { return [] }
        var crumbs: [URL] = []
        while url.path != root.path, url.path.count > root.path.count {
            crumbs.append(url)
            url = url.deletingLastPathComponent()
        }
        crumbs.append(root)
        return crumbs.reversed()
    }

    /// A step in the trail. Tapping one goes there, which makes the crumb to
    /// the left of the last one the back button — there is no separate arrow
    /// to keep in step with the path any more.
    private func crumb(for folder: URL) -> some View {
        let isCurrent = folder.path == current?.path
        return Button {
            show(folder, asRoot: false)
        } label: {
            HStack(spacing: 4) {
                if folder.path == selected?.path {
                    Image(systemName: "folder").font(.system(size: 9))
                }
                // Capped: a folder saved by a browser is named after a page
                // title, and one of those spends a whole row on its own.
                Text(folder.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .foregroundStyle(isCurrent ? FlowTheme.ink : FlowTheme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.chipShape.fill(fill(here: isCurrent, folder: folder)))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredChip = folder.path
            } else if hoveredChip == folder.path {
                hoveredChip = nil
            }
        }
    }

    /// What a chip or crumb is painted with. Bare is the resting state: a row
    /// of filled capsules is six painted pills saying nothing, and the label
    /// already carries the meaning. A fill has to earn itself — you are
    /// pointing at it, it is where you are, or it is armed to be deleted.
    private func fill(here: Bool, folder: URL) -> Color {
        if armedChip == folder.path { return FlowTheme.danger.opacity(0.18) }
        if here { return FlowTheme.raised }
        return hoveredChip == folder.path ? FlowTheme.subtleFill : .clear
    }

    /// A root folder, and the only place one can be taken off the shelf.
    ///
    /// Removal is two gestures, not one: a double-click arms the chip — red,
    /// with a ✕ — and the ✕ is what actually removes it. A ✕ that appeared on
    /// hover was one stray click away from deleting a folder the user was only
    /// reaching past, and nothing here can be undone: the store saves `[]`
    /// deliberately rather than revive the Downloads default (see `DESIGN.md`
    /// §11). Not a `Button` around the whole capsule, because the ✕ inside is
    /// its own button and a button nested in another button's label never gets
    /// the click.
    private func chip(for folder: URL) -> some View {
        let isSelected = folder.path == selected?.path
        let isArmed = armedChip == folder.path
        return HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 9))
            Text(folder.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            if isArmed {
                // Inserted rather than faded in, unlike a hover affordance:
                // arming is a state the user asked for and is looking at, so
                // the row shifting under a chip that just turned red is the
                // feedback, not a glitch.
                Button {
                    store.remove(folder)
                    armedChip = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(folder.lastPathComponent)")
            }
        }
        .foregroundStyle(isArmed ? FlowTheme.danger : (isSelected ? FlowTheme.ink : FlowTheme.inkSecondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Self.chipShape.fill(fill(here: isSelected, folder: folder)))
        .contentShape(Self.chipShape)
        // Declared before the single tap, which is what lets SwiftUI hand a
        // double click to this one instead of firing the single twice.
        .onTapGesture(count: 2) { armedChip = folder.path }
        .onTapGesture {
            armedChip = nil
            show(folder, asRoot: true)
        }
        // Leaving the chip disarms it: an armed chip left behind is a red
        // capsule sitting in the row with no way back except deleting it.
        .onHover { inside in
            if inside {
                hoveredChip = folder.path
            } else {
                if hoveredChip == folder.path { hoveredChip = nil }
                if isArmed { armedChip = nil }
            }
        }
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to show on the edge."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        store.add(picked)
        // Read back from the store rather than trust `picked` directly: `add`
        // is what decides the canonical form a folder is compared by, and
        // matching it here is what keeps the new chip lit as selected.
        selected = store.folders.first { $0.path == picked.path } ?? picked
    }

    /// Double-click: a file opens in whatever owns it, a folder is browsed in
    /// place. Reading the path through `SurfaceCard.path` rather than the row
    /// directly keeps the one "there is no path here" rule shared with the
    /// icon and the drag — `URL(fileURLWithPath: "")` is the working
    /// directory, not nothing.
    private func activate(_ row: SurfaceRow) {
        guard let path = SurfaceCard.path(for: "path", in: row) else { return }
        let url = URL(fileURLWithPath: path)
        if FolderHubRows.isBrowsable(url) {
            show(url, asRoot: false)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Switches to `folder` on the frame the press happened, and loads it after.
    ///
    /// Everything a press changes is set here, in one action, and that is the
    /// whole point. It used to be a chain — `selected` set by the tap, `current`
    /// by one `.onChange`, the old rows cleared by a second — so the first frame
    /// after a click still carried the previous folder's eighty cards and merely
    /// moved the highlight. The highlight then waited on a grid that was about
    /// to be thrown away, and a press that does not visibly land reads as a
    /// press that did not register.
    ///
    /// `asRoot` is what a chip picks: it lands you at the top of that folder,
    /// never inside wherever the previous chip was browsed to. Walking into a
    /// subfolder moves `current` alone, which is what keeps the crumb trail.
    private func show(_ folder: URL, asRoot: Bool) {
        if asRoot { selected = folder }
        guard current?.path != folder.path else {
            // Already here. `current` would not change, so nothing downstream
            // would fire — re-read in place rather than clearing a grid that
            // nothing is going to refill.
            reload(folder)
            return
        }
        // Cleared in the same action as the switch, so the frame that moves the
        // highlight draws an empty grid instead of the old folder's eighty
        // cards. The load itself follows from `current` changing.
        rows = []
        selectedFiles = []
        current = folder
    }

    /// What a drag off this card carries. Dragging a card that isn't in the
    /// selection drags that card alone and makes it the selection — Finder's
    /// own rule, and the one that stops a selection made three folders ago
    /// from riding along with the file actually under the pointer. Order is
    /// the grid's, not the selection's: a `Set` has none, and a drop that
    /// reshuffles the files is a drop the user has to sort out afterwards.
    private func dragURLs(from row: SurfaceRow) -> [URL] {
        guard selectedFiles.contains(row.id) else {
            selectedFiles = [row.id]
            return SurfaceCard.path(for: "path", in: row).map { [URL(fileURLWithPath: $0)] } ?? []
        }
        return rows
            .filter { selectedFiles.contains($0.id) }
            .compactMap { SurfaceCard.path(for: "path", in: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Repainting the chips is not allowed to wait for the files.
    ///
    /// A switch used to list the folder and rebuild the grid inside the same
    /// SwiftUI update, so the chip you clicked lit up only once every card had
    /// been built — for as long as that took, the click read as ignored. Now
    /// the chip row gets a frame to itself, the listing happens off the main
    /// thread, and the cards land after. Files arriving a beat late is what
    /// anyone expects from a folder; a button that doesn't answer is not.
    private func refresh(in folder: URL?) {
        guard let folder else {
            current = nil
            return
        }
        show(folder, asRoot: false)
    }

    /// The folder changed underneath us — a download finished, something was
    /// trashed from Finder, a drop landed. Reloads in place: no clearing, so
    /// nothing blinks, and the selection survives whatever is still there.
    private func reload(_ folder: URL) {
        load(folder, keepingSelection: true)
    }

    private func load(_ folder: URL, keepingSelection: Bool) {
        Task { @MainActor in
            let fresh = await Task.detached(priority: .userInitiated) {
                FolderHubRows.rows(in: folder, limit: FolderHubRows.defaultLimit)
            }.value
            // The user may have clicked past this folder while the disk was
            // answering. Only the folder still being shown gets to fill it.
            guard current?.path == folder.path else { return }
            rows = fresh
            guard keepingSelection else { return }
            // A file that went away takes its selection with it; the rest keep
            // theirs, because a reload nobody asked for must not undo a
            // selection somebody did.
            selectedFiles.formIntersection(Set(fresh.map(\.id)))
        }
    }
}

/// A file-drop target that lights up while something is over it.
///
/// `URL` rather than a bespoke `Transferable`: Finder puts `public.file-url` on
/// the pasteboard and the system knows that type. A custom `UTType(exportedAs:)`
/// would not be registered anywhere — it has to be declared in an `Info.plist`,
/// and under `swift run` there is no bundle to declare it in, which is exactly
/// how the Edges figure's drag came to pick up and never drop.
private extension View {
    func dropTarget(
        isTargeted: Binding<Bool>? = nil,
        _ handle: @escaping ([URL]) -> Void
    ) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            handle(files)
            return true
        } isTargeted: { targeted in
            isTargeted?.wrappedValue = targeted
        }
    }
}

/// Holds the ⌘⌫ monitor for as long as a hub is on screen.
///
/// A reference type because `@State` on a struct would hand every re-render a
/// fresh copy, and the monitor has to be the same object to be removed. It is
/// scoped by the key window rather than by focus: the only windows that show a
/// hub are dock panels, so "this app's dock has the keyboard" is the whole
/// condition, and it needs no focus ring on a grid whose cards already own
/// their own clicks.
@MainActor
final class KeyMonitorBox {
    private var monitor: Any?

    func start(_ trash: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 51 is Delete. ⌘⌫ rather than ⌫ alone, exactly as in Finder: a
            // bare Backspace is one fat-fingered keystroke from emptying a
            // folder you were only looking at.
            guard event.keyCode == 51,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  NSApp.keyWindow is EdgeDockPanel
            else { return event }
            trash()
            return nil
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
