# Three Places Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Gizmate three sidebar places instead of one and a half — Home makes tools, Ring is what sits under the cursor, Edges is what sits on the screen borders — and make placement something an edge owns rather than a property scattered across three editors.

**Architecture:** `DockStore` already models an edge as an ordered list of ids; nothing has ever shown it. Edges inverts the ownership: an edge gets a screen, and every resident becomes its content. Ring moves out of `.home` unchanged, Home becomes the front door, and the three `DockPlacementPicker` sites collapse into one-line pointers.

**Tech Stack:** Swift 5.9 / SwiftPM, SwiftUI + AppKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-05-three-places-navigation-design.md`

## Global Constraints

- macOS 14 deployment target. No new SwiftPM or npm dependency.
- **`MainWindowSection`'s raw values are persisted as the restored sidebar selection** — its own doc comment says so. `home` must keep the raw value `home`; new cases take new raw values. A raw value written by an older build must still resolve.
- Bundle identity is frozen: `com.nugumi.app`, `~/Library/Application Support/Nugumi`, `com.nugumi.app.*` defaults keys. Never rename one.
- **`DockStore.defaultsKey` is `com.nugumi.app.dock.v1` and holds users' real placements.** Adding a method is safe; changing the stored shape is not.
- `DESIGN.md` binds every view: §2 `FlowTheme` tokens only and never a raw `Color(...)`; §3 the type scale is fixed and hierarchy comes from weight and colour, not new sizes; §4 the 4px grid; §7 no drop shadows; §8 `OverlayScrollHost` rather than `ScrollView` inside a borderless panel; §11 dock behaviour.
- Never write "translate", "translation" or "translator" in user-visible copy. Code identifiers are exempt.
- `swift build` green after every task. Never commit a build broken by your own change.
- One subsystem per file, target under ~400 lines. New sections go in `Sources/Gizmate/MainWindow/Sections/`.
- Comments explain _why_, in prose, not _what_.
- **Stage by path, never `git add -A`.** The repo owner edits this worktree while work runs. Check `git status` before staging and `git diff --cached --stat` before committing.
- Before committing, ask of each test: **if the code it names were deleted, would this test still fail?** Seven tests in the preceding branch passed for the wrong reason.

---

### Task 1: An edge can be reordered

**Files:**

- Modify: `Sources/Gizmate/Dock/DockStore.swift`
- Test: `Tests/GizmateTests/DockStoreTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces: `DockStore.move(_ id: String, to edge: DockEdge, at index: Int)`.

`dock(_:to:)` appends, which is why tab order has always been "the order they were docked" — not a decision, just the absence of anywhere to make one. Edges cannot exist without this.

`move` must handle the awkward case correctly: moving an item **within** the edge it is already on. Remove-then-insert shifts every later index by one, so an item dragged from position 0 to position 2 lands at position 1 unless the index is adjusted. That off-by-one is the whole reason this task has its own tests.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testMoveInsertsAtTheRequestedIndex() {
    let store = DockStore(defaults: scratchDefaults())
    store.dock("a", to: .right)
    store.dock("b", to: .right)
    store.move("c", to: .right, at: 1)
    XCTAssertEqual(store.items(on: .right), ["a", "c", "b"])
}

/// The case remove-then-insert gets wrong: every index after the removed one
/// shifts down, so a naive implementation lands one short.
@MainActor
func testMovingAnItemForwardWithinItsOwnEdgeLandsWhereAsked() {
    let store = DockStore(defaults: scratchDefaults())
    ["a", "b", "c"].forEach { store.dock($0, to: .right) }
    store.move("a", to: .right, at: 2)
    XCTAssertEqual(store.items(on: .right), ["b", "c", "a"])
}

@MainActor
func testMovingAnItemBackwardWithinItsOwnEdgeLandsWhereAsked() {
    let store = DockStore(defaults: scratchDefaults())
    ["a", "b", "c"].forEach { store.dock($0, to: .right) }
    store.move("c", to: .right, at: 0)
    XCTAssertEqual(store.items(on: .right), ["c", "a", "b"])
}

