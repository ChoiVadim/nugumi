# Radial Menu Layout Refactor Plan

**Goal:** Extract the pure radial-menu geometry policy from the stateful
controller without changing behavior or access.

**Architecture:** Move one complete top-level declaration into a sibling
source file. Leave controller state and behavior untouched.

**Design:**
`docs/superpowers/specs/2026-07-31-radial-menu-layout-refactor-design.md`

Commit this design and plan before implementation with
`Plan radial menu layout split`.

---

### Task 1: Extract Layout Policy

**Files:**

- Create: `Sources/Gizmate/Ring/RadialMenuLayoutPolicy.swift`
- Modify: `Sources/Gizmate/Ring/RadialMenuController.swift`

**Move unchanged:** complete `RadialMenuLayoutPolicy` declaration.

**Imports:** `AppKit`, `Foundation`.

- [ ] Preserve every constant, derived property, geometry function, comment,
      and access level byte-identically.
- [ ] Remove only the declaration and its separator from the controller file.
- [ ] Keep controller imports, state, behavior, and private panel unchanged.
- [ ] Run build; focused layout, folder, and drag tests; full tests; exact
      motion, residual, import, access, uniqueness, scope, and diff checks.
- [ ] Commit with `Split radial menu layout policy`.

---

### Task 2: Final Verification and Review

- [ ] Confirm the production range changes exactly the two Ring source files.
- [ ] Confirm no test, package, resource, dependency, or controller behavior
      changed.
- [ ] Record controller line reduction from 788 to 605.
- [ ] Run `swift build`, the three focused suites, full `swift test`, and
      `git diff --check`.
- [ ] Request an independent broad, read-only review.
