# Gizmate Design System

## 1. Atmosphere & Identity

Gizmate should feel like a quiet Mac-native command surface: compact, glassy, and direct. The signature is dark liquid glass around a restrained near-black settings shell, with a single Gizmate green accent used only for progress, success, and primary action.

## 2. Color

### Palette

| Role             | Token                                        | Light                   | Dark                    | Usage                                               |
| ---------------- | -------------------------------------------- | ----------------------- | ----------------------- | --------------------------------------------------- |
| Surface/glass    | `FlowTheme.glass`                            | transparent             | transparent             | Visual-effect-backed window background              |
| Surface/card     | `FlowTheme.card`                             | rgba(255,255,255,0.06)  | rgba(255,255,255,0.06)  | Settings panels and setup cards                     |
| Surface/subtle   | `FlowTheme.subtleFill`                       | rgba(255,255,255,0.08)  | rgba(255,255,255,0.08)  | Secondary fills and inactive controls               |
| Text/primary     | `FlowTheme.ink`                              | #FFFFFF                 | #FFFFFF                 | Headings, body, active controls                     |
| Text/secondary   | `FlowTheme.inkSecondary`                     | #BDBDBD                 | #BDBDBD                 | Supporting copy and secondary labels                |
| Text/tertiary    | `FlowTheme.inkTertiary`                      | #8C8C8C                 | #8C8C8C                 | Disabled, metadata, inactive icons                  |
| Border/hairline  | `FlowTheme.hairline`                         | rgba(255,255,255,0.10)  | rgba(255,255,255,0.10)  | Dividers and quiet outlines                         |
| Accent/primary   | `FlowTheme.accent` / `NSColor.gizmateAccent` | #C9C9C9                 | #C9C9C9                 | Success, selected state, primary setup progress     |
| Surface/selected | `FlowTheme.selected`                         | rgba(255,255,255,0.055) | rgba(255,255,255,0.055) | The sidebar's current row                           |
| Accent/soft      | `FlowTheme.accentSoft`                       | rgba(255,255,255,0.18)  | rgba(255,255,255,0.18)  | Soft selected backgrounds                           |
| Status/error     | `FlowTheme.danger`                           | #FF8C8C                 | #FF8C8C                 | Failed setup status, and armed destructive controls |

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

- **A margin is measured against what can be seen, not against a frame.** The
  sidebar's right edge is invisible; the detail card's edge is not, so a nav
  row padded 12 on both sides read as 12 from the window and 22 from the card,
  because `DetailCardMetrics.leadingInset` landed inside the same gap. The
  sidebar subtracts it (`.padding(.trailing, 12 - leadingInset)`). Any view
  that ends where another view's inset begins owes the same subtraction.
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

### A press lands on the frame it happened

The control's own state — the selected chip, the opened panel, the pressed tab
— changes on the same frame as the click. Whatever the press _loads_ arrives
after, into a container that has already switched.

Never gate a selection on the work it triggers, and watch for the version of
this that hides inside a chain of `.onChange`. The folder hub's chips set
`selected`, one `onChange` set `current`, and a second cleared the rows — so the
first frame after a click carried the new highlight _and_ the previous folder's
eighty cards, and the highlight waited on a grid that was about to be thrown
away. `FolderHubView.show(_:asRoot:)` now does the whole switch in the tap:
select, clear, then load.

Work that only decides _where_ something goes runs beside the work itself,
not in front of it. Home's chat classified a message and then answered it, two
model calls back to back on the commonest thing anyone does here. Both start at
once now: the answer streams while the router decides, and a build request
spends one answer nobody sees, which is the rare case paying for the common one.
The speculative answer stays hidden until the router lands, because showing a
half-written reply that is about to be thrown away for the builder is worse than
the second it saves.

**An `ObservableObject` read through a computed property is observed by
nobody.** Home's chat pane reached its conversation as
`bridge.host?.homeChat`, which compiles, reads correctly, and subscribes to
nothing: every `@Published` change fired `objectWillChange` into an empty room,
so an answer appeared only when something unrelated forced a redraw — a click,
or leaving the section and coming back. The state was right the whole time.
Hold it as `@ObservedObject`, which means passing it in, which means the view
that has the host does the reaching. The tell is a symptom that sounds like
performance and is not: "it updates when I click something else".

**State that describes one row must not be reachable from the code drawing the
others.** Home's transcript drew every turn through one function that asked
`routing || turn.answer.isEmpty` — and `routing` belongs to the pane, not to a
turn, so the moment a new message was sent every finished exchange in the
history turned back into "Thinking". A finished turn and the one in flight are
two functions now, and the pane's state is only in scope inside the second. The
shape is the fix, not the condition: a flag that can be read from the wrong row
eventually is.

This includes work that decides _where_ a message goes. Home's chat sent a
typed message to a classifier before showing it, so between pressing send and
the model answering there was a second or two with the message gone from the
composer and nowhere else — and the router decides where it goes, never whether
it existed. It appears immediately and is routed underneath.

The failure mode is not "it feels slow", it is "the button is broken". A person
who sees no change assumes the click missed and clicks again, which is also what
a developer watching them concludes.

**Selection state does not belong in the environment.** An environment value
invalidates every view that reads it, so `SurfaceSelection` carrying the lit ids
meant one click rebuilt all eighty cards — and each card owns an
`NSViewRepresentable` with an AppKit view under the pointer, so the second press
of a double-click landed on a mouse view the first press had just torn down and
rebuilt. "Clicking a folder does nothing the first time" and "switching feels
slow" were one bug wearing two faces. What goes in the environment is how to
_act_ (closures that read the host's live state, so they never count as
changed); which rows are _lit_ is a plain value handed down the tree, so only
the cards whose state actually changed re-render.

