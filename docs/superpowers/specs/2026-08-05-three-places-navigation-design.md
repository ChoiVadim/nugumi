# Three places — Home, Ring, Edges

## The problem

Gizmate grew a second kind of thing and the navigation never noticed.

Every tool used to be summoned: you select something, you invoke it, it acts, it
finishes. Ring actions and prompt/native/agent gizmos all work that way, and a
sidebar built around "Home is the ring" fitted them.

Surfaces broke that. A `.surface` gizmo never finishes — it sits on a screen
edge showing what its script printed, and you drag files out of it. Notes has
worked that way since the dock shipped, and the folder hub was built that way
last night. Three residents now, and the interaction has nothing in common with
a run: you do not invoke them, you look at them and take things out.

Three symptoms, all of them the same missing concept:

**Placement lives in three places.** `DockPlacementPicker` is rendered from
`ToolEditor` for gizmos, `BuiltInEditor` for shipped actions, and
`SettingsSection` for the folder hub. The third one was chosen last night
because nowhere fitted — the hub has neither a `RingActionID` nor a
`GizmateTool`, so it fell out of both existing editors. A concept with no home
gets stapled to the nearest page.

**An edge cannot be seen.** Placement is stored as a property of the _tool_, so
the question "what is on my right edge, and in what order" can only be answered
by visiting every tool in turn across three screens. That is why tab order is
"the order they were docked" — not a decision, just the absence of anywhere to
make one. `DockStore` already models an edge as an ordered list; nothing shows
it.

**Making a tool requires knowing where it will go.** `case .home: RingSection()`
— Home _is_ the ring, and `ToolBuilderChat` is presented from inside
`ToolEditor`, which is reached by picking a ring slot. So the only door to
creating anything is a ring slot, and a surface gizmo — which never belongs on a
ring — has to be created through one anyway.

## What we are building

Three sections, one per question a person actually has:

| Section   | The question it answers                    |
| --------- | ------------------------------------------ |
| **Home**  | What can Gizmate do, and make me a new one |
| **Ring**  | What is under my cursor                    |
| **Edges** | What is on my screen borders               |

Home becomes the front door: the builder chat, the list of every tool, and the
detail view for one. Ring becomes what Home is today, moved and unchanged.
Edges is new and owns every edge.

## The risk this design exists to avoid

Decoupling creation from placement creates a way to make a tool that lives
nowhere. That is not hypothetical: this codebase shipped it twice in two days.

A surface gizmo reached the enum, the protocol, the sidecar, the dock catalog,
the model and the tests — and missed the single UI control that made it
dockable, so every line of it was dead in a shipped build. The folder hub
repeated it one level up hours later. Both times everything was green and
nobody could use the feature.

Today the ring slot hides this: you pick a slot _first_, so what you make is
placed by construction. Take that away and "created" and "reachable" become
independent events, with nothing forcing the second.

**So placement is part of creation, not a separate errand.** When the builder
finishes a tool, the same screen asks where it goes — a ring slot for a tool you
invoke, an edge for one that resides — and a tool with neither must be visibly
marked as such wherever tools are listed. Not a warning banner; a plain,
permanent statement of fact next to it.

## Sections

### Home — the front door

- The builder chat, at the top level rather than nested in a tool's editor.
- Every tool: shipped actions and generated gizmos in one list.
- Detail for one tool: what it does, its script or prompt, and where it lives.
- A tool that lives nowhere says so.

`ToolBuilderChat` moves out of `ToolEditor`. The editor keeps editing; Home
keeps making.

### Ring — what is under the cursor

`RingSection` moved from `.home` to its own case, otherwise untouched. It
already documents itself as "deliberately the ring and nothing else". Creating a
tool from a slot picker stays — it is a good shortcut when you already know
where the tool goes — but stops being the only door.

### Edges — what is on the borders

Organised **by edge, not by tool**. That inversion is the point: an edge owns an
ordered list, and the list is the thing you edit.

- Top, left and right, each showing its residents in tab order.
- Reorder within an edge by drag; move between edges by drag.
- Below them, what can be placed and is not: Notes, the folder hub, every
  usable `.surface` gizmo.
- A resident's own settings sit with it here — the folder hub's folder list is
  currently reachable **only from inside its panel**, which is discovery by
  accident.
- The consent sentence lives here once — _a resident runs whenever its edge
  opens_ — instead of being copied onto each of the three placement controls.

The three existing `DockPlacementPicker` sites become a one-line pointer: "On
the right edge — change in Edges." Locality is worth a sentence; it is not worth
three copies of a control.

## Non-goals

- **Multi-monitor.** Still main screen only.
- **Ask and Live as residents.** `DockCatalog` names them as future residents;
  they still build their own windows and there is nothing to hand an edge. Edges
  must not list them as if there were.
- **Redesigning the ring.** It moves. Nothing else.
- **A second placement model.** `DockStore` stays exactly as it is; this
  redistributes who _edits_ it.
- **Touching the tool protocol.** Nothing here reaches `GizmateToolAgentCore` or
  the sidecar.

## What has to be re-pointed

`MainWindowSection`'s cases are referenced by name across the app, and two of
them will now mean something different:

- `presentMainWindow(section: .home)` is called twice from
  `GizmateApp+ScriptTools.swift`. One of them is last night's toast telling the
  user to pick an edge — that must point at `.edges`, not Home.
- `GizmateApp+HotKeysMenus.swift` opens `.settings` from the menu bar; unchanged,
  but the menu should gain the new sections if it lists any.
- `SettingsSection`'s Files card moves to Edges, and
  `residentWithoutARingSlot` — the constant its parity test pins — moves with it.
- `DockCatalog.builtIns`' doc comment describes where residents get their edge;
  it will be wrong again.

Check whether the selected section is persisted anywhere before renaming a case:
a raw value written to disk by an older build must still resolve.

## Tests this must not lose

Two parity tests exist because this exact class of defect already shipped twice:

- `ToolProtocolEnumParityTests` — every output `DockCatalog.gizmos` will list is
  an output the editor can dock.
- `DockPlacementParityTests` — every built-in resident `DockCatalog.builtIns`
  returns has a placement control somewhere in the interface.

Both pin a constant against the live catalog. When the controls move, both must
follow and must still fail if the control is removed — not merely still compile.
A third parity test belongs here: **every tool that exists is reachable from
somewhere**, which is the invariant the "lives nowhere" risk is about.

## Open questions

- **Does Notes stay a section?** It is both a place to read and write notes and a
  dock resident. Most likely yes — reading notes is not the same act as choosing
  where the list appears — but the two must not both claim to own it.
- **Does Home's tool list replace the ring slot picker's list?** They show the
  same tools for different purposes. One of them should probably become the
  other.
