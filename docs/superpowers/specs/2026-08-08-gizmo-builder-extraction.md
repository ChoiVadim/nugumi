# Lifting the gizmo build loop out of the editor view

Written 2026-08-08, from three independent reads of the current code.

## Why

Home's chat can talk, and it can hand a build to a modal, but it cannot build
anything itself. The build-and-test loop lives as `@State` on `ToolEditorPanel`,
a 1600-line SwiftUI view shown as a sheet — so a build belongs to a view, and a
view dies when you look at another section.

The goal: the main chat builds a new gizmo and changes an existing one, in its
own transcript, with no per-gizmo conversation and no modal opening. Clicking a
gizmo keeps opening its Details modal, which is already how built-ins behave.

## Progress

- **Done.** `ToolEditorDraftVerification` and `ToolTestState` moved to
  `GizmoDraft.swift`. `GizmoDraft` written and tested (10 tests), used by
  nothing yet.
- **Next.** Commits 2 through 5 below.

## The plan

Repo root: `/Users/vadimchoi/Documents/vadim/translater`.

## 1. New types

**`GizmoDraft`** — `/Users/vadimchoi/Documents/vadim/translater/Sources/Gizmate/MainWindow/GizmoDraft.swift` (`@MainActor final class ... : ObservableObject`). One gizmo's editable state plus its own run. No chat, no agent, so it is unit-testable with no model.

```
let subject: Subject            // .new | .existing(UUID)
@Published var draft: GizmateTool { didSet { invalidate() } }   // was :101
@Published var script: String   { didSet { invalidate() } }     // was :102
@Published var brief: String    { didSet { invalidate() } }     // was :116
@Published private(set) var test/liveOutput/elapsed              // :104,:106,:107
@Published private(set) var summary: String?, assurance: ToolAgentAssuranceV1?, hasTool: Bool  // :118,:120,:131
private var ticker, runTask, runningFingerprint, passedFingerprint, builtAndRanFingerprint, readyFingerprint  // :108,:110,:111,:112,:126,:141
private var applying = false     // invalidate() no-ops during apply()
```
API: `fingerprint`, `canSave`, `isRunning`, `reportText`, `apply(_:)`, `markCandidateReady()`, `runTest() async -> ToolTestState?` (nil when the double fingerprint guard discarded the result), `cancelRun()`, `save() -> GizmateTool`, `cancelInFlight()`.
Injected: `tools: ToolsStore` (hydrate at :248-249, persist at :962, `approvalHash` at :972) and `runner` (the `testScriptTool` closure). `ToolApprovals` stays static. `ToolEditorDraftVerification` (:6-38) and `ToolTestState` (:1756-1773) move into this file unchanged, so `ToolApprovalOnSaveTests` and `ToolsStoreTests` keep compiling untouched.

The `didSet` is the point of the type: the invalidation edge (`:191-193` plus `draftDidChange` `:932-953`) stops being a view `.onChange` and becomes unbypassable, which is what protects the first-run approval decision.

**`GizmoBuilder`** — `/Users/vadimchoi/Documents/vadim/translater/Sources/Gizmate/MainWindow/GizmoBuilder.swift` (`@MainActor final class ... : ObservableObject`). App-owned. Holds **one** build transcript and **one** in-flight build (the answer broker at `ToolBuilderChat.swift:254-257` structurally forbids two anyway, so one is the honest number).

