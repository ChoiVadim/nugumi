# Pi Tool Agent Developer Preview Implementation Plan

> Execute with red-green tests and one implementation task at a time. Preserve
> the existing dirty tool-builder worktree; never stage unrelated files.

**Goal:** A user description enters a real Pi `AgentSession`, a bad Python
candidate is tested inside the packaged XPC sandbox, Pi receives the structured
failure and repairs it, and Nugumi returns only the passing candidate.

**Baseline:** `035fd57604cb5d88f03c0bc18a8d6c5ce7f0bd16` plus the user's current
uncommitted Tool Builder work.

**Runtime pins:** `@earendil-works/pi-coding-agent@0.82.1`,
Node.js `22.19.0`, Python `3.12.11`, protocol version `1`.

---

## Task 0: Preserve the adopted dirty baseline

**Files**

- Create: `.superpowers/sdd/2026-07-27-pi-tool-agent-preview/baseline.json`

Before implementation, record:

- exact HEAD;
- SHA-256 of the staged diff excluding this plan/spec;
- SHA-256 of the unstaged diff;
- SHA-256 of the sorted `path + file SHA-256` inventory for all untracked files,
  plus individual hashes for every adopted source file;
- the explicit adopted baseline files:
  `ToolGenerator.swift`, `ToolEditor.swift`, `NugumiApp+ScriptTools.swift`, and
  the modified `LLMCore.swift`.

Patch these files in place. Do not reset, stash, or replace them. Before every
task commit, compare the live worktree against the baseline and stage only that
task's owned files.

## Task 1: Versioned candidate and agent protocol

**Files**

- Modify: `Sources/NugumiToolIPC/ToolWorkerProtocol.swift`
- Create: `Sources/NugumiToolAgentCore/ToolAgentProtocol.swift`
- Create: `Sources/NugumiToolAgentCore/ToolAgentModels.swift`
- Modify: `Package.swift`
- Create: `Tests/NugumiToolAgentCoreTests/ToolAgentProtocolTests.swift`

**Red**

Add focused tests proving:

- every JSONL message round-trips with protocol version `1`;
- unknown versions and lines larger than 1 MiB are rejected;
- candidate source, fixture input, fixture output, fixture count, and repairs are
  bounded;
- a worst-case escaped valid candidate stays below the 1 MiB frame limit;
- `ModelActionV1` strictly parses one tool call or final text and rejects
  fenced/extra/malformed output;
- fingerprint changes for source, fixture, manifest, runtime, or policy changes;
- safe event metadata cannot encode source, fixture text, stdout, stderr, or
  host paths.

Run:

```bash
swift test --filter ToolAgentProtocolTests
```

The first run must fail because the module/types do not exist.

**Green**

Implement the smallest Codable models, canonical sorted-key encoder,
SHA-256 fingerprint, stable state/failure enums, model-action types, and
boundary validation. Include host-assigned candidate IDs and the exact
`write -> validate -> finish` attestation contract.

Run the focused test again and commit only Task 1 files.

## Task 2: Generic sandboxed candidate execution

**Files**

- Modify: `Sources/NugumiToolIPC/ToolWorkerProtocol.swift`
- Modify: `Sources/NugumiToolWorker/ToolWorkerService.swift`
- Create: `Sources/NugumiToolWorkerCore/CandidateValidator.swift`
- Modify: `Sources/Nugumi/Tools/ToolWorkerClient.swift`
- Create: `Tests/NugumiToolWorkerCoreTests/CandidateValidatorTests.swift`
- Modify: `Tests/NugumiToolIPCTests/ToolWorkerProtocolTests.swift`

**Red**

Add tests for a valid uppercase script and for:

- syntax error;
- non-zero exit;
- exact-output mismatch;
- timeout/process-group cleanup;
- stdout/stderr caps;
- source/input/output size rejection;
- strict UTF-8 rejection plus CRLF/single-terminal-LF comparison;
- concurrent duplicate run ID and cancellation;
- sanitized report with no workspace or host path.

The executable contract is:

```text
python3.12 -I -S main.py <one UTF-8 text argument>
```

