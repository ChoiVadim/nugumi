# Edge dock — tools that live on the screen edge

## The problem

Every surface Gizmate has today is summoned: the ring opens at the cursor, the
panel opens over the selection, the main window opens when you go looking for
it. Nothing is _there_ waiting. That is right for "act on what I selected" and
wrong for "let me glance at my notes" — a thing you want in reach without
deciding to reach for it.

The screen edges are the free real estate for that. The notch in particular is
dead space macOS already reserves.

## What we are building

Three docks — top (in/under the notch), left, right. Each dock is a container
that holds an ordered list of items shown as tabs. Hovering the edge reveals the
dock; picking a tab expands that item's panel.

For v1 exactly one item exists: **Notes**. The mechanism is built so that a
user-generated gizmo becomes the second one without the dock learning anything
new about it — see "Why the container shape" below.

## Non-goals

- **Generated tools with their own UI.** Its own spec, next. The dock is shaped
  to receive it (see `DockItem.makeView`) and nothing more.
- **Multi-monitor.** Main screen only. A second dock per screen is a loop over
  `NSScreen.screens` when someone asks; nothing in this design forbids it.
- **Reordering tabs by drag.** Tab order is the order items were docked.
- **Replacing the ring.** The ring is "do something to this selection, here".
  The dock is "open this thing". They coexist and do not share content.

## Why the container shape

The alternative was one tab per item, each with its own panel. Rejected: with
six items docked right, the edge becomes a column of buttons that needs its own
overflow rule, and every item pays for window plumbing it doesn't use.

A container means the dock owns the window, the reveal, the geometry and the
tab strip, and an item owns nothing but its content. So an item is:

```swift
struct DockItem {
    let id: String              // "notes", or a GizmateTool UUID string
    let title: String
    let symbolName: String
    let makeView: () -> NSView
}
```

A struct with a closure, not a protocol. There is one implementation today and a
protocol with one implementation is a shape waiting for a second — but the
closure already buys the extensibility, because `NSView` is the only thing the
dock ever needs. A SwiftUI notes view today, a schema-rendered gizmo view
tomorrow; the dock cannot tell the difference and must not be able to.

## Components

### `DockStore` — placement, persisted

```swift
enum DockEdge: String, Codable, CaseIterable { case top, left, right }
```

`@Published private(set) var placement: [DockEdge: [String]]` — edge to ordered
item ids. Same `@Published` + `onChange` contract as `NotesStore` and
`SnippetsStore`, so the settings UI binds identically.

Persisted to UserDefaults under `com.nugumi.app.dock.v1`. Lenient decoding, same
reason as `Note` and `GizmateTool`: an item id that no longer resolves (a gizmo
the user deleted) is dropped at read time, not thrown.

An item lives on at most one edge. `dock(_ id: String, to: DockEdge?)` moves it,
`nil` undocks.

### `DockGeometry` — pure functions, no windows

```swift
static func notchRect(on screen: NSScreen) -> NSRect
static func revealZone(for edge: DockEdge, on screen: NSScreen) -> NSRect
static func stripFrame(for edge: DockEdge, tabCount: Int, on screen: NSScreen) -> NSRect
static func expandedFrame(for edge: DockEdge, contentSize: NSSize, on screen: NSScreen) -> NSRect
```

`notchRect` reads `screen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`: the
notch is the gap between them. On a Mac without a notch both are nil, and we
return a virtual 200pt-wide rect centred on the menu bar — the same convention
NotchNook and friends use, so the feature is not Mac-model-gated.

Everything here is a pure function of a rect, which is the whole point: it is
where the geometry bugs will be, and it is testable without ever opening a
window. `Tests/GizmateTests/DockGeometryTests.swift` covers notched and
notchless screens plus the three reveal zones.

### `EdgeDockController` — one per edge

Owns an `EdgeDockPanel` and a state:

```swift
enum DockState { case hidden, strip, expanded(itemID: String) }
```

**Panel configuration**, following `RadialMenuController` and `KeyableLivePanel`:

- `.nonactivatingPanel`, `isFloatingPanel = true`, `hidesOnDeactivate = false`
- `canBecomeKey` overridden to `true`, the way `KeyableLivePanel` does it. A
  `.nonactivatingPanel` will not take key focus by default, and the docked Notes
  view has a text field in it — without this the panel reveals and then swallows
  every keystroke.
- `level = .statusBar` — the top dock has to draw over the menu bar
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- `constrainFrameRect(_:to:)` overridden to return the rect unchanged. Copied
  verbatim from `RadialMenuPanel` and for the same reason: AppKit silently pulls
  windows out from under the menu bar, which is exactly where the top dock lives.
- `isOpaque = false`, `backgroundColor = .clear`, content in a `GlassHostView`

