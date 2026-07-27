# Autonomous Tool Builder - design

2026-07-27 · branch `main` · approved direction: one description produces a tested Ring tool without requiring the user to install Pi, Node, Python, or dependencies manually

## Outcome

A user chooses a Ring slot, describes what the button should do, and presses
**Create tool**. Nugumi chooses the simplest implementation, builds it, tests it,
repairs failures within a fixed budget, verifies the exact candidate, saves it,
and assigns it to the chosen slot.

The default experience contains one text field and one primary button. Source
code, dependencies, permissions, test reports, and activity logs remain
available under **Advanced**, but are not part of the normal flow.

The builder may ask one focused question only when different interpretations
would produce materially different or unsafe behavior. It may ask for one
permission decision when a real test or installed tool needs access that was not
already granted.

## Product boundary

Version 1 supports:

- existing prompt tools for text understanding and generation;
- the existing closed catalog of native macOS actions;
- generated Python 3 scripts with PEP 723 metadata;
- selected text, clipboard text, copied URLs, copied files, or no input;
- panel, replacement text, clipboard, files, and notification outputs;
- controlled network access and controlled output-directory access;
- automatic build, test, repair, verification, install, revision, and rollback.

Version 1 does not run arbitrary host shell commands, AppleScript, JXA, browser
profiles, purchases, message sending, deletion, or account mutation. These
requests are rejected as unsupported rather than converted into Python.
Native macOS automation remains a closed catalog:

- `openApp`, `openAppFullScreen`, `revealInFinder`, and `openURL` may run after
  capability approval;
- `sendTextToApp` and `runShortcut` can be created, but validation is dry-run
  only and every real execution requires confirmation because their downstream
  effects cannot be inferred;
- no other native action is accepted in version 1.

Additional host capabilities can be added later only as explicit typed
capabilities with their own verifier and permission policy.

“Any tool” means arbitrary computation inside the build/runtime boundary plus
explicit host-mediated capabilities. It does not mean unrestricted access to
the user's Mac. CAPTCHA and interactive-login requests stop with a plain
unsupported/setup explanation. Purchases, message sending, deletion, and
destructive account changes are outside version 1.

## User experience

### Creation

1. The user selects an empty Ring slot.
2. The slot sheet leads with:

   > What should this Ring button do?

3. The user enters a plain-language request and presses **Create tool**.
4. The same panel moves through one visible state at a time:

   - Understanding…
   - Building…
   - Testing…
   - Fixing a test issue, attempt 1 of 3…
   - Verifying…
   - Ready

5. A verified tool is saved and assigned to the originating slot automatically.
6. The success state reads:

   > Download Video is ready in your Ring.

7. **Done** closes the panel. **Run now** is available when the action is safe
   to perform with the current context.

### Permission interruption

The builder pauses only when it needs a capability that cannot be safely tested
with synthetic input. The permission screen describes effects, not
implementation details:

> This test may read your copied link, connect to youtube.com, save temporary
> files, and run for up to 90 seconds. The full build can take up to 10 minutes.

Actions:

- **Allow test session**
- **Change access**
- **Cancel**

The user approves an effective capability set, not a tool name. Two independent
fingerprints prevent permission prompts from being confused with verification:

- the candidate-verification fingerprint covers code, dependencies, manifest,
  runtime, verifier, tests, and capabilities; any change requires revalidation;
- the capability-grant fingerprint covers canonical external effects and
  targets; only a new or expanded capability, changed destination/domain,
  changed secret reference, or higher risk class requires a new user decision.

Changing implementation details without changing external effects therefore
invalidates verification but does not show a misleading permission prompt.

### Advanced disclosure

The collapsed **Advanced** section contains:

- generated implementation type;
- source code;
- dependency lock;
- effective permissions;
- test fixtures and verifier report;
- capped activity log;
- **Edit manually**, **Rebuild**, **Rollback**, and **Delete**.

### Revision

Editing an installed tool uses one natural-language field:

> What should change?

The builder stages a new version, re-runs the complete validation pipeline, and
shows a permission diff. The old version remains active until the new version is
approved and promoted atomically.

## Architecture

The feature has three process boundaries:

