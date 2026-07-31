# Gizmate App Refactor Design

**Date:** 2026-07-31

## Goal

Reduce the edit surface of the 792-line
`Sources/Gizmate/App/GizmateApp.swift` by separating computed preferences and
Sparkle update behavior from stored app state and launch/lifecycle
orchestration.

## Target layout

| File | Ownership |
| --- | --- |
| `GizmateApp.swift` | `@main` app type, stored state, entrypoint, launch/bootstrap, app delegate lifecycle |
| `GizmateApp+Preferences.swift` | language, display, model, thinking, cleanup, style, privacy computed preferences |
| `GizmateApp+Updates.swift` | app-bundle detection and Sparkle delegate conformances |

The custom app-assignment block remains in `GizmateApp.swift`. It owns two
private stored type keys, and moving it through a cross-file extension would
require a source/access change. Stored app state also remains in the primary
type.

## Access and isolation

- Preserve all access levels.
- Preserve the type-level `@MainActor` isolation inherited by extensions.
- Keep preference migration helpers private beside their callers.
- Preserve every `nonisolated` Sparkle requirement.
- Preserve every `MainActor.assumeIsolated` update-state hop.
- Do not introduce stored properties in extensions.

## Behavior invariants

### Preferences

- Preserve every UserDefaults key and fallback.
- Preserve language migration and toggle pairing.
- Preserve model/thinking legacy fallback behavior.
- Preserve selection/floating display defaults.
- Preserve cleanup, Gen Z, voice sample, custom style, invisibility, and
  writing-style behavior.
- Preserve all property setters and helper dispatch by `ModelUseScope`.

### Updates

- Preserve app-bundle detection.
- Preserve the appcast URL.
- Preserve gentle scheduled-reminder behavior.
- Preserve update badge/state transitions and their main-actor hops.
- Preserve user-initiated update behavior by returning the same delegate
  values.

### Primary app

- Keep all stored state, updater construction, launch ordering, bootstrap,
  first-run handling, reopen, termination, and monitoring byte-identical.
- Do not move lifecycle blocks into extensions in this tranche.

## Imports

- `GizmateApp+Preferences.swift`: `Foundation`.
- `GizmateApp+Updates.swift`: `Foundation`, `Sparkle`.
- Keep primary-file imports unchanged; import cleanup is outside this
  source-motion tranche.

## Verification

Each move receives:

- `swift build`;
- `swift test --filter ModelRoutingTests` as a focused compilation smoke
  check; it does not directly exercise `GizmateApp` accessors or Sparkle;
- full `swift test`;
- `git diff --check`;
- exact moved-block and residual comparison;
- access, actor, import, uniqueness, and task-scope audit;
- independent read-only review.

The final audit verifies:

- every moved member exists exactly once;
- the primary class body is unchanged outside the removed blocks;
- no stored state moved;
- both Sparkle conformances and all `nonisolated` markers are preserved;
- primary file size is materially smaller;
- README source-map accuracy;
- a broad independent review.

## Deliberate deferrals

- Do not move custom app assignments or their private stored keys.
- Do not move launch, bootstrap, debug streaming, first-run, reopen, or
  termination behavior.
- Do not redesign UserDefaults access or add preference wrappers.
- Do not change Sparkle policy, appcast, update presentation, or badge state.
- Do not add live update/network verification to this source-only refactor.
