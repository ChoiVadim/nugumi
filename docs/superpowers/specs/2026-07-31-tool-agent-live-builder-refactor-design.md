# Tool Agent Live Builder Refactor Design

**Date:** 2026-07-31

## Goal

Reduce the edit surface of the 830-line
`Sources/Gizmate/App/ToolAgentLiveBuilder.swift` without changing the
stateful build coordinator, its actor boundaries, or any runtime behavior.

## Current shape

The file currently mixes four independent support responsibilities with the
core live-builder coordinator:

1. user-facing builder errors and runtime discovery;
2. fixture-retreat history;
3. host-side candidate validation;
4. model-action validation and unsupported-result inspection;
5. the stateful `ToolAgentLiveBuilder` coordinator and its private
   first-failure actor.

The first four responsibilities are top-level declarations with clean
module-internal boundaries. The coordinator is tightly coupled and remains
in place.

## Target layout

All files stay at the same `Sources/Gizmate/App/` directory depth:

| File | Ownership |
| --- | --- |
| `ToolAgentRuntimeLocation.swift` | `ToolAgentRuntimeLocation` |
| `ToolAgentFixtureHistory.swift` | `ToolAgentFixtureHistory` |
| `ToolAgentHostCandidateValidator.swift` | `ToolAgentHostCandidateValidator` |
| `ToolAgentModelActionValidation.swift` | `ToolAgentModelActionValidator`, `ToolAgentModelActionInspector` |
| `ToolAgentLiveBuilder.swift` | `ToolAgentLiveBuilderError`, private `ToolAgentModelFailure`, `ToolAgentLiveBuilder` |

Keeping the runtime file at the same directory depth is a behavior
requirement. `ToolAgentRuntimeLocation.resolve` derives the source root from
`#filePath` using four parent deletions. Moving it into a nested directory
would silently change local `swift run` and XCTest fallback resolution.

## Access and isolation

- Preserve every existing access level.
- Add only one internal testability seam: an injectable `sourceRoot` argument
  on `ToolAgentRuntimeLocation.resolve`, with the current four-parent
  `#filePath` expression as its default.
- Preserve `ToolAgentFixtureHistory` as an actor.
- Preserve `ToolAgentModelFailure` as a private actor beside the coordinator.
- Preserve `@MainActor` on installed-app lookup and all builder entry points.
- Preserve the explicit `MainActor.run` inside the escaping validation
  handler.
- Do not introduce public API or cross-file private widening.

## Behavior invariants

### Runtime and errors

- Keep every localized error string and failure-code mapping unchanged.
- Keep packaged-app lookup before development fallback.
- Keep real `.app` bundles self-contained.
- Preserve this exact development candidate order:
  1. `currentDirectory/ToolAgent/dist/{entry}`;
  2. `currentDirectory/.build/tool-agent-runtime/arm64/dist/{entry}`;
  3. `sourceRoot/ToolAgent/dist/{entry}`;
  4. `sourceRoot/.build/tool-agent-runtime/arm64/dist/{entry}`.
- Preserve executable/readable checks and default entry name.
- Preserve `#filePath` directory depth and source-root calculation.
- Add focused tests for packaged precedence, `.app` fallback rejection,
  current-directory versus source-root order, source versus staged order,
  default/custom entries, and unusable node/agent files.

### Fixture history

- Preserve whether a fixture has ever been offered.
- Preserve retreat rejection only after an earlier offered fixture.
- Preserve report outcome, failure code, fingerprint, and diagnostic copy.

### Host validation

- Preserve prompt/native/python/agent routing.
- Preserve installed-app lookup by bundle ID, running-app name, and standard
  application roots.
- Preserve URL-template substitution and http/https restriction.
- Preserve all validation reports, copy, and passing fingerprints.

### Model action validation

- Preserve the single permitted JSON code-fence normalization.
- Preserve exact tool-call names, key sets, UUID checks, fingerprint regex,
  Codable round-trip validation, and unknown/extra-key rejection.
- Preserve `UNSUPPORTED:` final-text extraction and trimming.

### Core coordinator

- Keep supervisor construction, process wiring, validation dispatch,
  attestation recheck, error precedence, clarification handling, conversion
  helpers, and identity preservation byte-identical.
- Keep `ToolAgentModelFailure` private and co-located with the coordinator.
- Do not extract coordinator methods into cross-file extensions in this
  tranche.

## Imports

- `ToolAgentRuntimeLocation.swift`: `Foundation`.
- `ToolAgentFixtureHistory.swift`: `Foundation`,
  `GizmateToolAgentCore`.
- `ToolAgentHostCandidateValidator.swift`: `AppKit`, `Foundation`,
  `GizmateToolAgentCore`.
- `ToolAgentModelActionValidation.swift`: `Foundation`,
  `GizmateToolAgentCore`.
- Remaining `ToolAgentLiveBuilder.swift`: `Foundation`,
  `GizmateToolAgentCore`.

## Verification

Each extraction receives:

- `swift build`;
- `swift test --filter ToolAgentLiveBuilderTests`;
- `swift test --filter ToolAgentFixtureHistoryTests`;
- `swift test --filter ToolSecretsTests`;
- full `swift test`;
- `git diff --check`;
- exact moved-block and residual-file comparison;
- declaration uniqueness, access, actor, import, and task-scope audit;
- independent read-only review before the next extraction.

Before source motion, add
`Tests/GizmateTests/ToolAgentRuntimeLocationTests.swift` and the injectable
`sourceRoot` seam. Those tests must pass against the declaration while it is
still in the original file and again after it moves.

The final tranche audit also verifies:

- an explicit declaration manifest mapping all eight original declarations
  to destination, access, and isolation;
- exactly two actor declarations and five `@MainActor` markers before and
  after;
- old and new runtime search ordering;
- no production change outside the five Tool Agent builder files;
- README source-map accuracy;
- a broad independent review.

## Deliberate deferrals

- Do not split the private coordinator or model-format repair path.
- Do not change runtime search ordering.
- Do not move files into a nested directory.
- Do not widen the injectable runtime seam beyond module-internal access.
- Do not add actor annotations or modernize Swift concurrency.
- Do not clean up imports, diagnostics, or validation schemas beyond what
  file-scoped compilation requires.
- Do not add live model/network or installed-app behavior to this source-only
  refactor.
