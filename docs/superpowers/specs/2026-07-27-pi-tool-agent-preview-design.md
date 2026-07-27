# Pi Tool Agent Developer Preview

Date: 2026-07-27

## Goal

Replace Nugumi's one-shot Python tool generation with a real agent loop:

1. The user describes a tool once.
2. Pi asks Nugumi's already selected model to create a candidate.
3. Nugumi runs the candidate in the existing App-Sandboxed XPC worker.
4. Pi receives a structured failure, edits the candidate, and tries again.
5. Only a passing candidate is returned to the editor.

This preview proves the feature before production hardening is complete. It does
not weaken the existing release blockers for universal packaging, Developer ID
signing, hard memory enforcement, network, dependencies, or user-file access.

## Product Contract

The existing "Create tool" description remains the only required input. During
generation the editor shows one simple status such as Writing, Testing, or
Repairing. Source, attempts, and validation details stay under the existing
advanced/detail surface.

The preview supports offline Python text tools:

- one text argument in `sys.argv[1]`;
- UTF-8 text on stdout;
- no dependencies;
- no network;
- no user files;
- no generated shell commands;
- no installation or Ring assignment until validation passes.

Requests outside this contract must stop with a plain explanation rather than
pretending they were verified.

A passing candidate carries its fingerprint into editor state. Its manifest and
source are read-only in the preview until the user either saves that exact
candidate or discards it. This removes any gap between what the worker validated
and what Save receives. Approval is always for the same attested fingerprint,
never only for a script hash.

## Agent Boundary

The packaged helper uses:

- `@earendil-works/pi-coding-agent` `0.82.1`;
- Node.js `22.19.0`;
- a committed lockfile;
- an in-memory Pi session and settings;
- no Pi built-in tools;
- sequential custom tools only.

Pi receives exactly four tools:

1. `read_build_context`
2. `write_candidate`
3. `run_validation`
4. `finish_candidate`

It receives no `bash`, generic file read/write/edit, process, network, or host
filesystem tool.

The helper does not receive provider credentials. Its custom model transport
sends a bounded `modelRequest` over JSONL to Swift. Swift calls the existing
selected `LLMBackend.complete(...)` and sends the text response back. This lets
Pi work with the models Nugumi already supports without exposing keys or OAuth
tokens to another process.

The bridge serializes Pi's complete bounded `Context`: system prompt, prior user
messages, prior assistant actions, prior structured tool results, and the four
tool schemas. It asks the text-only backend for exactly one `ModelActionV1`:

```json
{"version":1,"action":"toolCall","name":"write_candidate","arguments":{}}
```

or:

```json
{"version":1,"action":"finalText","text":"This request needs network access."}
```

The adapter assigns the Pi tool-call ID; the model cannot choose it. Tool names
are a closed enum and arguments are parsed against the same TypeBox schema used
by the registered Pi tool before an `AssistantMessage` is created. Fenced JSON,
extra prose, missing fields, unknown actions/tools, duplicate keys, oversized
transcripts, and malformed arguments produce a stable `invalidModelAction`
failure. On a repair turn, the serialized transcript must include the preceding
validation report, including `wrongOutput` and its bounded expected/actual
detail.

## Wire Protocol

JSONL protocol version is `1`. Every string limit below is measured as UTF-8
bytes before JSON encoding. Every encoded JSONL line is at most 1 MiB and
contains one object with `version`, `type`, `runID`, and a type-specific
payload. The aggregate encoded candidate is capped at 900 KiB, leaving framing
headroom. A boundary test uses worst-case control-character escaping to prove
that every valid candidate fits in one line.

Swift to helper:

- `start`: description and budgets;
- `modelResponse`: matching request ID plus model text or redacted error;
- `toolResponse`: matching tool-call ID plus bounded result;
- `cancel`.

Helper to Swift:

- `state`: current user-facing phase;
- `modelRequest`: system and user prompt for the existing backend;
- `toolRequest`: one of the four allowed tools and typed arguments;
- `completed`: final passing candidate and fingerprint;
- `failed`: stable failure code and safe message.

Unknown versions, unknown message types, oversized lines, duplicate terminal
messages, and mismatched IDs fail closed.

There are two fixed helper entrypoints. `agent.mts` builds to `dist/agent.mjs`
and imports only the live Swift-backed model bridge. `gate.mts` builds to
`dist/gate.mjs` and imports only the scripted faux provider. The faux module is
absent from the live entrypoint's dependency graph. The mode is never selectable
in a `start` payload. The editor resolves only `agent.mjs`; the app's
`--pi-tool-agent-gate` startup path resolves only `gate.mjs`. Tests prove the
gate makes no `modelRequest` and the live entrypoint cannot construct or import
the faux provider.

## Candidate Contract

Each candidate contains:

- schema version `1`;
- name, brief, and SF Symbol;
- Python source capped at 64 KiB;
- one to three synthetic text cases;
- input text capped at 8 KiB per case;
- expected stdout capped at 16 KiB per case.

