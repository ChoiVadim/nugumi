# Global Shortcuts Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task by task.

**Goal:** Replace `GlobalShortcuts.swift` with focused files so shortcut
models, persistence, input monitoring, and recorder UI can be edited
independently without changing behavior.

**Architecture:** Keep every declaration in the existing `Gizmate` target and
perform pure code motion along existing top-level declaration boundaries. Put
the replacements under `Sources/Gizmate/App/Shortcuts/`. Keep tightly coupled
private helpers with their callers so no access widening is required.

**Tech Stack:** Swift 5 language mode, AppKit, Carbon.HIToolbox, Foundation,
Swift Package Manager, XCTest

## Global Constraints

- Deployment target remains macOS 14.
- `Package.swift`, dependencies, app identity, persistence keys, Codable
  fields, action raw values and IDs, default shortcuts, event masks, timing,
  callbacks, UI copy, constraints, selectors, and lifecycle ordering must not
  change.
- No new targets or dependencies.
- Preserve existing access levels and `@MainActor` annotations.
- No UI redesign, formatting sweep, warning cleanup, feature work, or runtime
  rewrite.
- Run `swift build` and `git diff --check` after every extraction task.
- Do not split stateful types across files if it would expose private state.

---

### Task 1: Extract Shortcut Models and Persistence

**Files:**

- Create: `Sources/Gizmate/App/Shortcuts/GlobalShortcutModels.swift`
- Create: `Sources/Gizmate/App/Shortcuts/GlobalShortcutStore.swift`
- Modify: `Sources/Gizmate/App/GlobalShortcuts.swift`

**Move unchanged:**

- `GlobalShortcutAction`, `ShortcutGroup`, `GlobalShortcut`, and private
  `ShortcutKeyFormatter` to `GlobalShortcutModels.swift`.
- `GlobalShortcutStore` to `GlobalShortcutStore.swift`.

**Imports:**

- Models: `AppKit`, `Carbon.HIToolbox`, `Foundation`.
- Store: `Foundation`.

- [ ] Preserve raw values, IDs, defaults, alias, key codes, modifiers, strings,
      grouping, Codable behavior, equality, validation, and formatter maps.
- [ ] Keep `ShortcutKeyFormatter` private beside `GlobalShortcut`.
- [ ] Preserve UserDefaults keys and invalid-value fallback.
- [ ] Remove only the moved declarations from the original.
- [ ] Run `swift build`, `swift test --filter GlobalShortcutsTests`, and
      `git diff --check`.
- [ ] Commit with `Split global shortcut models and persistence`.

---

### Task 2: Extract Input Monitors

**Files:**

- Create:
  `Sources/Gizmate/App/Shortcuts/DoubleModifierPressDetector.swift`
- Create:
  `Sources/Gizmate/App/Shortcuts/MouseButtonShortcutMonitor.swift`
- Modify: `Sources/Gizmate/App/GlobalShortcuts.swift`

**Move unchanged:**

- `DoubleTapState` and `DoubleModifierPressDetector` to
  `DoubleModifierPressDetector.swift`.
- `MouseButtonShortcutMonitor` to
  `MouseButtonShortcutMonitor.swift`.

**Imports:** `AppKit` and `Foundation` in both files.

- [ ] Preserve gesture contamination rules, the double-tap interval, event
      masks, local/global monitor behavior, and reset behavior.
- [ ] Preserve event-tap consumption, re-enabling, run-loop setup, fallback
      monitors, callbacks, and teardown order.
- [ ] Preserve all actor annotations and private state.
- [ ] Remove only the moved declarations from the original.
- [ ] Run `swift build`, `swift test --filter GlobalShortcutsTests`, and
      `git diff --check`.
- [ ] Commit with `Split global shortcut input monitors`.

---

### Task 3: Extract Recorder UI and Remove the Catch-All

**Files:**

- Create:
  `Sources/Gizmate/App/Shortcuts/ShortcutRecorderWindowController.swift`
- Delete: `Sources/Gizmate/App/GlobalShortcuts.swift`

**Move unchanged:**

- `ShortcutRecorderWindowController`
- private `ShortcutRecorderPanel`
- private `ShortcutCaptureFieldView`

**Imports:** `AppKit`, `Carbon.HIToolbox`, and `Foundation`.

- [ ] Preserve panel geometry, controls, constraints, selectors, copy,
      first-responder handling, key and mouse capture, conflict handling,
      Escape/Return behavior, callbacks, and lifecycle exactly.
- [ ] Keep all three declarations together; do not widen the private panel or
      capture field.
- [ ] Delete the original only after it contains no declarations.
- [ ] Run `swift build`, `swift test --filter GlobalShortcutsTests`, and
      `git diff --check`.
- [ ] Confirm `GlobalShortcuts.swift` is absent.
- [ ] Commit with `Finish global shortcut split`.

---

### Task 4: Final Verification and Review

- [ ] Run full `swift test`.
- [ ] Record executed, skipped, and failure counts.
- [ ] Run `git diff --check`.
- [ ] Audit the tranche diff and confirm no production files outside
      `Sources/Gizmate/App/GlobalShortcuts.swift` and
      `Sources/Gizmate/App/Shortcuts/` changed.
- [ ] Compare original and replacement declarations for presence, uniqueness,
      body exactness, annotations, and access levels.
- [ ] Confirm `GlobalShortcuts.swift` is absent.
- [ ] Run `wc -l Sources/Gizmate/App/Shortcuts/*.swift` and confirm the
      documented recorder UI is the only replacement above roughly 400 lines.
- [ ] Update the README source map from `GlobalShortcuts.swift` to the new
      `Shortcuts/` directory.
- [ ] Request an independent read-only code review.