**Reveal.** While `hidden` the panel is `orderOut` — there is no window on the
edge at all. This is deliberate and it is the reason the feature does not break
anything: a transparent catcher window along the edge would eat clicks meant for
scrollbars and other apps' window frames. Instead one
`NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` plus its local twin
(global monitors don't fire while Gizmate itself is frontmost) tests the pointer
against `revealZone` and orders the panel in.

The monitor is installed once and shared by all three controllers via a small
`DockHoverMonitor`, throttled to ~30Hz. Three independent monitors on
`.mouseMoved` would be three closures on every pointer move.

**Reveal behaviour differs per edge, on purpose:**

| Edge         | Hover                          | Click                     |
| ------------ | ------------------------------ | ------------------------- |
| top          | expands straight to `expanded` | tab switches item         |
| left / right | shows `strip`                  | tab expands to `expanded` |

The notch is a handle you can already see, so a hover there can commit. The side
edges have nothing visible, so the hover has to produce the affordance first —
which is what the reference screenshots show, and it is also the honest
behaviour: an invisible edge that opens a full panel on hover would fire every
time the pointer crossed the screen.

`expanded` always draws the tab strip alongside the item's content — on top as a
row above it, on the sides as a column beside it — so switching items never
requires collapsing first. With a single item docked the strip is omitted
entirely: one tab is chrome that names what you are already looking at.

**Dismiss.** Escape, a click outside, or the pointer leaving the dock's frame
for longer than 400ms. Same `dismissMonitors` pattern `RadialMenuController`
already uses — with one addition: the pointer-left timer does not run while the
panel is key and its first responder is a text field. Typing a note is exactly
when the pointer sits still somewhere else, and a dock that vanished mid-sentence
would lose what was typed.

**Animation — the landmine.** Expanding animates the _window_ frame; the
`GlassHostView` fills `contentView` and follows. Collapsing does **not** shrink:
it fades the window at its current frame and orders out. Liquid glass takes its
shape from the model frame and teleports on frame-one of any close animation,
which pops a disc at the centre — this cost the ring a rewrite already, and the
dock must not relearn it.

### `DockNotesView` — the first item

Compact by construction, because the same view has to work in a wide-and-short
top panel and a narrow-and-tall side panel. `NotesSection` cannot: it is built
around `DetailContainer` with a title, subtitle, pinned tag bar and a
`PageBanner`, which in a 360pt panel is a full screen of chrome before the first
note.

Contents, top to bottom:

1. A one-line "new note" field. Return saves via `NotesStore.add(text:tagID:)`
   using the currently selected tag.
2. Tag chips — `nil` for All, then `notesStore.tags`. Filters the list below.
3. The 20 most recent matching notes, each row `note.displayTitle` plus a
   relative timestamp. Click opens it inline for editing via
   `NotesStore.update(_:text:)`.
4. "All notes" — opens the main window on the Notes section.

Reads and writes the same `NotesStore` through the existing
`GizmateSettingsBridge`. No second source of truth, no sync.

### Settings

Settings → General gains a **Dock** group: one row per dockable item with a
four-way segmented control — Off / Top / Left / Right. Today that is one row,
Notes, defaulting to Off. A dock nobody asked for that appears on first launch
would be a surprise on the user's screen edge.

## Data flow

```
pointer moves
  → DockHoverMonitor (throttled)
  → EdgeDockController.revealZone hit?
  → panel orders in as .strip (sides) or .expanded (top)
  → user clicks tab
  → DockItem.makeView() hosted in the panel's GlassHostView.contentView
  → item talks to its own store (NotesStore) as it always did
```

The dock never touches note data. It positions a window and hosts a view.

## Errors

There is no I/O and no model call in this feature, so the failure modes are
geometric:

- **Screen disappears** (display unplugged, resolution change):
  `NSApplication.didChangeScreenParametersNotification` → recompute frames, and
  if the dock's screen is gone, `hidden` and recompute against `NSScreen.main`.
- **Item id no longer resolves** (docked gizmo deleted): dropped from
  `DockStore` at read time; a dock left with zero items never reveals.
- **Notch geometry unavailable**: falls back to the virtual notch, which is the
  same path every notchless Mac takes, so it is exercised constantly rather than
  being an untested branch.

## Testing

- `DockGeometryTests` — notch rect on notched and notchless screens, reveal
  zones for the three edges, expanded frames clamped to the visible frame.
- `DockStoreTests` — placement round-trips through a scratch `UserDefaults`
  suite (the pattern `NotesStore`'s tag tests already use), an item moves
  between edges without duplicating, unknown ids drop on decode.
- Windowing and hover are verified by running the app: `swift run Gizmate`.

## Files

```
Sources/Gizmate/Dock/DockStore.swift
Sources/Gizmate/Dock/DockItem.swift
Sources/Gizmate/Dock/DockGeometry.swift
Sources/Gizmate/Dock/DockHoverMonitor.swift
Sources/Gizmate/Dock/EdgeDockController.swift
Sources/Gizmate/Dock/DockNotesView.swift
Tests/GizmateTests/DockGeometryTests.swift
Tests/GizmateTests/DockStoreTests.swift
```

Modified:

- `App/GizmateApp.swift` — hold `dockStore` and the three controllers
- `MainWindow/Core/GizmateSettingsBridge.swift` — expose `dock`
- `MainWindow/Sections/SettingsSection.swift` — the Dock group

New folder `Sources/Gizmate/Dock/`, matching the one-subsystem-per-folder rule.
SwiftPM discovers it with no `Package.swift` change.

## What comes after

`ToolOutput.view`: a gizmo prints a block schema instead of text, Gizmate renders
it with its own SwiftUI components, and the result is a `DockItem` like any
other. The model emits data, never code or markup, so a generated gizmo cannot
diverge from the app's look. That is a separate spec; this one only has to leave
`DockItem.makeView` in place, which it does.
