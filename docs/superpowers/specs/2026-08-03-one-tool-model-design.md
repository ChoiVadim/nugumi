# One tool model — built-ins and generated gizmos stop being different things

## The problem

Gizmate has two kinds of tool and they have different powers, in opposite
directions:

|                    | Built-in (`RingActionID`) | Generated (`GizmateTool`) |
| ------------------ | ------------------------- | ------------------------- |
| Editor             | `BuiltInEditorPanel`      | `ToolEditorPanel`         |
| Name, icon         | yes                       | yes                       |
| Global shortcut    | **yes**                   | **no**                    |
| Screen edge (dock) | **no**                    | **yes**                   |
| Prompt / behaviour | prompt only               | prompt, script, agent     |

A user who builds a gizmo cannot give it a key. A user who likes Explain cannot
put it on an edge. Neither limit is a decision anyone made — they are what fell
out of adding the two features at different times to two different types.

The cost compounds: every capability added from here has to be added twice, and
the second time is always the one that gets skipped.

## The shape

One idea, three properties:

```
Tool (built-in or generated)
├─ identity:  name, icon
├─ trigger:   ring slot, global shortcut
└─ display:   floating | dock(top | left | right)
```

**Display is one property for every tool**, because every tool already has a
surface — it just isn't named as one today:

| Tool                      | Its surface                  | Who owns the window today                            |
| ------------------------- | ---------------------------- | ---------------------------------------------------- |
| Note                      | the notes list               | main window section                                  |
| Ask                       | prompt capsule + answer      | `AskPromptController` + `TranslationPanelController` |
| Live                      | captions                     | `LiveCaptionController`                              |
| Explain / Rewrite / Reply | the result panel             | `TranslationPanelController`                         |
| Capture / Summarize       | the result panel             | `TranslationPanelController`                         |
| Dictate                   | the REC pill                 | `DictationController`                                |
| A generated gizmo         | its result, per `ToolOutput` | `TranslationPanelController`                         |

So "display" is not a new concept bolted on. It is naming a thing that already
exists and making it a choice.

## The one real obstacle

**Every surface today is a window, not a view.** `AskPromptController` builds
its content directly into an `NSPanel` it constructs in its own `init`.
`TranslationPanelController` and `LiveCaptionController` do the same. There is
nothing to hand a dock.

That is the whole engineering cost of this spec. The pickers are an afternoon;
this is the work.

The fix is the same in each case and it is pure code motion:

```swift
// before: one type that builds a panel and fills it
final class AskPromptController { let panel: NSPanel; init(near:) { …builds both… } }

// after: content that knows nothing about where it lives, and a host that decides
enum AskSurface { static func makeView(…) -> NSView }
final class AskFloatingHost { … puts it in a panel, as today … }
// and the dock hosts the same view through DockItem.makeView
```

No behaviour changes in that step. `swift build` stays green after each move,
and the floating path stays the default and stays byte-identical in behaviour.

## Correction, 2026-08-04 — a screen edge is a panel, not a launcher

The first cut of this shipped the edge choice as "put this tool on that edge",
which made it a second Ring: a button you press to run something. That is wrong,
and it is wrong in a way that matters, because it puts two launchers in the
product and answers a question nobody asked.

**A screen edge replaces the panel, never the trigger.** The Ring says *when* a
tool runs; `Result` says *what happens to what it produces*; and when that result
is a panel, the edge choice says *where that panel opens* — floating, as it
always has, or flush to an edge.

```
Tool
├─ trigger:  Ring slot, global shortcut          ← unchanged by this
├─ input:    selection, ask, files, screenshot…
└─ result:   replace / clipboard / notes / notify / files
             └─ panel → opens: Floating | Top | Left | Right
```

Consequences, all of them deliberate:

- A tool whose result is not a panel has **no** placement option. Rewrite writes
  into the app you were in; there is no panel, so there is nothing to place.
- Notes and Ask use the same control with the same meaning. Their "panel" is
  their surface — the notes list, the chat — and it opens floating or on an edge
  like any other.
- The run card is deleted. It existed only to give a launcher something to show.

**This makes phase 3 the whole feature, not a phase of it.** Until a result panel
is a view rather than a window, the only tool that can honour the choice is Note,
whose list already exists as one. `DockCatalog.dockableBuiltIns` is `[.saveNote]`
and `DockCatalog.gizmos` is empty — honestly, rather than offering a control that
does nothing.

## Non-goals

- **Merging the two editors into one screen.** `BuiltInEditorPanel` and
  `ToolEditorPanel` gain the same rows; they do not become one file. A built-in
  has no script and a gizmo has no shipped default to reset to, and pretending
  otherwise makes one editor full of "not for this kind".
- **Making built-ins deletable, or gizmos shipped.** They stay distinct in
  origin. They stop being distinct in _capability_.
- **A block schema for generated UI.** Still its own spec, still after this one.
  This spec gives it the place to land.
- **Multi-monitor docks.** Unchanged from the edge dock spec: main screen only.

## Components

### `ToolIdentity` — the id every store already wanted

`DockStore` keys on `String` today, exactly so `"notes"` and a gizmo's UUID can
share one table. That was the right instinct and it becomes the model:

```swift
enum ToolRef: Hashable, Codable {
    case builtIn(RingActionID)
    case generated(UUID)

    /// Stable across launches — this is what every store keys on and what every
    /// defaults key embeds.
    var storageID: String {
        switch self {
        case .builtIn(let id): return "builtin.\(id.rawValue)"
        case .generated(let id): return "tool.\(id.uuidString)"
        }
    }
}
```

