# Radial Menu Layout Refactor Design

**Date:** 2026-07-31

## Goal

Reduce the edit surface of the 788-line
`Sources/Gizmate/Ring/RadialMenuController.swift` by separating its pure,
unit-tested geometry policy from the stateful AppKit controller.

## Target layout

| File | Ownership |
| --- | --- |
| `RadialMenuLayoutPolicy.swift` | ring, orbit, label-bubble, and panel-frame geometry |
| `RadialMenuController.swift` | panel ownership, orbit state, hover behavior, animation, selection, and dismissal |

The complete `RadialMenuLayoutPolicy` declaration moves byte-identically.
`RadialActionMenuController` and private `RadialMenuPanel` remain in the
controller file.

## Access and behavior

- Preserve the policy's internal access and every member body.
- Preserve all radii, diameters, derived padding, slot order, angles, bubble
  limits, placement mapping, and unclamped panel anchoring.
- Keep `RadialMenuLabelPlacement` in its current owner.
- Do not widen controller-private state or split controller behavior.
- Do not relocate the shared `Array[safe:]` helper in this tranche.

## Imports

- `RadialMenuLayoutPolicy.swift`: `AppKit`, `Foundation`.
- Keep controller imports unchanged; import cleanup is outside this
  byte-motion tranche.

## Verification

- Exact moved-block and controller-residual comparison.
- Access, import, uniqueness, and two-file scope audit.
- `swift build`.
- Focused `RadialMenuLayoutTests`, `RingFolderTests`, and `RingDragTests`.
- Full `swift test`.
- `git diff --check`.
- Independent read-only review.

## Deliberate deferrals

- Do not split `RadialActionMenuController` through extensions; its private
  orbit, panel, animation, hover, and event-monitor state is tightly coupled.
- Do not move private `RadialMenuPanel` for a five-line reduction.
- Do not redesign geometry, animation, or edge behavior.
- Do not add manual Ring UI changes to this source-only refactor.
