# Surface gizmos — generated tools that show something on the edge

## The problem

Every gizmo Gizmate can generate is a one-shot: input arrives, the script runs,
`deliver` routes the result by `tool.output` and it is over
(`GizmateApp+ScriptTools.swift:578`). Even `.files` only calls
`activateFileViewerSelecting` — it opens Finder and forgets.

That model cannot express the thing a person asks for most naturally once they
have an edge dock: **"show me my Downloads on the side of the screen so I can
drag files out of it into other apps."** A folder hub is not a result. It is
resident — it exists before any run, it shows state rather than an answer, and
its whole point is what you do _with_ what it shows.

The edge dock was built for this and stops one step short: `DockItem` already
takes any `NSView`, but `DockCatalog.gizmos(host:)` returns `[]`, with a comment
saying a gizmo earns a place "as soon as the result panel is a view rather than
a window". That is the wrong condition. A gizmo earns a place when it has
something to show while nothing is running.

## What we are building

A fourth thing a generated tool can be: a **surface**. `output == .surface`
means the tool does not deliver a result at all — it renders into a dock.

Two halves, split by when they run:

- **Build time.** The agent composes a layout tree out of a closed set of
  components Gizmate ships. The tree is stored in the tool's manifest,
  validated on the way in, and never changes again.
- **Run time.** The script prints rows of data. The host renders those rows
  through the stored layout. **No model is involved.**

The runtime rule is not an optimisation, it is the constraint the whole design
falls out of: a dock opens on pointer hover (`DockHoverMonitor` →
`EdgeDockController.pointerMoved`). There is no LLM call that fits in that
budget, at any price. So everything the model does, it does once, at build time,
and the artifact runs forever without it — exactly as `.prompt` and `.python`
gizmos already work.

### Why a closed component vocabulary rather than generated UI

The rejected alternative was letting the agent write HTML into a `WKWebView`.
Two facts kill it:

1. **A file cannot be dragged out of a web view into another app.** Chrome
   supports `DataTransfer.setData('DownloadURL', …)`; WebKit does not. Getting a
   real file into Slack or Finder on mouse-up requires `NSItemProvider` or
   `NSFilePromiseProvider` on the AppKit side. Drag-out is the entire point of
   the request, and it is native-only.
2. Gizmate has a design system with teeth (`DESIGN.md`). A SwiftUI tree renders
   inside it for free; HTML would have to be re-persuaded to look like the rest
   of the app on every single generation.

A closed vocabulary also makes the layout **validatable**. The agent cannot name
a component that does not exist, the same way it cannot name an output that does
not exist — `invalidCandidate`, at build time, before the user ever sees it.

## Non-goals for v1

- **Buttons that call back into the script.** "Delete", "Archive", "Open PR".
  Needs a second run mode, a result protocol, and confirmation for destructive
  actions. v2 — see "What v2 adds".
- **Drop-in.** Dragging a file _onto_ the dock to hand it to the gizmo. Same
  second run mode. v2.
- **An expression language.** No conditionals, no arithmetic, no formatting in
  bindings. A script that wants "3.2 MB" prints `"3.2 MB"`.
- **A layout that changes with the data.** The tree is fixed at build time. A
  surface that wants to look different when empty gets `empty(…)` and nothing
  more.
- **FSEvents.** A surface refreshes when the dock opens, not while you watch it.

v1 is deliberately the read-only half, because the asymmetry is enormous:
drag-out costs about five lines and asks nothing of the agent, while callbacks
cost a protocol. The folder hub from the original request works completely
without any of the v2 half.

## Protocol

```swift
ToolAgentCandidateOutputV1 += .surface     // ToolAgentProtocolTypes.swift
ToolAgentCandidateV1       += layout: ToolAgentLayoutV1?
```

`layout` is required when `output == .surface` and rejected otherwise —
validated in `CandidateValidation`, mirrored in `ToolAgent/src/protocol.ts`
(four `z.enum` sites) and `tools.ts`.

`.surface` is added to the existing output enum rather than becoming a parallel
axis. That is not paperwork: `ToolProtocolEnumParityTests` then **forces** a
case into `ToolEvalSuite.resultSweep`. CLAUDE.md records that twice a new case
reached the enum, the sidecar schema and the capability description while
missing one hand-written allowlist in the host, and both times a user found out
first.

`.surface` is deliverable by `.python` only. Not `.native` (no script, no rows),
not `.prompt` (a model per hover), not `.agent` (same). Its `input` is `.none`
and its `trigger` is `.always`.

### The layout tree

```swift
indirect enum ToolAgentLayoutV1: Codable, Equatable, Sendable {
    case grid(cell: ToolAgentLayoutV1, minimumWidth: Int, empty: String)
    case list(row: ToolAgentLayoutV1, empty: String)
    case card(icon: Icon?, title: Binding, subtitle: Binding?,
              drag: Drag?, tap: Tap?)
    case text(Binding)
}

enum Binding { case key(String); case literal(String) }   // "$name" or "text"
enum Icon    { case file(key: String); case symbol(String) }
enum Drag    { case file(key: String); case text(key: String) }
enum Tap     { case open(key: String); case reveal(key: String) }
```

Four nodes, three modifiers. `grid` and `list` repeat their child once per row;
`card` and `text` are leaves. Nesting depth is capped at 3 — a surface is a
strip on a screen edge, not a document.

`empty` is a property of the repeater, not a node. It has nowhere else to live:
the root must be a repeater, so a sibling node could never be reached, and the
copy only means anything in the one place that can have zero children.

`Icon.file(key)` resolves through `NSWorkspace.shared.icon(forFile:)` — the same
icon Finder shows, including document thumbnails and app icons, for free. A
script listing files does not produce icons; it produces paths.
`Icon.symbol` names one of the bundled Phosphor glyphs for rows that are not
files, resolved through `RingIconKind` so a surface cannot draw art the ring
cannot.