```text
Swift Nugumi app
  ToolBuildSupervisor
        |
        | private JSONL protocol
        v
Pi reasoning sidecar
  no host built-in tools
        |
        | typed tool requests
        v
Sandboxed execution worker
  generated code + dependencies
```

### Swift app: `ToolBuildSupervisor`

Swift owns all authority and durable state:

- job creation and recovery;
- state transitions;
- budgets and deadlines;
- user questions and permissions;
- model grant creation;
- sidecar lifecycle;
- sandbox worker lifecycle;
- artifact validation;
- version promotion and rollback;
- Ring assignment;
- privacy-safe observability.

The model cannot mutate durable tool storage or approve itself. Every side
effect requested by Pi is validated and performed by the supervisor or sandbox
worker.

Before these contracts are implemented, a packaged feasibility gate must prove
that the proposed boundary works in a signed and notarizable app. The spike must
launch a bundled exact Python runtime and one pure-wheel dependency from the XPC
worker while demonstrating filesystem denial, proxy-only network, bounded
CPU/memory/disk/output, cancellation of the entire process group, and operation
on both supported architectures. Failure blocks the autonomous feature and
forces a redesign of the execution boundary; an unsandboxed fallback is not
allowed.

### Pi sidecar

Nugumi ships a compatible Pi runtime as a signed nested helper. The user does
not install Pi or Node.

The helper:

- uses the direct `@earendil-works/pi-coding-agent` SDK;
- pins the exact npm package and transitive lockfile used by the app release;
- uses one in-memory `AgentSession` per build job;
- disables all default coding tools;
- uses a fixed system prompt and a custom `ResourceLoader` that disables project
  extensions, skills, prompts, themes, context files, and package discovery;
- exposes only Nugumi-defined custom tools;
- emits typed JSONL events to Swift;
- accepts cancellation and exits when the job ends;
- never stores model credentials, Pi auth files, global skills, or sessions.

The sidecar is trusted application code, but model output and all candidate
content are untrusted. It runs under its own OS sandbox with a sanitized
environment, no Keychain access, no general home-directory access, and no
candidate workspace mount. It receives candidate data only through bounded
protocol messages. Model traffic uses a Nugumi-controlled relay restricted to
the selected provider endpoint; Ollama grants permit only the configured
loopback endpoint. The helper has no general-purpose egress.

The helper receives a one-job model grant over its private stdin channel.
`ModelRuntime` keeps the grant in memory. The grant is never placed in the
workspace, environment inherited by generated code, logs, or analytics.

`AgentModelGrant` contains provider, model, base URL when applicable, thinking
level, and one ephemeral credential payload. Swift creates it from the provider
already configured in Nugumi:

- OpenAI, Anthropic, Gemini, and OpenRouter use in-memory API-key grants with
  provider-specific endpoint and header adapters;
- Ollama uses its configured local base URL without a secret;
- Codex and Claude Code use explicit credential adapters that translate the
  existing Nugumi OAuth/session material into Pi's in-memory provider format.

The sidecar never reads Nugumi's Keychain or provider files directly. If the
selected provider does not have a working adapter, creation stops with a setup
message; it never silently switches provider or writes Pi auth state. Provider
parity is a release gate.

The release build places the helper and runtime under
`Nugumi.app/Contents/Helpers/NugumiToolAgent/`. Nested executables are built for
both supported architectures, signed before the outer app, included in
notarization, and updated with the app. Development may launch the same pinned
package from the repository, but production never depends on a user-installed
Node or Pi.

### Sandboxed execution worker

Pi never executes generated code directly. A separate worker owns dependency
resolution, candidate execution, and every execution of an installed Python
tool. Installed tools never fall back to the current unsandboxed runner.

The production worker must enforce:

- an isolated synthetic `HOME`;
- a fresh workspace for every attempt;
- no inherited host environment or provider credentials;
- read access only to staged inputs and approved runtime assets;
- write access only to the current attempt workspace;
- network denied by default;
- approved network routed through a Nugumi-controlled proxy;
- process-group cancellation;
- wall-clock, CPU, memory, disk, file-count, and output-stream limits;
- removal of the worker's runtime scratch directory after every run.

