# Gizmate Design System

## 1. Atmosphere & Identity

Gizmate should feel like a quiet Mac-native command surface: compact, glassy, and direct. The signature is dark liquid glass around a restrained near-black settings shell, with a single Gizmate green accent used only for progress, success, and primary action.

## 2. Color

### Palette

| Role            | Token                                        | Light                  | Dark                   | Usage                                               |
| --------------- | -------------------------------------------- | ---------------------- | ---------------------- | --------------------------------------------------- |
| Surface/glass   | `FlowTheme.glass`                            | transparent            | transparent            | Visual-effect-backed window background              |
| Surface/card    | `FlowTheme.card`                             | rgba(255,255,255,0.06) | rgba(255,255,255,0.06) | Settings panels and setup cards                     |
| Surface/subtle  | `FlowTheme.subtleFill`                       | rgba(255,255,255,0.08) | rgba(255,255,255,0.08) | Secondary fills and inactive controls               |
| Text/primary    | `FlowTheme.ink`                              | #FFFFFF                | #FFFFFF                | Headings, body, active controls                     |
| Text/secondary  | `FlowTheme.inkSecondary`                     | #BDBDBD                | #BDBDBD                | Supporting copy and secondary labels                |
| Text/tertiary   | `FlowTheme.inkTertiary`                      | #8C8C8C                | #8C8C8C                | Disabled, metadata, inactive icons                  |
| Border/hairline | `FlowTheme.hairline`                         | rgba(255,255,255,0.10) | rgba(255,255,255,0.10) | Dividers and quiet outlines                         |
| Accent/primary  | `FlowTheme.accent` / `NSColor.gizmateAccent` | #C9C9C9                | #C9C9C9                | Success, selected state, primary setup progress     |
| Accent/soft     | `FlowTheme.accentSoft`                       | rgba(255,255,255,0.18) | rgba(255,255,255,0.18) | Soft selected backgrounds                           |
| Status/error    | `FlowTheme.danger`                           | #FF8C8C                | #FF8C8C                | Failed setup status, and armed destructive controls |

### Rules

- Keep Gizmate green functional, not decorative.
- Prefer white opacity tokens over extra gray constants for panels and dividers.
- New semantic colors must be added here before use.

## 3. Typography

### Scale

| Level      | Size | Weight         | Line Height | Tracking | Usage                                           |
| ---------- | ---- | -------------- | ----------- | -------- | ----------------------------------------------- |
| Display    | 30px | regular        | system      | 0        | Main section headings via `FlowTheme.serif(30)` |
| H2         | 29px | regular        | system      | 0        | Onboarding panel headings                       |
| Card title | 15px | semibold       | system      | 0        | Settings cards and provider groups              |
| Row title  | 14px | medium         | system      | 0        | Setup rows and model rows                       |
| Body       | 13px | regular/medium | system      | 0        | Controls, compact explanatory text              |
| Caption    | 12px | regular        | system      | 0        | Secondary copy and status detail                |
| Micro      | 11px | semibold       | system      | 0        | Monospaced section labels and progress markers  |

### Font Stack

- Primary: Apple system sans via `.system`.
- Serif: Apple system serif through `FlowTheme.serif`.
- Display wordmark: bundled Pixelify through `Font.nugumiPixel`.

### Rules

- Main-window copy stays compact; do not use hero-scale type inside settings cards.
- Use medium and semibold for hierarchy instead of larger sizes.
- Letter spacing remains `0` unless an existing monospaced label already defines it.

## 4. Spacing & Layout

### Base Unit

All spacing maps to the 4px grid.

| Token     | Value | Usage                      |
| --------- | ----- | -------------------------- |
| `space-1` | 4px   | Tight label stacks         |
| `space-2` | 8px   | Icon-to-label, row gaps    |
| `space-3` | 12px  | Standard row spacing       |
| `space-4` | 16px  | Setup card internal stacks |
| `space-5` | 20px  | Card padding variant       |
| `space-6` | 24px  | Provider group spacing     |
| `space-8` | 32px  | Major panel separation     |

### Grid

- Main window uses a fixed sidebar plus flexible detail panel.
- Cards are un-nested `SubCard` panels with constrained text and stable row heights.
- Setup rows use glyph, text stack, spacer, then compact secondary buttons.

### Rules

- Do not add a card inside another card unless the existing component already owns the frame.
- Preserve arbitrary-window resizing; no text may clip at narrow widths.
- Setup and provider rows should not shift layout when status text changes.

