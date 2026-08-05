# Gizmate Design System

## 1. Atmosphere & Identity

Gizmate should feel like a quiet Mac-native command surface: compact, glassy, and direct. The signature is dark liquid glass around a restrained near-black settings shell, with a single Gizmate green accent used only for progress, success, and primary action.

## 2. Color

### Palette

| Role            | Token                                        | Light                  | Dark                   | Usage                                           |
| --------------- | -------------------------------------------- | ---------------------- | ---------------------- | ----------------------------------------------- |
| Surface/glass   | `FlowTheme.glass`                            | transparent            | transparent            | Visual-effect-backed window background          |
| Surface/card    | `FlowTheme.card`                             | rgba(255,255,255,0.06) | rgba(255,255,255,0.06) | Settings panels and setup cards                 |
| Surface/subtle  | `FlowTheme.subtleFill`                       | rgba(255,255,255,0.08) | rgba(255,255,255,0.08) | Secondary fills and inactive controls           |
| Text/primary    | `FlowTheme.ink`                              | #FFFFFF                | #FFFFFF                | Headings, body, active controls                 |
| Text/secondary  | `FlowTheme.inkSecondary`                     | #BDBDBD                | #BDBDBD                | Supporting copy and secondary labels            |
| Text/tertiary   | `FlowTheme.inkTertiary`                      | #8C8C8C                | #8C8C8C                | Disabled, metadata, inactive icons              |
| Border/hairline | `FlowTheme.hairline`                         | rgba(255,255,255,0.10) | rgba(255,255,255,0.10) | Dividers and quiet outlines                     |
| Accent/primary  | `FlowTheme.accent` / `NSColor.gizmateAccent` | #C9C9C9                | #C9C9C9                | Success, selected state, primary setup progress |
| Accent/soft     | `FlowTheme.accentSoft`                       | rgba(255,255,255,0.18) | rgba(255,255,255,0.18) | Soft selected backgrounds                       |
| Status/error    | inline status error                          | #FF8C8C                | #FF8C8C                | Failed setup status only                        |

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
- **Slide in from the bezel, fade out in place.** Arriving from off-screen is
  what makes a panel read as coming out of the edge rather than being placed on
  top of it.

## 11. Dock behaviour

- **A peek closes itself; a window the user opened does not.** The notch and the
  side tab strips come and go with the pointer. An expanded side dock stays until
  dismissed on purpose — dragged shut by its handle, or Escape. Clicking into
  another app is how you _use_ what is on the edge, so it must not dismiss it.
- **Every way out has a visible affordance.** A dock that stays open carries
  `DockDragHandle` on its inner edge. An exit nobody can see is not an exit.
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
- **Placement is written from exactly one screen.** `BuiltInEditor`'s "Panel"
  section, `ToolEditor`'s panel/edge fields, and Settings → General's Files
  card each used to carry their own `DockPlacementPicker`, writing straight to
  `DockStore`. All three now hold only a locality pointer — plain text saying
  where the thing currently sits, or that it sits nowhere — and `EdgesSection`
  is the one place that actually calls `DockPlacementPicker` and writes.
  Reading a pointer back from the store the same screen writes to needed no
  new plumbing: `bridge.dock.edge(of:)` was already there. The identity gap
  that used to route the folder hub to Settings → General still exists —
  `BuiltInEditor`'s gate is a `RingActionID`, `ToolEditor`'s a `GizmateTool`,
  and the folder hub has neither — but it no longer matters which editor
  _writes_ placement, because none of them do anymore.
  `EdgesSection.residentWithoutARingSlot` names the folder hub's id today (it
  moved from `SettingsSection` when the picker did); a future resident of this
  same ring-slot-less kind joins it there, not a new constant.
  `DockPlacementParityTests` holds it, together with `dockableBuiltIns` mapped
  to ring-action ids, against every id `DockCatalog.builtIns(host:)` actually
  returns — the same shape as the gizmo-output parity test below, generalized
  from a fixed enum to a live list because built-ins have no enum to diff
  against.