@MainActor
func testMovingBetweenEdgesLeavesTheOldOne() {
    let store = DockStore(defaults: scratchDefaults())
    store.dock("a", to: .left)
    store.dock("b", to: .right)
    store.move("a", to: .right, at: 0)
    XCTAssertEqual(store.items(on: .left), [])
    XCTAssertEqual(store.items(on: .right), ["a", "b"])
}

/// An index past the end is a drop below the last row, which is a normal
/// gesture, not a programming error.
@MainActor
func testAnIndexPastTheEndAppends() {
    let store = DockStore(defaults: scratchDefaults())
    store.dock("a", to: .right)
    store.move("b", to: .right, at: 99)
    XCTAssertEqual(store.items(on: .right), ["a", "b"])
}

@MainActor
func testMoveSurvivesAReload() {
    let defaults = scratchDefaults()
    let store = DockStore(defaults: defaults)
    ["a", "b"].forEach { store.dock($0, to: .top) }
    store.move("b", to: .top, at: 0)
    XCTAssertEqual(DockStore(defaults: defaults).items(on: .top), ["b", "a"])
}
```

Use whatever scratch-`UserDefaults` helper the existing tests in that file already use; if there is none, write one that makes a suite named after a fresh `UUID()` so tests never touch the real domain. Name it `scratchDefaults()` and say in your report which you did.

- [ ] **Step 2: Run them and watch them fail**

```sh
swift test --filter DockStoreTests 2>&1 | tail -20
```

Expected: "value of type 'DockStore' has no member 'move'".

- [ ] **Step 3: Implement `move`**

Put it directly below `dock(_:to:)` in `DockStore.swift`, and follow that method's own shape: mutate `placement`, then `save()`, then `onChange?()`. Clamp the index into `0...count` after the removal rather than before it — that is what makes the within-edge case land where the user dropped it. Carry a comment explaining the shift, because the next person to read it will assume remove-then-insert is enough.

- [ ] **Step 4: Run them and watch them pass**

```sh
swift test --filter DockStoreTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/Dock/DockStore.swift Tests/GizmateTests/DockStoreTests.swift
git commit -m "Let an edge decide the order of what sits on it"
```

---

### Task 2: The Edges section

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/EdgesSection.swift`
- Modify: `Sources/Gizmate/MainWindow/Core/MainWindowNavigation.swift`
- Modify: `Sources/Gizmate/MainWindow/Sections/DetailRouter.swift:8-14`
- Test: `Tests/GizmateTests/MainWindowNavigationTests.swift` (create if absent)

**Interfaces:**

- Consumes: `DockStore.move(_:to:at:)` (Task 1); `DockCatalog.all(host:) -> [DockItem]`, `DockCatalog.placeableIDs(host:) -> Set<String>`, `DockItem` (`id`, `title`, `icon: RingIconKind`); `DockEdge.allCases`, `DockEdge.displayName`.
- Produces: `MainWindowSection.edges`; `struct EdgesSection: View`.

Additive: nothing that works today changes. Placement moves here in Task 3.

**Layout.** One card per edge — Top, Left, Right, in `DockEdge.allCases` order — each listing its residents in tab order with their `DockItem` icon and title, draggable to reorder within an edge and between edges. Below the three, a list of everything placeable that is on no edge, each with a control to put it somewhere.

Read `DockCatalog`'s doc comments before writing: `all(host:)` is built-ins plus usable surface gizmos, and `placeableIDs(host:)` is deliberately wider than `knownIDs(host:)`. An id in `DockStore` that resolves to no `DockItem` must render as nothing at all, not as a broken row — `DockStore.prune` already drops those at read time and this view must not fight it.

**Do not list Ask or Live.** `DockCatalog`'s comments name them as future residents; they still build their own windows and there is nothing to hand an edge. Listing them as though they could be placed would be a promise the app cannot keep.

- [ ] **Step 1: Write the failing test**

