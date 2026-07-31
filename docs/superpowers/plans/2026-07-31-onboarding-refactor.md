# Onboarding Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task by task.

**Goal:** Replace `Onboarding.swift` with focused files so onboarding support,
state, window lifecycle, and presentation can be edited independently without
changing behavior.

**Architecture:** Move existing top-level declarations into
`Sources/Gizmate/App/Onboarding/`. Preserve stateful type bodies. Make only
`OnboardingRootView` internal so the window controller can construct it from a
separate file; keep every leaf view private.

**Tech Stack:** Swift 5 language mode, AppKit, AVKit, Combine, SwiftUI, Swift
Package Manager, XCTest

## Global Constraints

- Deployment target remains macOS 14.
- `Package.swift`, dependencies, app identity, defaults keys, analytics values,
  permission URLs, feature/media URLs, permission routing, timing, callbacks,
  UI copy, window geometry, constraints, animations, and lifecycle ordering
  must not change.
- No new targets or dependencies.
- Preserve access and actor annotations except for the documented
  `OnboardingRootView` private-to-internal change.
- No UI redesign, formatting sweep, warning cleanup, feature work, or runtime
  rewrite.
- Run `swift build` and `git diff --check` after every extraction task.
- Do not split stateful types across files.

---

### Task 1: Extract Onboarding Support

**Files:**

- Create: `Sources/Gizmate/App/Onboarding/OnboardingSupport.swift`
- Modify: `Sources/Gizmate/App/Onboarding.swift`

**Move unchanged:**

- `PermissionKind`
- `FullDiskAccessProbe`
- `FeatureTourStep`
- `OnboardingIntroVideo`

**Imports:** `Foundation`.

- [ ] Preserve analytics values, probe path/fallback/task priority, feature
      order/copy/steps, shortcut-derived instructions, bundled resource lookup,
      and remote URLs exactly.
- [ ] Preserve every body and access level.
- [ ] Remove only the moved declarations from the original.
- [ ] Run `swift build`, both focused onboarding test classes, and
      `git diff --check`.
- [ ] Commit with `Split onboarding support models`.

---

### Task 2: Extract the Onboarding State Model

**Files:**

- Create: `Sources/Gizmate/App/Onboarding/OnboardingModel.swift`
- Modify: `Sources/Gizmate/App/Onboarding.swift`

**Move unchanged:** complete `@MainActor OnboardingModel`.

**Imports:** `AppKit`, `Combine`, `Foundation`.

- [ ] Preserve modes/pages, defaults keys, initial routing, permission order,
      optional Full Disk Access behavior, probe coalescing, completion
      callbacks, Settings URLs, request delay, and display strings.
- [ ] Preserve private state and every actor annotation.
- [ ] Remove only the complete model declaration.
- [ ] Run `swift build`, both focused onboarding test classes, and
      `git diff --check`.
- [ ] Commit with `Split onboarding state model`.

---

### Task 3: Extract Onboarding Views

**Files:**

- Create: `Sources/Gizmate/App/Onboarding/OnboardingViews.swift`
- Modify: `Sources/Gizmate/App/Onboarding.swift`

**Move:**

- `OnboardingRootView`
- `OnboardingPalette`
- `FinaleChoiceButton`
- `PermissionCard`
- `FeatureInstructionCard`
- `IntroVideoPage`
- `IntroPlayerView`
- `loadOnboardingImage`
- `PermissionPreviewPanel`
- `FauxSystemDialog`
- `FauxSettingsList`
- `FauxSettingsRow`
- `FeatureVideoPanel`
- `LoopingVideoPlayer`

**Imports:** `AppKit`, `AVKit`, `Combine`, `SwiftUI`.

- [ ] Move every view body unchanged.
- [ ] Change only `OnboardingRootView` from private to internal so the window
      controller can access it across files.
- [ ] Keep every other view and `OnboardingPalette` private.
- [ ] Preserve polling, layout, copy, colors, actions, animation, media
      playback, coordinators, and constraints.
- [ ] Remove only the moved view declarations from the original.
- [ ] Run `swift build`, both focused onboarding test classes, and
      `git diff --check`.
- [ ] Commit with `Split onboarding views`.

---

### Task 4: Extract the Window Controller and Remove the Catch-All

**Files:**

- Create:
  `Sources/Gizmate/App/Onboarding/OnboardingWindowController.swift`
- Delete: `Sources/Gizmate/App/Onboarding.swift`

**Move unchanged:** complete `@MainActor OnboardingWindowController`.

**Imports:** `AppKit`, `SwiftUI`.

- [ ] Preserve all window sizes, style, level, collection behavior, hosting,
      constraints, callbacks, resize behavior, activation, and close routing.
- [ ] Delete the original only after it contains no declarations.
- [ ] Run `swift build`, both focused onboarding test classes, and
      `git diff --check`.
- [ ] Confirm `Onboarding.swift` is absent.
- [ ] Commit with `Finish onboarding split`.

---

### Task 5: Final Verification and Review

- [ ] Run full `swift test`.
- [ ] Record executed, skipped, and failure counts.
- [ ] Run `git diff --check`.
- [ ] Audit the tranche diff and confirm no production files outside
      `Sources/Gizmate/App/Onboarding.swift` and
      `Sources/Gizmate/App/Onboarding/` changed.
- [ ] Compare original and replacement declarations for presence, uniqueness,
      body exactness, and actor annotations.
- [ ] Confirm the only access change is the documented internal
      `OnboardingRootView`.
- [ ] Confirm `Onboarding.swift` is absent.
- [ ] Run `wc -l Sources/Gizmate/App/Onboarding/*.swift` and confirm the
      documented views cluster is the only replacement materially above
      roughly 400 lines; the coherent state model may sit only a few lines
      over after imports.
- [ ] Update the README source map from `Onboarding.swift` to the new
      `Onboarding/` directory.
- [ ] Request an independent read-only code review.