**In the ring, selection is a direction, not a rectangle.** Which button is
picked comes from the angle between the cursor and the ring's centre; the
distance only says which orbit is being read. The ring is a radial menu, and
asking someone to land inside a 46pt disc at radius 78 spends its one advantage
— that the target's size is the whole sector, not the glyph. `angularPick`
takes the nearest button by angle rather than a fixed 45° sector, because an
empty slot deliberately leaves a gap in the eight-way grid and a sector scheme
would hand that gap to nobody. A click anywhere in the band runs what is being
pointed at; the dead zone under the ✕ and everything outside the panel are
the two places where a click still means "put this away".

**The outermost live layer owns the band out to the panel's edge.** The wall
used to sit half a ring-gap past whichever layer was outermost, which made it
move: with only the ring up it stood at 115pt, so pointing at a button from
further out than that selected nothing at all and a click there dismissed. That
is the opposite of what a direction-based pick promises. The bands still split
at the midpoints between neighbouring live rings, but the last one runs to the
panel wall, and there is nothing past the panel to get wrong — the cursor is
over another app, whose click the global monitor turns into a dismiss anyway.
Two things fall out of it. Reaching for a far-out orbit no longer has a gap in
the middle where nothing is selected. And because a layer opening puts a new
band under a cursor that has not moved, `refreshPick` re-resolves in a loop
rather than once: pointing at a folder from out where its orbit is about to
appear lands the selection inside that orbit on the same gesture, and again in
the third if what it lands on is another folder. The loop is bounded by the
layer count, not by a guess — opening an orbit strictly grows `liveLayers` and
there are only three.

The corollary is stronger than the feature: **one input decides, and every
highlight is derived from it.** The discs used to carry a hover tint of their
own beside the controller's `setHighlighted`, with a `suppressHoverTint` flag
switching between them, and every highlight defect in that file came from the
two disagreeing about what was selected. `RadialMenuButtonView` tracks no mouse
now. This is the same rule the one-agent chat router follows (see the project
instructions): never add a second mechanism whose job is to have an opinion
about what the first one meant.

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
- A list the user keeps is ordered by the user, not by a clock. Notes sorted
  themselves by `updatedAt`, so the card being typed into jumped to the top and
  the list rearranged itself while it was being read. Creation order, then
  whatever order it was dragged into. Where a card is full of editable text,
  the drag starts from a handle of its own: `NSTextView` wins any argument with
  a SwiftUI gesture wrapped around it, so a drag begun on the card is someone
  selecting words. Reorder on the way past (`dropEntered`), so the list is its
  own preview, and carry the id as plain text — a `Transferable` of our own
  needs an `Info.plist` a `swift run` build does not have.

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
- **A background is a state, not a shape.** A control rests bare and takes a
  fill only when it has something to say: the pointer is on it, it is the one
  selected, or it is armed to destroy something. A row of chips each in its own
  painted capsule is six pills competing with the content while saying nothing
  the labels don't — and the same disc drawn filled whether or not it is
  hovered is a permanent grey circle. `ResetDiscButton` and the folder hub's
  chips and crumbs all follow this; `FolderHubView.fill(here:folder:)` is the
  whole rule in four lines.
- **That rule is about controls, and a card you write in is not one.** A note
  card lifted its fill on hover like a button does, which promises a press that
  does nothing — the card is already open, and the pointer is there to put a
  caret in it or reach the tick and the bin that fade in at its corner. Those
  appearing is the whole hover treatment. Repainting the surface underneath
  them says a second, wrong thing about the same gesture. `NoteCard` keeps one
  fill; only the controls it holds react.

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
- **A frame animation is for one object resizing, not for one object becoming
  another.** Switching between two expanded panels morphs: same panel, new
  contents, and the tab you clicked stays on screen the whole way. The tab
  strip is a different object — it is the trigger, not a small version of the
  panel — so clicking it makes it vanish at once and the panel arrives out of
  the bezel exactly as it does from hidden. Morphing the two instead stretched
  a 40pt tab into a 380pt panel, dragging the glass the whole distance and
  laying out squashed content at every frame of the trip.

## 11. Dock behaviour

- **A peek closes itself; a window the user opened does not.** The notch and the
  side tab strips come and go with the pointer. An expanded side dock stays until
  dismissed on purpose — dragged shut by its handle, or Escape. Clicking into
  another app is how you _use_ what is on the edge, so it must not dismiss it.
- **How a dock closes is the user's call, per tool.** It was decided by which
  edge it was, then made a per-edge choice, and both were wrong in the same
  direction: an edge holds several tools, and a chat you type into and a file
  shelf you glance at want opposite answers while sitting an inch apart on the
  same bezel. Per-edge forced them to agree about something they disagree
  about. `DockStore.dismissal(of:)` is keyed by tool now, and the control lives
  in the tool's own tile on the figure — on the thing it is about, the same rule
  every other decision on that screen follows.
  The edge still supplies the _default_, because that part really is about the
  edge's shape: the notch is a glance, the sides are somewhere you work. Absent
  means "whatever this edge does", so a tool dragged to another edge picks up
  that edge's habit rather than carrying a choice it never made.
  `EdgeDockController.staysOpen` reads the tool currently expanded, which is the
  three behaviours that used to test the edge — the pointer-left timer, the
  outside-click monitor and the drag handle — all asking one question. The tab
  strip stays a peek whatever any of them says: it is the thing you aim at to
  open a dock, not the dock. A result panel always carries a handle, because it
  owns the edge until it closes itself by definition.