```swift
final class MainWindowNavigationTests: XCTestCase {
    /// The raw value is the restored sidebar selection, so a build that
    /// renames one silently drops the user on a different screen.
    func testHomeKeepsItsPersistedRawValue() {
        XCTAssertEqual(MainWindowSection.home.rawValue, "home")
    }

    func testEdgesIsOfferedInTheSidebar() {
        XCTAssertTrue(MainWindowSection.primary.contains(.edges))
    }

    /// Every case has to answer both, or the sidebar renders a blank row.
    func testEveryCaseHasATitleAndASymbol() {
        for section in MainWindowSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section.rawValue) has no title")
            XCTAssertFalse(section.symbol.isEmpty, "\(section.rawValue) has no symbol")
        }
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter MainWindowNavigationTests 2>&1 | tail -20
```

Expected: "type 'MainWindowSection' has no member 'edges'".

- [ ] **Step 3: Add the case**

In `MainWindowNavigation.swift`: add `edges` to the enum, `"Edges"` to `title`, a symbol to `symbol`, and place it in `primary` after `.home`. Use an SF Symbol that reads as a border rather than a container — `rectangle.lefthalf.inset.filled` or similar; check it resolves on macOS 14 before settling.

Update the enum's doc comment: it currently says `home` **is** the ring, which stops being true in Task 4. Say what is true now and leave the persistence note intact.

- [ ] **Step 4: Build the section**

`EdgesSection.swift`, following `NotesSection.swift` for how a section is structured and `SettingsSection.swift` for card shapes. Rows carry `DockItem.icon` via `Image(nsImage: item.icon.image(pointSize:))` the way `DockTabStrip` does.

For drag-reordering use SwiftUI's `.onMove` inside a `List` if that fits the existing look, or `.draggable`/`.dropDestination` if the cards are not lists — pick whichever matches the surrounding section style and say which in your report. The store call is `store.move(id, to: edge, at: index)`.

An edge with nothing on it says so in `FlowTheme.inkSecondary` rather than rendering an empty card.

- [ ] **Step 5: Route it**

`DetailRouter.swift`: `case .edges: EdgesSection()`.

- [ ] **Step 6: Run the tests and build**

```sh
swift test 2>&1 | tail -10 && swift build 2>&1 | tail -3
```

- [ ] **Step 7: Commit**

```sh
git add Sources/Gizmate/MainWindow/Sections/EdgesSection.swift \
        Sources/Gizmate/MainWindow/Core/MainWindowNavigation.swift \
        Sources/Gizmate/MainWindow/Sections/DetailRouter.swift \
        Tests/GizmateTests/MainWindowNavigationTests.swift
git commit -m "Give every screen edge a place where it can be seen"
```

---

### Task 3: Edges owns placement

**Files:**

- Modify: `Sources/Gizmate/MainWindow/Sections/EdgesSection.swift`
- Modify: `Sources/Gizmate/MainWindow/ToolEditor.swift:795-840`
- Modify: `Sources/Gizmate/MainWindow/BuiltInEditor.swift:105-116`
- Modify: `Sources/Gizmate/MainWindow/Sections/SettingsSection.swift:124,138-172`
- Modify: `Tests/GizmateTests/ToolProtocolEnumParityTests.swift:183-231`

**Interfaces:**

- Consumes: `EdgesSection` (Task 2); `SettingsSection.residentWithoutARingSlot` (moving); `ToolEditorPanel.outputsWithPlacementControl` (moving or staying — decide and say which).
- Produces: placement editable in exactly one place; the two parity tests re-pointed at it.

Three `DockPlacementPicker` sites become one. The third — the Files card in Settings — exists only because nowhere fitted when the folder hub shipped; that is the whole reason this section exists.

**The editors keep a pointer, not a control.** Locality is worth a sentence: a gizmo's editor should still say "On the right edge — change in Edges", or "Not on an edge" when it is nowhere. It is not worth three copies of a control that edit the same store.

**Move the resident's own settings in too.** The folder hub's folder list is currently reachable **only from inside its panel** — discovery by accident. Its chips and `+` stay where they are for use, but Edges is where you set it up.