The folder hub in full:

```
grid(minimumWidth: 96, empty: "Nothing in Downloads") {
  card(icon: file($path), title: $name, subtitle: $size,
       drag: file($path), tap: reveal($path))
}
```

### Components (hand-written, in `Sources/Gizmate/Dock/Surface/`)

| Node   | View                             | Reuses                                 |
| ------ | -------------------------------- | -------------------------------------- |
| `grid` | `LazyVGrid(.adaptive(minimum:))` | the `NotesGrid` pattern, DESIGN.md §12 |
| `list` | `LazyVStack`                     | —                                      |
| `card` | icon + title + optional subtitle | `NoteCard`'s frame rules               |
| `text` | one label                        | `FlowTheme` type scale                 |

Both repeaters render their `empty` copy as centred `inkSecondary` text when the
rows are empty; that is a branch inside the repeater's view, not a fifth
component.

Adding a fifth component is four edits: the SwiftUI view, an enum case, one line
in the model's catalog description in `model-bridge.ts`, and an eval case. That
list _is_ the answer to "how do we make generating these tools possible" — the
vocabulary is data, not model knowledge.

## The script contract

Run modes are selected by environment variable, matching `GIZMO_OPTION`
(`ToolRunner.swift:176`). argv is left alone: `.files` input already means one
argv entry per file, and a flag there would collide.

```
render (v1, the only mode):  no extra env
  stdout: {"rows": [ {"id": "…", "name": "…", "path": "…"}, … ]}
```

A row is a **flat dictionary of strings**. Two keys the host understands itself:

- `id` — stable identity across refreshes.
- `path` — by convention the file URL that `icon: file`, `drag: file` and
  `tap:` point at. Any key may hold one; `path` is what the agent is told to
  call it so surfaces read alike.

Every other key is inert data that bindings address as `$key`. Validation
rejects a layout whose binding names a key the fixture rows do not contain, and
rejects `drag: file` / `tap:` on rows without `path`.

Limits: 500 rows, 32 keys per row, 1 KB per value, 256 KB of stdout. A surface
that wants to show more than 500 things has misunderstood the screen edge.

## Rendering and refresh

```
DockCatalog.gizmos(host:)  →  one DockItem per tool with output == .surface
                              makeView: { SurfaceView(layout:, rows:) }
```

`SurfaceRowsCache` persists the last rows per tool under `GizmatePaths`. The
sequence on reveal:

1. Draw cached rows immediately.
2. Run the script in the background.
3. Swap in the new rows when it returns; on failure keep the cache and show a
   quiet staleness marker.

Without the cache every hover on a screen edge is a ~300 ms uv + Python start
staring at an empty panel. Refresh happens on reveal only.

## Interaction

- **Drag out** — `.onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) }`.
  Host-side, works into any macOS app, and the script never learns it happened.
- **Tap** — `NSWorkspace.shared.open(url)` or `activateFileViewerSelecting([url])`.

Both are pure host behaviour driven by `path`. This is why v1 needs no callback
protocol at all.

## Approval and trust

A surface breaks an assumption every other tool holds: that a script runs
because the user pressed something. A surface runs its script on pointer hover.

Nothing new is executed — it is the same sandboxed `ToolRunner` → worker XPC →
`CToolSandbox` path, and the tool went through the same approval-on-save gate.
What changes is the trigger, so it must be said plainly where the user docks the
gizmo: **this gizmo runs whenever its dock opens.** Docking is the consent.

## Validation and eval

Build-time checks in `CandidateValidation`:

- every referenced component exists and nesting depth ≤ 3;
- exactly one repeater (`grid`/`list`) at the root;
- every `$key` appears in the candidate's fixture rows;
- every key named by `icon: file`, `drag: file` or `tap:` holds a file URL in
  those rows — the key is conventionally `path`, but nothing forces the name;
- `layout` present iff `output == .surface`.

The eval case (`ToolEvalSuite.resultSweep`, written the way a user would type
it): _"show my downloads on the side of the screen so I can drag them out"_. It
passes when the agent produces a script whose stdout parses as rows, plus a
layout that validates and instantiates. Per CLAUDE.md, if it fails, the fix is
the generic machinery — never a recipe in the system prompt.

## Files

```
Sources/GizmateToolAgentCore/  ToolAgentProtocolTypes.swift   +.surface
                               ToolAgentLayoutV1.swift        new
ToolAgent/src/                 protocol.ts, tools.ts, model-bridge.ts
Sources/Gizmate/Tools/         GizmateTool.swift              +layout, labels
                               CandidateValidation.swift      layout rules
Sources/Gizmate/Dock/Surface/  SurfaceView.swift              new
                               SurfaceCard.swift, SurfaceGrid.swift, …  new
                               SurfaceRows.swift              new (decode + limits)
                               SurfaceRowsCache.swift         new
Sources/Gizmate/Dock/          DockItem.swift                 gizmos() stops being []
Sources/Gizmate/App/           GizmateApp+ScriptTools.swift   .surface = no delivery
                               ToolEvalMode.swift             eval case
Tests/                         layout validation, row decoding, parity
```

## What v2 adds

Named here so v1's shape does not have to be re-litigated later:

- `card(actions: [{id, label, confirm?}])` plus an `action` run mode
  (`GIZMO_ACTION`, `GIZMO_ITEM`) returning fresh rows.
- Drop-in: the panel as an `NSDraggingDestination`, `GIZMO_DROPPED` carrying the
  paths.
- FSEvents on a declared watch path, for surfaces that must change while visible.

Each is additive. None requires the v1 layout tree, script contract, or refresh
model to change.