- **A tab opens by being pulled as well as clicked.** A tab sticking out of the
  bezel looks like something you take hold of, and a dock is already closed by
  dragging it back into that bezel, so the pull was the half of the pair that
  did not work. `DockTab` fires the same pick once the drag has travelled 16pt
  off the edge — far below the 64pt a close asks for, because opening is cheap
  and undone by moving away, while a close throws a panel out. Simultaneous
  with the button rather than replacing it: a press that never moves stays a
  press, and a pull that ends back inside the tab firing both costs nothing,
  since `transition` refuses a state it is already in. What it deliberately is
  not is a panel that follows the pointer out: the strip does not morph into
  the dock (see the arrival rule above), so crossing the threshold hands over
  to the normal arrival out of the bezel.
- **Every way out has a visible affordance.** A dock that stays open carries
  `DockDragHandle` on its inner edge. An exit nobody can see is not an exit.
  The handle follows the setting above rather than the edge — which was two
  expressions saying one thing by coincidence, and is now one rule: the thing
  that stays open is the thing that carries a way out.
- **The panel holds its contents off the glass; a resident never pads itself.**
  Notes and the folder hub each carried their own `.padding(14)`, and that was
  invisible as a rule for exactly as long as every resident was written by hand.
  The first generated gizmo to dock had no way to know the number, so its cards
  sat flush against the panel edge while the two hand-written tools sat inside a
  margin. `DockGeometry.contentMargin` is that margin, applied once by
  `EdgeDockController` around whatever the active item draws, and the two tools
  that used to pad themselves no longer do. It wraps the resident alone: the tab
  rail hugs the bezel on purpose and the drag handle owns a gutter of its own, so
  neither may inherit it.
- **An affordance owns its space; it does not float over the content.**
  `DockDragHandle` was pinned on top of the panel's content, so its 16pt hit
  area swallowed clicks aimed at what was underneath and its tooltip appeared in
  the middle of the text. It is a gutter now — a column down the inner edge of a
  side dock, a bar across the bottom of the notch — and `install` insets the
  content past it, so the two cannot disagree about who owns those points.
  The notch got one when closing became a choice. It never had a handle before
  because it could not stay open, so `bezelwardOffset` measured `x` alone and
  returned zero for `.top` — correct then, and a pinned notch with no way out
  the moment that changed. A capsule lying flat is also what says the panel
  leaves upward; the same vertical bar on all three edges would not.
  The ink stays 4pt — a thick bar down the edge of every dock is a border — but
  the grab target is the panel's whole length rather than 38pt of it you have to
  find first.
- **A full-bleed subview of an animated panel gets its frame set on every
  resize.** Not an autoresizing mask, and not constraints either — both were
  tried and both failed here, for different reasons. A mask drops its deltas
  when an in-flight `animator().frame` animation is interrupted, which a dock's
  is on every hover cycle; that is why `GlassHostView` heals its own subviews
  in `resizeSubviews`. Constraints against a borderless panel's content view do
  not re-solve, because nothing in that subtree triggers a layout pass when the
  window is resized with `display: false`, which is how a dock arrives.
  `DockContentView` does the one thing that survives both.
  The failure looks exactly like a content-layout bug and is not one: the glass
  sits at whatever size it happened to have when it was installed, and the
  content lays out correctly inside that. Four rounds went into content-layout
  theories before anything was measured, and the measurement took one run —
  `EdgeDockController.debugRevealCycle`, behind `GIZMATE_DOCK_DEBUG`, opens and
  closes each dock and prints every frame that is meant to be full-bleed. It
  read `panel=380x520 glass=380x189` on the first try. Reach for it before the
  fifth theory, not after: a cumulative shrink is precisely the bug a person
  cannot report accurately and a screenshot cannot show.
- **A dock with two residents must lay out like a dock with one.** This broke
  twice, in opposite directions, and both times through `NSStackView`. It
  centres arranged views at their intrinsic size on the cross axis, and an
  `NSHostingView`'s intrinsic size is whatever its SwiftUI content would ideally
  be — so the content took its own height rather than the panel's, and the
  folder hub's chips sat halfway down an empty panel with its files cut off.
  Pinning each view to the stack's cross axis fixed that until the rail's own
  intrinsic height stopped being flexible, at which point the negotiation went
  wrong the other way and the content collapsed to two lines. A single resident
  never showed either, because there is no stack then and `install` pins the
  view to all four edges.
  `expandedView` uses plain constraints now. There are two subviews and the
  geometry is entirely known — the rail is a fixed `stripMaxBreadth` on the
  bezel side, the content takes the rest, both run the panel's full length —
  so there is nothing here worth letting a layout container negotiate. Reach
  for a stack when the arrangement is genuinely a list; two views whose sizes
  you already know is not that.
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
- **Draw thin, but hit big.** `DockDragHandle` is 4pt of ink inside a 14pt
  column that runs the panel's full length. A 4pt target is a miss waiting to
  happen.
- **Say which file is selected with a shape, not a shade.** A selected card and
  an unselected one were two whites a tenth of an alpha apart, on a translucent
  panel, over an arbitrary desktop. Gizmate has no colour accent to reach for
  (§2), so the shape carries it: a selected card takes an outline, which is
  present or absent and cannot be washed halfway out by a wallpaper. Same
  mistake and same fix as the tab strip below.
