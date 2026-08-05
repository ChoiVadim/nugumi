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
- **A placement control can be the only consent screen a background run
  gets.** A surface's script runs on pointer hover, not a press — the first
  trigger in Gizmate the user doesn't cause directly. Nothing new executes
  (same `ToolRunner`, same approval hash as every other tool), but what
  changed is _when_, and approving "run once" is not the same consent as
  "run again on every hover, forever." The dock's placement control is where
  that choice is actually made — picking an edge is what turns a saved gizmo
  into one that opens on its own — so it is also where the sentence has to
  live: _this gizmo runs whenever its dock opens._ It follows that the two
  placement pickers cannot share one default label: a `.panel` result still
  works undocked, so its picker calls `nil` "Floating"; a surface has no
  working undocked state, so its picker calls the same `nil` "Off" rather
  than borrow a word that would say otherwise.

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
