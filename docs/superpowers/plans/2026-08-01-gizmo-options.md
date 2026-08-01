# Gizmo Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A gizmo can carry 2–5 named options; in the Ring its button expands into one circle per option, exactly the way Summarize expands into Today / Week / Month, and the builder agent (Pi) emits those options on its own when a request has an obvious axis of choice.

**Architecture:** `GizmateTool` gains a persisted `options: [String]` and a per-run `chosenOption: String?` that is deliberately not persisted. `RingBuilder` turns a gizmo with options into an expandable parent whose sub-buttons each run a **copy** of the gizmo with `chosenOption` set — so no handler signature anywhere changes. The chosen value reaches a Python script as the `GIZMO_OPTION` environment variable, and a prompt / agent / native gizmo through `{option}` substituted into its text.

**Tech Stack:** Swift 6 / SwiftPM (macOS 14 target), AppKit + SwiftUI, XCTest. The builder agent sidecar is TypeScript (`ToolAgent/`, pnpm 11.17.0, Node 22.19.0, zod 4.4.3), built with `tsc`.

**Spec:** `docs/superpowers/specs/2026-08-01-gizmo-options-design.md`

## Global Constraints

- `swift build` must be green after every task. Never commit a build you broke.
- Swift tests are XCTest in `Tests/GizmateTests` (app) and `Tests/GizmateToolAgentCoreTests` (protocol). Run one with `swift test --filter <ClassName>`.
- Any change to `ToolAgent/src/*.ts` requires `pnpm --dir ToolAgent build` before the app or the TS tests see it: the app resolves `ToolAgent/dist/<entry>.mjs` first in dev (`ToolAgentRuntimeLocation.resolve`), and `ToolAgent/test/*.ts` imports from `../dist/`.
- **The candidate contract is verified byte for byte.** `ToolAgentModelActionValidator` accepts a candidate by re-encoding it and comparing against exactly what the model sent. A field that is present on one side and absent on the other fails the round trip. Every schema change lands in `ToolAgent/src/protocol.ts` **and** `Sources/GizmateToolAgentCore/ToolAgentModels.swift` in the same task.
- **A key the model had no reason to write must not appear on the way back.** `options` is therefore optional on the wire (`[String]?` in Swift, `.optional()` in zod) and encoded with `encodeIfPresent` — a gizmo with no options keeps the exact fingerprint it had before options existed.
- **Do not add `options` to `ToolsStore.approvalHash(for:)` or `scriptHash(for:)`.** An option is what a gizmo is _handed_ on one run — the same category as the selection or the clipboard, neither of which is hashed. The hash covers what a gizmo _is_. Reasoning in full is in the spec's "Security posture" section.
- House copy rule: never use "translate" / "translation" / "translator" in user-visible strings. Code identifiers are fine.
- Never touch the `com.nugumi.app` bundle ID, `~/Library/Application Support/Nugumi`, `SUFeedURL`, `SUPublicEDKey`, or any other identifier listed under "Identity that must not change" in `CLAUDE.md`.
- **Stage by path. Never `git add -A` or `git add .`.** The maintainer edits this same worktree while you work, so it routinely holds unrelated WIP. Run `git status` and `git diff --cached --stat` before every commit; if the index already holds work you did not stage, `git restore --staged <path>` it, commit yours, then re-stage it.
- The suite in `ToolEvalSuite.all` must never be made to pass by teaching the system prompt a specific answer. Rules go in as generic axes, never as recipes.

---

### Task 1: `GizmateTool` learns what an option is

**Files:**

- Modify: `Sources/Gizmate/Tools/GizmateTool.swift:198-383`
- Test: `Tests/GizmateTests/GizmoOptionsTests.swift` (create)

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `GizmateTool.options: [String]` — persisted, sanitized on every write path.
  - `GizmateTool.chosenOption: String?` — not persisted.
  - `GizmateTool.activeOption: String?` — `chosenOption ?? options.first`.
  - `GizmateTool.resolvingOption(_ template: String) -> String`
  - `static GizmateTool.sanitizedOptions(_ raw: [String]) -> [String]`
  - `GizmateTool.init(..., options: [String] = [], ...)` — new parameter, placed directly after `output:`.

- [ ] **Step 1: Write the failing test**

Create `Tests/GizmateTests/GizmoOptionsTests.swift`:

```swift
import XCTest
@testable import Gizmate

/// `chosenOption` is the one field on a gizmo that belongs to a run rather than
/// to the gizmo. If it ever reached `tool.json`, a gizmo would start remembering
/// the last button pressed — which is not a setting anybody asked for.
final class GizmoOptionsTests: XCTestCase {

    func testOptionsSurviveEncodingAndChosenOptionDoesNot() throws {
        var tool = GizmateTool(name: "Download", options: ["360p", "480p", "720p"])
        tool.chosenOption = "480p"

        let encoded = try JSONEncoder().encode(tool)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("chosenOption") ?? true)

        let decoded = try JSONDecoder().decode(GizmateTool.self, from: encoded)
        XCTAssertEqual(decoded.options, ["360p", "480p", "720p"])
        XCTAssertNil(decoded.chosenOption)
    }

    /// A gizmo saved before options existed decodes as one with none, rather
    /// than throwing away everything else the user configured.
    func testAManifestWithNoOptionsKeyDecodes() throws {
        let json = """
        {"id":"5B9F9F3E-0000-4000-8000-000000000001","name":"Plain","kind":"prompt",\
        "prompt":"Do the thing","symbolName":"sparkles","input":"selection","output":"panel"}
        """
        let decoded = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.options, [])
        XCTAssertNil(decoded.activeOption)
    }

    func testActiveOptionFallsBackToTheFirst() {
        var tool = GizmateTool(name: "Download", options: ["360p", "480p"])
        XCTAssertEqual(tool.activeOption, "360p")
        tool.chosenOption = "480p"
        XCTAssertEqual(tool.activeOption, "480p")
        XCTAssertNil(GizmateTool(name: "Plain").activeOption)
    }

    func testOneOptionIsNoChoiceAndDuplicatesAndOverflowAreDropped() {
        XCTAssertEqual(GizmateTool(name: "One", options: ["720p"]).options, [])
        XCTAssertEqual(GizmateTool(name: "Blank", options: ["720p", "   "]).options, [])
        XCTAssertEqual(
            GizmateTool(name: "Dupes", options: ["720p", " 720p ", "480p"]).options,
            ["720p", "480p"]
        )
        XCTAssertEqual(
            GizmateTool(name: "Many", options: ["a", "b", "c", "d", "e", "f"]).options,
            ["a", "b", "c", "d", "e"]
        )
    }

    func testTemplateSubstitutionOnlyHappensForAGizmoWithOptions() {
        var tool = GizmateTool(name: "Download", options: ["360p", "720p"])
        tool.chosenOption = "720p"
        XCTAssertEqual(tool.resolvingOption("save at {option}"), "save at 720p")
        XCTAssertEqual(
            GizmateTool(name: "Plain").resolvingOption("save at {option}"),
            "save at {option}"
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter GizmoOptionsTests`
Expected: compile failure — `extra argument 'options' in call`, `value of type 'GizmateTool' has no member 'chosenOption'`.

- [ ] **Step 3: Add the two stored properties**

In `Sources/Gizmate/Tools/GizmateTool.swift`, directly after `var output: ToolOutput` (line 206):

```swift
    /// Variants this gizmo offers. In the Ring its button expands into one
    /// circle per option — the same second layer Summarize's time ranges use.
    /// The label IS the value: "720p" is both what the button says and what the
    /// gizmo is handed. Empty for a gizmo that does one thing.
    var options: [String]
    /// Which option this run picked. Deliberately absent from `CodingKeys`: it
    /// belongs to a run, not to the saved gizmo. A gizmo that remembered the
    /// last button pressed would be a setting nobody asked for.
    var chosenOption: String?
```

- [ ] **Step 4: Add the init parameter**

In the same file, add to `init(...)` directly after `output: ToolOutput = .panel,`:

```swift
        options: [String] = [],
```

and in the body, directly after `self.output = output`:

```swift
        self.options = Self.sanitizedOptions(options)
```

- [ ] **Step 5: Teach `Codable` about `options` and nothing about `chosenOption`**

In `private enum CodingKeys`, extend the first line:

```swift
        case id, name, symbolName, kind, input, output, options
```

In `init(from decoder:)`, directly after the `output = ...` assignment:

```swift
        options = Self.sanitizedOptions(
            try c.decodeIfPresent([String].self, forKey: .options) ?? []
        )
```

`chosenOption` gets no `CodingKeys` case, so the synthesized `encode(to:)` skips it and a saved `tool.json` can never carry a stale choice.

- [ ] **Step 6: Add the three accessors**

Directly above `var isUsable: Bool`:

```swift
    /// The option in force for this run: what the Ring picked, or the first one
    /// for a run started from a hotkey or the quick menu, which never offered a
    /// choice. nil for a gizmo with no options.
    var activeOption: String? { chosenOption ?? options.first }

    /// `template` with `{option}` filled in. A gizmo with no options gets its
    /// template back untouched, so an author who typed `{option}` by mistake
    /// sees the literal rather than an empty hole.
    func resolvingOption(_ template: String) -> String {
        guard let activeOption else { return template }
        return template.replacingOccurrences(of: "{option}", with: activeOption)
    }

    /// Trimmed, de-duplicated and capped at five — more than that stops fanning
    /// cleanly at the outer orbit. Fewer than two is dropped entirely: a
    /// one-circle sub-orbit is a worse button than the one it replaced.
    static func sanitizedOptions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        let cleaned = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(5)
        return cleaned.count < 2 ? [] : Array(cleaned)
    }
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter GizmoOptionsTests`
Expected: PASS, 5 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/Gizmate/Tools/GizmateTool.swift Tests/GizmateTests/GizmoOptionsTests.swift
git commit -m "Give a gizmo a list of options and a per-run choice"
```

---

### Task 2: The Ring expands a gizmo with options

**Files:**

- Modify: `Sources/Gizmate/Ring/RingBuilder.swift:69-80`
- Test: `Tests/GizmateTests/GizmoOptionsRingTests.swift` (create)

**Interfaces:**

- Consumes: `GizmateTool.options`, `GizmateTool.chosenOption` (Task 1).
- Produces: nothing new. `RingActionHandlers.tool` keeps its `((GizmateTool) -> Void)?` type, and `runTool(_:selection:)` keeps its signature — that is the point of carrying the choice inside the value.

- [ ] **Step 1: Write the failing test**

Create `Tests/GizmateTests/GizmoOptionsRingTests.swift`:

```swift
import XCTest
@testable import Gizmate

/// A gizmo with options is the second thing in the Ring that expands (Summarize
/// was the first), and the only one that does it from user data. What matters
/// is that picking a circle runs *that* variant — the choice rides inside the
/// value, so nothing between here and the runner had to learn a new parameter.
final class GizmoOptionsRingTests: XCTestCase {

    private func configuration(_ tool: GizmateTool) -> RingConfiguration {
        RingConfiguration(layout: RingLayout(slots: [.tool(tool.id)]), tools: [tool])
    }

    @MainActor
    func testAGizmoWithOptionsBecomesAFannedParent() {
        let tool = GizmateTool(
            name: "Download",
            kind: .python,
            options: ["360p", "480p", "720p"]
        )
        var handlers = RingActionHandlers()
        handlers.tool = { _ in }

        let items = RingBuilder.slots(
            configuration: configuration(tool),
            handlers: handlers,
            dismiss: {}
        )

        let item = items.first ?? nil
        XCTAssertEqual(item?.label, "Download")
        XCTAssertEqual(item?.subLayout, .fan)
        XCTAssertEqual(item?.expandsOnHover, true)
        XCTAssertEqual(item?.subItems.compactMap { $0?.label }, ["360p", "480p", "720p"])
    }

    @MainActor
    func testPickingACircleRunsThatVariantAndDismissesFirst() {
        let tool = GizmateTool(
            name: "Download",
            kind: .python,
            options: ["360p", "480p", "720p"]
        )
        var ran: GizmateTool?
        var dismissedBeforeRun = false
        var dismissed = false
        var handlers = RingActionHandlers()
        handlers.tool = { picked in
            ran = picked
            dismissedBeforeRun = dismissed
        }

        let items = RingBuilder.slots(
            configuration: configuration(tool),
            handlers: handlers,
            dismiss: { dismissed = true }
        )
        items.first??.subItems[1]??.handler()

        XCTAssertEqual(ran?.chosenOption, "480p")
        XCTAssertEqual(ran?.id, tool.id, "the script, approval and stats all key off the id")
        XCTAssertTrue(dismissedBeforeRun, "the ring tears down before the gizmo runs")
    }

