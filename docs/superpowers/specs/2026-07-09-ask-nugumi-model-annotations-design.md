# Ask Nugumi Model Annotations — Design

Date: 2026-07-09
Status: approved

## Problem

The model can point at one screen location (`petTarget`), but cannot draw
richer explanations — circle an element, draw an arrow between two things,
box a region, attach a short label. The user wants the model to draw shapes
over the real UI when that explains the answer better than words.

## Solution overview

Extend the existing structured Ask response with an optional `annotations`
array of simple shapes in the same normalized screenshot coordinates as
`petTarget`. Render them natively on a click-through transparent overlay
(NSBezierPath — no Excalidraw, no WKWebView). Every answer (including
follow-ups) fully replaces the annotation layer: new shapes redraw it, no
shapes clear it.

Decision record: Excalidraw embed and model-emitted SVG were considered and
rejected — for drawing over a real UI the bottleneck is the model's
localization accuracy, not renderer expressiveness; a compact validated
vocabulary is more reliable and adds zero dependencies. An Excalidraw-style
blank-canvas diagram panel is a possible v2 using the same shape vocabulary
in a second coordinate space; explicitly out of scope here.

## Response schema (`Sources/Nugumi/AskNugumi.swift`)

> **Protocol v2 (amended 2026-07-10, supersedes the JSON envelope below).**
> Asking the model for multi-line markdown inside a JSON string field made
> the two goals fight: strict JSON flattened the text, good markdown broke
> the JSON (the model split its output and the shapes leaked into the
> visible answer). The wire format is now **plain markdown answer text +
> one trailing fenced ` ```annotations ` block containing a bare JSON array
> of shapes**. Parser precedence: (1) trailing fence — qualifies by info
> string `annotations`, or by payload actually decoding to valid shapes
> (including a ` ```json ` fence wrapping `{"annotations": [...]}`); an
> `annotations`-labeled fence is stripped from the visible message even
> when its JSON is broken (the machine block is never shown); user-facing
> code fences never qualify; (2) legacy whole/embedded `{"message": ...}`
> JSON object, kept as a fallback for models that still answer in the
> retired shape; (3) plain text. `emotion` is retired from the protocol
> entirely (schema field deleted; stray keys ignored; the pet answers with
> its default face). Validation (per-shape `isValid`, cap 12) is unchanged.

Retired v1 envelope (kept for historical context):

```json
{
  "message": "...",
  "emotion": "neutral",
  "annotations": [
    { "type": "ellipse", "cx": 0.42, "cy": 0.31, "w": 0.1, "h": 0.05 },
    { "type": "rect", "cx": 0.6, "cy": 0.2, "w": 0.2, "h": 0.1 },
    { "type": "arrow", "fromX": 0.42, "fromY": 0.45, "toX": 0.55, "toY": 0.32 },
    { "type": "label", "x": 0.42, "y": 0.5, "text": "жми сюда" }
  ]
}
```

- One flat struct `AskNugumiAnnotation` with `type: AskNugumiAnnotationType`
  (`ellipse | rect | arrow | label`) and per-type optional fields:
  `cx, cy, w, h` (ellipse/rect), `fromX, fromY, toX, toY` (arrow),
  `x, y, text` (label). No polymorphic decoder.
- Per-element `isValid` (mirrors `AskNugumiPetTarget.isValid`): all required
  fields for the type present and finite; positions in 0...1; `w`/`h` in
  (0...1]; label `text` non-empty after trimming, ≤ 60 characters.
- Lenient decoding: an element that fails to decode or is invalid is dropped
  silently; the rest survive. At most the first 12 valid annotations are
  kept (garbage flood guard for weak local models).
- `AskNugumiResponse.annotations` defaults to `[]`; absent field ≡ empty.
- `petTarget` and `emotion` behavior is unchanged; `petTarget` and
  `annotations` may coexist in one response.

## Prompt (`AskNugumiPromptBuilder`)

System prompt gains an annotations section:

- Vocabulary and JSON shape as above; same normalized coordinate space as
  `petTarget` (x left-to-right, y top-to-bottom over the screenshot).
- Use only when a screenshot is attached AND drawing over it genuinely helps;
  never without a screenshot.
- Few precise shapes beat many: ellipse to circle an element, arrow for
  direction/flow between two visible things, rect for a region, label for a
  ≤ 5 word caption anchored near its subject.
