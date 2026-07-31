# Tool Agent Live Builder Refactor Plan

**Goal:** Split independent Tool Agent support declarations out of
`ToolAgentLiveBuilder.swift` while leaving the stateful coordinator intact.

**Architecture:** Use straight top-level declaration motion into sibling
files under `Sources/Gizmate/App/`. Preserve bodies, access, actor isolation,
and source-directory depth. No coordinator method moves or access widening.

**Design:** `docs/superpowers/specs/2026-07-31-tool-agent-live-builder-refactor-design.md`

Commit this design and plan before implementation with
`Plan tool agent builder split`.

---

### Task 1: Characterize Runtime Discovery

**Files:**

- Create: `Tests/GizmateTests/ToolAgentRuntimeLocationTests.swift`
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`

**Intentional source change:** add an internal injectable `sourceRoot`
argument to `ToolAgentRuntimeLocation.resolve`. Its default must be the exact
current four-parent `#filePath` expression, so production callers and behavior
remain unchanged.

- [ ] Test packaged runtime precedence over all development candidates.
- [ ] Test that an incomplete real `.app` never uses development fallback.
- [ ] Test current-directory candidates before source-root candidates.
- [ ] Test source `ToolAgent/dist` before staged `.build/dist` for both roots.
- [ ] Test default `agent.mjs` and a custom entry.
- [ ] Test executable-node and readable-agent requirements.
- [ ] Enumerate the four development candidates explicitly in assertions.
- [ ] Run the new focused class, existing three focused classes, full tests,
      scope, and diff checks.
- [ ] Commit with `Characterize tool agent runtime resolution`.

---

### Task 2: Extract Runtime Discovery

**Files:**

- Create: `Sources/Gizmate/App/ToolAgentRuntimeLocation.swift`
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`

**Move unchanged:** complete `ToolAgentRuntimeLocation`, including the new
tested `sourceRoot` seam.

**Imports:** `Foundation`.

- [ ] Preserve packaged/development lookup order and `.app` guard.
- [ ] Preserve the exact four-candidate development order tested in Task 1.
- [ ] Keep the new file at the same directory depth so `#filePath` behavior is
      unchanged.
- [ ] Remove only the moved declarations from the original.
- [ ] Confirm `ToolAgentLiveBuilderError` remains beside the coordinator.
- [ ] Run build, the runtime test class, all three existing focused classes,
      full tests, exact-motion, scope, uniqueness, and diff checks.
- [ ] Commit with `Split tool agent runtime support`.

---

### Task 3: Extract Fixture History

**Files:**

- Create: `Sources/Gizmate/App/ToolAgentFixtureHistory.swift`
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`

**Move unchanged:** complete `ToolAgentFixtureHistory` actor and its
documentation.

**Imports:** `Foundation`, `GizmateToolAgentCore`.

- [ ] Preserve actor isolation and private stored state.
- [ ] Preserve ever-offered-fixture state transitions, failure report, copy,
      fingerprint, and failure code.
- [ ] Remove only the moved declaration from the original.
- [ ] Run build, the runtime class, all three existing focused classes, full
      tests, exact-motion, scope, uniqueness, and diff checks.
- [ ] Commit with `Split tool agent fixture history`.

---

### Task 4: Extract Host Candidate Validation

**Files:**

- Create: `Sources/Gizmate/App/ToolAgentHostCandidateValidator.swift`
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`

**Move unchanged:** complete `ToolAgentHostCandidateValidator`.

**Imports:** `AppKit`, `Foundation`, `GizmateToolAgentCore`.

- [ ] Preserve `@MainActor` on installed-app lookup.
- [ ] Preserve candidate-kind routing, URL-template rules, app discovery,
      report contents, and passing fingerprints.
- [ ] Remove only the moved declaration from the original.
- [ ] Remove `AppKit` from the original only after proving no remaining AppKit
      identifier use.
- [ ] Run build, the runtime class, all three existing focused classes, full
      tests, exact-motion, scope, uniqueness, actor, import, and diff checks.
- [ ] Commit with `Split tool agent host validation`.

---

### Task 5: Extract Model Action Validation

**Files:**

- Create: `Sources/Gizmate/App/ToolAgentModelActionValidation.swift`
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`

**Move unchanged:**

- `ToolAgentModelActionValidator`
- `ToolAgentModelActionInspector`

**Imports:** `Foundation`, `GizmateToolAgentCore`.

- [ ] Preserve strict JSON parsing, single-fence normalization, exact key
      sets, UUID and fingerprint checks, Codable round-trip validation, and
      `UNSUPPORTED:` inspection.
- [ ] Preserve all private validator helpers and access levels.
- [ ] Remove only the moved declarations from the original.
- [ ] Confirm private `ToolAgentModelFailure` remains beside the coordinator.
- [ ] Run build, the runtime class, all three existing focused classes, full
      tests, exact-motion, scope, uniqueness, and diff checks.
- [ ] Commit with `Split tool agent model validation`.

---

### Task 6: Final Verification and Review

- [ ] Run full `swift test` and record executed, skipped, and failure counts.
- [ ] Run `git diff --check`.
- [ ] Audit the full tranche and confirm production scope is limited to:
  - `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`
  - `Sources/Gizmate/App/ToolAgentRuntimeLocation.swift`
  - `Sources/Gizmate/App/ToolAgentFixtureHistory.swift`
  - `Sources/Gizmate/App/ToolAgentHostCandidateValidator.swift`
  - `Sources/Gizmate/App/ToolAgentModelActionValidation.swift`
- [ ] Confirm the only test change is
      `Tests/GizmateTests/ToolAgentRuntimeLocationTests.swift`.
- [ ] Compare all eight original top-level declarations against an explicit
      declaration-to-file/access/isolation manifest.
- [ ] Confirm exactly two actors and five `@MainActor` markers before and
      after.
- [ ] Confirm `ToolAgentModelFailure` remains private and the coordinator body
      is byte-identical.
- [ ] Confirm runtime `#filePath` directory depth and search order are
      unchanged.
- [ ] Run `wc -l` and confirm the coordinator file is materially smaller.
- [ ] Add a README source-map row for the Tool Agent builder/runtime files.
- [ ] Commit the README update with `Refresh tool agent builder source map`.
- [ ] Request an independent broad, read-only review.