    /// The overwhelming majority of gizmos have no options, and they must keep
    /// drawing as one plain button that fires on click.
    @MainActor
    func testAGizmoWithNoOptionsIsStillAPlainButton() {
        let tool = GizmateTool(name: "Slugify", kind: .python)
        var ran: GizmateTool?
        var handlers = RingActionHandlers()
        handlers.tool = { ran = $0 }

        let items = RingBuilder.slots(
            configuration: configuration(tool),
            handlers: handlers,
            dismiss: {}
        )
        let item = items.first ?? nil
        XCTAssertEqual(item?.expandsOnHover, false)
        item?.handler()
        XCTAssertEqual(ran?.id, tool.id)
        XCTAssertNil(ran?.chosenOption)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter GizmoOptionsRingTests`
Expected: FAIL — `testAGizmoWithOptionsBecomesAFannedParent` reports `expandsOnHover` false and no sub-items; the builder still returns a plain button.

- [ ] **Step 3: Build the expandable parent**

In `Sources/Gizmate/Ring/RingBuilder.swift`, replace the body of the `case .tool(let id):` branch (currently lines 69-79) with:

```swift
            case .tool(let id):
                // Every gizmo the user placed stays where they put it, whatever
                // is on the clipboard: a slot that comes and goes is a slot
                // nobody can aim at. A gizmo run without its input says so
                // instead (`ToolRunError.noInput`).
                guard let tool = configuration.tools.first(where: { $0.id == id }),
                      let run = handlers.tool
                else { return nil }
                guard tool.options.isEmpty else {
                    // The choice rides inside the value: a copy with
                    // `chosenOption` set is still the same gizmo by id, so the
                    // script, its approval and its usage count all resolve
                    // exactly as they did before options existed.
                    let subItems: [RingItem?] = tool.options.map { option in
                        RingItem(label: option, image: RingTextBadge.image(option)) {
                            dismiss()
                            var picked = tool
                            picked.chosenOption = option
                            run(picked)
                        }
                    }
                    return RingItem(
                        label: tool.name,
                        image: RingIconKind.symbol(tool.resolvedSymbolName).image(),
                        // Unused, as for any expandable parent — hovering opens
                        // the orbit instead.
                        handler: {},
                        subItems: subItems,
                        subLayout: .fan
                    )
                }
                return RingItem.symbol(tool.resolvedSymbolName, label: tool.name) {
                    dismiss()
                    run(tool)
                }
```

The `let subItems: [RingItem?]` annotation is load-bearing: `RingItem.subItems` is an array of _optionals_, and `map` on `[String]` produces `[RingItem]`, which will not convert implicitly.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter GizmoOptionsRingTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Check the neighbouring ring tests still pass**

Run: `swift test --filter RingFolderTests && swift test --filter RingDefaultLayoutTests && swift test --filter BuiltInOverridesTests`
Expected: PASS. These cover the slot-by-slot arrangement the new branch sits inside.

- [ ] **Step 6: Commit**

```bash
git add Sources/Gizmate/Ring/RingBuilder.swift Tests/GizmateTests/GizmoOptionsRingTests.swift
git commit -m "Expand a gizmo with options into a fanned orbit"
```

---

### Task 3: The chosen option reaches the work

**Files:**

- Modify: `Sources/Gizmate/Tools/ToolRunner.swift:74-105` and `:148-168`
- Modify: `Sources/Gizmate/Panels/TranslationModes.swift:258-272`
- Modify: `Sources/Gizmate/App/GizmateApp+ScriptTools.swift:356`
- Modify: `Sources/Gizmate/Tools/NativeToolRunner.swift:52`
- Test: `Tests/GizmateTests/GizmoOptionsTests.swift` (extend)

**Interfaces:**

- Consumes: `GizmateTool.activeOption`, `GizmateTool.resolvingOption(_:)` (Task 1).
- Produces: the environment variable name `GIZMO_OPTION`, which Task 5 documents to the model.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GizmateTests/GizmoOptionsTests.swift`, inside the class:

```swift
    /// The three text-substituted kinds all go through `resolvingOption`, and
    /// the prompt path is the one a user sees most, so pin it here rather than
    /// only trusting the helper's own test.
    func testAPromptGizmoGetsItsOptionSubstitutedBeforeTheLanguageLine() {
        var tool = GizmateTool(
            name: "Summarise",
            kind: .prompt,
            options: ["short", "long"],
            prompt: "Write a {option} version of the text.",
            appliesTargetLanguage: false
        )
        tool.chosenOption = "long"

        let system = TranslationMode.custom(tool).systemPrompt(
            targetLanguage: TranslationLanguage.language(id: "en"),
            appCategory: .other,
            composition: nil
        )
        XCTAssertTrue(system.contains("Write a long version of the text."))
        XCTAssertFalse(system.contains("{option}"))
    }
```

Note the `init` argument order: `options:` sits directly after `output:`, before `prompt:`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter GizmoOptionsTests/testAPromptGizmoGetsItsOptionSubstitutedBeforeTheLanguageLine`
Expected: FAIL — the system prompt still contains the literal `{option}`.

- [ ] **Step 3: Substitute in the prompt path**

In `Sources/Gizmate/Panels/TranslationModes.swift`, in `customPrompt(_:targetLanguage:composition:)`, replace line 263:

```swift
        var body = tool.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
```

with:

```swift
        var body = tool.resolvingOption(tool.prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
```

- [ ] **Step 4: Substitute in the agent path**

In `Sources/Gizmate/App/GizmateApp+ScriptTools.swift`, in the agent branch, replace:

```swift
        var contextualized = tool
        contextualized.prompt += TranslationMode.contextSections(
```

with:

```swift
        var contextualized = tool
        // Resolved before the context blocks are appended, so `{option}` in the
        // user's own instruction is filled in and `{option}` inside a context
        // block — which is not a template — is left alone.
        contextualized.prompt = tool.resolvingOption(tool.prompt)
        contextualized.prompt += TranslationMode.contextSections(
```

- [ ] **Step 5: Substitute in the native path**

In `Sources/Gizmate/Tools/NativeToolRunner.swift`, replace line 52:

```swift
        let target = tool.target.trimmingCharacters(in: .whitespacesAndNewlines)
```

with:

```swift
        // `{option}` is resolved here, once, so every action below sees a
        // finished target — `openURL` percent-encodes only the `{input}` it
        // substitutes afterwards, and `runShortcut` never substitutes at all.
        let target = tool.resolvingOption(tool.target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
```

- [ ] **Step 6: Hand a Python script its option through the environment**

In `Sources/Gizmate/Tools/ToolRunner.swift`, in `run(tool:script:arguments:uv:deliverOutputs:onOutput:)`, add an argument to the `execute` call directly after `secrets:`:

```swift
                option: tool.activeOption,
```

Then in `private static func execute(...)`, add the parameter after `secrets: [String: String],`:

```swift
        option: String?,
```

and replace the `process.environment` assignment:

```swift
        // Secrets go in the environment, never in argv: argv is readable by any
        // process on the machine via `ps`. On a name collision the runtime wins
        // — `PATH` and `HOME` are legal secret names, and a tool that shadowed
        // either would break uv rather than authenticate anything.
        //
        // The picked option rides the same channel, and for a different reason:
        // a `.files` input already resolves to one argv entry per file, so a
        // trailing argument would be indistinguishable from one more file.
        // `GIZMO_OPTION` is not a secret — it is the user's own visible choice.
        var environment = UVBootstrap.environment().merging(secrets) { runtime, _ in runtime }
        if let option { environment["GIZMO_OPTION"] = option }
        process.environment = environment
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter GizmoOptionsTests`
Expected: PASS, 6 tests.

- [ ] **Step 8: Check nothing that runs a tool regressed**

Run: `swift build && swift test --filter CandidateValidationRunTests && swift test --filter AgentToolTests`
Expected: build succeeds; both suites PASS. `CandidateValidation` calls `ToolRunner.run` too, so a missed argument shows up here.

- [ ] **Step 9: Commit**

```bash
git add Sources/Gizmate/Tools/ToolRunner.swift Sources/Gizmate/Tools/NativeToolRunner.swift \
        Sources/Gizmate/Panels/TranslationModes.swift \
        Sources/Gizmate/App/GizmateApp+ScriptTools.swift \
        Tests/GizmateTests/GizmoOptionsTests.swift
git commit -m "Hand the picked option to the script, prompt and action"
```

---

### Task 4: `options` crosses the builder protocol

**Files:**

- Modify: `ToolAgent/src/protocol.ts:3-29` (LIMITS) and `:73-93` (`commonCandidate`)
- Modify: `Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift:3-23` (limits)
- Modify: `Sources/GizmateToolAgentCore/ToolAgentModels.swift` — `ToolAgentCandidateV1` and `ToolAgentInstalledToolV1`
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift:130-164` and `:469-512`
- Test: `Tests/GizmateToolAgentCoreTests/ToolAgentProtocolTests.swift` (extend)
- Test: `ToolAgent/test/session.test.ts` (extend the test at line 165)

**Interfaces:**

- Consumes: `GizmateTool.options` (Task 1).
- Produces:
  - `ToolAgentCandidateV1.options: [String]?` — init parameter `options: [String]? = nil`, placed after `extensions:`.
  - `ToolAgentInstalledToolV1.options: [String]?` — same position.
  - `ToolAgentProtocolLimitsV1.maximumOptionCount = 5`, `.maximumOptionBytes = 64`.
  - TS `LIMITS.optionBytes = 64`, `LIMITS.optionCount = 5`.

- [ ] **Step 1: Write the failing Swift test**

Append to `Tests/GizmateToolAgentCoreTests/ToolAgentProtocolTests.swift`, inside `final class ToolAgentProtocolTests: XCTestCase` (line 5):

```swift
    /// Options are optional on the wire on purpose: the validator compares a
    /// re-encoded candidate byte for byte against what the model sent, so a
    /// candidate with no options must not grow an `"options":[]` key it never
    /// wrote — that would change the fingerprint of every gizmo built so far.
    func testOptionsAreOmittedWhenAbsentAndRoundTripWhenPresent() throws {
        let plain = try ToolAgentCandidateV1(
            kind: .prompt,
            name: "Plain",
            brief: "Does one thing.",
            symbolName: "sparkles",
            input: .selection,
            output: .panel,
            trigger: .always,
            prompt: "Do the thing."
        )
        let plainJSON = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        XCTAssertFalse(plainJSON.contains("options"))

        let varied = try ToolAgentCandidateV1(
            kind: .prompt,
            name: "Varied",
            brief: "Does it three ways.",
            symbolName: "sparkles",
            input: .selection,
            output: .panel,
            trigger: .always,
            options: ["short", "medium", "long"],
            prompt: "Write a {option} version."
        )
        let decoded = try JSONDecoder().decode(
            ToolAgentCandidateV1.self,
            from: try JSONEncoder().encode(varied)
        )
        XCTAssertEqual(decoded.options, ["short", "medium", "long"])
    }

    /// One option is not a choice, six do not fan cleanly, and a blank circle is
    /// a button with no name. All three are the model's mistake to fix, not
    /// something to quietly repair on the way in.
    func testOptionsOutsideTheAllowedShapeAreRejected() {
        func candidate(_ options: [String]) throws -> ToolAgentCandidateV1 {
            try ToolAgentCandidateV1(
                kind: .prompt,
                name: "Varied",
                brief: "Does it several ways.",
                symbolName: "sparkles",
                input: .selection,
                output: .panel,
                trigger: .always,
                options: options,
                prompt: "Write a {option} version."
            )
        }
        XCTAssertThrowsError(try candidate(["only"]))
        XCTAssertThrowsError(try candidate(["a", "b", "c", "d", "e", "f"]))
        XCTAssertThrowsError(try candidate(["a", ""]))
        XCTAssertThrowsError(try candidate(["a", "a"]))
        XCTAssertThrowsError(try candidate(["a", String(repeating: "x", count: 65)]))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ToolAgentProtocolTests`
Expected: compile failure — `extra argument 'options' in call`.

- [ ] **Step 3: Add the Swift limits**

In `Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift`, inside `enum ToolAgentProtocolLimitsV1`, after `maximumSecretNameBytes`:

```swift
    /// Mirrors LIMITS.optionCount / LIMITS.optionBytes in protocol.ts. Five is
    /// what the outer orbit fans cleanly; two is the smallest real choice.
    public static let maximumOptionCount = 5
    public static let minimumOptionCount = 2
    public static let maximumOptionBytes = 64
```

- [ ] **Step 4: Add the field to `ToolAgentCandidateV1`**

In `Sources/GizmateToolAgentCore/ToolAgentModels.swift`:

Declare it after `public let extensions: [String]`:

```swift
    /// Variants the finished gizmo offers, drawn as a second orbit behind its
    /// Ring button. Optional for the same reason `secretNames` is: the
    /// validator re-encodes a candidate and compares byte for byte, and a plain
    /// array cannot tell `"options":[]` from an absent key. nil is "didn't
    /// say", and a gizmo with no options keeps the fingerprint it always had.
    public let options: [String]?
```

Add to the throwing `init` signature after `extensions: [String] = [],`:

```swift
        options: [String]? = nil,
```

Pass it into the `Self.validate(...)` call (after `extensions: extensions,`):

```swift
            options: options,
```

and assign after `self.extensions = extensions`:

```swift
        self.options = options
```

In `init(from decoder:)`, after the `extensions` line:

```swift
        let options = try container.decodeIfPresent([String].self, forKey: .options)
```

pass `options: options,` into that method's `Self.validate(...)` call as well, and assign `self.options = options` alongside the other properties.

Add `options` to `CodingKeys`.

In `encode(to:)`, after `try container.encode(extensions, forKey: .extensions)`:

```swift
        try container.encodeIfPresent(options, forKey: .options)
```

In `private static func validate(...)`, add the parameter `options: [String]?,` after `extensions: [String],` and this check in the body:

```swift
        if let options {
            var seen = Set<String>()
            guard options.count >= ToolAgentProtocolLimitsV1.minimumOptionCount,
                  options.count <= ToolAgentProtocolLimitsV1.maximumOptionCount,
                  options.allSatisfy({
                      !$0.isEmpty
                          && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumOptionBytes
                          && seen.insert($0).inserted
                  })
            else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        }
```

- [ ] **Step 5: Add the same field to `ToolAgentInstalledToolV1`**

Repeat Step 4's declaration, init parameter, assignment, `CodingKeys` case, `encodeIfPresent`, decode and validation in `ToolAgentInstalledToolV1` (same file, from line 452). Its shape mirrors the candidate's; an edit session that dropped `options` would silently strip them from a gizmo the user only asked to rename.

- [ ] **Step 6: Run the Swift protocol tests**

Run: `swift test --filter ToolAgentProtocolTests`
Expected: PASS.

- [ ] **Step 7: Carry options through the live builder**

In `Sources/Gizmate/App/ToolAgentLiveBuilder.swift`:

In `installedTool(from:script:)`, add after `extensions: [],`:

```swift
            options: tool.options.isEmpty ? nil : tool.options,
```

In `generatedTool(from:)`, add to the `GizmateTool(...)` construction after `output: output,`:

```swift
            options: candidate.options ?? [],
```

`GizmateTool.init` sanitizes, so a candidate that slipped a duplicate past validation still cannot produce a bad Ring.

- [ ] **Step 8: Add the TS limits and schema field**

In `ToolAgent/src/protocol.ts`, inside `LIMITS`, after `secretNameBytes: 64,`:

```typescript
  // Mirrors ToolAgentProtocolLimitsV1.maximumOption*.
  optionBytes: 64,
  optionCount: 5,
```

and in `commonCandidate`, after the `extensions` entry:

```typescript
  // Variants the gizmo offers, drawn as a second orbit behind its Ring button.
  // Optional rather than defaulted to []: the host re-encodes a candidate and
  // compares byte for byte, so a key the model did not write must not appear.
  // `.min(2)` is why this cannot carry a `.default([])` the way secretNames
  // does — one option is not a choice, and an empty default would fail it.
  options: z
    .array(byteString(LIMITS.optionBytes))
    .min(2)
    .max(LIMITS.optionCount)
    .optional(),
```

- [ ] **Step 9: Write the failing TS test**

In `ToolAgent/test/session.test.ts`, inside the test at line 165 ("model action contract accepts every runnable candidate shape and rejects invalid outputs"), append before its closing `});`:

```typescript
assert.doesNotThrow(() =>
  parseModelAction(action({ ...python, options: ["360p", "480p", "720p"] })),
);
assert.throws(
  () => parseModelAction(action({ ...python, options: ["720p"] })),
  /invalid tool arguments/,
);
assert.throws(
  () =>
    parseModelAction(
      action({ ...python, options: ["a", "b", "c", "d", "e", "f"] }),
    ),
  /invalid tool arguments/,
);
assert.throws(
  () => parseModelAction(action({ ...python, options: ["a", "x".repeat(65)] })),
  /invalid tool arguments/,
);
```

- [ ] **Step 10: Build the sidecar and run its tests**

Run: `pnpm --dir ToolAgent test`
Expected: `tsc` succeeds, then all node tests PASS. (The `test` script runs `pnpm build` first; the tests import from `../dist/`, so a stale `dist` is the usual cause of a confusing failure here.)

- [ ] **Step 11: Verify the whole build**

Run: `swift build && swift test --filter ToolAgentProtocolTests && swift test --filter ToolBuildSupervisorTests`
Expected: build succeeds, both suites PASS.

- [ ] **Step 12: Commit**

```bash
git add ToolAgent/src/protocol.ts ToolAgent/test/session.test.ts \
        Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift \
        Sources/GizmateToolAgentCore/ToolAgentModels.swift \
        Sources/Gizmate/App/ToolAgentLiveBuilder.swift \
        Tests/GizmateToolAgentCoreTests/ToolAgentProtocolTests.swift
git commit -m "Carry gizmo options across the builder protocol"
```

`ToolAgent/dist` is not tracked by git — do not try to stage it.

---

### Task 5: Pi learns when to offer options

**Files:**

- Modify: `ToolAgent/src/model-bridge.ts` — the candidate-writing system prompt, in the paragraph beginning "Every candidate also includes schemaVersion 1"
- Modify: `Sources/Gizmate/App/ToolEvalMode.swift:19-31` (`ToolEvalCase`), `:34+` (`ToolEvalSuite.all`), `:312-337` (`assertions`)

**Interfaces:**

- Consumes: `ToolAgentCandidateV1.options` (Task 4), `GIZMO_OPTION` (Task 3).
- Produces: `ToolEvalCase.minimumOptions: Int?`.

- [ ] **Step 1: Add the prompt rule**

In `ToolAgent/src/model-bridge.ts`, directly after the paragraph that begins "Every candidate also includes schemaVersion 1, kind, name, brief, symbolName, input, output, trigger, hosts, and extensions.", insert:

```
When a request has an obvious axis of choice — quality, format, size, length,
style, language — express it as options rather than hardcoding one value or
spending an ask_user question on it. Two to five short labels, and the label is
the value: "720p" is both what the button says and what the tool is handed. The
Ring draws them as a second layer behind the tool's button, so the user picks one
per run. Leave options out entirely when a request names exactly one way to do
the thing.

A Python tool reads the picked option from the environment, not from argv:
os.environ.get("GIZMO_OPTION", "<your default>"). A prompt, agent or native tool
writes {option} wherever the value belongs in its text or target, and the host
substitutes it. Validation runs with the first option, so order them so the
first is the sensible default.
```

Written as an axis, never as a recipe: `CLAUDE.md` forbids making the eval suite pass by teaching the prompt a specific answer, and "for video downloads offer 360p/480p/720p" would be exactly that.

- [ ] **Step 2: Add the eval assertion hook**

In `Sources/Gizmate/App/ToolEvalMode.swift`, add to `struct ToolEvalCase` after `var declaresNetwork: Bool?`:

```swift
    /// How many options the finished gizmo must carry. The point of the case is
    /// that the model reached for options unprompted, so this asserts the count,
    /// not the labels — pinning "360p" would be pinning one right answer.
    var minimumOptions: Int?
```

and in `assertions(_:generated:)`, after the `check("declaresNetwork", ...)` line:

```swift
        if let minimum = testCase.minimumOptions, generated.tool.options.count < minimum {
            failures.append(
                "options: expected at least \(minimum), got \(generated.tool.options.count)"
            )
        }
```

- [ ] **Step 3: Add the eval case**

In `ToolEvalSuite.all`, after the `python-download-youtube` case:

```swift
        ToolEvalCase(
            name: "python-download-youtube-quality",
            request: "скачивать видео с youtube по скопированной ссылке, "
                + "и чтобы я мог выбрать 360p, 480p или 720p",
            kind: .python,
            input: .clipboardURL,
            output: .files,
            minimumOptions: 3
        ),
```

- [ ] **Step 4: Build, then run just this eval case**

Run:

```bash
pnpm --dir ToolAgent build
swift build
Scripts/tool-eval.sh download-youtube-quality
```

Expected: PASS. The case costs real tokens and minutes — it runs the configured model through the real agent.

If it fails, read `.build/tool-eval/report.json`, not the pass/fail line: it holds every candidate the model wrote and the diagnostic it got back. Fix the generic machinery — the schema, the diagnostics, the wording of the axis rule. **Do not add the answer to the prompt.**

- [ ] **Step 5: Confirm the older download case still passes**

Run: `Scripts/tool-eval.sh python-download-youtube`
Expected: PASS with no options — the request names one way to do the thing, and the new rule must not make every gizmo grow buttons.

- [ ] **Step 6: Commit**

```bash
git add ToolAgent/src/model-bridge.ts Sources/Gizmate/App/ToolEvalMode.swift
git commit -m "Teach Pi to offer options on an axis of choice"
```

---

### Task 6: Editing options by hand

**Files:**

- Modify: `Sources/Gizmate/MainWindow/ToolEditor.swift:359-372` (add the section) and near `:504` (add the sub-view)

**Interfaces:**

- Consumes: `GizmateTool.options`, `GizmateTool.sanitizedOptions(_:)` (Task 1).
- Produces: nothing.

- [ ] **Step 1: Add the section to `detailsContent`**

In `Sources/Gizmate/MainWindow/ToolEditor.swift`, directly after the "General" `editorSection` block (which closes at line 371) and before `switch draft.kind {`:

```swift
            editorSection(
                "Options",
                subtitle: "Variants this gizmo offers. The Ring shows them as a "
                    + "second layer behind its button, and the first one is used "
                    + "when you run the gizmo from a shortcut."
            ) {
                optionsEditor
            }
```

Deliberately outside the `switch`: every kind can carry options.

- [ ] **Step 2: Add the sub-view**

Directly above `private func editorSection<Content: View>(` (line 504):

```swift
    /// A plain list of variant labels. Rows are edited in place and sanitized
    /// on the way into the draft, so a blank or duplicate row simply doesn't
    /// become an option rather than becoming a broken button.
    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(draft.options.enumerated()), id: \.offset) { index, option in
                HStack(spacing: 8) {
                    TextField("720p", text: Binding(
                        get: { index < draft.options.count ? draft.options[index] : "" },
                        set: { newValue in
                            guard index < draft.options.count else { return }
                            var edited = draft.options
                            edited[index] = newValue
                            draft.options = edited
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        var edited = draft.options
                        edited.remove(at: index)
                        draft.options = edited
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(option)")
                }
            }
            if draft.options.count < 5 {
                Button {
                    // Two at a time from nothing: one option is not a choice, so
                    // a list that starts at one can never be saved.
                    draft.options += draft.options.isEmpty ? ["", ""] : [""]
                } label: {
                    Label("Add an option", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlowTheme.inkTertiary)
            }
        }
    }
```

**Important:** `draft.options` is assigned raw here, not through `sanitizedOptions` — sanitizing on every keystroke would delete a row the moment it went momentarily blank while being typed into. Sanitizing happens on save, in the next step.

- [ ] **Step 3: Sanitize on save**

In `private func save()` (line 577), directly after the `tool.brief = ...` line and before `bridge.tools.save(tool, ...)`:

```swift
        tool.options = GizmateTool.sanitizedOptions(tool.options)
```

`save()` already trims `name`, `prompt` and `brief` in exactly this spot; options join them rather than getting their own pass.

- [ ] **Step 4: Build and check the editor by hand**

Run: `swift build && (pkill -f 'Gizmate' ; swift run Gizmate)` in the background.

Then, in the app: open the main window → a gizmo's editor → add two options ("360p", "720p") → save → drop the gizmo in a Ring slot → open the Ring → hover the gizmo. Expected: two word circles fan out behind the button, and picking one runs it.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: PASS. This is the last task, so the whole suite is the gate.

- [ ] **Step 6: Commit**

```bash
git add Sources/Gizmate/MainWindow/ToolEditor.swift
git commit -m "Edit a gizmo's options by hand"
```

---

## Verification checklist

After Task 6, all of the following should be true:

- [ ] `swift build` clean, `swift test` green.
- [ ] `pnpm --dir ToolAgent test` green.
- [ ] `Scripts/tool-eval.sh download-youtube` passes both download cases — one with options, one without.
- [ ] A gizmo saved before this change still loads with `options == []` and draws as one plain button.
- [ ] `tool.json` for a gizmo that was just run from the Ring contains no `chosenOption` key.