⚠️ `DockStore` already has keys on disk under the current scheme —
`"notes"` for the built-in Notes item and bare UUID strings for gizmos. `load()`
migrates both forms to `storageID` once and rewrites. Its decoding is already
lenient, so a key that matches neither is dropped rather than fatal.

### Trigger: opening up `GlobalShortcutAction`

Today it is a closed enum whose `id: UInt32` is a hand-assigned constant per
case, and whose `defaultsKey` is `"globalShortcut.\(rawValue)"`.

The `UInt32` is only used to build an `EventHotKeyID` so the Carbon handler can
tell which key fired **inside the running process**. It is never persisted. So:

- **Persisted key** becomes `"globalShortcut.\(ToolRef.storageID)"`. The eleven
  built-ins keep their current `rawValue`-based keys through a one-time
  migration, so nobody loses a shortcut they set.
- **Carbon id** becomes a runtime counter handed out at registration and held in
  a `[UInt32: ToolRef]` map for the handler. The existing fixed ids 2–12 stay
  reserved so the always-on ⌃⌥A alias at id 100 keeps its clearance.

This is what makes a per-gizmo shortcut possible at all, and it costs less than
it looks because the hard-looking part — the fixed ids — turns out to be
ephemeral.

### Display: `ToolSurface`

```swift
/// What a tool shows, independent of where it shows it.
struct ToolSurface {
    /// nil for a tool whose surface only exists after a run (a result panel).
    let makeView: () -> NSView
    /// Whether this surface can sit in a dock waiting, or only appears on
    /// demand. Notes and Ask are resident; a result panel is not.
    let isResident: Bool
}
```

A resident surface (Notes, Ask, Live) is what a dock tab opens. A non-resident
one (Explain's result) means "when this tool produces a result, put it in the
dock instead of floating over the selection".

Both are the same setting to the user — "where does this appear" — and the
difference is a property of the tool, not a second control.

### Editors

`BuiltInEditorPanel` gains the display picker; `ToolEditorPanel` gains the
shortcut row. Both reuse what the other already has:

- `DockPlacementPicker` — exists, built for the edge dock.
- The shortcut row — exists in `BuiltInEditorPanel` as `shortcutRow`, moves to a
  shared control so both editors bind it the same way.

After this, opening either editor shows the same three groups in the same order:
identity, trigger, display — then whatever is specific to the kind.

## Phases

Each phase leaves the app working and is worth landing on its own.

**Phase 1 — built-ins get a display picker.** `DockCatalog` learns built-ins;
`BuiltInEditorPanel` gets `DockPlacementPicker`. Only the tools with a surface
that already exists as a view are resident: Notes. The rest dock as a run card,
which is honest and temporary. Ships in an afternoon and makes the asymmetry
visible rather than theoretical.

**Phase 2 — `ToolRef` and the storage migration.** One id type, one migration,
`DockStore` and the shortcut keys move onto it. No user-visible change; this is
the phase that makes phases 3 and 4 small.

**Phase 3 — surfaces become views.** `AskPromptController`,
`TranslationPanelController`, `LiveCaptionController` each split into content and
host. Pure code motion, `swift build` green after each move. At the end, Ask and
Live are resident dock surfaces and the result panel can be docked.

**Phase 4 — gizmos get shortcuts.** `GlobalShortcutAction` opens up, the Carbon
id becomes a runtime counter, `ToolEditorPanel` gets the shortcut row.

**Phase 5 — the block schema** (separate spec). A generated gizmo describes its
output as data, Gizmate renders it with its own components, and it becomes a
resident surface like any other.

## Errors

- **A shortcut a gizmo claims is already taken.** The recorder already has to
  answer this for built-ins; the same check covers gizmos once both live in one
  table. First registration wins, and the second is shown as taken rather than
  silently losing.
- **A docked tool whose surface is not resident yet** (phases 1–2): the dock
  shows its run card. No dead tab, no empty panel.
- **A gizmo deleted while docked and keyed to a shortcut**: `DockStore.prune`
  already runs on `toolsStore.onChange`; the shortcut registry gets the same
  hook, so the key is released rather than left registered to nothing.
- **Migration run twice** (a downgrade then an upgrade): keys are written in the
  new form and the old form is removed, so the second run finds nothing to do.

## Testing

- `ToolRefTests` — `storageID` round-trips, and migration maps every current key
  form (`"notes"`, a bare UUID, `globalShortcut.dictate`) to the right ref.
- `DockStoreTests` — extended with the migration cases.
- `ShortcutRegistryTests` — two tools cannot hold the same key; releasing a tool
  frees its Carbon id for reuse.
- Phase 3 is verified by running: every surface must behave exactly as before in
  its floating default. That is the point of doing it as code motion.

## Files

Phase 1 touches `Dock/DockItem.swift`, `MainWindow/BuiltInEditor.swift`.
Phase 2 adds `Tools/ToolRef.swift` and touches `Dock/DockStore.swift`,
`App/Shortcuts/GlobalShortcutModels.swift`.
Phase 3 adds `Ask/AskSurface.swift`, `Panels/ResultSurface.swift`,
`Live/LiveSurface.swift` and thins the three controllers.
Phase 4 touches `App/HotKeys.swift`, `App/Shortcuts/*`,
`MainWindow/ToolEditor.swift`.

Exact file lists per phase belong in that phase's plan, not here — phases 3 and
4 will read differently once phase 2 has landed.