The worker adds only the packaged stdlib/site-packages paths it owns and a
synthetic HOME/TMPDIR. It never receives a host path from the helper.

Run:

```bash
swift test --filter CandidateValidatorTests
swift test --filter ToolWorkerProtocolTests
```

**Green**

Add `runCandidate`/`cancelCandidate` beside the existing probe RPC. The reply
contains candidate ID/fingerprint, fixture index, stable kind, exit/signal,
bounded redacted output/stderr detail, truncation flags, duration, and passing
fingerprint. Reuse `BoundedProcess` and its cancellation coordinator; do not
repurpose or weaken the feasibility probe.

Run focused tests, the full Swift suite, and strict worker build. Commit only
Task 2 files.

## Task 3: Real Pi sidecar with a deterministic provider

**Files**

- Create: `ToolAgent/package.json`
- Create: `ToolAgent/pnpm-lock.yaml`
- Create: `ToolAgent/tsconfig.json`
- Create: `ToolAgent/src/protocol.ts`
- Create: `ToolAgent/src/model-bridge.ts`
- Create: `ToolAgent/src/session.ts`
- Create: `ToolAgent/src/live-provider.ts`
- Create: `ToolAgent/src/faux-provider.ts`
- Create: `ToolAgent/src/agent.mts`
- Create: `ToolAgent/src/gate.mts`
- Create: `ToolAgent/test/session.test.ts`

**Red**

Add Node tests that launch the JSONL process and prove:

- a real Pi `AgentSession` is created with all built-ins disabled;
- only the four named sequential tools exist;
- the fake provider creates a wrong candidate, receives `wrongOutput`, repairs,
  validates, and finishes;
- the live bridge serializes the complete bounded Pi Context and the repaired
  turn contains the prior `wrongOutput`;
- model/tool requests require matching IDs;
- malformed `ModelActionV1` never becomes a Pi message/tool call;
- cancellation and budget exhaustion produce one terminal event;
- oversize/unknown JSONL input fails closed;
- no credential-shaped environment value appears in output.

Run:

```bash
npx --yes pnpm@11.17.0 --dir ToolAgent install --frozen-lockfile
npx --yes pnpm@11.17.0 --dir ToolAgent test
```

The first test must fail before the implementation exists.

**Green**

Use `createAgentSession`, `SessionManager.inMemory()`,
`SettingsManager.inMemory()`, an isolated `ResourceLoader`, and a registered
inline provider. Use `InMemoryCredentialStore`; never read process credentials.

`src/agent.mts` imports only `live-provider.ts`, emits `modelRequest` to Swift,
and awaits a matching `modelResponse`. It parses exactly one `ModelActionV1` and
converts it to a Pi assistant tool call. `src/gate.mts` imports only
`faux-provider.ts` and never emits a model request. TypeScript emits the fixed
artifacts `dist/agent.mjs` and `dist/gate.mjs`; a dependency-graph test rejects
any faux import reachable from `agent.mjs`. There is no runtime mode switch in
the JSONL payload.

Run the pinned pnpm test and typecheck scripts. Commit only `ToolAgent`.

## Task 4: Swift process client, supervisor, persistence, and LLM bridge

**Files**

- Create: `Sources/NugumiToolAgentCore/JSONLProcess.swift`
- Create: `Sources/NugumiToolAgentCore/ToolBuildStore.swift`
- Create: `Sources/NugumiToolAgentCore/ToolBuildSupervisor.swift`
- Create: `Tests/NugumiToolAgentCoreTests/ToolBuildSupervisorTests.swift`
- Modify: `Package.swift`

**Red**

Use fake process/model/worker seams to prove the exact state path:

```text
created -> understanding -> writing -> testing -> diagnosing -> repairing
-> writing -> testing -> verifying -> candidateReady
```

Also prove immutable attempts, persisted counters, fingerprint agreement,
single active run, max three repairs, eight turns, 32 calls, ten-minute timeout,
cancellation cleanup, first-terminal-wins races, accepted-request charge
points, `finish_candidate` attestation checks, and no candidate on terminal
failure.