- **Say which one is open with a shape, not a shade.** `DockTabStrip` marked
  the active tab by tint alone — `ink` against `inkSecondary` — on the argument
  that the glass is already the surface being pressed and a plate fights the
  flare it sits in. That argument is right about a hover treatment and wrong
  here: two greys 0.25 of alpha apart, at 15pt, on translucent glass, over an
  arbitrary desktop, tell nobody which tool they are looking at. The rail's
  active tab carries a filled plate now. The peek strip does not, and not for
  consistency's sake: nothing is open yet there, so it has nothing to mark.
  Size and position stay identical between the two, and that is the harder
  rule: expanding a dock must not move its icons. The rail briefly used tighter,
  squarer tabs grouped at the top, on the reference of web navigation rails —
  the wrong reference, because those are navigation for a whole app with nothing
  before them to stay continuous with. Here the peek strip is where the tool was
  picked seconds earlier, so repeating its exact rhythm is what makes the two
  read as one control growing rather than two swapping.
- **A gizmo can be a dock's resident, not just something it summons.** Every
  other result exists only after a run finishes, so a tab for one is either
  empty or a false promise until then. A `.surface` gizmo is the exception:
  its script's last output is already sitting in `SurfaceRowsCache`, so its
  tab has something to draw before it ever hovers into view. That is the same
  rule `residentBuiltIns` states for Note, and `DockCatalog.dockableGizmoOutputs`
  is where a gizmo output earns the same standing — an output added there
  needs a real answer to "what does this tab show with nothing running yet?",
  not just "what does it show after."
- **A resident is anything with a transcript, not just anything with a view.**
  Ask joined `residentBuiltIns` when its chat became a view instead of a
  window, and it passes the same "something to draw before any run starts" test
  Note does for the same reason: `AskGizmateHistoryStore` already holds the
  conversation, so the tab has a transcript the moment it opens. The capsule at
  the cursor is that same conversation with the transcript not shown, which is
  what makes the Edges figure the switch between them: on an edge Ask is a
  chat, in the middle it is the capsule. No second control was added for this,
  and none should be.
- **A shortcut for a resident opens the resident.** Every other way into a dock
  is the pointer arriving, so nothing needed `EdgeDockController.reveal` before:
  by the time the panel exists the pointer is already at the edge. A shortcut is
  pressed from anywhere, so it has to expand the dock and place the caret
  itself. `startAskGizmatePrompt` asks `DockStore` where Ask sits and does one
  of two things; it never opens a second place to type the same question.
  Generated gizmos follow the same rule: `runToolFromShortcut` reveals a
  `.surface` gizmo's edge and runs everything else headlessly, so a key on a
  resident is "show me what it has", never a phantom run.
- **Whatever starts a screen capture is what dates it.** Ask's floating capsule
  captures the instant the shortcut fires, before the capsule appears, because
  activating Gizmate closes the very menu the user is asking about. A docked
  chat has no such moment: it is already open, and a permanently armed
  full-screen canvas would swallow every drag on the desktop. So there are
  exactly two triggers, and each one dates its own shot. The camera captures at
  send. The pencil captures on **press**, and that is not a detail: strokes are
  composited into a frame taken earlier and line up with what is underneath them
  only while the two are moments apart, so a shot taken at send would be of a
  screen the strokes were never drawn on. Arming is what pins the frame.
  It follows that an answer's shapes need a life of their own once the surface
  showing them stops closing. They clear on the next send, on arming the pencil,
  and on Escape; a modal answer used to take them with it.
- **Escape clears the shapes, wherever you are, and it is not a layered
  dismissal.** The layer ignores mouse events by design, so a keystroke is the
  only exit it can own, and it needs a local monitor as well as a global one:
  the edge dock is key while its chat is open, and a global monitor never sees
  that Escape. That was the bug — Escape closed the dock and left the shapes
  standing over the screen with nothing left to explain them. Neither monitor
  consumes the event. One Escape means "clear this answer", and whatever else
  it meant on the way past still happens.
  Dragging the dock shut is the other half of that rule and deliberately does
  **not** clear them: circling the button you have to click is only useful if
  you can then put the chat away and click it.
- **A rare panel-wide action floats over the content; it does not buy a header
  row.** A dock is 360pt wide, and a strip above the first message is paid for
  on every reading of the panel by an action used once a day. Ask's "New chat"
  is a `ResetDiscButton` overlaid on the top-trailing corner of the transcript,
  inside the top fade where content is dissolving anyway, and absent entirely
  until there is something to clear. Notes has a real header row because that
  row also carries the tag chips — it earns its height; a lone button does not.
  Nor may such an action move into the composer: the camera and the pencil are
  there to say what _this message_ carries, and a conversation-wide action
  standing among them reads as one more thing the next question will do.
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
- **One variable moves, and moving it is what loads.** The folder hub has four
  ways to change folder — a chip, a crumb, walking into a card, and falling back
  when the chip you were on is deleted — and for a while the loading lived in
  the function three of them called. The fourth set `current` directly, so
  walking back up the crumb trail moved the crumbs and left the grid showing the
  folder you had just left. Loading now hangs off `current` changing, which no
  caller can forget to do, and the callers only decide _what_ to show. The one
  thing they still do themselves is clear the old rows, in the same action as
  the switch, because §6 needs the press to land on its own frame.