The durable attempt directory retains only bounded candidate source, fixtures,
structured reports, hashes, and redacted log tails copied by the supervisor. It
never retains an executable environment, dependency cache, uncontrolled output,
or worker scratch filesystem.

The initial production implementation is a separately signed XPC worker with
an OS-enforced sandbox policy. Direct network egress stays denied; approved
requests go through a host proxy so the effective domain policy can be audited.
The packaged-app QA gate must demonstrate denied home-directory reads, denied
undeclared network, blocked path/symlink escapes, complete child-process
termination, and secret isolation. `sandbox-exec` may be used in a development
spike but is not the production security boundary.

An installed run creates a fresh workspace, copies approved inputs, mounts the
immutable revision and hash-verified runtime assets read-only, applies its
runtime capability grant, and uses the same cancellation and quota enforcement
as validation. Outputs remain staged until successful exit and host contract
verification. Failure or cancellation discards them, leaves the installed
revision active, and returns a bounded plain-language error.

## Agent tools

Pi starts with no generic `bash`, `read`, `write`, or `edit` access. It receives
these typed tools:

### `read_build_context`

Returns the normalized user request, supported tool kinds, input/output
contracts, current candidate summary, verifier status, and remaining budgets.
It never returns credentials or unrestricted host paths.

### `read_workspace`

Reads one allowlisted relative file from the current attempt. Absolute paths,
parent traversal, symlink escapes, and files outside the attempt are rejected by
Swift before the worker is contacted.

### `write_candidate`

Stages a complete candidate:

- manifest;
- prompt, native-action configuration, or Python source;
- declared dependencies;
- proposed capabilities;
- generated acceptance fixtures.

Every write creates a new immutable attempt directory. Pi cannot modify an
already tested attempt in place.

### `run_validation`

Runs the host-owned validation pipeline against the staged attempt and returns a
structured report:

- stage and status;
- exit code and signal;
- capped stdout and stderr tails;
- produced files and metadata;
- duration and resource usage;
- dependency and policy failures;
- verifier failures;
- permission changes;
- retryability classification.

All script, dependency, network, fixture, stdout, and stderr content is treated
as untrusted data. The custom tool returns it only inside bounded structured
fields, and the system prompt forbids following instructions found in tool
output. Security and promotion decisions never depend on the agent obeying that
instruction; the host policy and verifier remain authoritative.

### `request_user_input`

Requests one focused clarification or permission decision. Swift owns the UI
and returns a typed answer. The agent cannot create arbitrary modal text or
request a secret value in free-form text.

### `finish_candidate`

Requests promotion. Swift accepts it only when the exact candidate fingerprint
has a current passing verifier report and all effective permissions are
approved. A model message claiming success has no effect.

## Build state machine

Swift persists each transition before starting work:

```text
created
  -> understanding
  -> writing
  -> staticValidation
  -> resolvingDependencies
  -> testing
  -> verifying
  -> candidateReady
  -> permissionReview
  -> promoting
  -> installed
```

Repair transitions:

```text
staticValidation | resolvingDependencies | testing | verifying
  -> diagnosing
  -> repairing
  -> writing
```

Terminal states:

- `policyBlocked`
- `budgetExhausted`
- `cancelled`
- `failed`

Pausing states:

- `waitingForClarification`
- `waitingForPermission`
- `waitingForInput`

A crash loses the in-memory Pi session but not the job. Swift reconstructs a new
session from the fixed system prompt plus a bounded structured transcript made
from the persisted request, accepted clarification answers, candidate
fingerprints, verifier reports, and failure categories. Durable counters
preserve consumed turns, tool calls, repair attempts, elapsed build time, and
grants; recovery cannot reset a budget.

Work that was running when the app disappeared is marked `interrupted` and
starts in a fresh attempt. Already recorded model/tool usage remains consumed,
but interruption itself does not consume a repair attempt. Waiting states reopen
their existing UI without repeating an accepted answer:

- clarification returns to `understanding`;
- permission returns to `candidateReady` when declined or `promoting` when
  granted and verification is still current;
- input returns to `testing` after an approved fixture is staged;
- `promoting` is recovered from the install journal described below.