```
let chat = ToolBuilderChatSession(greeting: nil)   // one session for the app, not per gizmo
@Published private(set) var live: GizmoDraft?
@Published private(set) var generating = false      // was :117
private var drafts: [Subject: GizmoDraft]           // one draft per gizmo, memoized
private var generateTask: Task<Void, Never>?        // was :127
```
API: `draft(for:) -> GizmoDraft` (memoized, hydrates from `ToolsStore`, replaces `loadOnce` :245-259), `startNew(_:)`, `startEdit(_:instruction:)`, `send(_:) async` (was `sendChatMessage` :1388-1406), `stop()` (:226-229), `tryCandidate(_:) async`, `repair() async`, `saveLive()`, `discard(_:)`, `isBuilding`, `isBuilding(_ subject:)`, `cancel() async`.
Injected: `tools: ToolsStore`; `agent: Agent` (a struct of the three closures with exactly the bridge signatures at `GizmateSettingsBridge.swift:177-232`); `runner`. Closures rather than `SettingsHost` for the reason `ToolChatConversation.Answer` is one (`ToolChatConversation.swift:34-37`): drivable with no network, and no fifth protocol method to spell out in six stub conformances.

Ownership: `lazy var gizmoBuilder` on `GizmateApp` beside `homeChat` (`GizmateApp.swift:77`), exposed as `var gizmoBuilder: GizmoBuilder { get }` on `SettingsHost` beside `homeChat` (`SettingsContracts.swift:100`), mirrored as `let builder` on `GizmateSettingsBridge` (:14-16, :56-70). It must not live on the bridge: `MainWindowController` creates it (`MainWindowController.swift:48`) and is nil'd when the window closes (`GizmateApp+HotKeysMenus.swift:272-274`), so a bridge-owned build would die with the window. Cost: one `fatalError` line in each of the three `SettingsHost` stubs (`ToolProtocolEnumParityTests.swift` ×2, `DockCatalogSurfaceTests.swift`). `ToolBuilderChatSession.init` gains `greeting: String? = <current text>`, so every assertion in `ToolBuilderChatTests` stays green while the builder starts with an empty transcript.

## 2. What moves out of `ToolEditorPanel`

| To `GizmoDraft` | To `GizmoBuilder` | Stays in the panel |
|---|---|---|
| :101, :102, :104, :106, :107, :108, :110, :111, :112, :116, :118, :120, :126, :131, :141; `canSave` :922-926; `currentDraftFingerprint` :928-930; `draftDidChange` :932-953; `save` :955-977 (without `dismiss()` :978); `apply` :1285-1305 (without `page` :1300); `readyDraftFingerprint` half of :1308; `reportText` :1625-1632; `runTest` :1643-1696 (without the `chat.*` lines :1652, :1681-1694) | :117, :127, :129; `stopBuilding` :226-229; `cancelInFlightWork` :233-243 (task half); `revise` :1249-1282; `candidateReady` chat half :1309-1318; `generate` :1321-1350; `repairScript` :1352-1386; `sendChatMessage` :1388-1406; the chat calls cut from `runTest` | :85 bridge; :130, :140, :144 with :843-857 and :865-903; header :263-302; footer :336-375; `behaviourLine` :438-450; details form :470-822 and :983-1244; `scriptField` :1408-1432; :1434-1436; :1440-1581; `testSection` :1585-1621; `runHint` :1634-1641 (it reads `bridge.uvReady`); :1700-1752; `IconGrid` :1778-1868; `ToolEditorChrome` :1876-1897 |

Deleted outright once Home hosts the build (commit 4): `Chrome` :53-59, `EditorStage` :61-64, `EditorPage` :66-83, `opensOnDetails` :95, `onClose` :99, `loaded` :103, `page`/`didChoosePage` :132-135, the chat branch of `body` :155-166, `editorTabs` :304-334, `summaryCard` :403-435 (moves into the new card view), and the whole `ToolBuilderChat` **view** (`ToolBuilderChat.swift:309-736`). The session, the broker and their tests survive intact.

This deletion costs no reachable behaviour: both production sites pass a non-nil id (`RingSlotPicker.swift:262`, `HomeSection.swift:270`), so `opensOnDetails` is always true and the panel's chat page is already unreachable from the sheet. Home is its only user.

## 3. How the panel drives it afterwards