- **Dropping files in follows Finder, because the hub shows Finder's folders.**
  The folder hub is a view onto real directories, so a drop onto it is the same
  act as a drop onto a Finder window and gets the same rule: within a volume it
  moves, across volumes it copies, Option always copies. The same gesture doing
  two different things depending on which window caught it is the thing to
  avoid, not the extra branch. A drop back into the folder something already
  lives in is Finder's no-op too, except under Option, where it is a deliberate
  duplicate.
  Nothing is ever overwritten. A drop has no undo and is aimed by hand, so a
  name already in use takes Finder's suffix — `a.txt` becomes `a 2.txt`, and
  `a.tar.gz` becomes `a.tar 2.gz` because the last extension is the extension.
  `FolderHubDrop` keeps the two decisions that matter — which operation, which
  name — as pure functions, so both are pinned by tests rather than by a
  careful read.
  The chips take drops as well as the body: a file bound for Documents should
  not need you to switch to Documents first. And the work runs off the main
  actor, because copying a folder is unbounded and the panel that accepted the
  drop is the one that would freeze.
- **Files can leave the hub as well as arrive.** `FileActionMenu` deliberately
  had no Move to Trash while the hub was only a hand-off shelf: something whose
  job is passing files to other apps should not be one stray click from
  deleting them, and the Finder it can already reveal into had the real thing.
  Taking drops is what changed that — a place you can put files into and cannot
  take them out of is a one-way drawer. The stray-click objection is answered by
  where it puts them: `NSWorkspace.recycle`, so the file is in the Trash with
  Put Back working, never `removeItem`. The word on the menu says so too.
  The shortcut is ⌘⌫ and never bare ⌫, and it does nothing with an empty
  selection rather than falling back to whatever the pointer is over: a
  destructive key acting on something you did not choose is the one miss the
  Trash does not excuse.
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
- **The control answers on the click; the content answers when it can.** A
  folder switch used to list the folder and rebuild the grid inside the same
  SwiftUI update, so the chip lit up only once the cards were built and the
  click read as ignored for as long as that took. The chip row now gets a
  frame to itself, the listing runs off the main thread, and the cards land
  after — with the result dropped if the user has clicked past that folder
  meanwhile. This is the general shape for anything a click loads: repaint the
  thing that was pressed first, always.
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
- **Emphasis is relative, so a repeated value loses its capsule.** Home's rail
  put a `RingTag` on every gizmo living nowhere, and nine identical capsules
  down one column mark nothing — which §11's own text already said about the
  tile grid this replaced, and the rail reintroduced anyway. When most of a list
  shares a value, that value is the background. `HomeRowLocationLabel` takes an
  `emphasised` flag: off in a list, on in isolation. The words stay on every row
  either way, because the rule is that nothing lives nowhere _without saying
  so_, and the words are what say it. Only the shouting goes.
- **A panel earns a toggle by being big enough to be worth hiding.** Home's
  gizmo rail collapses; the navigation sidebar was given one and had it taken
  away again. Six short labels never filled 256pt, and trimming it to 212
  reclaims most of what hiding it would — for free, and without asking anyone to
  decide anything. A control to put away six rows costs a glance every time you
  look at the window, to buy less than the trim already did.
  Where a toggle is warranted it sits in the chrome beside what it hides, never
  within it: a control inside the thing it hides has nowhere to be once it
  works. Its state lives on `GizmateSettingsBridge` rather than in a view,
  because someone who closed a panel meant it, and `@State` brings it back on
  the next rebuild of the tree.
  The rail starts closed. Home is the chat, and a list of everything you own
  sitting beside it on first open is a second thing competing for the same
  glance.
- **A composer's text starts at the top of its box.** A field sized for six
  lines and holding one reads as misaligned wherever the single line is placed,
  because the box is sized for growth the text has not done yet. Text at the
  top, controls on their own row underneath, the box growing downward — which
  is the shape ChatGPT's composer uses and the reason it never has this problem.
- **A row of chips is one set of choices, so they are one height.** Home's
  third starter carried a gizmo's own name, and a long one wrapped it to two
  lines: one of three neighbours taller than the others for a reason about that
  gizmo rather than about the action. The chip says "Change a gizmo" and inserts
  an `@`, which is also the thing it is teaching.
- **A conversation is a column, measured for reading.** Home's transcript, its
  composer and its empty state share one 520pt cap, which is also what makes the
  empty state and the conversation read as one object growing rather than two
  layouts swapping. The number is a reading measure, not a window fraction: at
  640 a line ran past a hundred characters, roughly twice what the eye tracks
  back from comfortably, and a full-width line is one nobody finishes because
  the start of the next one is lost on the way there.
  Cap it once, around everything. Capping the transcript and the composer
  separately with the same number still misaligned them, because the composer
  carries its padding inside the cap while the transcript's sits outside.
- **Gizmate has a voice, and it is written down in one place.**
  `GizmateApp.homeChatSystemPrompt` is it. The character is the point rather
  than decoration: someone opens that window to make their Mac do something, and
  a support desk reading its own feature list back is not who they wanted to
  find there. Warm and direct, short, no "I'd be happy to", and no em dash —
  the same ban the visible copy in this file follows.
  The order in that prompt is the order that comes back out of it. It listed
  troubleshooting, settings and file help first and reached gizmos with "I can
  also build small custom tools", so that is exactly what it said when asked
  what it does: the one thing nothing else on the machine can do, arriving as an
  afterthought. Building tools leads, and answering questions is named as the
  fallback it is.
  Three clauses in there are not style and must survive any rewrite. This
  conversation sends no picture, so claiming to see the screen is a lie the user
  catches one question later; explaining how to build a gizmo competes with the
  builder that would actually build it; and the prompt has to say what a gizmo
  _can be_, in terms of the enums rather than in examples.
  That third one is here because its absence was a refusal. Told only that a
  gizmo is "a chore they keep doing by hand" and shown five examples of exactly
  that, the model invented a ceiling and declined a request that sat squarely
  inside `prompt` + `selection` + `replace`: "too complex for what a local mac
  utility can do right now". The builder's own prompt is hardened against
  precisely this, but that hardening sits behind the gate and the refusal
  happened at it, so `ToolChatRouter.directiveContract` now also says the chat
  does not decide what is buildable and that an unsure case is still a `BUILD`
  line. Never fix a refusal by adding its subject to the example list: that
  teaches one answer, and the next request fails the same way.