- **Placeable is wider than resident, and both get a picker in `EdgesSection`
  now, just not the same list.** A `.surface` gizmo, the folder hub, and Note
  are residents — something to draw before any run starts — and sit in the
  three edge cards or the "Not on an edge" list beneath them, the same list
  `DockCatalog.knownIDs` names. A `.panel` gizmo and a dockable-but-not-
  resident ring action (Explain, Reply, Summarize) are placeable but draw
  nothing while idle, so a card row would either sit empty or promise a run
  that hasn't happened — DESIGN.md said as much above, before this section
  existed to act on it. Those get their own "Panel placement" list instead:
  same `DockPlacementPicker`, same `DockStore`, no card, no drag — there is
  nothing to reorder relative to since none of them ever render together.
- **A resident with nothing to place still gets a way off an edge.** Once a
  resident is docked it is drawn as a plain drag row with no picker — a
  picker on every row would fight the row's own drag gesture for the same
  click. The "Not on an edge" card is the drop target that takes its place:
  dragging a docked resident there calls `dock.dock(_:to: nil)` the same as
  picking "Off" used to. Removing this dropped the last way to undock
  anything once the three editors stopped writing to `DockStore` themselves,
  so it isn't optional polish — without it, taking something off an edge
  would have been simply impossible.
- **A placement control can be the only consent screen a background run
  gets.** A surface's script runs on pointer hover, not a press — the first
  trigger in Gizmate the user doesn't cause directly. Nothing new executes
  (same `ToolRunner`, same approval hash as every other tool), but what
  changed is _when_, and approving "run once" is not the same consent as
  "run again on every hover, forever." `EdgesSection`'s picker is where that
  choice is actually made — picking an edge is what turns a saved gizmo into
  one that opens on its own — so it is also the one place the sentence has to
  live now: not copied onto whichever editor happens to also mention
  placement, the way it briefly was on both `ToolEditor` and `SettingsSection`.
  It follows that the two placement pickers cannot share one default label: a
  `.panel` result still works undocked, so its picker calls `nil` "Floating";
  a surface has no working undocked state, so its picker calls the same `nil`
  "Off" rather than borrow a word that would say otherwise.
- **The consent sentence says what's actually true of the resident, not the
  sentence a neighbouring one happens to use.** The folder hub's picker also
  calls `nil` "Off" — same invisible-until-docked reasoning as a surface's —
  but its sentence doesn't borrow the surface's wording about running and
  approving. A surface executes a script on every hover; the folder hub reads
  a folder with `FileManager` on every hover, which is not a thing a user
  approves at all. Saying "nothing to run or approve" is the honest claim for
  this resident specifically, not a shorter version of the gizmo's sentence.
- **A resident's own configuration belongs where its placement does.** The
  folder hub's folder list used to be reachable only by docking it, opening
  its panel, and finding the chips there — discovery by accident, and the
  reason Settings → General grew a Files card to begin with. `FolderHubView`'s
  chips and `+` still live in the panel, for use once it's docked, but
  `EdgesSection` carries a second, independent view onto the same
  `FolderHubStore` so a user can add a folder before ever placing the hub
  anywhere.

## 12. Reuse before variants

Before writing a second version of a component, check whether the first already
adapts. `NotesGrid` lays out with `.adaptive(minimum: 235)` and collapses to one
column on its own, so the dock reuses it rather than shipping a second note list
that would drift out of step with the first.

Where a real difference exists, make it a parameter and attach the reason —
`NoteCard(fixedHeight:)` is fixed in a grid row so cards line up, and
content-sized in a single column where uniform height only buys dead space.

## 13. Copy

Never write "translate", "translation" or "translator" in anything the user
reads. Prefer results, replies, output. Code identifiers are exempt.
