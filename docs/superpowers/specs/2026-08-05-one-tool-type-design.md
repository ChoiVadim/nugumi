# One tool type — a shipped action and a generated gizmo become one struct

Follows `2026-08-03-one-tool-model-design.md`, whose phases 1–2 landed: `ToolRef`
exists, `DockStore` keys on it, and `RingSlotContent` holds either kind. That
spec unified the **id**. This one unifies the **type**.

## The problem

`ToolRef` gave every store one key. It did not give the app one thing behind
that key, so five seams still run the length of the codebase:

|          | Shipped                                       | Generated                        |
| -------- | --------------------------------------------- | -------------------------------- |
| Data     | `RingActionID` + `BuiltInOverride` (5 fields) | `GizmateTool` (24 fields)        |
| Store    | `BuiltInOverridesStore` → UserDefaults        | `ToolsStore` → dir + `tool.json` |
| Editor   | `BuiltInEditor.swift` (282 lines)             | `ToolEditor.swift` (1674 lines)  |
| Run      | `performBuiltIn(_:)` — a ten-way switch       | `runTool(_:)` → `dispatch`       |
| Shortcut | `GlobalShortcutAction`, closed enum           | none                             |

The two data models have already converged on their own without anyone deciding
they should. `BuiltInOverride` carries `name`, `symbol`, `prompt`, `usesVoice`,
`usesNotes` — five fields whose names and meanings are identical to
`GizmateTool`'s. That is not a coincidence to preserve; it is one type wearing
two coats.

The cost is the one the previous spec named and did not finish paying: every
capability added from here is added twice, and the second time is the one that
gets skipped. A gizmo still cannot hold a key. Explain still cannot sit on an
edge.

## What the ten shipped actions actually are

They are not one family, which is why "make built-ins be `GizmateTool`s" has
felt wrong every time it has been considered:

| Family             | Who                           | Expressible in `GizmateTool` today?                                                                                                                                                                  |
| ------------------ | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prompt             | explain, rewrite, genZ, reply | Yes. `.prompt` with `.panel` / `.replace`. Nothing new needed                                                                                                                                        |
| Nearly             | saveNote, capture             | `NativeAction.saveToNote`; `input: .screenshotText` + `.prompt`                                                                                                                                      |
| Genuine capability | ask, live, summarize, dictate | No. Each owns a controller and a window — `AskPromptController`, `LiveCaptionController`, `DictationController` — and summarize is one button standing for two prompts with the frontmost app's icon |

So the honest unification is not "every shipped action becomes a prompt tool."
It is "every shipped action becomes a `GizmateTool` **value**, and the ones whose
behaviour is a controller say so in their `kind`."

**All ten start as `.capability`, including the first two families.** A shipped
action's `kind` describes how it runs, and today all ten run through
`performBuiltIn`. Giving Explain `kind: .prompt` before phase 4 would either be a
lie the run path has to special-case, or a behaviour change smuggled into a
refactor — Explain's prompt lives in `TranslationMode` and takes composition
settings the generic `.prompt` path does not apply. The table above is the map of
what can be converted _later_, one action at a time, each with its own before/after
comparison; it is not work this spec schedules. The unification being bought here
is the type, not the kind.

## Components

### `ToolOrigin` — one field, zero migration

```swift
enum ToolOrigin: Equatable {
    case shipped(RingActionID)
    case generated
}
```

Deliberately **absent from `CodingKeys`**. Only generated tools are written to
disk, and theirs is always `.generated`; shipped tools are assembled in memory at
launch and never persisted whole.

That last clause is the load-bearing one. `BuiltInOverride` is sparse on purpose
— see its doc comment at `Ring/BuiltInOverrides.swift:3-8`: "Reset to default" is
a _removal_ rather than a copy of today's defaults back over the top, so a user
who never touched Explain's prompt still picks up improvements to it in a later
release. Seeding shipped tools onto disk as whole records would kill that
property silently. **Unify the type, not the storage.**

`GizmateTool.id` for a shipped tool comes from a fixed table, one deterministic
UUID per `RingActionID`. Precedent: `RingFolder.moreID`
(`Ring/RingLayout.swift:58`), fixed for the same reason — a generated id would
leave saved references pointing at something nobody can find. With the table in
place, `ToolRef(tool)` resolves to `.builtIn(id)` or `.generated(uuid)` and
**every key already on disk keeps working**: no `DockStore` migration, no
`RingLayout` migration, no `globalShortcut.*` rewrite.

### `ToolKind.capability` — exactly one new case

```swift
case capability   // every shipped action, until one is converted on purpose
```

No associated value. `ToolKind` is `String, Codable, CaseIterable` and five
parity tests plus the sidecar schema stand on those conformances; an associated
value costs all three to save a field lookup. The `RingActionID` is read off
`origin`, and a `.capability` tool is `.shipped` by construction — asserted in
the parity test below rather than left as a comment.

⚠️ A `.passthrough` kind was considered for dictate — input equals output, no
model in the loop — and rejected. Dictate has `DictationController` and a REC
pill; it is a capability, not a transform with the transform removed. Add
`.passthrough` when a _user's_ gizmo asks for it, not before: a speculative kind
has to be threaded through five parity tests, the eval sweep, the sidecar schema
and the host allowlist, and `CLAUDE.md` records what that costs when one of those
is missed.

### `ToolCatalog` — one vendor, two sources