## 5. Components

### `SubCard`

- **Structure**: One framed panel with vertical content.
- **Variants**: Default padding, compact padding, fill-height.
- **Spacing**: 16-24px internal rhythm.
- **States**: Static container only.
- **Accessibility**: Contains real buttons and labels; no fake interactive badges.
- **Motion**: None.

### `SecondaryButton`

- **Structure**: Compact SwiftUI button with rounded rectangle surface.
- **Variants**: Normal and destructive.
- **Spacing**: Minimum width only where repeated rows need alignment.
- **States**: Hover/press handled by platform button behavior and existing style.
- **Accessibility**: Visible text labels only.
- **Motion**: None.

### `SetupStepRow`

- **Structure**: Status glyph, title/status copy, flexible spacer, optional secondary and primary actions.
- **Variants**: Unknown, checking, ok, needs action, working, failed.
- **Spacing**: 12px horizontal gap, 2px text gap.
- **States**: Status copy appears only when meaningful; action buttons hide when terminal OK.
- **Accessibility**: Status is textual as well as visual.
- **Motion**: Progress spinner only for checking/working.

## 6. Motion & Interaction

### Timing

| Type     | Duration  | Easing      | Usage                                                |
| -------- | --------- | ----------- | ---------------------------------------------------- |
| Platform | system    | system      | Native buttons, menus, focus                         |
| Micro    | 100-150ms | ease-out    | Hover treatments already present in onboarding cards |
| Standard | 200-300ms | ease-in-out | Tab and panel transitions if added later             |

### Rules

- Prefer native AppKit/SwiftUI interaction behavior.
- Do not animate layout properties.
- Progress should use `ProgressView` for long-running setup work.

## 7. Depth & Surface

### Strategy

Mixed, but constrained: real `NSVisualEffectView` glass at the window layer, translucent tonal card fills inside it, and one-pixel hairlines for structure.

| Level           | Value                                   | Usage                   |
| --------------- | --------------------------------------- | ----------------------- |
| Window glass    | `NSVisualEffectView.Material.hudWindow` | Main shell/background   |
| Card tonal fill | white opacity 0.06                      | Settings panels         |
| Hairline        | white opacity 0.10                      | Separators and outlines |

### Rules

- Do not introduce generic drop shadows.
- Use tonal fills and hairlines for hierarchy.
- Keep card radius aligned with existing component radius unless changing a whole component family.

## 8. Scrollers

**Thin, overlay, auto-hiding, light knob. Everywhere, no exceptions.** A scroller
that holds a track open while nothing is scrolling is the loudest thing in a
small panel, and macOS's "Show scroll bars: Always" turns that on for a large
share of users regardless of what looks right.

| Context                                 | How                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------------------------- |
| SwiftUI `ScrollView`, main window       | `.background(ScrollerConfigurator())` inside the content                              |
| SwiftUI content, borderless panel       | `OverlayScrollHost { … }` — **not** a `ScrollView`                                    |
| An `NSScrollView` you own               | `scrollerStyle = .overlay`, `autohidesScrollers = true`, `scrollerKnobStyle = .light` |
| An `NSScrollView` in a borderless panel | subclass `OverlayScrollView`                                                          |

- In a borderless panel, AppKit **reverts** a manually-set `.overlay` back to the
  wide legacy scroller, whose track never hides. Setting the property is not
  enough there — `OverlayScrollView` (`Live/LiveCaptionViews.swift`) overrides
  the getter so the revert cannot land. A SwiftUI `ScrollView` cannot be given a
  custom `NSScrollView` subclass, so in a panel the nesting inverts: host the
  SwiftUI content inside `OverlayScrollHost`, which owns the scroll view.
- **A scroll view nested in a list must pass the wheel through.** An
  `NSScrollView` swallows `scrollWheel` even with nothing to scroll, so a text
  editor inside a card stops the list dead wherever the pointer rests. Forward to
  `nextResponder` unless the editor is first responder — being edited is the one
  case with a real claim on it. `PassthroughScrollView` does this and
  `PlainTextEditor` uses it.
- SwiftUI's `TextEditor` re-applies its own scroller config on every update, so
  nothing set on it sticks. Use `PlainTextEditor`, which owns its
  `NSScrollView` — and which also avoids the bug where dismissing a panel
  containing a SwiftUI `TextEditor` leaves the main window swallowing clicks.
