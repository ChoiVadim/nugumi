# Ask Nugumi On-Screen Drawing — Design

Date: 2026-07-09
Status: approved

## Problem

Ask Nugumi captures one full-screen screenshot at invocation. The user has no
way to indicate _which part_ of the screen the question is about.

## Solution overview

While the Ask Nugumi prompt is open, a transparent overlay on the captured
screen lets the user draw freehand red strokes. At submit, strokes are
composited into the already-captured screenshot (no re-capture), and one
sentence is appended to the prompt telling the model the red marks are the
user's annotations.

## Component

`AskDrawingOverlayController` — new class in `App.swift` (single-file rule):

- Borderless transparent `NSPanel` covering **only the captured screen** (the
  screen containing the cursor at invocation; other screens are not in the
  image, so drawing there is meaningless).
- Window level just below the Ask pill.
- `sharingType = .none` so strokes can never leak into the submit-time
  fallback capture.
- Non-activating: accepts mouse events but never becomes key — the pill keeps
  keyboard focus for typing.
- Crosshair cursor over the overlay. `mouseDown`/`mouseDragged`/`mouseUp`
  builds freehand strokes (red, ~4 pt, round caps/joins) rendered in a custom
  view.
- API: `init(screen:)`, `strokes` (arrays of points in AppKit global
  coordinates), `undoLastStroke()`, `close()`.

## Interaction

- ⌃⌥A → screenshot captured (unchanged) → pill **and** overlay appear.
- Any mouse drag on the captured screen = red stroke. Strokes stay visible
  while the prompt is open; draw and type in any order.
- ⌘Z removes the last stroke (key event lands on the pill, routed to the
  overlay).
- Esc / repeat ⌃⌥A close everything (existing paths). Outside-click-to-close
  is **disabled while the overlay is active** — background clicks now draw.
  Verify during implementation how `AskPromptController`'s outside-click
  monitors work and suppress them for the overlay window/session.
- Submit → overlay closes; strokes are composited into the image.
- Pet mode gets the same overlay; the submit path is shared.

## Compositing

At submit, only if strokes exist:

- Decode `capture.image` (JPEG/PNG data) back to a `CGImage`, draw strokes
  into a `CGContext` on top, re-encode JPEG 0.85 (same encoder settings as the
  capture path). No changes to `AskNugumiScreenCapture`.
- Coordinate mapping already exists in the struct: AppKit global points →
  image pixels via `screenFrame` and `imagePixelSize` (scale + Y flip).
- Stroke width: 4 pt scaled by the point→pixel ratio, floored at ~3 px so
  marks stay visible on downscaled (≤2048) images.
- Best-effort: any compositing failure sends the unannotated image; the
  request is never blocked.
- No strokes → the image is sent untouched; behavior identical to today.

## Prompt addition

When strokes exist, append to the outgoing prompt:
"The red marks on the screenshot were drawn by the user to point at what they
are asking about."

## Non-goals (YAGNI)

Color/width pickers, arrow/shape tools, drawing across multiple displays,
per-stroke eraser, persisting drawings between invocations.

## Manual QA checklist

1. Circle a UI element, ask "what did I circle?" → answer references it.
2. Esc closes overlay + pill; repeat ⌃⌥A toggles closed.
3. ⌘Z removes only the last stroke.
4. Submit with no strokes → request identical to current behavior.
5. Fallback capture path (pending capture nil): on-screen strokes do not
   appear in the captured image (`sharingType = .none`).
6. Screenshot-translation mode unaffected.
7. Pet mode drawing works.
