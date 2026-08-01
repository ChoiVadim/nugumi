# Gizmo options — one button, several variants

**Date:** 2026-08-01
**Status:** approved, not yet implemented

## Problem

A `GizmateTool` is one button that does one thing. When a request names
alternatives — "save the video in 360p, 480p or 720p" — the builder agent (Pi)
has three bad choices: hardcode one resolution, spend one of its three
clarification questions asking which, or give the tool `.ask` input so the user
types "720p" into a capsule every time.

The ring already knows how to do better. Summarize is a button that expands into
Today / Week / Month on hover (`summarizeRingItem`, `Ring/RingModel.swift:139`),
drawing each range as a word badge (`RingTextBadge`). That mechanism —
`RingItem.subItems` plus `subLayout: .fan` — is generic; it is just not reachable
from a user gizmo, because `GizmateTool` has no notion of a variant and
`RingBuilder` builds every gizmo as a plain button (`Ring/RingBuilder.swift:73`).

## Goal

A gizmo can carry a short list of options. In the ring it becomes an expandable
button, one sub-circle per option, exactly like Summarize. Pi emits those options
on its own when a request has an obvious axis of choice.

## Non-goals

- Options on the built-in ring actions. They have their own shapes already.
- Nested options (an option that expands into further options).
- Options in the approval hash. See "Security posture" below.
- A dedicated picker for hotkey / quick-menu runs. The first option is the
  default there.

## Design

### 1. Model — `Sources/Gizmate/Tools/GizmateTool.swift`

Two fields:

```swift
/// Variants this gizmo offers, shown as a hover-expandable orbit in the ring —
/// the same second layer Summarize's time ranges use. Empty for a gizmo that
/// does one thing. The label IS the value: "720p" is both what the button says
/// and what the gizmo is handed.
var options: [String]          // persisted; 0, or 2...5

/// Which option this particular run picked. Deliberately absent from
/// `CodingKeys`: it belongs to a run, not to the saved gizmo.
var chosenOption: String?      // not persisted
```

and one accessor, which is where "first option is the default" lives:

```swift
/// The option in force for this run: what the ring picked, or the first one for
/// a run that came from a hotkey or the quick menu and never offered a choice.
var activeOption: String? { chosenOption ?? options.first }
```

Decoding stays lenient like every other field (`options` absent → `[]`), and the
2...5 bound is clamped on the way in the way `maxSteps` already is.

`chosenOption` is left out of `CodingKeys`, so Swift's synthesized `encode(to:)`
skips it and a saved `tool.json` never carries a stale choice.

### 2. Ring — `Sources/Gizmate/Ring/RingBuilder.swift`

In the `.tool` branch, a gizmo with options becomes a parent:

```swift
guard !tool.options.isEmpty else { /* today's plain button */ }
return RingItem(
    label: tool.name,
    image: RingIconKind.symbol(tool.resolvedSymbolName).image(),
    handler: {},                       // unused, as for any expandable parent
    subItems: tool.options.map { option in
        RingItem(label: option, image: RingTextBadge.image(option)) {
            dismiss()
            var picked = tool
            picked.chosenOption = option
            run(picked)
        }
    },
    subLayout: .fan
)
```

The parent keeps the gizmo's own SF Symbol; each option draws its word through
the badge renderer Summarize already uses.

**Why nothing else changes signature.** `GizmateTool` is a value type, and every
downstream lookup keys off `id` (script, approval) or `name` (usage stats) —
neither of which the copy alters. So `RingActionHandlers.tool`,
`FloatingButton`'s `onTool` and `runTool(_:selection:)` all stay exactly as they
are. The codebase already mutates a per-run copy this way:
`var contextualized = tool; contextualized.prompt += …`
(`App/GizmateApp+ScriptTools.swift:356`).

### 3. Delivery — how the option reaches the work

| Kind                | Channel                                                             |
| ------------------- | ------------------------------------------------------------------- |
| `.python`           | environment variable `GIZMO_OPTION`                                 |
| `.prompt`, `.agent` | `{option}` substituted into the prompt                              |
| `.native`           | `{option}` substituted into `target`, beside the existing `{input}` |

**Why an environment variable and not argv.** `.files` input already resolves to
one argv entry per file (`ToolContext.arguments(for:)`, `Tools/ToolContext.swift:94`),
so a trailing argument would be indistinguishable from one more file. The env
channel is uniform across every input kind and costs one line in
`ToolRunner.execute`, merged the same way secrets are:

```swift
process.environment = UVBootstrap.environment()
    .merging(secrets) { runtime, _ in runtime }
    .merging(tool.activeOption.map { ["GIZMO_OPTION": $0] } ?? [:]) { $1 }
```

