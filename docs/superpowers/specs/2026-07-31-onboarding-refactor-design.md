# Onboarding Refactor Design

## Goal

Replace the 1,592-line `Sources/Gizmate/App/Onboarding.swift` catch-all with a
focused `Sources/Gizmate/App/Onboarding/` directory so permission support,
state transitions, window lifecycle, and SwiftUI presentation can be edited
independently without changing onboarding behavior.

## Constraints

- Keep every declaration in the existing `Gizmate` target.
- Do not change `Package.swift`, dependencies, deployment target, app identity,
  persistence keys, analytics values, permission URLs, feature copy, media
  URLs, timing, callbacks, window geometry, constraints, or lifecycle order.
- Preserve declaration bodies, comments, and actor annotations.
- Do not split stateful types across extensions or files.
- Do not redesign onboarding or exercise live TCC permission mutations during
  this source-only refactor.

## Existing Responsibilities

The current file contains four distinct layers:

1. Permission/data support:
   `PermissionKind`, `FullDiskAccessProbe`, `FeatureTourStep`, and
   `OnboardingIntroVideo`.
2. `OnboardingModel`, which owns modes, pages, persisted completion state,
   permission checks, routing, and display strings.
3. `OnboardingWindowController`, which owns AppKit window construction,
   resizing, presentation, callbacks, and close semantics.
4. A private SwiftUI/AppKit view cluster rooted at `OnboardingRootView`.

## Target Structure

Create `Sources/Gizmate/App/Onboarding/` with:

- `OnboardingSupport.swift`
  - `PermissionKind`
  - `FullDiskAccessProbe`
  - `FeatureTourStep`
  - `OnboardingIntroVideo`
- `OnboardingModel.swift`
  - `OnboardingModel`
- `OnboardingWindowController.swift`
  - `OnboardingWindowController`
- `OnboardingViews.swift`
  - `OnboardingRootView`
  - all existing private onboarding palettes, cards, previews, and media views

Delete `Onboarding.swift` after every declaration has moved. SwiftPM
recursively discovers the directory, so the package manifest remains
unchanged.

## Deliberate Visibility Change

`OnboardingRootView` is currently a private top-level type constructed by
`OnboardingWindowController`. Moving those responsibilities to separate files
requires that one root type to become module-internal.

Change only:

```swift
private struct OnboardingRootView: View
```

to:

```swift
struct OnboardingRootView: View
```

This is the smallest maintainable boundary: the window controller depends on
the root view as a collaborator, while every leaf view and palette remains
private inside `OnboardingViews.swift`. There is no public API or runtime
behavior change.

Keeping every private view together leaves `OnboardingViews.swift` around 915
lines. That is an intentional exception to the roughly-400-line guideline;
splitting it further would widen many private declarations for little editing
benefit. `OnboardingModel.swift` is expected to sit only a few lines over 400
after adding its imports and remains one coherent state machine.

## Imports

- Support: `Foundation`.
- Model: `AppKit`, `Combine`, `Foundation`.
- Window controller: `AppKit`, `SwiftUI`.
- Views: `AppKit`, `AVKit`, `Combine`, `SwiftUI`.

## Behavior Invariants

- Preserve `PermissionKind.analyticsValue`.
- Preserve the KakaoTalk/TCC Full Disk Access probe and detached utility task.
- Preserve feature order, copy, shortcuts, bundled-resource preference, and
  CloudFront fallbacks.
- Preserve modes, page ordering, completion keys, intro key, main-window key,
  dev override, permission ordering, optional Full Disk Access semantics, and
  asynchronous probe coalescing.
- Preserve Accessibility, Screen Recording, and Full Disk Access URLs; the
  one-time screen-capture flag; the 0.2-second request delay; close-before-
  system-dialog behavior; and every completion callback.
- Preserve all stage/title/subtitle/button strings.
- Preserve intro, standard, and feature window sizes, window level/behavior,
  liquid-glass hosting, resize centering, activation, and close routing.
- Preserve the one-second permission poll, all SwiftUI layout, colors, media
  playback/looping, constraints, actions, and animations.
- Preserve both declaration-level `@MainActor` annotations and every nested
  actor hop.

## Verification

After each extraction:

- compare moved blocks against the parent commit;
- run `swift build`;
- run `swift test --filter OnboardingFlowTests`;
- run `swift test --filter FullDiskAccessProbeTests`;
- run `git diff --check`;
- inspect the scoped diff.

At the end:

- run full `swift test`;
- confirm `Onboarding.swift` is absent;
- confirm each original declaration exists exactly once;
- audit actor annotations and access levels, allowing only the documented root
  view change;
- confirm `OnboardingViews.swift` is the only file materially above roughly
  400 lines and the state model remains only a few lines over;
- update the README source map;
- request an independent read-only review.