- **Ask about the work, not about the person.** Home opened with "What do you
  want to do?", which asks someone to describe their own afternoon. What the box
  needs is a job for a gizmo, so the question names the gizmo as the thing doing
  it: "What should a gizmo do for you?". The same swap runs through the
  subtitle — "describe the tool you want" before "ask a question", because the
  tool is what this screen is for and the question is the fallback.
- **A selected row is said by its label first.** The sidebar's current section
  carried a well of black punched into the panel with a hairline around it,
  which read as a pressed button on a screen where nothing else is pressed. The
  label already carries the selection in weight and in ink, so the fill only has
  to group them — 5.5% white, no border. Lighter rather than darker, because a
  dark fill on a dark panel is a hole and a light one is a highlight.
- **An empty chat opens where it is used.** The greeting sat top-left and the
  composer sat pinned to the bottom of an empty column: two halves of one thing
  with the whole pane between them, and neither reading as the place to start.
  Both are centred together until there is a transcript, which is how WRITER and
  Otter open one. Three starter chips come with them — an empty field asks a
  person to guess what it accepts, and this one accepts three different kinds of
  message. Empty states are the case where more is unambiguously better.
- **Two controls for one action makes a person read both.** The inline gizmo
  editor kept the modal's Cancel next to a ✕ that does exactly the same thing.
  Cancel is now only drawn as a sheet, where it is the way out that is not Save.
- **One chat, and a build happens inside it.** Home used to swap the whole pane
  for the gizmo editor when a message turned out to be a build request, so
  asking a question and building a tool looked like two different applications
  and every change to a gizmo cost an open and a close. The build renders as
  ordinary exchanges in the same transcript now, ending in a card with Save,
  and nothing closes when it does — the rail updates from `ToolsStore` on its
  own, and Details is still one click away.
  A build in flight owns the composer. Routing a message that is an answer to
  the agent's own question would strand the continuation it is waiting on and
  start a second build besides, so `builder.chat.isAwaitingAnswer` is checked
  before the router is asked anything. The key request is answered in the
  transcript for the same reason: a build blocked on a question nobody can see
  waits forever.
- **A question is a control, not a paragraph.** The builder's clarifications
  arrived as ordinary assistant prose and were answered in the main composer,
  which cost twice. Typing: "Safari" is a word someone has to spell to a machine
  that already knew the three apps worth naming. And scrolling: a question drawn
  as prose scrolls away, and a build waiting on an answer nobody can still see
  waits forever. `ChatQuestionCard` is a stop instead — it says how many
  questions are left, its options are one click each, and it carries its own
  field so the main composer stands down while it is up (two fields asking for
  one answer makes a person read both, §12).
  Three rules travel with it. **Options are a shortcut, never a constraint**:
  the free-text field is always beside them, because the moment a closed list is
  the only way to answer, an incomplete list becomes a wrong answer nobody can
  correct. **✕ skips, it does not cancel**: the builder gets empty answers and
  decides for itself, since a person who does not know the answer must not be
  the reason the gizmo is never made. And **one card, not one question at a
  time**: `ask_user` carries up to six questions and the host budget is a single
  call (`ToolBuildSupervisorRequests.acceptClarification`), because three
  separate calls were three model turns and three stops for facts that fit in
  one breath.
  What the card must always ask, when the request did not say it, is which input
  the gizmo reads and where its result goes. Those are the two choices a person
  touches every time they run the thing, and the two they are least likely to
  know exist, so a silent default there is a decision taken from them rather
  than made for them.
- **Reaching a gizmo is not the same as opening it.** Home's tile grid was
  both: clicking a tile opened the editor as a modal, so changing one gizmo cost
  an open and a close, and changing two cost four. The editor now runs inline
  beside a rail (`ToolEditorPanel.Chrome.inline`), and clicking a row only says
  what the chat is about. What the rail did not give up is the answer Home owes:
  every row still carries its `location`, and the group still counts the ones
  that live nowhere.
  Which of the three a typed message means — talk, build, change — is
  `ToolChatRouter`'s, and a mention is decided without the model: `@Prices`
  names a tool outright, and a classifier confirming it would add latency to the
  one case that has none. Everything ambiguous resolves to talk, because reading
  a build request as a question costs a sentence and reading a question as a
  build request starts writing software nobody asked for.
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
  home a tool can have — a ring slot, `DockStore`, and a global shortcut,
  a built-in's always-resolved one or the binding a user recorded for a gizmo
  in `ToolShortcutStore` — and reads back `.nowhere` only when none of them
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
  never earn an edge, but it can now earn a key — recorded from the Shortcut
  row in its own editor — so `.nowhere` for one of those means "no slot and
  no key", and Home is still the only screen that was ever going to catch it. `DockPlacementParityTests` pins this against real `ToolsStore`
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

## 13. Cards in a grid of files, rows in a list of readings

One card type, two arrangements, and the repeater picks which. A `grid` cell is
a square with the icon above centred text; a `list` row is as wide as the panel
with the icon beside left-aligned text and a hairline ruling it off from the
next. Nothing in the wire format says which — `SurfaceCard(height:)` is already
the parameter that differs, so the axis follows it rather than becoming a knob
the model has to set correctly (§12).