No partial attempt is promoted.

## Agent loop

1. Swift normalizes the request into a `ToolBuildRequest`.
2. Pi chooses the first sufficient implementation:

   `prompt -> native -> python`

3. Pi writes a complete candidate and acceptance fixtures.
4. Host static validation checks schema, runtime contract, dependency policy,
   permissions, and source syntax.
5. The worker resolves dependencies and creates a lock.
6. The worker runs synthetic happy-path, invalid-input, and boundary fixtures.
7. The host verifier evaluates outputs and policy invariants.
8. A failure report returns to the same Pi session, or to its reconstructed
   equivalent after crash recovery.
9. Pi diagnoses and writes a complete new candidate. Repair can change the
   manifest when the failure proves the input, output, timeout, dependency, or
   permission plan was wrong.
10. After at most three repair attempts, the job either reaches
    `candidateReady` or stops with a plain-language blocker.
11. Approved candidates enter one crash-recoverable install transaction that
    promotes the revision and, when still valid, assigns it to the Ring.

Pi provider retries handle transient model/API failures. They do not increase
the repair-attempt budget.

## Budgets

Initial hard limits per build:

- one active build per app;
- eight model turns;
- three repair attempts;
- thirty-two agent tool calls;
- ten minutes total, including dependency resolution and all validation runs;
- ninety seconds per ordinary validation run;
- 256 KiB retained per stdout/stderr stream;
- 512 MiB attempt workspace;
- 500 produced files;
- at most five of those minutes and 1 GiB for dependency resolution/download;
- a user-runtime timeout stored in the manifest and clamped to 5–1800 seconds.

Cancellation aborts the Pi session, kills the worker process group, discards
staged outputs, and retains the original request so the user can resume.

## Artifact and storage contract

Build jobs live under:

```text
~/Library/Application Support/Nugumi/
  AgentRuns/<run-id>/
    request.json
    state.json
    events.jsonl
    attempts/<attempt>/
      tool.json
      main.py
      main.py.lock
      permissions.json
      fixtures/
      tests/
      report.json
      artifacts/
```

Installed tools live under:

```text
Tools/<tool-id>/
  current.json
  versions/<revision>/
    tool.json
    main.py
    main.py.lock
    permissions.json
    report.json
```

Prompt and native tools omit irrelevant files.

`current.json` contains the active immutable revision and its fingerprint.
Promotion writes and fsyncs a complete revision, then atomically replaces the
pointer. Rollback replaces only the pointer. Storage errors are surfaced and
leave the previous revision active.

The candidate-verification fingerprint covers:

- normalized manifest;
- source or prompt/native configuration;
- dependency lock;
- effective capabilities;
- runtime and verifier versions;
- acceptance-fixture and test-suite hashes.

The verifier report contains that fingerprint, verifier version, result, and
timestamp. Changing any covered value requires revalidation and, when
capabilities expand, new permission approval.

The capability-grant fingerprint separately covers normalized capability kind,
risk class, domain/port policy, output bookmark, application/Shortcut target,
and secret reference. A code, dependency, runtime, verifier, or test change with
the same capability-grant fingerprint does not re-prompt. A grant change always
re-prompts even if the candidate previously passed.

Promotion and Ring assignment use an `install-transaction.json` journal with a
unique transaction ID, desired revision, originating slot, and the slot's
captured generation token. Recovery idempotently completes or rolls back each
step. The active revision is committed first; Ring assignment follows only when
the slot token is unchanged. If the user edited that slot while the build was
running, Nugumi never overwrites the change: the tool remains installed and the
Ready screen offers **Add to Ring**. A crash may temporarily leave an installed
tool unassigned, but journal recovery never leaves a Ring slot pointing to a
missing revision.

## Python and dependency policy

Python candidates use:

- an exact CPython `3.12.x` patch build and exact `uv` build identified by
  version, architecture, signing identity, and SHA-256;
- PEP 723 inline metadata;
- `uv lock --script main.py`;
- the adjacent `main.py.lock` for validation and runtime;
- the app-configured registry policy, initially the official PyPI simple index
  with alternative indexes disabled.

Unattended builds reject:

