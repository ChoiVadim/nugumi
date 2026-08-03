# One Tool Model — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every built-in ring action gains the screen-edge choice gizmos already have, chosen in its own editor.

**Architecture:** `ToolRef` becomes the one id both kinds of tool are keyed by, and `DockStore` migrates its existing keys onto it in one pass so phase 2 does not need a second migration. `DockCatalog` grows from one built-in to eight. Built-ins with a resident surface show it (Note → the notes list); the rest show a run card driven by a new single entry point, `performBuiltIn(_:)`.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI, XCTest.

## Global Constraints

- Deployment target macOS 14. Dock defaults key stays exactly `com.nugumi.app.dock.v1`.
- User-facing copy avoids "translate"/"translation"/"translator".
- Tests are XCTest with a scratch `UserDefaults(suiteName:)` per test.
- `swift build` after every task; commit per task, staging by path.

## Why the id migration lands here and not in phase 2

`DockStore` already holds `"notes"` and bare UUID strings on disk. Phase 1 has to
rename the Notes item anyway — it stops being its own thing and becomes the
built-in `saveNote`'s surface. Doing that with a temporary key and renaming again
in phase 2 means writing two migrations and testing two. So `ToolRef.storageID`
arrives now, and phase 2 is reduced to the shortcut half.

## Summarize is not dockable

Its ring button is built from the frontmost app — an app icon and a time-range
orbit that only exist while something is in front. There is no meaningful
"Summarize, waiting on an edge". Excluded from the catalog with a comment, not
silently missing.

---

### Task 1: `ToolRef` and the dock key migration

**Files:**

- Create: `Sources/Gizmate/Tools/ToolRef.swift`
- Modify: `Sources/Gizmate/Dock/DockStore.swift`
- Test: `Tests/GizmateTests/DockStoreTests.swift`

**Interfaces:**

- Produces: `enum ToolRef: Hashable { case builtIn(RingActionID); case generated(UUID) }` with `var storageID: String`, `static func migratedID(from legacy: String) -> String`.

- [ ] **Step 1: Write the failing tests**

Add to `DockStoreTests`:

```swift
    @MainActor
    func testLegacyNotesKeyMigratesToTheBuiltInNoteAction() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        defaults.set(["right": ["notes"]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .right), [ToolRef.builtIn(.saveNote).storageID])
    }

    @MainActor
    func testLegacyBareUUIDMigratesToAGeneratedRef() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        let id = UUID()
        defaults.set(["left": [id.uuidString]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .left), [ToolRef.generated(id).storageID])
    }

    @MainActor
    func testMigrationIsWrittenBackSoItRunsOnce() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        defaults.set(["right": ["notes"]], forKey: DockStore.defaultsKey)
        _ = DockStore(defaults: defaults)
        let raw = defaults.dictionary(forKey: DockStore.defaultsKey) as? [String: [String]]

        XCTAssertEqual(raw?["right"], [ToolRef.builtIn(.saveNote).storageID])
    }

    @MainActor
    func testAlreadyMigratedKeysAreLeftAlone() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        let already = ToolRef.builtIn(.ask).storageID
        defaults.set(["top": [already]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .top), [already])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter DockStoreTests`
Expected: compile failure — `cannot find 'ToolRef' in scope`.

- [ ] **Step 3: Write `ToolRef`**

```swift
import Foundation

/// What every store keys a tool by, whether it shipped with the app or the user
/// built it.
///
/// `DockStore` already keyed on `String` so a built-in and a gizmo could share
/// one table; this is that instinct made explicit, and it is what lets the
/// shortcut keys join them in phase 2.
enum ToolRef: Hashable {
    case builtIn(RingActionID)
    case generated(UUID)

    /// Stable across launches. Prefixed so the two namespaces cannot collide —
    /// a gizmo named "dictate" is not the Dictate built-in.
    var storageID: String {
        switch self {
        case .builtIn(let id): return "builtin.\(id.rawValue)"
        case .generated(let id): return "tool.\(id.uuidString)"
        }
    }

    init?(storageID: String) {
        if let raw = storageID.dropPrefixIfPresent("builtin."),
           let id = RingActionID(rawValue: String(raw)) {
            self = .builtIn(id)
        } else if let raw = storageID.dropPrefixIfPresent("tool."),
                  let id = UUID(uuidString: String(raw)) {
            self = .generated(id)
        } else {
            return nil
        }
    }

    /// Maps a key written before this type existed. The dock shipped with
    /// `"notes"` for the notes list and bare UUID strings for gizmos; the notes
    /// list is now the Note built-in's surface, so it lands there.
    static func migratedID(from legacy: String) -> String {
        if ToolRef(storageID: legacy) != nil { return legacy }
        if legacy == "notes" { return ToolRef.builtIn(.saveNote).storageID }
        if let id = UUID(uuidString: legacy) { return ToolRef.generated(id).storageID }
        return legacy
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
```