**The consent sentence lands here once.** The spec requires that where a user chooses an edge it says plainly that a resident runs whenever its edge opens. It is currently copied onto two controls with slightly different wording. One statement, in Edges, next to the choice.

- [ ] **Step 1: Re-point the parity tests first, and watch them fail**

`DockPlacementParityTests` lives in `Tests/GizmateTests/ToolProtocolEnumParityTests.swift:183`. Its two tests pin `ToolEditorPanel.outputsWithPlacementControl` and `SettingsSection.residentWithoutARingSlot` against the live catalog. Both constants are about to move.

Point them at wherever placement now lives, before moving anything.

```sh
swift test --filter DockPlacementParityTests 2>&1 | tail -20
```

Expected: compile failure naming the constants that do not exist yet.

- [ ] **Step 2: Move placement into Edges**

Every placeable thing gets its edge chosen in `EdgesSection` — gizmos, built-ins and the folder hub through one path, since from an edge's point of view they are all just residents.

- [ ] **Step 3: Replace the three controls with pointers**

`ToolEditor.swift`'s `placementControl` and its `outputsWithPlacementControl` gate, `BuiltInEditor.swift`'s `dockableBuiltIns` block, and `SettingsSection.swift`'s `filesOnEdgeCard` all become a line of text stating where the thing currently sits.

- [ ] **Step 4: Verify the parity tests still bite**

Both must fail if the control is removed, not merely compile. Check it the way the earlier waves did: blank the constant each test pins, confirm the test fails, restore it.

```sh
swift test --filter DockPlacementParityTests 2>&1 | tail -20
```

- [ ] **Step 5: Full suite and build**

```sh
swift test 2>&1 | tail -10 && swift build 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```sh
git add Sources/Gizmate/MainWindow/Sections/EdgesSection.swift \
        Sources/Gizmate/MainWindow/ToolEditor.swift \
        Sources/Gizmate/MainWindow/BuiltInEditor.swift \
        Sources/Gizmate/MainWindow/Sections/SettingsSection.swift \
        Tests/GizmateTests/ToolProtocolEnumParityTests.swift
git commit -m "Let one screen own where things sit"
```

---

### Task 4: Ring moves out, Home becomes the tool list

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/HomeSection.swift`
- Modify: `Sources/Gizmate/MainWindow/Core/MainWindowNavigation.swift`
- Modify: `Sources/Gizmate/MainWindow/Sections/DetailRouter.swift`
- Modify: `Sources/Gizmate/App/GizmateApp+ScriptTools.swift` (two `presentMainWindow(section: .home)` calls)
- Test: `Tests/GizmateTests/MainWindowNavigationTests.swift`

**Interfaces:**

- Consumes: `MainWindowSection.edges` (Task 2); `RingSection` (unchanged); `ToolsStore.usableTools()`; `DockStore.edge(of:)`.
- Produces: `MainWindowSection.ring`; `struct HomeSection: View`.

`case .home: RingSection()` — Home _is_ the ring today. This task separates them: `.ring` renders `RingSection` unchanged, `.home` renders a new list of every tool.

**`home` keeps its raw value.** It is the persisted restored selection. A user who last had Home open lands on the new Home, which is correct — they land on the front door. Giving `.ring` the new raw value and leaving `home` alone is what makes an older build's saved selection still resolve.

**Re-point the two callers.** `GizmateApp+ScriptTools.swift` calls `presentMainWindow(section: .home)` twice. Read both: one is a uv-missing error path and belongs wherever a person fixes that; the other is the toast telling a user to pick an edge for a surface gizmo, and **that one must now open `.edges`**. Sending someone to Home to do a thing Home no longer does is the exact failure this restructure exists to remove.

- [ ] **Step 1: Write the failing test**

