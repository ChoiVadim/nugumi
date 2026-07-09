# Ask Nugumi — Remove petTarget Pointer — Design

Date: 2026-07-09
Status: approved

## Problem

`petTarget` (single-point pointer) and `annotations` (model-drawn shapes) are
two competing pointing mechanisms: the model must choose between them, the
prompt teaches both, and the user sees two visual languages (a flying pointer
button vs drawn shapes). Annotations strictly supersede the pointer.

## Solution overview

Remove the petTarget mechanism end to end — schema, prompt, pill-mode
floating pointer, pet-mode pixel marker, mapper overloads, tests — leaving
`annotations` as the only way the model points at the screen. The valuable
aiming guidance from the old coordinate guide is REWORDED for annotations,
not deleted.

## Removal inventory

### `Sources/Nugumi/AskNugumi.swift`

- `AskNugumiCoordinateSpace` enum (exists only for petTarget) — delete.
- `AskNugumiPetTarget` struct — delete.
- `AskNugumiResponse`: `petTarget` stored property, its `CodingKeys` case,
  decode/encode lines, and the init parameter. New memberwise init:
  `init(message:emotion:annotations:)` with `annotations: [AskNugumiAnnotation] = []`.
  A model that still emits `petTarget` in JSON is harmless — Codable ignores
  unknown keys.
- Prompt (`AskNugumiPromptBuilder`):
  - Delete the petTarget example JSON line and every petTarget rule bullet
    from `systemPromptBase`.
  - The annotations example/rules become the only pointing mechanism.
  - The per-question coordinate guide (`prompt(question:hasImage:)`) is
    retitled "Coordinate guide for annotations:" and its aiming advice is
    reworded for annotations (kept, not deleted): aim at the geometric center
    of the target element's visible bounding box, never the top-left of a
    text label; for small menu-bar/status icons use the glyph's visual
    center; identify the target's row/column context in `message` before
    choosing coordinates. The `coordinateSpace` bullet is deleted.
- Mapper: delete the petTarget overloads `exactScreenPoint(for:screenFrame:)`
  and `screenPoint(for:screenFrame:visibleFrame:)`. Keep the raw
  `exactScreenPoint(normalizedX:normalizedY:screenFrame:)` and
  `screenRect(centerX:centerY:normalizedWidth:normalizedHeight:screenFrame:)`
  (annotations renderer uses them).
- Pet-marker geometry types — delete: `AskNugumiTargetMarkerMetrics`,
  `AskNugumiPetAnswerTargetPanelPresentation`,
  `AskNugumiPetAnswerTargetPanelMetrics`,
  `AskNugumiPetAnswerTargetPresentation`,
  `AskNugumiPetAnswerTargetPresentationPolicy`.
- `AskNugumiFloatingTargetPresentationPolicy`: `presentation(...)` and
  `pointerOffset` are pointer-only — delete them. `buttonSize`,
  `shadowPadding`, `totalSize` are used by the floating loading bar and the
  selection button geometry — verify usage by grep and keep exactly what
  non-pointer callers need (rename is out of scope).

### `Sources/Nugumi/App.swift`

- `floatingTargetButton` property and every `floatingTargetButton?.close();
floatingTargetButton = nil` pair (entry cleanup, answer panel onClose,
  dismissAskNugumi, follow-up success/else, presentAskNugumiResult else) —
  delete.
- `presentFloatingAskTargetPointer(for:capture:)` — delete.
- `FloatingTranslateButtonController.pointAt(_:visibleFrame:)` and the
  pointer-arrow rendering it drives — delete IF grep confirms the Ask
  pointer was the only caller (expected). The class itself stays: it is the
  selection floating button and the Ask loading bar.
- Pet marker: `markerTarget` parameter of `PetController.showAnswer`, the
  target marker panel + its glide animation (including the
  `targetMarkerGlideTimer` whose Sendable-closure warning is the build's
  only warning), and the dead `moveToAnswerTarget` — delete.
  `presentPetAskNugumiResult` simplifies to
  `showAnswer(message, emotion:)` + `presentAskAnnotations(...)`.
- Response fallback constructors `AskNugumiResponse(message: "",
petTarget: nil, emotion: nil)` (4 sites) → `(message: "", emotion: nil)`.

### Tests (`Tests/NugumiTests/`)

- Delete petTarget-specific tests: parse tests asserting `petTarget`
  decoding/validation, mapper tests of the deleted overloads, and
  `testPetTargetMappingStillDelegatesUnchanged` in
  `AskNugumiAnnotationTests`.
- Flip prompt assertions: the system prompt must NOT contain "petTarget" or
  "screenshot_normalized"; the annotations vocabulary/rules assertions stay.
- Keep every remaining annotations/mapping/history/emotion test passing
  unchanged.

## Constraints

- `emotion`, ask history, the drawing (user strokes) feature, and the
  annotations feature are untouched.
- `presentAskAnnotations` replace semantics and all its teardown points stay
  exactly as shipped (including `onAnswerDismissedByUser`).
- No user-facing strings change (the pointer had none of its own).
- Net-negative diff expected; no new abstractions.

## Sequencing

Executed after the model-annotations final review verdict lands, folded into
the same branch (`ask-nugumi-drawing`).

## Testing

- `swift build` with ZERO warnings expected (the only pre-existing warning
  lives in the deleted glide timer) — if other warnings appear, report them.
- Full `swift test` green after test updates.
- Manual QA: ask a "where is X?" question → model answers with an annotation
  arrow/ellipse instead of the old pointer; pet mode shows bubble + shapes,
  no pixel marker; loading bar still appears while a question is in flight;
  selection floating button (translate/rewrite) unaffected.
