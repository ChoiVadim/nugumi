# Ask Gizmate Refactor Plan

**Status:** Implemented and verified. Checkboxes below preserve the original
pre-implementation contract; they are not a live progress tracker.

**Goal:** Split the mixed Ask Gizmate domain file into response,
conversation, and layout ownership without changing behavior or access.

**Architecture:** Move three complete top-level declaration clusters into
sibling files, then delete the empty original.

**Design:**
`docs/superpowers/specs/2026-07-31-ask-gizmate-refactor-design.md`

Commit this design and plan before implementation with
`Plan Ask Gizmate source split`.

---

### Task 1: Split Ask Gizmate Domain Types

**Create:**

- `Sources/Gizmate/Ask/AskGizmateResponse.swift`
- `Sources/Gizmate/Ask/AskGizmateConversation.swift`
- `Sources/Gizmate/Ask/AskGizmateLayout.swift`

**Delete:** `Sources/Gizmate/Ask/AskGizmate.swift`

**Move unchanged:**

- original lines 4–245 to response;
- original lines 247–351 to conversation;
- original lines 353–616 to layout.

- [ ] Use imports exactly as defined by the design.
- [ ] Preserve every declaration, comment, string, constant, function body,
      conformance, and access level byte-identically.
- [ ] Preserve nested private helpers with their owning cluster.
- [ ] Confirm the original contains no remaining declaration before deletion.
- [ ] Run build, both focused suites, full tests, exact-motion, import, access,
      nested-private, uniqueness, scope, line-count, and diff checks.
- [ ] Commit with `Split Ask Gizmate domain types`.

---

### Task 2: Final Verification and Review

- [ ] Confirm the production range is exactly three additions and one deletion.
- [ ] Confirm no tests, packages, resources, dependencies, strings, keys, or
      behavior changed.
- [ ] Confirm expected line counts: response 245, conversation 107, layout 267.
- [ ] Update the README Ask source-map row to replace `AskGizmate.swift` with
      `AskGizmateResponse.swift`, `AskGizmateConversation.swift`, and
      `AskGizmateLayout.swift`.
- [ ] Commit the README-only update with `Refresh Ask Gizmate source map`.
- [ ] Re-run build, both focused suites, full tests, and diff checks.
- [ ] Request an independent broad, read-only review.