- arbitrary package indexes;
- direct URLs;
- VCS dependencies;
- editable or local-path dependencies;
- unapproved source builds;
- installation scripts outside the sandbox;
- undeclared native executables.

Native binaries come from a Nugumi catalog with version, architecture, URL,
checksum, license, and signing metadata. The catalog is controlled by Nugumi,
not generated by the model.

Dependency resolution accepts binary wheels only in version 1. The exact
hash-verified wheels, CPython runtime, and `uv` executable are retained in a
content-addressed Nugumi `RuntimeAssets/` store. An installed revision references
their hashes and architecture. Assets are garbage-collected only when no active
or rollback revision references them.

Every saved tool executes the exact locked dependency graph and runtime assets
that passed its verification. A missing hash, unavailable architecture, or
invalid lock blocks promotion and execution. A Python or `uv` update stages
revalidation as a new revision; failure leaves the old revision executable with
its referenced runtime assets.

A verifier or sandbox-policy security version change marks affected revisions
**Needs verification** and blocks their execution until they pass under the new
policy. The source, reports, and old runtime assets remain available for rebuild
or inspection, but the app never retains or invokes an obsolete sandbox worker.

## Capability and permission model

Capabilities are explicit typed data:

- `network(origins)`
- `readInputFiles`
- `writeOutput(bookmarkID)`
- `clipboardRead`
- `clipboardWrite`
- `selectedTextRead`
- `selectedTextReplace`
- `openApplication(bundleID, fullScreen)`
- `revealInputFiles`
- `openURL(origin)`
- `runShortcut(name)`
- `sendTextToApp(bundleID)`
- `networkCredential(secretID, origin, headerName)`
- future capabilities added by schema version.

Network origins are canonical lowercase IDNA hostnames with HTTPS port 443 in
version 1. Wildcards, userinfo, IP literals, non-default ports, and
private/link-local/loopback/reserved addresses are rejected. The proxy resolves
DNS itself, rejects rebinding, rechecks every redirect against the grant, and
authenticates the worker over its private process channel. Generated code never
receives proxy credentials. Local test fixtures use a separate supervisor-owned
channel and cannot be addressed by generated runtime code.

`networkCredential` is the only secret capability in version 1. The proxy
injects the named HTTP header only for the exact granted origin; neither Pi nor
generated code can read the value. Arbitrary environment-variable, file, query
parameter, and command-line secret injection are unsupported.

Build-time and runtime capabilities are separate. Package resolution may use the
approved package registry without giving the installed tool general network
access.

Inputs are copied into the sandbox. The generated script receives sandbox paths,
never original user paths. Outputs remain staged until the run exits
successfully and the host verifier accepts them. Swift then moves accepted
outputs to the approved destination.

Secrets are stored in Keychain and referenced by stable secret IDs. The model
sees only the ID and purpose label, never the value. Swift retrieves a value
only for a matching runtime grant and sends it directly to the proxy's
per-request header injector. It never enters a process environment, workspace,
log, or agent message.

Risk classes:

- pure prompt/native transforms run after existing app permissions;
- sandboxed read/network operations can be tested automatically after capability
  approval;
- writes outside staging require destination approval;
- `sendTextToApp` and `runShortcut` require confirmation on every execution;
- sending, publishing, deleting, purchasing, and account mutation outside those
  two closed actions are rejected in version 1.

## Host-owned validation

Model-generated tests are useful but cannot approve a tool. The host verifier
produces two explicit results:

- **safety/contract verification** proves that the artifact obeys its declared
  schema, capabilities, runtime, input/output contract, and resource policy;
- **semantic evaluation** checks the user's explicit examples and
  kind-specific acceptance oracle, but does not claim proof for every real-world
  input.

**Ready** requires both results to pass for the exact candidate. For prompt
tools, the oracle checks structured input/output examples with a separate
read-only evaluator. For native tools, it checks exact catalog action and
arguments without performing risky side effects. For Python tools, it checks
deterministic fixtures, declared file/text properties, and repeat execution in
a clean workspace. Ambiguous intent with no executable oracle triggers one
clarification instead of a guessed Ready state.

The host verifier always checks:

- manifest schema and exhaustive kind handling;
- prompt/native/Python payload requirements;
- Python syntax and import smoke test;
- dependency lock creation and clean resolution;
- argv/input mapping;
- expected output type and the declared deterministic output properties;
- output location and extension contract;
- path traversal and symlink escape attempts;
- undeclared filesystem and network access;
- timeout and process-group cleanup;
- stdout/stderr, file-count, and byte limits;
- cancellation;
- repeat execution in a clean workspace;
- permission diff against the active revision.

Network tests use controlled public fixtures or local fakes. Real clipboard,
copied files, authenticated endpoints, and account actions are not used without
explicit approval.

For complex Python tools, one read-only critic turn may inspect the passing
candidate and propose edge cases. Any resulting change creates a new attempt and
must pass the complete host validation again.

A **false-ready** result is a promoted corpus candidate that violates an
explicit request assertion, kind-specific oracle, declared output contract, or
safety policy when replayed on its held-out fixture. It does not mean that
Nugumi promises correctness for unspecified behavior outside the accepted
oracle.

## Error handling

The agent receives structured failure categories:

- `invalidManifest`
- `policyViolation`
- `dependencyResolution`
- `syntax`
- `missingInput`
- `runtimeFailure`
- `wrongOutput`
- `timeout`
- `resourceLimit`
- `permissionRequired`
- `providerFailure`
- `cancelled`

Raw tracebacks remain in Advanced activity and are capped. Normal UI uses one
plain sentence and one recovery action.

After the repair budget is exhausted:

> Nugumi couldn't verify this tool after 3 attempts.

Actions:

- **Change request**
- **Try again**
- **Advanced**

The Ring never receives an unverified candidate.

## Observability and privacy

Local `events.jsonl` records:

- run and attempt IDs;
- state transitions;
- Pi turn and tool-call IDs;
- model/provider identity;
- token, duration, and cost counters when available;
- policy decisions;
- dependency/runtime hashes;
- process exit/signal and resource use;
- capped, redacted failure tails;
- verifier result and promotion fingerprint.

Analytics may include only:

- tool kind;
- input/output categories;
- success/failure category;
- attempt count;
- stage durations;
- sandbox/verifier version;
- anonymous app version and platform.

Analytics never include:

- user request text;
- clipboard or selected text;
- source code;
- filenames or filesystem paths;
- URLs beyond an explicitly approved coarse provider category;
- stdout/stderr;
- credentials or secret IDs.

## Migration from the current builder

Migration is additive and feature-flagged:

0. Pass the packaged XPC/Python feasibility gate; do not continue if the
   production boundary cannot enforce the required policy.
1. Introduce schema-versioned manifests, immutable revisions, atomic promotion,
   rollback, full fingerprints, and surfaced persistence errors.
2. Correct existing input contracts so prompt and Python tests consume their
   declared input.
3. Prevent failed runs from publishing files.
4. Add locked dependencies and sanitized environments.
5. Add the sandbox worker and hostile-boundary tests.
6. Add the pinned Pi helper and private protocol.
7. Replace separate Create, Install & test, Fix it, and Save supervision with the
   background state machine.
8. Route both the existing and autonomous builders through the sandbox worker.
   Keep the existing one-shot generation UI behind a developer-only fallback
   until the autonomous path passes release gates.

Existing prompt tools migrate to revision 1 without changing behavior. Existing
Python tools remain visible and installed with a **Needs verification** badge,
but cannot execute under the new policy. Their first edit or attempted execution
offers **Verify this tool**, which stages and validates a new revision without
overwriting the original. Declining or failing verification leaves the legacy
tool visible for editing, rebuilding, or deletion and keeps execution blocked.

## Testing and evaluation

### Unit and contract tests

- manifest and capability decoding;
- fingerprint stability and invalidation;
- state-machine transitions and crash recovery;
- Pi JSONL protocol and event ordering;
- attempt budgets and cancellation;
- atomic promotion and rollback;
- dependency-policy parsing;
- verifier output contracts;
- input routing for every tool kind;
- redaction and analytics allowlist.

### Integration tests