**Green**

Implement an actor-owned supervisor. It launches the sidecar, services
`modelRequest` via an injected closure, services `run_validation` via the XPC
client, persists before external work, and kills the full sidecar process group
on cancellation or protocol failure.

Run focused tests and commit only Task 4 files.

## Task 5: Package the pinned helper and add a deterministic app gate

**Files**

- Create: `Scripts/prepare-tool-agent-runtime.sh`
- Create: `Scripts/test-pi-tool-agent-gate.sh`
- Modify: `Scripts/build-app-bundle.sh`
- Modify: `Sources/Nugumi/App/NugumiApp.swift`
- Create: `Sources/Nugumi/App/ToolAgentGateMode.swift`
- Create: `Tests/NugumiTests/ToolAgentGateModeTests.swift`

**Red**

Add a CLI-mode test showing `--pi-tool-agent-gate --report <path>` routes before
normal app startup. The shell gate must initially fail because the helper is not
embedded.

**Green**

Download/cache exact Node `22.19.0` arm64 using Node's signed checksum file,
copy `dist/agent.mjs`, `dist/gate.mjs`, and production dependencies from the
committed `pnpm-lock.yaml`, then embed them under:

```text
Nugumi.app/Contents/Helpers/ToolAgent/
```

Sign nested Mach-O files deepest-first, then the helper directory, XPC, and app.
The normal editor process launches:

```text
Contents/Helpers/ToolAgent/node dist/agent.mjs
```

The CLI gate launches:

```text
Contents/Helpers/ToolAgent/node dist/gate.mjs
```

The CLI gate runs the fixed uppercase request through the real Pi session and
packaged XPC worker.

Assert:

- exactly two immutable attempts;
- first report is `wrongOutput`;
- second report passes;
- final state is `candidateReady`;
- fingerprint matches;
- budget counters are within limits;
- schema exposes no secrets or paths;
- gate uses only `gate.mjs` and makes zero `modelRequest` calls;
- no Node, worker, or Python process survives;
- Tools storage and Ring defaults are byte-identical before/after;
- deep strict code-sign verification passes.

## Task 6: Replace one-shot generation in the editor

**Files**

- Modify: `Sources/Nugumi/App/NugumiApp+ScriptTools.swift`
- Modify: `Sources/Nugumi/MainWindow/ToolEditor.swift`
- Create: `Sources/Nugumi/App/NugumiApp+ToolAgent.swift`
- Create: `Tests/NugumiTests/ToolAgentEditorBridgeTests.swift`

**Red**

Add bridge tests showing:

- Generate uses the agent supervisor rather than `ToolGenerator.generate`;
- status updates are Writing, Testing, and Repairing without raw model output;
- only `candidateReady` converts to `GeneratedTool`;
- the exact passing fingerprint enables Save and the attested manifest/source
  remain read-only until that exact candidate is saved or discarded;
- failure preserves the description and existing draft;
- save/approval/Ring behavior is unchanged.

**Green**

Connect the supervisor to `currentBackend.complete(...)`, the packaged helper,
and `ToolWorkerClient`. Convert the passing offline-text candidate to an
existing `.python` `NugumiTool` with fixed clipboard-text input, clipboard
output, always trigger, ten-second timeout, no network, and no output directory.
Keep revise and legacy manual repair unchanged for this preview.

Run focused tests, `swift test`, `swift build`, and package the app.

## Final Verification

1. Run the pinned pnpm test and typecheck scripts under `ToolAgent`.
2. Run `swift test` and `swift build`.
3. Run `Scripts/test-pi-tool-agent-gate.sh` twice.
4. Verify `codesign --verify --deep --strict`.
5. Launch packaged Nugumi.
6. In Create Tool, enter an offline text request such as "make copied text
   uppercase."
7. Observe Writing -> Testing; for the deterministic gate observe Repairing.
8. Confirm the editor receives a passing Python tool and no unverified candidate
   is saved or assigned to Ring.
9. Record x86_64, Developer ID, hard memory enforcement, network, dependencies,
   and user-file inputs as release blockers, not preview regressions.