- Constructed with the draft, not the id: `ToolEditorPanel(gizmo: bridge.builder.draft(for: .existing(id)))` at `RingSlotPicker.swift:40`. `@ObservedObject var gizmo: GizmoDraft`, no `@StateObject`, no `loadOnce`, no `loaded` guard.
- Every form control becomes `$gizmo.draft.<field>` (about 20 sites, :984 through :1244). `optionRows` keeps its `.onChange(of: gizmo.draft.options)` (:899-902) and still resyncs, because `draft` is `@Published`.
- `detailsContent.disabled(bridge.builder.isBuilding(gizmo.subject))` replaces `.disabled(generating)` (:170), so a revise driven from Home locks the same gizmo's fields.
- `testSection` (:1585-1621): Stop calls `gizmo.cancelRun()`, "Install & test" calls `Task { await bridge.builder.tryCandidate(gizmo) }` (one path, and `tryCandidate` only speaks into the chat when `live === gizmo`), "Fix it" calls `bridge.builder.repair()`. `runHint` unchanged.
- Footer Save (:353): `gizmo.save()`, then `bridge.builder.discard(gizmo.subject)`, then `dismiss()`. Delete (:339-344) unchanged plus `discard`.
- `escapePressed` (:214-220) becomes `gizmo.isRunning ? gizmo.cancelRun() : dismiss()`. `.onDisappear` (:187) no longer cancels anything (see regressions).

## 4. How Home drives the same store

`HomeChatPane` gains `@ObservedObject var builder: GizmoBuilder` (passed from `HomeSection.swift:114`) and loses `Subject` (:34-41), the `switch` (:66-104) and `editor(toolID:)` (:106-120). The pane is always transcript plus composer.

Transcript (`HomeChatPane.swift:127-135`), one column, in this order: talk turns, pending turn, then `ForEach(builder.chat.messages)` rendered with the same `ChatQuestionBubble` / `ChatAnswerText` the talk half uses, then `ChatThinkingText(builder.chat.currentActivity)` while `builder.isBuilding`, then the key row when `builder.chat.pendingSecret != nil`, then the candidate card when `builder.chat.readyMessage != nil && !builder.isBuilding`. Two new `.onChange` hooks beside :140-155 (`builder.chat.messages.count`, `builder.chat.readyMessage`) keep the scroll pinned.

New view file `/Users/vadimchoi/Documents/vadim/translater/Sources/Gizmate/MainWindow/GizmoBuildCard.swift`: the old `summaryCard` body (:403-435, reading `builder.live`), the `readyActions` switch (`ToolBuilderChat.swift:690-704`), and the key row plus `saveKey` (`ToolBuilderChat.swift:411-519`) which must keep calling `chat.resolveSecret(true)` for a fixed name and going through `builder.send(...)` for a user-named one.

Send routing (`HomeChatPane.swift:355-387`), in order:
1. `if builder.chat.isAwaitingAnswer || builder.isBuilding { await builder.send(text) }`. A clarification is an ordinary assistant bubble at the tail (`ToolBuilderChat.swift:112`), the composer stays enabled by the rule moved from `canSend` (`ToolBuilderChat.swift:335-338`), and the answer returns `.answeredClarification` so no second build starts.
2. `ToolChatRouter.mentioned` -> `builder.startEdit(id, instruction: text)`. A bare `@Prices` with no instruction calls `chat.greetForEditing(name)` and waits.
3. Otherwise unchanged: `conversation.send(text)` beside the router, then `.build` -> `conversation.cancel(); builder.startNew(text)`, `.edit(id)` -> `conversation.cancel(); builder.startEdit(id, instruction: text)`.

Save without a modal: the card's Save button calls `builder.saveLive()`, which is `draft.save()` (ToolsStore write plus the `savingApproves` approve/revoke), then appends "Saved <name>." to the transcript, `markCandidateStale()`, `discard(subject)`, `live = nil`. Nothing closes and nothing navigates; the rail updates from `ToolsStore`'s `@Published`, and Details is still one rail click away (`HomeSection.swift:270`, unchanged).