- real Pi session with deterministic fake model responses;
- real `uv` dependency lock and clean execution;
- XPC sandbox filesystem/network denial;
- controlled network proxy;
- redirect, DNS-rebinding, private-address, and secret-header enforcement;
- process-group timeout and child cleanup;
- packaged helper launch on arm64 and x86_64;
- app update preserving tools and active revisions.

### Adversarial tests

- read home directory and Keychain-related paths;
- read inherited API-key environment values;
- write outside the workspace;
- symlink and `..` path escape;
- connect to an undeclared domain or raw IP;
- fork children after timeout;
- flood stdout, files, memory, or disk;
- dependency URL/VCS/source-build bypass;
- model attempts to call unavailable Pi built-ins;
- generated tests falsely claiming success.

### Product evaluation corpus

The release corpus contains at least one hundred representative requests, with
at least twenty eligible cases in each supported prompt, native, offline
Python, and controlled-network Python bucket, plus unsafe/impossible cases:

- prompt transforms;
- native app actions;
- clipboard and selected-text processing;
- image/PDF/CSV conversions;
- network downloads;
- multi-file input and output;
- invalid and empty input;
- dependency and provider failures;
- ambiguous requests;
- unsafe or impossible requests.

Measured outcomes:

- first-attempt verification rate;
- verification rate within three repairs;
- false-ready rate;
- sandbox/policy escape rate;
- median and p95 time;
- model turns, tool calls, tokens, and cost;
- reproducible clean rerun rate;
- user clarification and permission frequency.

Release gates:

- zero false-ready results in the corpus;
- zero sandbox/policy escapes;
- at least 95% of eligible prompt and native requests verify within budget;
- at least 85% of eligible offline Python requests verify within budget;
- at least 75% of eligible controlled-network Python requests verify within
  budget;
- 100% of unsafe/impossible requests are rejected without execution;
- every promoted tool has a complete fingerprint and passing report;
- clean rerun succeeds for every promoted corpus tool;
- median build time is at most 90 seconds and p95 is at most 5 minutes;
- median agent use is at most 4 model turns and 12 tool calls, while no build
  exceeds the hard budgets;
- on the release baseline cloud model, median model cost is at most USD 0.25 and
  p95 is at most USD 1.00; releases record the exact model and pricing date;
- cancel leaves no worker or child process;
- packaged-app creation, permission, install, run, revision, and rollback pass
  manual QA on a clean Mac.

## Rollout

1. Developer-only feature flag and fake-model integration tests.
2. Internal packaged-app testing with local prompts and synthetic fixtures.
3. Opt-in preview for existing users, with the old builder retained.
4. Metrics review by failure category, not only aggregate success.
5. Default-on only after release gates hold across at least two app releases.
6. Remove the old builder after migrated tools and rollback paths have been
   exercised in production.

## Acceptance criteria

The feature is complete when:

- a user with Nugumi and a configured AI provider does not install Pi, Node,
  Python, uv, or packages manually;
- one description can produce and assign a verified prompt, native, or Python
  tool;
- the agent automatically reads structured failures and repairs within budget;
- only the supervisor can approve and promote a candidate;
- generated code never receives unrestricted host access or provider secrets;
- dependencies and runtime are locked to the verified artifact;
- failed or cancelled attempts cannot publish files or replace the active tool;
- permission expansion is visible and requires approval;
- every still-policy-compatible installed revision can be rolled back without
  regeneration; incompatible revisions remain inspectable and rebuildable;
- normal UX shows only description, progress, permission when necessary, and
  ready/blocked outcome;
- implementation, integration, adversarial, evaluation, and packaged-app QA
  gates pass.

## Implementation order

The implementation plan must follow this dependency order:

0. packaged XPC/Python feasibility gate with hostile-boundary proof;
1. artifact/versioning, install-journal, and state-machine contracts;
2. host verifier and corrected current-runner behavior;
3. production sandbox worker, runtime assets, and permission enforcement;
4. Pi helper isolation, packaging, and private protocol;
5. autonomous agent loop and crash reconstruction;
6. simplified creation/revision UX;
7. migration, evals, packaged-app QA, and rollout.

No autonomous execution ships before the sandbox and host verifier gates pass.
