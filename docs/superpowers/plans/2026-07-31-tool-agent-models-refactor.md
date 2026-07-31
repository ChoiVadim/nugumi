# Tool Agent Models Refactor Plan

**Status:** Implemented and verified. Checkboxes below preserve the original
pre-implementation contract; they are not a live progress tracker.

**Goal:** Split public protocol foundations and request/fingerprint contracts
out of `ToolAgentModels.swift` without changing wire behavior or access.

**Architecture:** Move complete top-level declarations byte-identically into
two sibling files in the same target. Keep the file-coupled candidate models
together.

**Design:**
`docs/superpowers/specs/2026-07-31-tool-agent-models-refactor-design.md`

Commit this design and plan before implementation with
`Plan tool agent model split`.

---

### Task 1: Extract Protocol Types

**Files:**

- Create: `Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift`
- Modify: `Sources/GizmateToolAgentCore/ToolAgentModels.swift`

**Move unchanged:** original lines 4–186, from
`ToolAgentProtocolLimitsV1` through `ToolAgentCandidateTriggerV1`.

**Imports:** `Foundation`.

- [ ] Preserve every declaration, comment, nested private CodingKeys, raw
      value, conformance, initializer, and validation body byte-identically.
- [ ] Remove only the moved block and its separator.
- [ ] Keep original imports and candidate models unchanged in this task.
- [ ] Run build, protocol and supervisor tests, full tests, exact-motion,
      residual, imports, access, public API, uniqueness, scope, and diff checks.
- [ ] Commit with `Split tool agent protocol types`.

---

### Task 2: Extract Contracts and Fingerprinting

**Files:**

- Create: `Sources/GizmateToolAgentCore/ToolAgentContracts.swift`
- Modify: `Sources/GizmateToolAgentCore/ToolAgentModels.swift`

**Move unchanged:** original lines 922–994, from
`ToolAgentRequestContractV1` through `ToolAgentWriteCandidateRequestV1`.

**Imports:** `CryptoKit`, `Foundation`.

- [ ] Move the complete declarations byte-identically.
- [ ] Remove the moved block, its leading separator, and the now-unused
      `CryptoKit` import from `ToolAgentModels.swift`.
- [ ] Confirm SHA-256, canonical JSON, request validation, and payload behavior
      remain unchanged.
- [ ] Confirm the candidate/installed-tool core is otherwise byte-identical.
- [ ] Run build, protocol and supervisor tests, full tests, exact-motion,
      residual, imports, access, public API, uniqueness, scope, and diff checks.
- [ ] Commit with `Split tool agent contracts`.

---

### Task 3: Final Verification and Review

- [ ] Confirm the production range changes exactly the three model files.
- [ ] Confirm no tests, packages, resources, dependencies, or schemas changed.
- [ ] Confirm all public declarations/conformances remain unique.
- [ ] Confirm candidate and installed-tool models plus `fileprivate
      needsTarget` remain byte-identical and co-located.
- [ ] Record the primary-file reduction from 994 to 735 lines.
- [ ] Run build, both focused suites, full tests, and diff checks.
- [ ] Request an independent broad, read-only review.