That split is also what decides where the three row-only modifiers may be used.
`details` (up to six more lines), `meter` (a bar, from a `0…1` number or a
`"48.8%"` string) and `chart` (a sparkline, from 2–120 comma-separated numbers)
draw in a list row and are refused in a grid cell, by name, with "use a list"
as the diagnostic. A square sized from its own column has nowhere to put four
lines and a bar, and the two ways of not saying so are both worse: clipping
them silently, or dropping them silently.

Three rules the readings brought with them:

- **A row's value is a string, so a series is text.** `SurfaceRow` is flat and
  `SurfaceRows` refuses a JSON array outright, so `chart` reads `"18,22,19"`.
  The same trade `file:$path` already makes: the string promises a shape and
  the host checks the promise against a real run rather than trusting it.
- **One parser for drawing and for checking.** `SurfaceMeter` and
  `SurfaceSeries` are read by `SurfaceCard` and by `SurfaceLayoutCheck` both. A
  value the check accepted but the renderer could not draw is the worst
  outcome available: the surface still appears, and quietly shows less than it
  was asked to.
- **Out of range is refused, never clamped.** A script printing `48.8` where a
  fraction was asked for meant something, and a bar pinned at full would hide
  that it meant it wrongly — on a panel whose entire job is to report a number.

## 13.1 Inside a grid cell

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
- **The right-click menu is Finder's subset, not Finder's menu.** No API hands
  over Finder's own menu, so a card builds its own: Open, Open With (from
  `NSWorkspace.urlsForApplications(toOpen:)`, the list Finder's submenu is
  built from), Get Info, Show in Finder, Copy. No Move to Trash — a shelf whose
  job is handing files to other apps must not be one stray click from deleting
  them, and the Finder it can already reveal into has the real thing. Get Info
  is the one item with no framework behind it: it is an Apple event to Finder,
  which is why the filename is escaped on the way into the script rather than
  interpolated. A right-click inside the selection acts on all of it, and the
  item says so ("Open 9 Items") rather than let the user find out after.
- **A menu on screen suspends a peek's hover logic.** A context menu is its own
  window, so the pointer moving onto it reads as the pointer leaving the panel,
  and the top dock would close underneath the menu the user is still choosing
  from. `EdgeDockController` watches `NSMenu.didBeginTracking` and ignores
  pointer moves until it ends.
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

- **A model tier is chosen by the weight of the work, and a tier with no work
  is not a tier.** `ModelUseScope` is `fast` (translate, rewrite, replies:
  runs on every selection and wants to be cheap), `standard` (the conversation
  and screen questions) and `deep` (building and fixing gizmos). Vision is a
  _requirement_ of `standard`, not a tier beside it, because the only jobs that
  are handed a picture are the ones in that row.
  `deep` exists because its absence was a bug rather than because three rows
  look tidier than two. The builder ran on `standard` and inherited that tier's
  vision filter, a filter it has no use for since it writes Python and JSON and
  is never handed a picture. With the catalog narrowed to models that read
  images, the default landed on a small local one that could not hold the
  action envelope, and the heaviest job in the app died on its first model turn
  having understood the request perfectly. The rule the tier encodes: never let
  a constraint that belongs to one job decide another job's model.
  Before adding a fourth row, name the work that would sit in it. A tier whose
  subtitle describes nothing the app does is a setting every user has to read
  and nobody can answer.

## 15. Copy

Never write "translate", "translation" or "translator" in anything the user
reads. Prefer results, replies, output. Code identifiers are exempt.

## 16. A directory says what a thing is, not only where it is

Home is the worked example, and every rule below was paid for there. It listed
ten built-ins and every gizmo as `icon · name · where it lives`, which sounds
complete and answered none of the question the sidebar says this screen exists
for ("what can Gizmate do").

- **Show the thing, not the pointer to it.** `RingActionID.summary` and
  `GizmateTool.brief` already held a plain sentence for every tool, and both
  were drawn only inside the ring's slot picker — a modal you reach by already
  knowing what you want. A directory that omits the one field describing its
  contents is a table of contents over itself, the same failure §14 names for a
  settings page that lists field names instead of field values.
- **A repeated default drowns its exception.** With almost every built-in on the
  ring, the trailing column printed "In the ring." eight times, and the two rows
  that differed had to be found inside that repetition. Trailing metadata is a
  **value** — `Ring`, `Ring › More`, `⌃⌥Z`, `Right edge`, `Nowhere` — never a
  sentence. The eye reads the shape of a short token; it has to parse prose.
- **A per-item marker that turns out to be the majority belongs on the group.**
  `.nowhere` earned a capsule by §11's "shape, not a shade" rule, and the first
  build tinted it as well, on the assumption the state was rare. A real library
  is mostly unplaced gizmos: nine lit capsules down one column mark nothing.
  The capsule stayed (present-or-absent is the part that works), the tint went,
  and the count moved to the group heading — "9 of 11 live nowhere", said once.
  Emphasis is relative, so any treatment for an exceptional state has to survive
  the case where the exception is the majority.
- **An empty state carries the action, not directions to it.** Home's read "Use
  “New gizmo” above to build one" while that button was a bare `+` whose label
  only drew on hover — copy naming a string that was not on screen. The empty
  state holds a real button now, and the header's is labelled. A glyph-only
  control is right for a reset nobody is hunting for (`ResetDiscButton`) and
  wrong for the one action a screen exists to offer.