`GIZMO_OPTION` is data, not a secret — it is the user's own visible choice, and
it is absent for a gizmo with no options.

Substitution for the other three kinds is one shared helper on `GizmateTool`:

```swift
/// `template` with `{option}` resolved against the option in force. Templates
/// from a gizmo with no options are returned untouched, so an author who typed
/// `{option}` by mistake sees the literal rather than an empty hole.
func resolvingOption(_ template: String) -> String
```

Called from three places: `TranslationMode.customPrompt`
(`Panels/TranslationModes.swift:263`) for `.prompt`, the `contextualized.prompt`
assembly in `GizmateApp+ScriptTools.swift:356` for `.agent`, and
`NativeToolRunner.substitute` (`Tools/NativeToolRunner.swift:239`) for `.native`
— where `{option}` gets the same percent-encoding `{input}` gets, since both land
in a URL.

### 4. The builder agent

`options` is added in three places at once, because the validator accepts a
candidate by re-encoding it and comparing byte for byte
(`ToolAgentModels.swift:42`) — a field known to one side and not the other fails
the trip back:

1. `ToolAgent/src/protocol.ts` — the zod candidate schema, on all four kinds:
   an array of 0 or 2–5 non-empty short strings, unique. One option is not a
   choice; six do not fan cleanly at the outer orbit's angular step
   (`RadialMenuLayoutPolicy.subClusterCenters`).
2. `Sources/GizmateToolAgentCore/ToolAgentModels.swift` — the matching field on
   `ToolAgentCandidateV1` and `ToolAgentInstalledToolV1`, with the same bound
   enforced in `validate` (`throw .invalidCandidate` on violation).
3. `Sources/Gizmate/App/ToolAgentLiveBuilder.swift` — carried through
   `generatedTool(from:)` into the saved `GizmateTool`, and back out in the
   installed-tool description so an edit round-trip preserves it.

The system prompt (`ToolAgent/src/model-bridge.ts`) gains a generic rule, not a
recipe:

> When a request has an obvious axis of choice — quality, format, size, length,
> language — express it as `options` rather than hardcoding one value or spending
> a question on it. The chosen option reaches a Python tool as `GIZMO_OPTION` in
> the environment, and a prompt or native tool through `{option}` in its text.

Stated as an axis rather than as "for video downloads, offer 360p/480p/720p":
teaching the prompt one answer proves the prompt can hold an answer, which is
explicitly what the eval suite is there to prevent (CLAUDE.md, "the validation
set").

### 5. Editor — `Sources/Gizmate/MainWindow/ToolEditor.swift`

A plain list of text fields with + / − under the existing fields, shown for every
kind, capped at 5 rows. Blank rows are dropped on save. A gizmo with exactly one
option saves as zero — the ring would otherwise draw a sub-orbit with one circle
in it, which is a worse button than the one it replaced.

### 6. Verification

- One case in `ToolEvalSuite.all` (`App/ToolEvalMode.swift`), worded the way a
  user would type it: _"save a youtube video as mp4, let me pick 360p, 480p or
  720p"_. It passes only if the finished candidate carries three options and its
  script reads `GIZMO_OPTION` — with no recipe added to the system prompt.
- A unit test that a `GizmateTool` with `chosenOption` set encodes without it and
  decodes back with `options` intact.
- Manual: `swift run Gizmate`, build the download gizmo through Pi, drop it in a
  ring slot, hover it, confirm three word badges fan out and that picking 480p
  produces a 480p file.

## Security posture

Options are **not** part of the approval hash (`ToolsStore.approvalHash(for:)`).
The hash covers what a tool _is_ — its script, or an agent's instruction, step
budget and secrets. An option is what a tool is _handed_ on one run, the same
category as the selection or the clipboard, neither of which is hashed either. A
tampered `tool.json` can change the string a script receives; it cannot change
what the script does with it, and the script itself is still hash-pinned.

## Rejected alternatives

**Pi emits N sibling gizmos in a ring folder.** Folders already nest
(`RingBuilder.folderItem`), so this needs no new model at all. Rejected: three
scripts, three approval prompts, and editing the behaviour means editing all
three copies — the variants drift apart the first time one is fixed.

**`.ask` input.** Works today with zero new code, but it makes the user type
"720p" instead of pointing at it, which is the whole thing being asked for.

**Trailing argv entry.** Ambiguous under `.files` input, as above.

**Fixtures carrying which option to exercise.** Validation runs with the first
option; a fixture field to test the 720p branch specifically is deferred until an
eval run actually shows the model unable to verify a branch it cares about.