- [ ] **Step 4: Migrate in `DockStore.load()`**

Replace the body of `load()` so each id goes through `ToolRef.migratedID`, and
write back when anything changed:

```swift
    private func load() {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] else {
            return
        }
        var loaded: [DockEdge: [String]] = [:]
        var migrated = false
        for (key, ids) in raw {
            guard let edge = DockEdge(rawValue: key), !ids.isEmpty else { continue }
            let mapped = ids.map(ToolRef.migratedID(from:))
            if mapped != ids { migrated = true }
            loaded[edge] = mapped
        }
        placement = loaded
        // Written back so the mapping runs once rather than on every launch.
        if migrated { save() }
    }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter DockStoreTests`
Expected: 13 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Gizmate/Tools/ToolRef.swift Sources/Gizmate/Dock/DockStore.swift Tests/GizmateTests/DockStoreTests.swift
git commit -m "Key the dock on one tool reference"
```

---

### Task 2: One entry point for running a built-in

**Files:**

- Create: `Sources/Gizmate/App/GizmateApp+BuiltIns.swift`
- Modify: `Sources/Gizmate/MainWindow/Core/SettingsContracts.swift`

**Interfaces:**

- Produces: `func performBuiltIn(_ id: RingActionID)` on `GizmateApp` and on `SettingsHost`.

**Why:** the ring reaches built-ins through closures assembled in
`FloatingButton`, and the hot keys through a separate table in
`setupGlobalHotKeys`. A dock would be a third. One named entry point ends that.

- [ ] **Step 1: Write it**

```swift
import Foundation

extension GizmateApp {
    /// Runs a shipped ring action from anywhere — the dock today, and whatever
    /// surface comes next.
    ///
    /// The ring assembles these as closures in `FloatingButton` and the hot keys
    /// as a table in `setupGlobalHotKeys`; both predate there being a third
    /// caller. This is the one list, and the other two should fold into it when
    /// they are next touched.
    ///
    /// `summarize` is absent on purpose: its action is built from the frontmost
    /// app, so there is no app-independent way to run it.
    @MainActor
    func performBuiltIn(_ id: RingActionID) {
        switch id {
        case .explain: startSelectionTranslateOrReply(forcing: .translate)
        case .rewrite: startSelectedTextTranslationForReplacement()
        case .reply: startSelectionTranslateOrReply(forcing: .smartReply)
        case .ask: startAskGizmatePrompt()
        case .capture: startScreenshotTranslation()
        case .dictate: toggleDictation()
        case .live: toggleLiveTranslation()
        // The empty string routes through the read-the-selection-now branch, the
        // same way the quick menu does.
        case .saveNote: saveSelectionToNote("")
        case .summarize: break
        }
    }
}
```

- [ ] **Step 2: Expose on `SettingsHost`**

Beside `func runTool(_:selection:)`:

```swift
    func performBuiltIn(_ id: RingActionID)