```swift
func testRingIsItsOwnSection() {
    XCTAssertTrue(MainWindowSection.primary.contains(.ring))
}

/// Home stays first: it is the front door now, not the ring.
func testHomeIsStillTheLandingSection() {
    XCTAssertEqual(MainWindowSection.primary.first, .home)
}

/// Two cases must never share a raw value — the sidebar restores by it.
func testRawValuesAreUnique() {
    let raws = MainWindowSection.allCases.map(\.rawValue)
    XCTAssertEqual(Set(raws).count, raws.count)
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter MainWindowNavigationTests 2>&1 | tail -20
```

Expected: "type 'MainWindowSection' has no member 'ring'".

- [ ] **Step 3: Add `.ring` and split the router**

Add the case with title `"Ring"` and a symbol; put it in `primary` between `.home` and `.edges`. In `DetailRouter`: `case .ring: RingSection()` and `case .home: HomeSection()`.

- [ ] **Step 4: Build `HomeSection`**

Every tool in one list — shipped actions and generated gizmos — each row saying where it lives: which ring slot, which edge, or that it lives nowhere. Picking one opens its detail, which is the existing editor.

Follow `NotesSection.swift` for section structure. Reuse whatever the ring slot picker already uses to render a tool's name and icon rather than inventing a second row style; if that view is private to the picker, say so in your report rather than copying it.

- [ ] **Step 5: Re-point the two callers**

- [ ] **Step 6: Full suite and build**

```sh
swift test 2>&1 | tail -10 && swift build 2>&1 | tail -3
```

- [ ] **Step 7: Commit**

```sh
git add Sources/Gizmate/MainWindow/Sections/HomeSection.swift \
        Sources/Gizmate/MainWindow/Core/MainWindowNavigation.swift \
        Sources/Gizmate/MainWindow/Sections/DetailRouter.swift \
        Sources/Gizmate/App/GizmateApp+ScriptTools.swift \
        Tests/GizmateTests/MainWindowNavigationTests.swift
git commit -m "Separate the ring from the front door"
```

---

### Task 5: The builder chat comes to the front door

**Files:**

- Modify: `Sources/Gizmate/MainWindow/Sections/HomeSection.swift`
- Modify: `Sources/Gizmate/MainWindow/ToolEditor.swift:120`

**Interfaces:**

- Consumes: `HomeSection` (Task 4); `ToolBuilderChat`.
- Produces: tool creation reachable without picking a ring slot first.

`ToolBuilderChat` is presented from inside `ToolEditor`, which is reached by picking a ring slot. So the only door to making anything is a ring slot — and a surface gizmo, which never belongs on a ring, has to be created through one anyway.

Home gets the chat at its top level. **The slot picker's path stays**: choosing a slot and building a tool for it is a good shortcut when you already know where the tool goes. It stops being the only way in.

Read `ToolBuilderChat`'s own interface before moving anything — if it takes a target slot or a draft tool, Home needs a sensible value for that, and inventing one is a design decision worth reporting rather than guessing at.

- [ ] **Step 1: Read the chat's interface and report what it needs**

Before writing code, note in your report what `ToolBuilderChat` is initialised with at `ToolEditor.swift:120` and what Home must supply. If it cannot be presented without a slot, stop and say so — that is a finding about the design, not a task to force through.

- [ ] **Step 2: Present it from Home**

- [ ] **Step 3: Verify both doors still work**

The slot picker path must be untouched. Run the full suite and confirm nothing about the ring changed.

```sh
swift test 2>&1 | tail -10 && swift build 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```sh
git add Sources/Gizmate/MainWindow/Sections/HomeSection.swift \
        Sources/Gizmate/MainWindow/ToolEditor.swift
