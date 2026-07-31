# Tool Agent Models Refactor Design

**Date:** 2026-07-31

## Goal

Reduce the edit surface of the 994-line public wire-model file
`Sources/GizmateToolAgentCore/ToolAgentModels.swift` by separating protocol
foundations and request/fingerprint contracts from the two large candidate
models.

## Target layout

| File | Ownership |
| --- | --- |
| `ToolAgentProtocolTypes.swift` | limits, failure/build/assurance enums, fixtures, ask-user payloads, candidate surface enums |
| `ToolAgentModels.swift` | native action plus candidate and installed-tool Codable models |
| `ToolAgentContracts.swift` | request validation, canonical JSON, fingerprints, write-candidate payload |

The final `ToolAgentModels.swift` remains the coherent candidate-model core and
drops from 994 to 735 lines.

## Access and compatibility

- Preserve every public declaration, initializer, conformance, raw value,
  CodingKey, validation branch, and encoded shape byte-identically.
- Preserve nested private CodingKeys and fingerprint input.
- Keep `ToolAgentNativeActionV1`, `ToolAgentCandidateV1`, and
  `ToolAgentInstalledToolV1` in one file. Their validation shares the
  `fileprivate needsTarget` helper.
- Do not widen `fileprivate` or `private` access.
- Keep all declarations in the same SwiftPM target, so module-internal helpers
  such as `ToolAgentDynamicCodingKeyV1` and fingerprint validity remain
  available.

## Imports

- `ToolAgentProtocolTypes.swift`: `Foundation`.
- `ToolAgentModels.swift`: `Foundation` after the fingerprint block moves.
- `ToolAgentContracts.swift`: `CryptoKit`, `Foundation`.

Import removal from `ToolAgentModels.swift` is limited to `CryptoKit`, whose
only consumer is the moved SHA-256 fingerprint implementation.

## Behavior invariants

- Preserve every protocol size limit and failure/build state.
- Preserve strict ask-user unknown-key and UTF-8 validation.
- Preserve every candidate enum raw value and Codable conformance.
- Preserve create/edit/fix request-contract validation.
- Preserve canonical JSON options and SHA-256 fingerprint binding.
- Preserve the write-candidate request payload.
- Leave candidate and installed-tool decoding, encoding, and validation
  byte-identical.

## Verification

Each extraction receives:

- exact moved-block and original-residual comparison;
- import, access, declaration uniqueness, public API, and scope audit;
- `swift build`;
- focused `ToolAgentProtocolTests` and `ToolBuildSupervisorTests`;
- full `swift test`;
- `git diff --check`;
- independent read-only review.

The final audit verifies the exact three-file production scope, no test or
package changes, stable public declaration/conformance counts, and the
994-to-735 line reduction.

## Deliberate deferrals

- Do not split the candidate and installed-tool models across files.
- Do not deduplicate their validators; persisted and candidate shapes enforce
  different contracts.
- Do not rename schemas, keys, payloads, or public types.
- Do not move declarations into existing message files in this tranche.