```

- [ ] **Step 3: Build**

Run: `swift build` — expected clean. If a method name differs, fix against
`grep -n "func start\|func toggle" Sources/Gizmate/App/*.swift`.

- [ ] **Step 4: Commit**

```bash
git add Sources/Gizmate/App/GizmateApp+BuiltIns.swift Sources/Gizmate/MainWindow/Core/SettingsContracts.swift
git commit -m "Give built-in actions one entry point"
```

---

### Task 3: The catalog learns built-ins

**Files:**

- Modify: `Sources/Gizmate/Dock/DockItem.swift`
- Create: `Sources/Gizmate/Dock/DockRunCard.swift`
- Delete the built-in-specific parts of: `Sources/Gizmate/Dock/DockGizmoView.swift` (folded into `DockRunCard`)

**Interfaces:**

- Produces: `DockCatalog.builtIns(host:)` returning eight items keyed by `ToolRef.builtIn(_).storageID`; `struct DockRunCard: View` with `init(title:symbolName:subtitle:options:onRun:)`.

- [ ] **Step 1: Generalise the run card**

`DockGizmoView` already is a run card that happens to take a `GizmateTool`.
Rewrite it as `DockRunCard` taking plain values, so a built-in uses the same one:

```swift
struct DockRunCard: View {
    let title: String
    let symbolName: String
    /// What pressing it will do with the result — "Show panel", "Save to notes".
    let subtitle: String
    /// What it works on, shown small at the bottom. Empty hides the line.
    let footnote: String
    /// One button per entry, the label being the value. Empty means one Run.
    let options: [String]
    let onRun: (String?) -> Void
    …
}
```

`DockGizmoView` becomes a thin wrapper that maps a `GizmateTool` onto it, or is
deleted if the mapping is a one-liner at the call site. Prefer deleting it.

- [ ] **Step 2: Rewrite `DockCatalog`**

```swift
    /// Everything that ships. `summarize` is missing on purpose — its button is
    /// built from the frontmost app, so there is nothing to park on an edge.
    static let dockableBuiltIns: [RingActionID] =
        RingActionID.allCases.filter { $0 != .summarize }

    static func builtIns(host: any SettingsHost) -> [DockItem] {
        dockableBuiltIns.map { action in
            let override = host.builtInOverrides.override(for: action)
            return DockItem(
                id: ToolRef.builtIn(action).storageID,
                title: override?.name ?? action.displayName,
                symbolName: override?.symbol ?? action.fallbackSymbolName
            ) { [weak host] in
                hosted(surface(for: action, host: host))
            }
        }
    }

    /// Note already has a view — the notes list. The rest get a run card until
    /// phase 3 turns their panels into views.
    private static func surface(for action: RingActionID, host: (any SettingsHost)?) -> AnyView { … }
```

Confirm the override accessor and symbol fallback before writing:

```bash
grep -n "func override\|func name(for\|func icon(for" Sources/Gizmate/Ring/BuiltInOverrides.swift
grep -n "var icon\|var displayName" Sources/Gizmate/Ring/RingCatalog.swift
```

`RingActionID.icon` returns a `RingIconKind` (bundled Phosphor art for some
actions), not an SF Symbol name. `DockItem.symbolName` is an SF Symbol. Where a
built-in has no SF Symbol of its own, fall back to a per-action constant rather
than rendering a blank tab.

- [ ] **Step 3: Build and run**

```bash
swift build && pkill -f 'debug/Gizmate' ; swift run Gizmate
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Gizmate/Dock/
git commit -m "Let every shipped action live on a screen edge"
```

---

### Task 4: The picker moves into the built-in editor

**Files:**

- Modify: `Sources/Gizmate/MainWindow/BuiltInEditor.swift`
- Modify: `Sources/Gizmate/MainWindow/Sections/NotesSection.swift`

- [ ] **Step 1: Add the row**

In `BuiltInEditorPanel.fields`, after `shortcutRow` and its divider — trigger
then display, the same order the gizmo editor uses:

```swift
            if DockCatalog.dockableBuiltIns.contains(actionID) {
                Divider().background(FlowTheme.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Screen edge")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    DockPlacementPicker(
                        store: bridge.dock,
                        itemID: ToolRef.builtIn(actionID).storageID
                    )
                }
            }
```

- [ ] **Step 2: Remove `dockRow` from `NotesSection`**

Delete the `dockRow` property and its call site. Notes' placement is now the
Note built-in's, set in that action's editor — one control, not two pointing at
the same key.

- [ ] **Step 3: Build, test, run**

```bash
swift build && swift test --filter Dock
pkill -f 'debug/Gizmate' ; swift run Gizmate
```

Check by hand:

1. Ring tab → Note → its editor shows Name, Shortcut, Icon, **Screen edge**.
2. Pick Right; hover the right edge; the notes list opens.
3. Ask → Screen edge → Left; hovering left opens Ask's run card.
4. Both docked at once: two tabs, switching between them works.
5. Quit and relaunch: both survive.
6. A dock set before this change (key `"notes"`) still opens after the upgrade.

- [ ] **Step 4: Commit**

```bash
git add Sources/Gizmate/MainWindow/BuiltInEditor.swift Sources/Gizmate/MainWindow/Sections/NotesSection.swift
git commit -m "Choose a built-in's screen edge in its own editor"
```

---

## Self-review notes

**Spec coverage (phase 1 only).** Built-ins in `DockCatalog` → Task 3. Picker in
`BuiltInEditorPanel` → Task 4. Notes as the resident surface of `saveNote` →
Task 3. The `ToolRef` migration was pulled forward from phase 2 → Task 1, for
the reason stated above.

**Deferred, deliberately.** Ask, Live and the result panel are still windows, so
they dock as run cards. That is phase 3 and the plan says so out loud rather
than leaving an empty panel to discover.

**Known risk.** `RingActionID.icon` is a `RingIconKind`, not an SF Symbol name —
several built-ins ship bundled Phosphor art. Task 3 Step 2 has to pick SF Symbol
fallbacks for those, and a wrong guess is a blank tab rather than a crash.
