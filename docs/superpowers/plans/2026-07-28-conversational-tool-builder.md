# Conversational Tool Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn New Tool into a Pi-powered chat with bounded clarification questions, safe activity, a verified preview, and explicit Save.

**Architecture:** Add `ask_user` to the existing typed Pi tool protocol and route it through the supervisor to a cancellable SwiftUI chat session. Keep build, validation, repair, and attestation unchanged. Treat the generated result as an editor draft and reuse the existing Save path for all persistence.

**Tech Stack:** Swift 6/SwiftUI, XCTest, TypeScript, Zod, TypeBox, Pi coding-agent SDK, Node test runner.

## Global Constraints

- `ask_user` is allowed only for Create and before the first candidate.
- At most three questions, one at a time; question and answer are non-empty and at most 1 KiB UTF-8.
- Activity is host-authored safe text; never display raw model output.
- Generation must not mutate ToolsStore, approvals, or Ring layout.
- Cancel must terminate both the build and any pending user-answer wait.
- Existing edit/fix behavior and candidate attestation stay compatible.

---

### Task 1: Typed clarification protocol

**Files:**
- Modify: `Sources/NugumiToolAgentCore/ToolAgentModels.swift`
- Modify: `Sources/NugumiToolAgentCore/ToolAgentToolMessages.swift`
- Modify: `Tests/NugumiToolAgentCoreTests/ToolAgentProtocolTests.swift`
- Modify: `ToolAgent/src/protocol.ts`
- Modify: `ToolAgent/src/tools.ts`

**Interfaces:**
- Produces: `ToolAgentAskUserRequestV1`, `ToolAgentAskUserResponseV1`, and `ToolAgentToolNameV1.askUser`.
- Produces: TypeScript tool name `ask_user` with `{question}` and `{answer}` payloads.

- [ ] Add failing Swift round-trip and UTF-8-bound tests for `ask_user`.
- [ ] Add failing TypeScript malformed/oversized payload tests.
- [ ] Implement strict Swift request/response types and enum cases.
- [ ] Implement matching Zod/TypeBox schemas and the fifth sequential tool.
- [ ] Run `swift test --filter ToolAgentProtocolTests`.
- [ ] Run ToolAgent typecheck and tests.

### Task 2: Supervisor clarification gate

**Files:**
- Modify: `Sources/NugumiToolAgentCore/ToolBuildSupervisor.swift`
- Modify: `Sources/NugumiToolAgentCore/ToolBuildSupervisorRequests.swift`
- Modify: `Tests/NugumiToolAgentCoreTests/ToolBuildSupervisorTests.swift`

**Interfaces:**
- Consumes: `ToolAgentAskUserRequestV1`.
- Produces: `ToolBuildClarificationHandlerV1`.

- [ ] Add a scripted process test where Create asks a question, receives the
      handler answer, and only then writes a candidate.
- [ ] Add tests rejecting Edit/Fix questions, questions after a write, and a
      fourth question.
- [ ] Add a cancellation test while the handler is suspended.
- [ ] Inject the async handler into `ToolBuildSupervisor`.
- [ ] Gate and count `ask_user` inside the existing tool-request path.
- [ ] Run `swift test --filter ToolBuildSupervisorTests`.

### Task 3: Pi conversation behavior

**Files:**
- Modify: `ToolAgent/src/model-bridge.ts`
- Modify: `ToolAgent/src/session.ts`
- Modify: `ToolAgent/test/session.test.ts`
- Modify: `Sources/Nugumi/App/ToolAgentLiveBuilder.swift`
- Modify: `Tests/NugumiTests/ToolAgentLiveBuilderTests.swift`

**Interfaces:**
- Consumes: `ask_user`.
- Produces: a same-session answer round trip before candidate generation.

- [ ] Add a live-sidecar test where the first model action is `ask_user` and
      the next model context contains the exact host answer.
- [ ] Update the bridge action schema and strict Swift action validator.
- [ ] Update the Pi prompts to ask only materially necessary Create questions.
- [ ] Forward the supervisor clarification callback through LiveBuilder.
- [ ] Run the focused Node and LiveBuilder suites.

### Task 4: Chat state and manual-save UI

**Files:**
- Create: `Sources/Nugumi/MainWindow/ToolBuilderChat.swift`
- Modify: `Sources/Nugumi/MainWindow/ToolEditor.swift`
- Modify: `Sources/Nugumi/MainWindow/MainWindow.swift`
- Modify: `Sources/Nugumi/App/NugumiApp+ScriptTools.swift`
- Create: `Tests/NugumiTests/ToolBuilderChatTests.swift`

**Interfaces:**
- Produces: `ToolBuilderChatSession` with message, activity, ask, answer, and cancel behavior.
- Consumes: `ToolBuildClarificationHandlerV1`.

- [ ] Add chat-session tests for initial message, question/answer, status
      de-duplication, and pending-answer cancellation.
- [ ] Implement the MainActor session plus single-continuation broker.
- [ ] Replace New Tool's form with transcript, bounded Activity disclosure,
      multiline composer, send action, and summary preview.
- [ ] Keep Overview/Details for existing tools and manual setup.
- [ ] Replace generated auto-install with applying the verified candidate to
      the draft; persist only in the existing `save()`.
- [ ] Thread clarification callbacks through SettingsHost and the app bridge.
- [ ] Run focused Swift tests and `swift build`.

### Task 5: Full verification

**Files:**
- Modify: `tasks/lessons.md`

**Interfaces:**
- Consumes: completed chat and agent flow.
- Produces: packaged, visually verified behavior.

- [ ] Run full `swift test`.
- [ ] Run the complete ToolAgent test suite and typecheck.
- [ ] Build the arm64 app bundle and run the Pi package gate.
- [ ] Launch `dist/Nugumi.app` and create an intentionally ambiguous tool.
- [ ] Verify the Pi question and answer appear in the transcript.
- [ ] Snapshot ToolsStore/Ring state and prove it is unchanged before Save.
- [ ] Press Save and verify the manifest and Ring assignment appear afterward.
- [ ] Inspect the final diff for unrelated changes and run `git diff --check`.