- **A list of things you own is a grid of tiles.** Ring and Edges each draw a
  figure; Home drawing a flat two-column table read as a spreadsheet beside
  them, with a name at the left edge, one short value at the right and two
  thirds of the line empty. Tiles spend that width, and they are what gives the
  glyphs weight — at 15pt in `inkSecondary` an icon is decoration, at 17pt on a
  tinted disc it is how you find a tool without reading. No `SubCard` around
  them: a tile is already a card and §4 forbids the nesting.
- **Let the grid row set tile height; do not pin a constant.** `LazyVGrid`
  already gives every tile in a row the tallest one's height, so
  `maxHeight: .infinity` above a `Spacer` lines the footers up while a row of
  one-liners stays short. A fixed height bought that same alignment and charged
  every short tile a hole beneath its text. §13's fixed cell is the other case
  and stays: a square grid of files inherits height from the column width, and
  uniform cells there are the whole point.
- **Home is not a third figure.** The tempting next step is to draw the ring and
  the screen edges here with every tool on them. It is the wrong step: §11 makes
  `EdgesDiagram` and the Ring tab the only writers of placement, and a picture of
  where things live that cannot move them is a control that lies. Home names each
  tool's home in words and links to the editor; deciding the home stays where the
  one writer for it already is.

## 17. A chat takes a picture the three ways macOS offers

Home's chat accepts an attached picture because describing a thing is slower
than showing it, and every rule here was paid for by the same principle: the
person aims at the conversation, not at a control.

- **Drop, paste, clip, and in that order of forgiveness.** The drop target is
  the whole pane rather than the composer, because a target the size of one
  control is a target you can miss; the composer is what highlights, so the aim
  still learns where the picture lands. The clip is last and smallest — it is
  the discoverable one, not the fast one.
- **⌘V is caught before the responder chain or it is not caught at all.** A
  `NSEvent` local monitor. By the time the event reaches the field editor, the
  field editor has already decided a paste means text and swallowed it, so
  `onPasteCommand` on a view under a focused `TextField` never fires.
- **A key monitor matches the physical key, never the character.**
  `charactersIgnoringModifiers` ignores the modifiers, not the layout: ⌘V is
  "м" on a Russian layout and a jamo on a Korean one. Keyed to `"v"`, this
  watcher did nothing whatsoever for anyone not typing in English, and it read
  as "paste is broken" rather than as anything about layouts. Match `kVK_ANSI_V`
  through `Carbon.HIToolbox`, the way `GlobalShortcutModels` already does.
- **Focus gates a monitor by when it is installed, not by what it reads.** A
  handler installed at `onAppear` holds a copy of the view made when focus was
  false, and asking that copy for `@FocusState` later is asking the wrong
  object. Install on focus, remove on blur, and let `onAppear` cover coming
  back to a pane that is still focused — the one case `onChange` alone never
  sees.
- **Pixels and words on the board are two questions, not one.** Refusing every
  board that carries text refuses most photos: one copied in Finder arrives with
  its own file name beside it, and a browser's "Copy image" puts markup there.
  So a picture _file_ attaches and the paste ends (its name is noise in a
  message), and pixels sitting beside real words attach _and_ let the event
  through, because a spreadsheet cell is a rendered copy of its own text and
  picking one half for someone loses the half they wanted (`ChatImage.pasted`).
- **Encode at attach, twice.** One fitted to the 2048px edge vision models tile
  at, which is what keeps a retina screenshot under the 5 MB every cloud backend
  guards on; one thumbnail. The second is not a nicety: a streaming answer
  re-evaluates every row above it, so a chip decoding the full-size JPEG on each
  chunk stutters the whole transcript. Flatten alpha in the same pass — JPEG has
  none, and a transparent PNG handed straight to the encoder comes back black.
- **A picture is a message on its own.** Send is enabled with no words, and the
  bubble drops the pill rather than drawing an empty one.
- **A control that cannot deliver what it accepts is hidden, not silent.** The
  clip disappears while a build owns the composer, because the next message
  there is an answer to the builder's own question and a picture has nowhere to
  go. The builder never receives pictures at all: the one agent sees it and
  writes the `BUILD:` line, so what the picture _showed_ travels as words.

## 18. Notes reach a model through three gates, and only through them

A note is handed to anything that thinks — a gizmo, Ask — exactly when all
three of these say yes, and there is no fourth switch anywhere:

1. **The master switch** in Settings ("Let gizmos read my notes",
   `NotesAccess`, default on). It is enforced inside `NotesContext.records()`,
   the one function every consumer is built on, so no call site can forget it.
2. **The per-gizmo `usesNotes` flag**, set in the gizmo's editor or by the
   builder. Ask deliberately has no flag of its own: it is the front door, and
   the master switch plus the ticks are its whole configuration.
3. **The per-note tick** (`Note.usedAsContext`), which exists to exclude the
   scratch notes, not to make every note opt in.

What the consumer then sees is standardized, not bespoke per consumer:

- **Prompt text** (`NotesContext.text`, for `.prompt` gizmos, `.agent` gizmos,
  built-ins, and Ask): one line per note, newest first, `- [Folder] Title:
body`. The bracket is the folder — a `NoteTag` name — so a model can tell
  work notes from personal ones without being handed the store.
- **A JSON file** (`NotesContext.fileData()`, for `.python` gizmos): the same
  records as `[{title, text, folder, updatedAt}]`, handed over as a file whose
  path arrives in `GIZMO_NOTES_FILE`. The variable is absent when there is
  nothing to share — the master switch off, or nothing ticked — so a script
  must treat it as optional, and candidate validation runs without it on
  purpose: model-written code the user never approved does not get the user's
  notes.

Do not add a consumer that decodes the notes key itself. `records()` is where
the gates live, and a consumer that goes around it is a consumer the master
switch does not reach.
