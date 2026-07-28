# Pi Tool Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nugumi Edit and Fix use the same Pi build-test-repair-attest loop as Create.

**Architecture:** Extend the version-1 start request with a typed operation and installed-tool snapshot, then serialize that context into Pi's first user message. Map the attested replacement back to the existing identity and apply the full result in the editor.

**Tech Stack:** Swift 6, XCTest, TypeScript, Zod, Node 22, Pi SDK, SwiftUI.

## Global Constraints

- Preserve the current dirty worktree and stage only owned files.
- Keep the existing four Pi tools and version-1 JSONL envelope.
- Do not execute native side effects during validation.
- Python source stays capped at 64 KiB and validated through the XPC sandbox.
- Preserve edited tool `id` and `createdAt`.

---

### Task 1: Typed edit request

**Files:**
- Modify: `Sources/NugumiToolAgentCore/ToolAgentModels.swift`
- Modify: `Sources/NugumiToolAgentCore/ToolAgentMessages.swift`
- Modify: `Sources/NugumiToolAgentCore/ToolBuildStore.swift`
- Modify: `Sources/NugumiToolAgentCore/ToolBuildSupervisor.swift`
- Modify: `ToolAgent/src/protocol.ts`
- Test: `Tests/NugumiToolAgentCoreTests/ToolAgentProtocolTests.swift`

**Interfaces:**
- Produces: `ToolAgentOperationV1`, `ToolAgentInstalledToolV1`, and matching optional start/request fields.

- [ ] **Step 1: Write failing request tests**

Add tests that round-trip an edit with a 64 KiB installed Python source and
reject create/edit/fix field combinations that violate the operation contract.

- [ ] **Step 2: Run the red tests**

Run: `swift test --filter ToolAgentProtocolTests`

Expected: compilation fails because the new operation and snapshot types do not
exist.

- [ ] **Step 3: Implement the minimal typed contract**

Add the Swift Codable models, supervisor validation, start forwarding, and
matching strict Zod schema without changing the four tool names.

- [ ] **Step 4: Run focused Swift and TypeScript protocol tests**

Run:

```bash
swift test --filter ToolAgentProtocolTests
npm --prefix ToolAgent test
```

Expected: both pass.

### Task 2: Pi receives editing context

**Files:**
- Modify: `ToolAgent/src/session.ts`
- Modify: `ToolAgent/src/model-bridge.ts`
- Test: `ToolAgent/test/session.test.ts`

**Interfaces:**
- Consumes: typed `StartPayload`.
- Produces: `makeInitialPrompt(start)` containing operation, instruction,
  current tool, and optional failure.

- [ ] **Step 1: Write a failing live-session test**

Launch `agent.mjs` with a Fix payload and assert the first `modelRequest.user`
contains the current manifest/source and exact failure, while its system prompt
requires preserving unspecified behavior.

- [ ] **Step 2: Run the red sidecar test**

Run: `npm --prefix ToolAgent test`

Expected: the edit-context assertions fail.

- [ ] **Step 3: Build Pi's structured initial prompt**

Serialize the bounded start context as JSON and update the model bridge rules
for create/edit/fix.

- [ ] **Step 4: Run the sidecar suite**

Run: `npm --prefix ToolAgent test`

Expected: all sidecar tests pass.

### Task 3: Pi-backed Edit and Fix

**Files:**
- Modify: `Sources/Nugumi/App/ToolAgentLiveBuilder.swift`
- Modify: `Sources/Nugumi/App/NugumiApp+ScriptTools.swift`
- Modify: `Sources/Nugumi/MainWindow/MainWindow.swift`
- Modify: `Sources/Nugumi/MainWindow/ToolEditor.swift`
- Test: `Tests/NugumiTests/ToolAgentLiveBuilderTests.swift`

**Interfaces:**
- Produces: `ToolAgentLiveBuilder.revise(tool:script:instruction:failure:...)`.
- Changes: `repairScriptTool` returns `Result<GeneratedTool, Error>`.

- [ ] **Step 1: Write failing snapshot and identity tests**

Cover prompt/native/Python installed-tool mapping and prove an attested
replacement keeps the original `id` and `createdAt`.

- [ ] **Step 2: Run the red Nugumi tests**

Run: `swift test --filter ToolAgentLiveBuilderTests`

Expected: compilation fails because revise/snapshot helpers do not exist.

- [ ] **Step 3: Route both host methods through Pi**

Build a typed edit/fix request, run the shared supervisor, restore identity,
and make Fix apply the whole returned candidate.

- [ ] **Step 4: Prove the old one-shot path is unreachable**

Run:

```bash
rg -n "ToolGenerator\\.(revise|repair)" Sources/Nugumi/App Sources/Nugumi/MainWindow
swift test --filter ToolAgentLiveBuilderTests
```

Expected: no call sites and focused tests pass.

### Task 4: Persistence safety

**Files:**
- Modify: `Sources/Nugumi/Tools/ToolsStore.swift`
- Modify: `Sources/Nugumi/MainWindow/ToolEditor.swift`
- Test: `Tests/NugumiTests/ToolsStoreTests.swift`

**Interfaces:**
- Changes: `ToolsStore.save(_:script:)` removes stale `main.py` when `script` is nil.

- [ ] **Step 1: Write a failing kind-change persistence test**

Save Python source, save the same tool as native with nil source, and assert
`script(for:)` returns nil.

- [ ] **Step 2: Run the red store test**

Run: `swift test --filter ToolsStoreTests`

Expected: stale Python source remains.

- [ ] **Step 3: Remove stale source and revoke approval**

Delete `main.py` when saving a non-Python tool and revoke old approval after an
agent edit until the exact draft is manually tested.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter ToolsStoreTests`

Expected: pass.

### Task 5: End-to-end verification

**Files:**
- Verify: all files above
- Verify: `dist/Nugumi.app`

**Interfaces:**
- Consumes: completed implementation.
- Produces: automated and UI evidence.

- [ ] **Step 1: Run all automated gates**

Run:

```bash
swift test
npm --prefix ToolAgent test
Scripts/test-pi-tool-agent-gate.sh
Scripts/build-app-bundle.sh
codesign --verify --deep --strict dist/Nugumi.app
```

Expected: all pass.

- [ ] **Step 2: Run one real packaged-app edit**

Open an existing tool, request a visible change, confirm Pi statuses, save, and
verify the tool retains its ID/Ring slot and performs the changed behavior.

- [ ] **Step 3: Review the final diff**

Confirm only Edit/Fix protocol, routing, persistence, tests, docs, and the
required lesson changed.