## 5. Commits

1. **Move the two pure types.** Create `GizmoDraft.swift` holding `ToolEditorDraftVerification` (:6-38) and `ToolTestState` (:1756-1773), nothing else. Same module, same names, zero test edits.
2. **`GizmoDraft` owns the draft and the run.** (The risky one, alone.) Move the left column of the table above; panel takes `@ObservedObject var gizmo`; add the memo table and hydration on a still-agent-free `GizmoBuilder`; `RingSlotPicker.swift:40` and `HomeChatPane.swift:114` pass the draft in. Chat still lives on the panel and the app looks identical. Add `GizmoDraftTests`.
3. **`GizmoBuilder` owns the agent loop and the one session.** Move the middle column; add `SettingsHost.gizmoBuilder`, the `GizmateApp` lazy var, the bridge `let`, three stub lines, and the `greeting:` parameter. Panel's chat page now renders `builder.chat`. Still identical on screen.
4. **Home hosts the build.** Add `GizmoBuildCard.swift`, rewrite `HomeChatPane`'s transcript and `send()`, delete `Subject`/`editor(toolID:)`, delete the panel's chat page and `ToolBuilderChat.swift:309-736`.
5. **Cleanup.** Drop `Chrome`, `onClose`, `isNew`, and make `RingSheet.toolEditor(id:)` non-optional.

## 6. Regressions and their checks

| Regression | Check |
|---|---|
| Edit a field after a passed test and still get first-run approval | `GizmoDraftTests`: pass a run, mutate `draft.timeoutSeconds`, assert `save()` revokes. `didSet` is what makes this unbypassable |
| `apply()` writing draft, script and brief in three steps trips `invalidate()` mid-flight and drops `builtAndRanFingerprint` | The `applying` flag; test `apply(assurance: .smoke)` then `save()` approves, and `.unverified` then `save()` revokes |
| A stale run's result adopted after the draft moved | Test with a runner closure that mutates the draft before returning; `runTest()` must return nil and leave `test == .idle` |
| Two drafts of one gizmo (chat saves over the modal's field edits) | `XCTAssertTrue(builder.draft(for: .existing(id)) === builder.draft(for: .existing(id)))` |
| A second build starts while a clarification is open | Test: `chat.isAwaitingAnswer == true`, call `builder.send`, assert the agent closure call count stays 1 |
| Secret continuation stranded, so the validation run hangs forever | Existing `ToolBuilderChatTests:216-227` plus a new one: the Home key row's save resolves `true` |
| Ticker leaking now that `.onDisappear` no longer cancels | Assert `runTest`'s completion cancels the ticker (`elapsed` stops advancing after the runner returns) and that `discard` cancels an in-flight run |
| A run started from Home's trial killed by opening and closing Details (previously `.onDisappear` cancelled everything) | Deliberate change: only Stop, Escape and `discard` cancel. Manual: start a trial, open Details, close it, run still finishes |
| A build killed by leaving Home (today `.id(toolID)` plus `.onDisappear` does exactly that) | Manual: start a build, switch to Ring, come back, the transcript is still streaming. This is the bug the app-owned builder fixes |
| The options editor going stale after a regeneration | Manual: generate a gizmo with options while its Details modal is open, confirm the rows refresh (the `.onChange(of: gizmo.draft.options)` must survive the port) |
| Escape closing instead of stopping | `escapePressed` reads `gizmo.isRunning` only, since the panel can no longer generate. Manual on both a running test and an idle panel |
| The `MainWindow` on-disk scans silently stop covering the new code | Both new files land in `Sources/Gizmate/MainWindow/`, which is what `MainWindowInputControlTests:21-35` enumerates |
| Signature churn breaking the whole test target | The builder takes closures, so `SettingsHost`'s four build methods are untouched and the six stub conformances keep compiling |