- **No `LazyVGrid`/`LazyVStack` — or a raw `GeometryReader` — directly inside
  `OverlayScrollHost`.** Its document view leaves height deliberately
  unbounded so the `NSScrollView` has something to scroll; a lazy container
  or a `GeometryReader` asked to size itself against an unbounded axis
  collapses to zero rather than picking a fallback, and the panel renders
  nothing. Hit twice: `NotesGrid`'s dock path went eager (`add5b4f`), then
  the folder hub's `.grid` surface shipped with a `LazyVGrid` anyway and
  reproduced it exactly. Multi-column content should measure its width with
  a `GeometryReader` placed _outside_ `OverlayScrollHost` — where the
  container is already resolved on every side — and pass that down as a
  plain value to an eager, chunked layout (`SurfaceGrid` in
  `Dock/Surface/SurfaceView.swift`), not try to self-size from inside it.

## 9. Glass surfaces

- **Never animate a glass view's frame on close.** Glass takes its shape from the
  model frame and teleports on frame one of a closing animation, popping a disc
  at the panel's centre. Opening may animate a frame; closing fades in place and
  orders out. This cost the ring a rewrite.
- **No glass inside glass.** A panel is one glass surface; controls on it are
  drawn with tint, not with their own material.
- **Buttons on glass are tint-only — no plate.** A filled rounded rect on glass
  fights the shape it sits in and has to be clipped against the panel's corners.
  Show state with the icon's tint (`ink` active, `inkSecondary` resting), as
  `HoverIconButton` does.

## 10. Panels that touch the bezel

- **Square the corners that meet the screen edge, and flare them inward.** A
  rounded corner flush against the bezel reads as a gap.
  `DockGeometry.panelPath` builds the concave shape and
  `GlassHostView(cornerPath:)` takes it as a mask — `CALayer.cornerRadius` can
  only round outward, so a concave corner needs a path.
- **No window shadow.** macOS pairs a shadow with a thin light rim, and on a
  panel hugging the bezel that rim reads as a border along the screen edge.
- **Slide in from the bezel, and leave the way you came.** Arriving from
  off-screen is what makes a panel read as coming out of the edge rather than
  being placed on top of it; retracting into the same edge — accelerating out,
  the mirror of the decelerating arrival — is what keeps it one thing moving
  instead of two effects sharing an edge. Every dock does both. What makes the
  exit safe is that it is a pure _translation_: liquid glass takes its shape
  from the model frame and teleports on frame-one of a resizing close, so a
  shrink still pops a disc at the centre, but a window that only moves carries
  its glass along unchanged. The retraction is measured from wherever the panel
  currently is, not from where it opened, so a side dock dragged halfway to its
  bezel by hand carries on in that same direction rather than snapping back to
  finish the trip.

## 11. Dock behaviour

- **A peek closes itself; a window the user opened does not.** The notch and the
  side tab strips come and go with the pointer. An expanded side dock stays until
  dismissed on purpose — dragged shut by its handle, or Escape. Clicking into
  another app is how you _use_ what is on the edge, so it must not dismiss it.
- **Every way out has a visible affordance.** A dock that stays open carries
  `DockDragHandle` on its inner edge. An exit nobody can see is not an exit.
- **A top dock keeps the notch's height clear, and grows to pay for it.** The
  panel starts at `screenFrame.maxY` on purpose, so it reads as the notch
  growing rather than as a window appearing beneath it — which puts its first
  menu-bar-height points physically behind the housing on a notched Mac.
  Content there isn't dim or clipped, it is invisible, and the folder hub's
  chips sat in exactly that strip. The inset belongs to
  `EdgeDockController.topContentInset` rather than to any one view: every top
  resident pays the same toll, and a hub that padded itself would leave the
  next one to rediscover the notch. The inset is added to the panel's height
  as well as to its content, so a top dock still gets its full 300pt.
- **Never auto-close over a text field.** While the panel holds key focus in an
  `NSTextView`, the pointer is parked elsewhere by definition, and closing throws
  away what was typed.
- **Horizontal distance decides a side dock, never vertical.** How far down the
  screen the pointer is says nothing about whether it is heading for an edge.
- **Draw thin, but hit big.** `DockDragHandle` is 4pt of ink inside a 16pt
  target. A 4pt target is a miss waiting to happen.
