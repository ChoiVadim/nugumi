# Pi Tool Editing Design

Date: 2026-07-28

## Goal

Use the same bounded Pi agent for Create, Edit, and Fix. A user gives one
instruction; Pi receives the current tool when one exists, writes a complete
replacement candidate, asks Nugumi to validate it, repairs failures, and
returns only the exact attested candidate.

## Product Flow

```text
Edit: current tool + requested change
Fix:  current tool + exact failed-test report
  -> Pi agent
  -> complete prompt/native/Python candidate
  -> type-specific host validation
  -> Pi repair loop when validation fails
  -> attested draft
  -> user Save
```

The existing editor stays simple. `Apply change` and `Fix with Nugumi` show the
same short progress statuses as Create. Edit/Fix update the open draft rather
than auto-saving it.

## Request Contract

The existing free-text description remains bounded and is not used to smuggle
the current source into the prompt. The version-1 start payload gains:

- `operation`: `create`, `edit`, or `fix`;
- `description`: the create request or edit instruction;
- optional `currentTool`: the full installed manifest plus current Python
  source, with no invented fixtures;
- optional `failure`: the exact bounded failed-test report for Fix.

Create forbids `currentTool` and `failure`. Edit requires `currentTool` and
forbids `failure`. Fix requires both. Current source remains separately bounded
at 64 KiB, so editing a valid saved Python tool cannot fail only because the
instruction field is capped at 1 KiB.

Pi receives one JSON user message built from these fields. Its system prompt
requires preserving behavior the user did not ask to change, while still
allowing a kind change when the requested behavior is better represented by a
prompt or native macOS action.

## Identity and Storage

Pi returns a new candidate, but Edit/Fix restore the existing tool's `id` and
`createdAt` before applying it. This keeps the same Ring assignment.

Saving a non-Python result removes any stale `main.py`. Saving an agent-edited
Python draft revokes the previous script approval unless that exact current
script was explicitly run and passed from the editor.

## Validation and Safety

- prompt candidates receive structural host validation;
- native actions are checked without executing their side effects;
- Python candidates run through the same `uv` that runs a saved tool, and the
  report grades what that proved: `verified` (matched an exact fixture),
  `smoke` (ran cleanly, output not predictable), or `unverified` (not run,
  dependencies resolved and source compiled);
- Pi can finish only the candidate ID and fingerprint that just passed;
- the old one-shot `ToolGenerator.revise` and `ToolGenerator.repair` are no
  longer reachable from the editor.

## Proof

Focused tests cover request validation/round-trip, large Python edit context,
Pi seeing current tool and failure context, all-kind snapshot mapping, identity
preservation, full-candidate Fix application, stale-script removal, and
approval revocation. Completion also requires the full Swift suite, sidecar
suite, packaging gate, codesign validation, and one real packaged-app edit.