- If uncertain about a location, omit the shape and explain in `message`.
- Each answer's annotations REPLACE the previous ones (the old layer is
  cleared before every new answer); to keep pointing at something across a
  follow-up, re-emit its shapes.

The per-question coordinate guide (`prompt(question:hasImage:)`) mentions
that the same guide applies to `annotations` coordinates. `petTarget` rules
stay untouched (pet mode unchanged).

## Rendering (`Sources/Nugumi/App.swift`)

New `AskAnnotationOverlayController`, modeled on `AskDrawingOverlayController`
but purely visual:

- Transparent borderless non-activating `NSPanel` covering the capture's
  `screenFrame`; never key/main; level `.floating - 1`;
  `.canJoinAllSpaces, .fullScreenAuxiliary`.
- Capture visibility (amended 2026-07-10, maintainer decision): the layer is
  deliberately screenshot-capturable — `InvisibilityState.apply(to:)` like
  any other window (`.readOnly` normally, `.none` in invisibility mode) — so
  the model's shapes survive into the user's own Cmd+Shift+3/4 screenshots
  and screen sharing. Nugumi's own captures still never see it: the Ask
  capture paths wrap in `hideAppWindowsFromScreenCapture()` snapshot/restore,
  and the area screenshot-translation capture wraps in the same helper so
  annotation text labels cannot pollute OCR. (The original design clamped
  `sharingType` to `.none`; superseded by this amendment.) All shapes cast
  one soft drop shadow via a single transparency layer.
- **Click-through:** `ignoresMouseEvents = true`. No event monitors, no
  cursor changes — the user keeps working through the overlay.
- Style: `nugumiAccent` strokes (~3 pt) with a white halo (wider white
  stroke underneath) so shapes read on any background and are visually
  distinct from the user's red drawing strokes. Labels render as small
  rounded pills (accent background, white text, system font ~12 pt).
- Arrowheads: filled triangle at the `to` end.
- API: `init(screenFrame: NSRect)`, `show(_ annotations: [AskNugumiAnnotation])`
  (replaces current content), `close()` idempotent.

Coordinate mapping normalized → AppKit screen points lives next to
`AskNugumiCoordinateMapper` as pure functions (same y-flip semantics:
normalized y is top-to-bottom, AppKit y is bottom-up), unit-tested with
asymmetric points that distinguish a correct mapping from a flipped one.

## Lifecycle

- Annotations appear wherever a `petTarget` pointer can appear today: the
  pill-mode answer (`presentAskNugumiResult`), pet-mode answer, and
  follow-up answers (`submitAskNugumiFollowUp`) — using that answer's own
  capture `screenFrame` (follow-ups re-capture, so shapes map to the fresh
  screen).
- Replace semantics on EVERY answer: `annotations` non-empty → overlay
  redraws with the new shapes; empty → overlay closes. Mirrors the existing
  `petTarget` present/absent handling in the follow-up path.
- Torn down everywhere the target pointer dies today: answer panel close,
  Esc, new ask, `dismissAskNugumi`.
- Coexists with the user's drawing overlay only transiently (user strokes
  die at submit; annotations appear with the answer) — no interaction
  between the two layers.

## Degradation / errors

- No `annotations` field, invalid elements, or a text-only model → behavior
  identical to today. Nothing in the request path changes.
- Annotations are never persisted: not in `askHistory`, not in the history
  store — `message` text only, as today.
- Overlay rendering failure must never affect the answer text presentation.

## Out of scope (YAGNI)

Blank-canvas diagram panel (v2), interactive/clickable annotations,
animations, per-shape colors, freedraw paths from the model, Excalidraw or
SVG rendering.

## Testing

- Parsing: valid full set; unknown `type` dropped; missing/NaN/out-of-range
  fields dropped; mixed valid+invalid keeps valid; 13+ valid → capped at 12;
  absent field → `[]`; round-trip encode/decode.
- Mapping: normalized point/rect → screen with non-zero-origin screenFrame
  and asymmetric y (flip-regression-proof, per `tasks/lessons.md`).
- Prompt: system prompt mentions `annotations` only in the intended section;
  `petTarget` rules unchanged.
- Rendering/lifecycle: manual QA checklist (circle + arrow + label visible,
  click-through works, follow-up redraw, follow-up with no shapes clears,
  Esc/dismiss teardown, invisibility toggle keeps overlay uncapturable).