- **A gizmo can be a dock's resident, not just something it summons.** Every
  other result exists only after a run finishes, so a tab for one is either
  empty or a false promise until then. A `.surface` gizmo is the exception:
  its script's last output is already sitting in `SurfaceRowsCache`, so its
  tab has something to draw before it ever hovers into view. That is the same
  rule `residentBuiltIns` states for Note, and `DockCatalog.dockableGizmoOutputs`
  is where a gizmo output earns the same standing — an output added there
  needs a real answer to "what does this tab show with nothing running yet?",
  not just "what does it show after."
- **A resident does not have to be a ring action or a gizmo.** The folder hub
  is a third kind: it is not in `residentBuiltIns` (no `RingActionID` names
  it) and not a gizmo output in `dockableGizmoOutputs` (no `GizmateTool`
  behind it either) — `DockCatalog.builtIns` appends it directly, because a
  folder listing passes the same "something to draw before any run starts"
  test Note and a `.surface` gizmo do, without a run to speak of at all.
- **Placement splits by kind, not by screen.** Both halves write the same
  `DockStore` key, and for a while both were written from `EdgesSection` alone
  — one screen, one writer, which read as the tidy rule. It wasn't: it forced
  five lists onto a page about three places, and put a segmented picker in
  front of "where does Explain's answer open" as though that were a question
  about the shape of the screen. It is a question about one tool. The split
  that actually holds is between the two things a placement can mean.
  **Where a resident waits** is a property of the screen: several share one
  edge, in an order only that edge can decide, and every one of them draws
  something before any run starts. That is `EdgesDiagram` and nothing else.
  **Where a result panel opens** is a property of one tool: it draws nothing
  until that tool runs, it never shares an edge, and there is no order to
  arrange it in. That goes back to the tool's own editor — `ToolEditorPanel`
  and `BuiltInEditor` each call `DockPlacementPicker` directly again.
  `PanelPlacement` is the live gate both editors ask, and
  `DockPlacementParityTests` pins two things about it: that it agrees with the
  sets the editors are really gated on, and that it is **disjoint** from
  `EdgesSection.offeredIDs`. Overlap is the failure that matters — one id with
  two controls writing it is exactly what collapsing everything onto one
  screen was meant to prevent, and the split only keeps that promise while the
  two sides cannot both claim the same tool.
  Settings → General's Files card stays deleted: a card whose whole content is
  "go to Edges" is a signpost, not a setting. The folder hub remains the one
  resident with no editor of its own — `BuiltInEditor`'s gate is a
  `RingActionID`, `ToolEditorPanel`'s a `GizmateTool`, and it has neither —
  but that costs nothing now, because a resident is placed on the figure
  rather than from an editor. `EdgesSection.residentWithoutARingSlot` names its
  id for `DockPlacementParityTests`, which holds it, together with
  `dockableBuiltIns` mapped to ring-action ids, against every id
  `DockCatalog.builtIns(host:)` actually returns.
- **Edges is a picture of a screen, not a list of edge names.** Three cards
  headed "Top", "Left", "Right" plus two more lists underneath made a person
  translate three words back into a picture of their own monitor before they
  could decide anything, and left five places a tool could be listed for three
  places it could be. `EdgesDiagram` draws one screen with a rail on each edge
  a dock can hang off, and every resident is on it exactly once: on a rail, or
  in the middle — which _is_ "not on an edge", not a fourth place. That is why
  dropping in the middle is `dock(_:to: nil)` and not a placement of its own,
  and why it is still the only way back off an edge: a rail tile carries no
  picker, because a picker would fight the tile's own drag for the same click.
  Same reasoning as `RingDiagram`, and it borrows nothing else from it —
  the ring needs a hand-rolled `DragGesture` because its targets are discs on
  a circle with folders that spring open under a carried button, while four
  rectangles are exactly what `.draggable` / `.dropDestination` already do.
- **The top rail holds one, and that was always true.** `EdgeDockController`
  expands straight to `items[0]` on hover — the top dock has no tab strip — so
  a second resident up there was stored and then never shown again. The figure
  states the rule instead of quietly discarding it, and a drop onto an
  occupied top rail evicts rather than refuses: a rail that silently declines
  a drop is indistinguishable from one that doesn't work, which is what the
  old page felt like. The cap lives in `EdgesSection.placeOnTop`, not in
  `DockStore`, because `placement[.top]` carries both meanings above in one
  array — residents that wait there, and ids whose result panel merely opens
  there — and only the first kind is capped. The store cannot tell them apart,
  so a cap enforced down there would silently undo a `.panel` placement every
  time someone parked a surface up top. `residentIDs` is a parameter for that
  reason and not a convenience.