Fixtures belong to the immutable candidate and are created only by
`write_candidate`; the host never invents a live fixture from clipboard or user
files. stdout must decode as strict UTF-8. Comparison converts CRLF to LF and
removes exactly one terminal LF from expected and actual values; all other
whitespace is significant. Invalid UTF-8 is `invalidOutput`.

Candidate V1 maps to the existing editor model without model-controlled
permissions:

- kind: `.python`;
- input: `.clipboardText`;
- output: `.clipboard`;
- trigger: `.always`;
- timeout: 10 seconds;
- network: false;
- output directory: nil;
- summary: the candidate brief.

The model controls only name, brief, SF Symbol, source, and synthetic fixtures.

The host assigns attempt numbers and candidate IDs. Candidates are immutable
once validation starts. A candidate fingerprint is SHA-256 over sorted-key
canonical JSON for the schema version, manifest fields, source, fixtures,
runtime version, and validation-policy version.

The legal attestation sequence is:

1. `write_candidate(candidate)` returns host-assigned `candidateID` and
   `fingerprint`;
2. `run_validation(candidateID)` returns a report bound to that exact
   fingerprint;
3. `finish_candidate(candidateID, fingerprint)` succeeds only if Swift holds a
   passing report for the same immutable fingerprint.

Stale IDs, changed candidates, a supplied fingerprint mismatch, re-running a
superseded candidate, and finishing an unvalidated candidate fail closed.

## Validation

`run_validation` crosses from the Pi helper to Swift, then to the XPC worker.
The helper never executes Python.

For each fixture the worker:

1. creates a private temporary directory in its sandbox container;
2. writes `main.py`;
3. runs the packaged Python 3.12.11 with a sanitized environment;
4. passes the fixture as one argv item;
5. applies the existing wall/CPU/file/output limits;
6. returns one structured result.

Candidate execution uses a distinct additive
`CandidateValidationRequest/Reply` XPC method; the existing feasibility probe
is unchanged. A reply includes candidate ID/fingerprint, failing fixture index,
failure kind, exit code or signal, bounded redacted stderr and actual-output
detail, stdout/stderr truncation flags, duration, and the passing fingerprint.

Stable failure kinds are `invalidCandidate`, `syntaxError`, `runtimeError`,
`invalidOutput`, `wrongOutput`, `timedOut`, `outputLimit`, `cancelled`, and
`workerFailure`. stdout and stderr are capped and paths are redacted.

The agent may create one initial candidate and at most three repairs. It may use
at most eight model turns and 32 tool calls, and the whole run lasts at most ten
minutes. Swift owns and enforces every budget.

An accepted `modelRequest` charges a turn and an accepted `toolRequest` charges
a tool call before any external work starts. The first accepted
`write_candidate` is the initial attempt; each later accepted write charges one
repair before persistence. Schema-invalid or duplicate-ID messages terminate as
protocol failures before charging. The actor records a terminal result with one
compare-and-set; whichever cancellation, deadline, exhaustion, protocol error,
or success is accepted first wins, all in-flight work is cancelled, and late
replies are ignored.

## Persistence

Developer runs are stored under an injected root:

```text
AgentRuns/<run-id>/
  request.json
  state.json
  events.jsonl
  attempts/1/{candidate.json,report.json}
  attempts/2/{candidate.json,report.json}
```

The packaged deterministic gate injects `.build/pi-tool-agent-gate` instead of
Application Support. Events contain IDs, state, counters, durations, and stable
failure kinds; they exclude API keys, OAuth tokens, host paths, prompt contents,
fixture contents, source, stdout, and stderr.

## Deterministic Gate

The helper has a test-only inline Pi provider, but still runs a real
`AgentSession`.

For the fixed request "make a tool that uppercases text":

1. the first Pi candidate intentionally prints the input unchanged;
2. sandbox validation returns `wrongOutput`;
3. the same Pi session writes a repaired candidate;
4. sandbox validation passes;
5. Pi calls `finish_candidate`;
6. Swift persists two immutable attempts and reaches `candidateReady`.

The packaged gate also proves that no worker, Python, or Node process survives,
no installed Tool or Ring state changes, and no sentinel path/value is present
in protocol output or persisted event metadata.

## Live Preview

The normal editor uses the same supervisor with the current `LLMBackend` bridge.
A passing candidate is converted to the existing `GeneratedTool` value and
shown in the editor together with its attestation. Save/approval is enabled only
for the exact passing fingerprint. A failed or budget-exhausted run leaves the
user's description and previous draft intact and exposes a short error plus the
final bounded validation detail.

The deterministic packaged gate is required for every build. A live-provider
smoke is manual because it may cost money and needs the user's configured
provider.

## Non-Goals

- automatic package installation;
- network access;
- copied files or arbitrary filesystem access;
- AppleScript or shell;
- automatic save, approval, or Ring placement;
- promotion, rollback, or revision migration;
- claiming 90% success before a representative evaluation corpus exists.

This preview is the first measurable step toward the 90% goal. The later
quality gate is a corpus of real tool requests with first-pass, repaired-pass,
unsupported, latency, and regression metrics.
