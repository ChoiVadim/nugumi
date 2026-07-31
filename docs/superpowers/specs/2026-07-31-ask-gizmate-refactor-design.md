# Ask Gizmate Refactor Design

**Date:** 2026-07-31

## Goal

Replace the 616-line mixed-domain
`Sources/Gizmate/Ask/AskGizmate.swift` file with three focused files for
response parsing, conversation/prompt state, and presentation geometry.

## Target layout

| File | Ownership |
| --- | --- |
| `AskGizmateResponse.swift` | emotions, annotation wire types/validation, lenient annotation decoding, response parsing/Codable |
| `AskGizmateConversation.swift` | turns, persisted history, prompt construction |
| `AskGizmateLayout.swift` | prompt/answer/pet layout models, metrics, dismissal, presentation, coordinate mapping |

The original file is deleted after all three declaration clusters move
byte-identically.

The README source map is updated after implementation so it names the three
replacement files instead of the deleted `AskGizmate.swift`.

## Access and coupling

- Preserve all internal access and every nested private declaration.
- Keep private `FailableDecodable`, `AnnotationsWrapper`, parsing helpers, and
  response CodingKeys with `AskGizmateResponse`.
- Keep private history keys and prompt strings with conversation ownership.
- Keep private layout constants and clamping helper with their metric types.
- All files remain in the same target; no access widening is needed.

## Imports

- `AskGizmateResponse.swift`: `CoreGraphics`, `Foundation`.
- `AskGizmateConversation.swift`: `Foundation`.
- `AskGizmateLayout.swift`: `CoreGraphics`, `Foundation`.

## Behavior invariants

- Preserve annotation validation, lenient per-item decoding, fence detection,
  legacy JSON fallback, caps, and encoded payload shape.
- Preserve the pre-rename history keys, expiration window, save clock, and
  history cap.
- Preserve the complete system prompt, Gen Z suffix, user context, and
  screenshot coordinate guide byte-identically.
- Preserve every layout dimension, clamp, scroll threshold, hit tolerance,
  pet/bubble placement, and coordinate transform.

## Verification

- Exact moved-block comparison for original lines 4–245, 247–351, and
  353–616.
- Confirm original deletion leaves only imports/separators and is therefore
  complete.
- Import, access, nested-private, declaration uniqueness, and scope audit.
- `swift build`.
- Focused `AskGizmateTests` and `AskGizmateAnnotationTests`.
- Full `swift test`.
- `git diff --check`.
- README source-map accuracy.
- Independent read-only review.

Expected new line counts are 245, 107, and 267.

## Deliberate deferrals

- Do not change parsing strictness, prompt copy, persistence keys, layout
  constants, or coordinate behavior.
- Do not merge layout metric types or deduplicate their calculations.
- Do not move UI controllers or app orchestration into these domain files.
