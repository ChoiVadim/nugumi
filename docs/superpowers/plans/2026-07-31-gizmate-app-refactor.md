# Gizmate App Refactor Plan

**Status:** Implemented and verified. Checkboxes below preserve the original
pre-implementation contract; they are not a live progress tracker.

**Goal:** Split computed preferences and update delegates out of
`GizmateApp.swift` while preserving stored state and app lifecycle behavior.

**Architecture:** Move existing members into same-type sibling extensions.
No state-container redesign, access widening, or lifecycle extraction.

**Design:** `docs/superpowers/specs/2026-07-31-gizmate-app-refactor-design.md`

Commit this design and plan before implementation with
`Plan Gizmate app split`.

---

### Task 1: Extract Computed Preferences

**Files:**

- Create: `Sources/Gizmate/App/GizmateApp+Preferences.swift`
- Modify: `Sources/Gizmate/App/GizmateApp.swift`

**Move unchanged:** complete member block from `targetLanguage` through
private `defaultStyle(for:)`.

**Imports:** `Foundation`.

- [ ] Wrap the byte-identical member block in `extension GizmateApp`.
- [ ] Preserve every UserDefaults key, fallback, migration, setter, and helper.
- [ ] Preserve private legacy/default-style helpers.
- [ ] Confirm no stored instance or type property moves.
- [ ] Remove only the moved block from the original.
- [ ] Run build, `ModelRoutingTests` as a focused compilation smoke check,
      full tests, exact-motion, residual, access, actor, import, uniqueness,
      scope, and diff checks.
- [ ] Commit with `Split Gizmate app preferences`.

---

### Task 2: Extract Update Behavior

**Files:**

- Create: `Sources/Gizmate/App/GizmateApp+Updates.swift`
- Modify: `Sources/Gizmate/App/GizmateApp.swift`

**Move unchanged:**

- computed `isRunningFromAppBundle`;
- `GizmateApp: SPUUpdaterDelegate`;
- `GizmateApp: SPUStandardUserDriverDelegate`.

**Imports:** `Foundation`, `Sparkle`.

- [ ] Preserve app-bundle detection and appcast URL.
- [ ] Preserve both conformances, every `nonisolated` marker, gentle-reminder
      policy, return value, and `MainActor.assumeIsolated` hop.
- [ ] Remove only the three moved declaration blocks and separators.
- [ ] Confirm updater stored state and construction remain in the primary
      class.
- [ ] Run build, `ModelRoutingTests` as a focused compilation smoke check,
      full tests, exact-motion, residual, access, actor, import, uniqueness,
      scope, and diff checks.
- [ ] Commit with `Split Gizmate app update delegates`.

---

### Task 3: Final Verification and Review

- [ ] Run full `swift test` and record executed, skipped, and failure counts.
- [ ] Run `git diff --check`.
- [ ] Confirm production scope is limited to the three GizmateApp files.
- [ ] Confirm no test, package, resource, or dependency changes.
- [ ] Compare every moved member and both conformances for exact bodies,
      access, isolation, and uniqueness.
- [ ] Confirm no stored property moved and primary lifecycle blocks remain
      byte-identical.
- [ ] Run `wc -l` and record the primary-file reduction.
- [ ] Update the README app-lifecycle source map to
      `GizmateApp.swift` and `GizmateApp+*.swift`.
- [ ] Commit the README update with `Refresh Gizmate app source map`.
- [ ] Request an independent broad, read-only review.
