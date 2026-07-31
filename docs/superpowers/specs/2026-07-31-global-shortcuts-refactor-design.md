# Global Shortcuts Refactor Design

## Goal

Replace the 1,201-line
`Sources/Gizmate/App/GlobalShortcuts.swift` catch-all with focused files under
`Sources/Gizmate/App/Shortcuts/` so shortcut data, persistence, input
monitoring, and recorder UI can be edited independently without changing
behavior.

## Constraints

- This is pure code motion inside the existing `Gizmate` target.
- `Package.swift`, dependencies, deployment target, app identity, persisted
  keys, encoded fields, shortcut IDs, defaults, event masks, timing, callbacks,
  UI copy, constraints, and lifecycle ordering must not change.
- Preserve all declaration bodies, comments, annotations, and access levels.
- Do not split a stateful type across files or widen private declarations.
- Do not redesign the recorder UI or change shortcut behavior.

## Existing Responsibilities

The current file contains five independent responsibility groups:

1. Shortcut actions, grouping, value encoding, display formatting, and Carbon
   modifier conversion.
2. Double-modifier gesture state and event monitoring.
3. Spare-mouse-button monitoring through an event tap with NSEvent fallback.
4. UserDefaults persistence.
5. Shortcut recorder window, panel, and capture field.

The top-level declarations already expose these boundaries, so the refactor
does not require new protocols, wrappers, or runtime indirection.

## Target Structure

Create `Sources/Gizmate/App/Shortcuts/` with:

- `GlobalShortcutModels.swift`
  - `GlobalShortcutAction`
  - `ShortcutGroup`
  - `GlobalShortcut`
  - private `ShortcutKeyFormatter`
- `DoubleModifierPressDetector.swift`
  - `DoubleTapState`
  - `DoubleModifierPressDetector`
- `MouseButtonShortcutMonitor.swift`
  - `MouseButtonShortcutMonitor`
- `GlobalShortcutStore.swift`
  - `GlobalShortcutStore`
- `ShortcutRecorderWindowController.swift`
  - `ShortcutRecorderWindowController`
  - private `ShortcutRecorderPanel`
  - private `ShortcutCaptureFieldView`

Delete `GlobalShortcuts.swift` after every declaration has moved.

SwiftPM recursively discovers sources below `Sources/Gizmate`, so this
directory move requires no manifest change.

## Privacy Boundary

`ShortcutKeyFormatter` must remain in the same file as `GlobalShortcut`
because the value type calls that private helper.

The recorder controller, panel, and capture field must remain together. The
controller constructs the two private types, and separating them would require
access widening. Their focused file is expected to remain around 550 lines;
that is an intentional exception to the normal roughly-400-line guideline.

## Imports

- Models: `AppKit`, `Carbon.HIToolbox`, `Foundation`.
- Double-modifier detector: `AppKit`, `Foundation`.
- Mouse monitor: `AppKit`, `Foundation`.
- Store: `Foundation`.
- Recorder UI: `AppKit`, `Carbon.HIToolbox`, `Foundation`.

## Behavior Invariants

- Preserve action raw values, Carbon IDs, menu text, groups, default key codes,
  modifier sets, the permanent Ask Gizmate alias, and the middle-click default.
- Preserve Codable keys and the legacy missing-`kind` fallback.
- Preserve equality, validation, display strings, Carbon modifier conversion,
  and every key-name/menu-equivalent mapping.
- Preserve double-tap contamination rules, the 0.30-second interval, local and
  global monitor behavior, and enabled-state reset behavior.
- Preserve mouse event consumption, tap re-enabling, run-loop registration,
  and observe-only fallback monitors.
- Preserve UserDefaults keys and invalid-value fallback to defaults.
- Preserve recorder panel geometry, copy, selectors, first-responder behavior,
  conflict handling, double-tap capture, mouse-button capture, and Escape/Return
  behavior.
- Preserve every `@MainActor` annotation and private declaration.

## Verification

After each extraction:

- compare moved blocks against the parent commit;
- run `swift build`;
- run `swift test --filter GlobalShortcutsTests`;
- run `git diff --check`;
- inspect the scoped diff.

At the end:

- run the full `swift test` suite;
- confirm `GlobalShortcuts.swift` is absent;
- confirm every original declaration exists exactly once with unchanged
  access and annotations;
- confirm only the recorder UI file exceeds roughly 400 lines;
- request an independent read-only review.