```swift
@MainActor
enum ToolCatalog {
    static func all(host: any SettingsHost) -> [GizmateTool]
    static func tool(ref: ToolRef, host: any SettingsHost) -> GizmateTool?
    static func save(_ tool: GizmateTool, script: String?, host: any SettingsHost)
}
```

Built against `SettingsHost` rather than `GizmateSettingsBridge`, matching
`DockCatalog` — the bridge dies with the main window, and the ring and the dock
both need this with no window open.

`save` routes by `origin`: `.shipped` writes a `BuiltInOverride` (dropping fields
that match what shipped, so the sparse contract survives a round trip through the
one editor), `.generated` writes through `ToolsStore` as today.

### Editors

`BuiltInEditor.swift` is deleted. `ToolEditorPanel` already switches on `kind` in
eight places; it gains `.capability` and one gate on `origin`:

- `.shipped` — no script section, no delete; "Reset to shipped" appears.
- `.generated` — as today; no reset.

This reverses the previous spec's non-goal ("merging the two editors into one
screen"). The reason it was a non-goal was that a merged editor would fill with
"not for this kind" rows — but the editor already answers that question eight
times for python/native/agent, and `origin` is a ninth of the same shape. What
changed is that `ToolEditorPanel` grew the machinery in the meantime.

## Phases

Each leaves the app working and is worth landing alone.

**Phase 1 — `ToolCatalog` and `origin`.** `HomeSection`, `DockCatalog`,
`RingSlotPicker` and `EdgesSection` stop branching on builtIn-vs-tool. Nothing
user-visible changes; this is the phase that makes the rest small.

**Phase 2 — one editor.** `BuiltInEditor.swift` deleted, `ToolEditorPanel` gains
`.capability` and the `origin` gate.

**Phase 3 — shortcuts open up.** Persisted key becomes
`"globalShortcut.\(ToolRef.storageID)"` with a one-time migration of the eleven
current `rawValue` keys; the Carbon `UInt32` becomes a runtime counter over a
`[UInt32: ToolRef]` map, with 2–13 reserved and 100 still the always-on ⌃⌥A Ask
alias. Gizmos get keys. (This is the previous spec's phase 4, unchanged — it was
right, it was just waiting on a type both kinds could share.)

**Phase 4 — one run funnel.** `runTool(_:)` handles `.capability` by dispatching
to `performBuiltIn`. `FloatingButton`'s ring closures and `setupGlobalHotKeys`'
table fold into it, which is what `App/GizmateApp+BuiltIns.swift:6-11` already
says should happen "when they are next touched rather than growing a fourth."

**Not in this spec:** moving the four prompt built-ins' prompts out of
`TranslationMode` and into `GizmateTool.prompt`. `usesCompositionSettings`,
`revisesAsContent` and revise inheritance all key off those enum cases; unpicking
them is its own spec and may never earn itself.

## Errors

- **A shipped tool edited to be identical to what shipped.** `save` sees an
  override where `isShipped` is true and removes the record, exactly as
  `BuiltInOverridesStore.save` does today. Round-tripping through the merged
  editor must not leave a stored copy of the defaults behind.
- **A `RingActionID` retired in a later build.** `ToolCatalog` builds shipped
  tools from `RingActionID.allCases`, so a retired action simply stops appearing;
  its stored override decodes to a skipped key, which `BuiltInOverridesStore.load`
  already handles.
- **A `.capability` tool reaching the run path with `.generated` origin.**
  Impossible by construction and asserted by the parity test rather than
  defended at run time — there is no honest fallback, and a silent one would run
  the wrong action.
- **A symbol a shipped tool's override names that no longer resolves.**
  `resolvedSymbolName` already falls back; shipped tools reach it through the
  same struct now, so the Phosphor glyph stays the default when no override is set.

## Testing

- `ToolProtocolEnumParityTests` gains a sixth parity test: every `RingActionID`
  appears exactly once in `ToolCatalog.all`, and every `.capability` tool has a
  `.shipped` origin. Built from live sets typed out independently on both sides,
  with the fixture asserting it discriminates — the house rule for this file.
- `ToolCatalogTests` — a shipped tool with no override equals the shipped
  default; saving an edit and resetting returns the same value; `ToolRef(tool)`
  round-trips for both origins.
- The fixed shipped-UUID table is covered the way `RingDefaultLayoutTests` covers
  `RingFolder.moreID`: a typo there must fail a test, not show a user a blank slot.
- Phase 3 extends `ShortcutRegistryTests`: two tools cannot hold one key, and
  releasing a tool frees its Carbon id.

## Files

Phase 1 adds `Tools/ToolCatalog.swift` and `Tools/ToolOrigin.swift`; touches
`Tools/GizmateTool.swift`, `Dock/DockItem.swift`,
`MainWindow/Sections/HomeSection.swift`, `MainWindow/Sections/EdgesSection.swift`,
`MainWindow/RingSlotPicker.swift`.
Phase 2 deletes `MainWindow/BuiltInEditor.swift`; touches
`MainWindow/ToolEditor.swift`.
Phase 3 touches `App/Shortcuts/*`, `App/HotKeys.swift`.
Phase 4 touches `App/GizmateApp+Tools.swift`, `App/GizmateApp+BuiltIns.swift`,
`Panels/FloatingButton.swift`, `App/GizmateApp+HotKeysMenus.swift`.

Exact file lists per phase belong in that phase's plan — phases 3 and 4 will read
differently once phase 1 has landed.