- **A placement control can be the only consent screen a background run
  gets.** A surface's script runs on pointer hover, not a press — the first
  trigger in Gizmate the user doesn't cause directly. Nothing new executes
  (same `ToolRunner`, same approval hash as every other tool), but what
  changed is _when_, and approving "run once" is not the same consent as
  "run again on every hover, forever." Parking a gizmo on the figure is where
  that choice is made, but the sentence saying so belongs on the gizmo, not on
  the figure: `ToolEditorPanel`'s Edge hint carries it, worded from that
  gizmo's actual state ("On the Right edge, so it runs on its own every time
  that edge opens"). It sat under the figure for one round and was wrong there
  for a reason worth keeping — the figure draws Note and the folder hub too,
  and neither runs a script, so a page-wide warning had most of its readers
  reading about something they weren't doing. A consent line has to be attached
  to the thing it is true of, and the only screen that shows one tool at a time
  is that tool's editor.
  Undocked still has two different meanings: a `.panel` result works fine
  floating, so `DockPlacementPicker`'s `nil` pill keeps its default "Floating"
  in the editors. A surface has no working undocked state — it is simply in the
  middle of the figure — and its own hint says "Not on an edge, so it never
  runs" rather than borrowing a word that would claim otherwise.
- **Say what's true of the resident, not the sentence a neighbouring one
  happens to use.** The folder hub used to carry a second consent sentence
  purely so it would not borrow the surface's wording about running and
  approving: a surface executes a script on every hover, while the hub reads a
  folder with `FileManager`, which is not a thing anyone approves. It is gone,
  and the rule is what let it go: the sentence now lives on one gizmo's editor,
  where there is no neighbour to be confused with. The hub has no editor and
  needs none — nothing anywhere claims it runs.
- **One tool never configures itself in the main window.** The folder hub's
  folder list once lived two places at once: `FolderHubView`'s own chips, for
  use once it's docked, and a second, independent view onto the same
  `FolderHubStore` inside `EdgesSection`, added so a user could add a folder
  before ever placing the hub anywhere. That second view is gone — the folder
  list lives only in the hub's own panel now, because a resident configuring
  itself anywhere but its own panel is the same "two places to keep in sync"
  problem placement itself was collapsed to `EdgesSection` to fix. This is
  safe only because `FolderHubStore.load` falls back to `~/Downloads` when
  nothing has ever been saved: a hub that has never been configured is never
  an empty hub, so docking one for the first time already shows real chips
  beside real contents, and there is no "the panel has nothing in it yet"
  case for this rule to make worse. (A hub a user has since emptied on
  purpose is a different case — `remove(_:)` deliberately saves `[]` rather
  than reviving the default, so "silently un-removing the folder you just
  took out" doesn't become the trade-off; that user was already standing in
  the panel when they did it.) If the `~/Downloads` fallback is ever removed,
  the folder list needs a way back into Edges — an empty, never-configured
  panel with no chips in it is exactly the discovery-by-accident problem that
  put the second view there the first time.
- **A click whose meaning depends on the host is the host's, not the layout's.**
  A layout `tap` names an action bound to a row — open this path, reveal that
  one. The folder hub's click isn't that: a file opens, a folder is browsed
  into, and "browsed into" is a position in a tree the host owns. Adding a case
  to `ToolAgentLayoutTapV1` would have cost the sidecar schema, the capability
  description and a parity test to serve the one caller that isn't a gizmo, so
  the hub installs a handler through `EnvironmentValues.surfaceActivate`
  instead and `SurfaceCard` reads it. The handler _replaces_ the layout tap
  rather than joining it: a single-click gesture beside a double-click one
  fires on the first half of every double click, which is how a browse would
  also reveal in Finder on its way. Double-click, not single: a card is a drag
  source first, and a shelf's files are picked up more often than opened.
- **An irreversible removal is armed, then confirmed — never revealed on
  hover.** A hover-revealed ✕ on a folder chip sat one stray click away from
  deleting a folder the pointer was only reaching past, and nothing about it
  can be undone: `remove(_:)` saves `[]` on purpose rather than revive the
  Downloads default. So a double-click arms the chip instead — `FlowTheme.danger`
  fill, ✕ inserted — and the ✕ is what removes. Arming is a state the user
  asked for and is looking at, which is why the ✕ is inserted rather than
  faded in: the row shifting under a chip that just turned red is the feedback.
  Leaving the chip disarms it, so an armed capsule can't be stranded red with
  no way out but deletion. This replaced the context menu as well — two routes
  to an irreversible action is one more than it deserves.