git commit -m "Let a tool be made without choosing a slot first"
```

---

### Task 6: Nothing lives nowhere

**Files:**

- Modify: `Sources/Gizmate/MainWindow/Sections/HomeSection.swift`
- Modify: `Tests/GizmateTests/ToolProtocolEnumParityTests.swift`
- Modify: `DESIGN.md`
- Modify: `Sources/Gizmate/Dock/DockItem.swift` (the `builtIns` doc comment)

**Interfaces:**

- Consumes: everything above.
- Produces: a third parity test asserting every tool is reachable from somewhere.

Decoupling creation from placement creates a way to make a tool that lives nowhere. This codebase shipped exactly that twice in two days: a surface gizmo that reached the enum, the protocol, the sidecar, the dock catalog, the model and the tests but missed the one control that made it dockable, and the folder hub repeating it one level up hours later. Both times everything was green and nobody could use the feature.

The ring slot used to hide this — you picked a slot first, so what you made was placed by construction. That safety net is gone as of Task 5, and this task replaces it.

- [ ] **Step 1: Write the failing test**

A tool is reachable when it is on a ring slot or on an edge. Assert that a tool which is on neither is reported as such by whatever Home uses to describe a tool's home, so the statement cannot quietly stop being rendered.

Write it against a real `ToolsStore` on a scratch directory and a real `DockStore` on a scratch `UserDefaults`, the way `DockPlacementParityTests` already builds its stub host.

- [ ] **Step 2: Run it and watch it fail**

- [ ] **Step 3: Say it in Home**

A tool that is on no ring slot and no edge says so plainly on its row — a permanent statement of fact in `FlowTheme.inkTertiary`, not a warning banner. The point is that a person scanning the list sees which of their tools do nothing.

- [ ] **Step 4: Update the documentation that is now wrong**

`DESIGN.md` §11 describes where residents get their edge, and `DockItem.swift`'s `builtIns` doc comment does too. Both change with this plan. Write the new convention with its reason, in the file's existing voice — that is this project's rule for `DESIGN.md`, not a nicety.

- [ ] **Step 5: Full suite and build**

```sh
swift test 2>&1 | tail -10 && swift build 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```sh
git add Sources/Gizmate/MainWindow/Sections/HomeSection.swift \
        Tests/GizmateTests/ToolProtocolEnumParityTests.swift \
        DESIGN.md Sources/Gizmate/Dock/DockItem.swift
git commit -m "Say when a tool has nowhere to live"
```

---

## The live check

Navigation cannot be verified by the test suite — the whole point is where a person's eye and hand go. When the six tasks are done, the repo owner runs this; **no agent may launch the app**, because doing so from an agent's shell misattributes macOS permissions to the shell rather than the app bundle, and the folder hub reads `~/Downloads`.

```sh
bash Scripts/build-app-bundle.sh
open dist/Gizmate.app
```

1. The sidebar reads Home, Ring, Edges, Notes, Voice, Insights.
2. Home lists every tool, each saying where it lives; one that lives nowhere says so.
3. Home's chat builds a tool without picking a ring slot first.
4. Ring is exactly what Home used to be.
5. Edges shows three edges with their residents in order; dragging a resident between edges moves it, and the change survives a relaunch.
6. A gizmo's editor states where it sits and points at Edges instead of offering a second control.
7. The folder hub's folders can be set up from Edges, not only from inside its panel.

## Self-Review

**Spec coverage.** Three sections → Tasks 2, 4. Placement owned by Edges → Task 3. Edge order → Task 1. Resident settings in Edges → Task 3. Consent copy once → Task 3. Chat at the front door → Task 5. Nothing lives nowhere → Task 6. Re-pointed callers → Task 4. Parity tests preserved → Tasks 3, 6. Documentation → Task 6.

**Not covered, deliberately.** The spec's non-goals: multi-monitor, Ask and Live as residents, redesigning the ring, a second placement model, and anything touching the tool protocol or the sidecar.

**Type consistency.** `DockStore.move(_ id: String, to edge: DockEdge, at index: Int)` is used with that signature in Tasks 1 and 2. `MainWindowSection.edges` (Task 2) and `.ring` (Task 4) are referenced consistently after their introducing tasks. `HomeSection` is created in Task 4 and extended in Tasks 5 and 6.

**Known softness.** Tasks 2, 4 and 5 specify structure and behaviour but not exact view code, because the surrounding section style is the constraint and it must be read rather than guessed. Every one of them asks the implementer to name what they matched and to report anything that would not fit — a design decision surfaced is worth more than a snippet I wrote without seeing the file.