- **One chip row shows the roots or the trail, never both.** Standing three
  folders deep, "which folders did I add" is not a question you have; "where
  am I" is. So browsing swaps the roots for `Downloads › sub › sub`, each
  crumb a jump back to that level — which makes the crumb left of the last one
  the back button, and retires the separate arrow that had to be kept in step
  with the path. The trail is derived by trimming components off the current
  folder, never stored: a stack is a second copy of where you are, and the two
  disagree the first time anything else moves the current folder. Each crumb's
  name is capped at 140pt — a folder a browser saved is named after a page
  title, and an uncapped one pushed every other chip off the row.
- **A tool with no edge is not necessarily a tool with a home, and only Home
  says which one it has.** Everything above is about `DockCatalog`'s
  residents — how a resident earns an edge, and who writes it. A tool doesn't
  have to be a resident, or even dockable, to need somewhere to live: once
  "New gizmo" could save a tool with `assignTo: nil` instead of requiring a
  ring slot first, a tool could exist on no ring slot and no edge at all — a
  state the ring's old placement-by-construction made impossible. Nothing in
  this section, and nothing `DockCatalog` computes, ever checks the ring, so
  none of it can tell that state apart from a resident correctly sitting on
  an edge. `HomeSectionContent.location` is the one place that checks every
  home a tool can have — a ring slot, `DockStore`, and, for a built-in, its
  own global shortcut — and reads back `.nowhere` only when none of the three
  claims it, worded plainly on the tool's own row (`FlowTheme.inkTertiary`,
  not a banner) rather than left for someone to notice only by trying to run
  it. The ring and `DockStore` never write to each other, so a tool can
  genuinely sit on both — most often a `.surface` gizmo carrying a ring slot
  left over from approving it once (`SurfaceRefresh`'s "run it once from the
  ring" message asks the user to create exactly that state) — and when that
  happens `location` checks the edge first for `.surface` content, since the
  edge is what the gizmo is actually for. A built-in with a `shortcutAction`
  is never `.nowhere` even off the ring and off every edge: `GlobalShortcutStore`
  always resolves a binding, saved or default, so the key still runs it
  regardless of where else it sits. A `.clipboard` or `.notify` gizmo can
  never earn an edge or a shortcut at all, so for one of those `.nowhere` is
  still the only way to fail, and Home is the only screen that was ever going
  to catch it. `DockPlacementParityTests` pins this against real `ToolsStore`
  / `RingLayoutStore` / `DockStore` instances — the same shape as the
  built-in resident check earlier in this section, generalized from "does a
  control exist for this" to "does any home exist at all."

## 12. Reuse before variants

Before writing a second version of a component, check whether the first already
adapts. `NotesGrid` lays out with `.adaptive(minimum: 235)` and collapses to one
column on its own, so the dock reuses it rather than shipping a second note list
that would drift out of step with the first.

Where a real difference exists, make it a parameter and attach the reason —
`NoteCard(fixedHeight:)` is fixed in a grid row so cards line up, and
content-sized in a single column where uniform height only buys dead space.
`SurfaceCard(height:)` is the same parameter for the same reason, and carries
the three rules below with it.

## 13. Cards in a grid of files

A grid cell is a square: `SurfaceGrid` hands each card the column width it
already computed as the card's height. Uniform cells are the whole point — a
two-line filename must not make one card taller than its neighbours — and
reusing the width means there is no second constant to keep in step with the
first, so a wider column buys a bigger cell for free.

Inside that fixed cell:

- **The label reserves its lines, the preview takes the rest.**
  `.lineLimit(2, reservesSpace:)` in a grid, then the thumbnail gets
  `maxHeight: .infinity`. Sizing the preview instead and letting the label
  fall where it may puts every icon in the row on a different line.
- **A file draws its real preview, not its type glyph.** `FileThumbnail` asks
  QuickLook — the same source Finder's icon view reads — so an image is the
  image and a video is a frame from it. It falls back to
  `NSWorkspace.icon(forFile:)` while the answer is in flight, so the worst
  case is what a card drew before previews existed.
- **Filenames truncate in the middle.** The end is where the extension lives,
  and the extension is the one thing a preview genuinely cannot tell you: a
  video's thumbnail is a still frame and reads as a photo.

- **A selectable card gives its whole mouse to AppKit, or none of it.**
  Dragging more than one file has no SwiftUI expression — `.onDrag` returns one
  `NSItemProvider`, and one provider is one item however many representations
  it registers — so a multi-file drag is `beginDraggingSession` with an
  `NSDraggingItem` each. The AppKit view that catches the drag catches the
  clicks with it, which is why selection and double-click moved there too
  rather than stay as SwiftUI gestures that would never fire underneath it. A
  host opts in by installing a `SurfaceSelection`; every gizmo surface installs
  none and keeps the `.onDrag`/`.onTapGesture` pair it always had. Selection is
  drawn as a lit fill (`FlowTheme.accentSoft`), never a border: at 110pt a
  border reads as a second card edge. The session offers `.copy` and `.link`
  and never `.move` — deleting the user's file because a drop target preferred
  it is not a shelf's call to make. Dragging a card outside the selection
  drags it alone and makes it the selection, Finder's rule, so a selection
  made three folders ago can't ride along with the file under the pointer.
- **A plain press collapses a selection on mouse-_up_, not mouse-down.** This
  is the difference between multi-drag working and not: a drag reads the
  selection as it stands, so collapsing to one card the moment the button goes
  down means every drag carries exactly one file however many were lit — which
  is precisely how it shipped. The collapse is still owed; it just waits for a
  mouse-up that no drag intervened in. ⌘-click is the exception and toggles
  immediately, since no drag can follow a modifier the user is still holding
  for a second click.

Metadata competes with the preview for the same two lines, so a shelf shows
neither by default — the folder hub dropped its size line to buy the preview
53pt instead of 34pt in a ~110pt cell. A surface gizmo that has something to
say beyond the name still passes a `subtitle`; it just pays for it.

## 14. A settings page states its values; it does not lay out its fields

A panel with more than about four settings shows each one as a **row carrying
its current value**, and opens that row to the control. `ToolEditor`'s Details
page is the worked example: `detailGroup` / `detailRow` there, one row open at a
time, keyed by title in `openRow`.

The alternative — every field expanded, each under its own heading and
paragraph — is what that page shipped as, and it failed twice over in a 620pt
panel. Nothing could be **found**: seven sections meant roughly a screen and a
half of configuration below the fold with nothing naming what was down there.
And nothing could be **read**: a paragraph per section plus a hint per field is
a uniform grey texture, and uniform is the one thing hierarchy cannot be. Both
are structural. Neither is reachable by adjusting spacing.

- **The closed row must state the real value, never that one exists.** "Not
  set", "12 lines", "120s · network", "Failed" — a row reading "Configured"
  puts the page back where it started, because the only way to check would be
  to open it. This is what makes the collapsed list _be_ the settings rather
  than a table of contents over them, and it is the whole reason collapsing is
  safe here: every setting on this page happens to have a short answer.
- **The explanatory sentence belongs inside the row, not above the group.** It
  is what you want while deciding and at no other time. Printed permanently it
  is the texture described above; printed on open it answers the question you
  just asked by opening.
- **One row open at a time.** The closed rows are the only thing keeping the
  whole configuration on one screen, so closing the previous one is the
  mechanism, not a restriction.
- **A warning is not a value and does not collapse.** The consent notices for
  `.python` and `.agent` gizmos sit below the groups, always visible. A row is
  for something the user set; a notice is for something they need to have read
  before Save, and one hidden behind a chevron has not been read.
- **Do not put a disclosure inside a disclosure.** The icon field used to carry
  its own Change/Done toggle over `IconGrid`; inside a row that already opens,
  that is two clicks to reach one grid. The row's own expansion is the
  disclosure.
- **Say each fact once.** The old page stated the gizmo's name in the window
  header, again in a summary card, and again in the Name field, and stated its
  kind in the header subtitle, the card's tag, and the Kind picker. The header
  now carries identity (icon, name, kind tag, behaviour line) on Details, where
  nothing else does; the chat page keeps `summaryCard` and a header naming the
  job instead, because there the card is inline in a transcript and the header
  is chrome.

## 15. Copy

Never write "translate", "translation" or "translator" in anything the user
reads. Prefer results, replies, output. Code identifiers are exempt.
