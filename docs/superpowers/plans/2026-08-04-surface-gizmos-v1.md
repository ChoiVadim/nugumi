# Surface Gizmos v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A generated gizmo can declare `output: .surface`, carry a layout tree the agent composed from Gizmate's own components, and render rows its script prints into an edge dock — with files draggable out into any macOS app.

**Architecture:** Split by when it runs. At build time the agent writes a `ToolAgentLayoutV1` tree out of a closed four-node vocabulary; it is validated against rows produced by really running the script, then stored on the tool. At run time the host renders those rows through the stored tree in hand-written SwiftUI. No model is involved at render time — a dock opens on pointer hover and there is no LLM call that fits that budget.

**Tech Stack:** Swift 5.9 / SwiftPM, SwiftUI + AppKit, XCTest, Zod (sidecar `ToolAgent/src`), `uv` for script execution.

**Spec:** `docs/superpowers/specs/2026-08-04-surface-gizmos-design.md`

## Global Constraints

- macOS 14 deployment target. No new SwiftPM or npm dependency — everything here is Foundation, SwiftUI, AppKit.
- Bundle identity is frozen: `com.nugumi.app`, `~/Library/Application Support/Nugumi`, `com.nugumi.app.*` defaults keys. Never "finish the rename" (CLAUDE.md, "Identity that must not change").
- One subsystem per file, target under ~400 lines, extensions named `Type+Feature.swift`. Never create `main.swift`.
- `swift build` must be green after every task. Never commit a build broken by your own change.
- UI follows `DESIGN.md`: `FlowTheme` tokens only, 4px spacing grid, no drop shadows, no glass inside glass, buttons on glass are tint-only, overlay scrollers everywhere (`OverlayScrollHost` inside a borderless panel).
- Never write "translate", "translation" or "translator" in user-visible copy (`DESIGN.md` §13). Code identifiers are exempt.
- Stage by path, never `git add -A`. The user edits this worktree concurrently; run `git status` and `git diff --cached --stat` before every commit. `ToolAgent/src/model-bridge.ts` currently holds uncommitted user WIP — check before touching it.
- The eval suite must never be made to pass by teaching the system prompt a specific answer (CLAUDE.md).

---

### Task 1: `.surface` reaches both output enums

**Files:**

- Modify: `Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift:181-212`
- Modify: `Sources/Gizmate/Tools/GizmateTool.swift:190-245`
- Modify: `Sources/Gizmate/MainWindow/ToolEditor.swift:839-848`
- Modify: `Sources/Gizmate/App/ToolEvalMode.swift:199-255` (`resultSweep`)
- Test: `Tests/GizmateTests/ToolProtocolEnumParityTests.swift:71-75`

**Interfaces:**

- Consumes: nothing.
- Produces: `ToolAgentCandidateOutputV1.surface`, `ToolOutput.surface`, `ToolAgentCandidateOutputV1.surfaceDeliverable: Set<ToolAgentCandidateOutputV1>`, `ToolEditorPanel.outputs(for:)` narrowed for `.prompt` and `.agent`.

Only a `.python` gizmo can be a surface: `.native` has no script to print rows, and `.prompt` / `.agent` would put a model call behind every dock reveal.

- [ ] **Step 1: Write the failing test**

Replace `testPromptAndScriptAreOfferedEveryResult` — prompt is no longer unrestricted:

```swift
/// Script is unrestricted. Prompt is not, any more: a surface renders rows a
/// script printed, and a prompt gizmo has no script — it has a model, which
/// cannot run on every pointer hover over a screen edge.
func testOnlyScriptGizmosAreOfferedEveryResult() {
    XCTAssertEqual(ToolEditorPanel.outputs(for: .python), ToolOutput.allCases)
    XCTAssertFalse(ToolEditorPanel.outputs(for: .prompt).contains(.surface))
    XCTAssertFalse(ToolEditorPanel.outputs(for: .agent).contains(.surface))
    XCTAssertFalse(ToolEditorPanel.outputs(for: .native).contains(.surface))
    XCTAssertEqual(
        ToolEditorPanel.outputs(for: .prompt),
        ToolOutput.allCases.filter { $0 != .surface }
    )
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter ToolProtocolEnumParityTests 2>&1 | tail -20
```

Expected: `ToolOutput.surface` does not compile — "type 'ToolOutput' has no member 'surface'".

- [ ] **Step 3: Add the case to the protocol enum**

In `ToolAgentProtocolTypes.swift`, inside `ToolAgentCandidateOutputV1`:

```swift
    /// Not a result at all: the gizmo renders rows its script prints into an
    /// edge dock, and keeps doing so with no run to speak of. The only output
    /// whose tool is never "finished".
    case surface
```

Then, beside `nativeDeliverable` / `agentDeliverable`:

```swift
    /// A surface needs a script to print rows and no model in the render path,
    /// which is `.python` and nothing else. Written as its own set rather than
    /// a subtraction so the reason lives next to the rule.
    public static let surfaceDeliverable: Set<ToolAgentCandidateOutputV1> = [.surface]
```

Remove `.surface` from `agentDeliverable` by narrowing its subtraction:

```swift
    public static let agentDeliverable: Set<ToolAgentCandidateOutputV1> =
        Set(ToolAgentCandidateOutputV1.allCases).subtracting([.files, .surface])
```

`nativeDeliverable` is an explicit list and already excludes it — leave it alone.

- [ ] **Step 4: Add the case to the app enum**

In `GizmateTool.swift`, `ToolOutput`:

```swift
    case surface
```

and in its `displayName` / `explanation` switches:

```swift
        case .surface: return "Screen edge"
```

```swift
        case .surface:
            return "Sits on a screen edge showing whatever the script lists, "
                + "with files you can drag straight into another app."
```

- [ ] **Step 5: Narrow the editor**

In `ToolEditor.swift:839`:

```swift
    static func outputs(for kind: ToolKind) -> [ToolOutput] {
        switch kind {
        case .python:
            return ToolOutput.allCases
        // A surface renders rows a script printed. A prompt gizmo has a model
        // where the script would be, and a dock reveal cannot wait for one.
        case .prompt:
            return ToolOutput.allCases.filter { $0 != .surface }
        case .native:
            return deliverable(ToolAgentCandidateOutputV1.nativeDeliverable)
        case .agent:
            return deliverable(ToolAgentCandidateOutputV1.agentDeliverable)
        }
    }
```

- [ ] **Step 6: Fix the prompt-pairing test that now over-reaches**

`testEveryPromptPairingTheEditorOffersPassesCandidateValidation` loops `ToolEditorPanel.outputs(for: .prompt)`, which no longer contains `.surface` — it needs no edit. Confirm by running.

- [ ] **Step 7: Add the eval case the new result now owes**

`testTheEvalSuiteAsksForEveryInputAndEveryResult` fails the moment an output exists with no eval case asking for it. That guardrail is the point, so the case lands with the enum rather than eight tasks later. It is one literal and needs nothing else in this plan to compile.

Add to `ToolEvalSuite.resultSweep` in `Sources/Gizmate/App/ToolEvalMode.swift`, written the way a user would type it:

```swift
        ToolEvalCase(
            name: "result-surface-downloads",
            request: "хочу видеть свои загрузки сбоку экрана, "
                + "чтобы перетаскивать файлы оттуда в другие приложения",
            kind: .python,
            input: .none,
            output: .surface
        ),
```

Do **not** run `Scripts/tool-eval.sh` yet — the agent has not been told the vocabulary and nothing renders a surface until Task 9. Task 10 runs it.

- [ ] **Step 8: Run the tests**

```sh
swift test --filter ToolProtocolEnumParityTests 2>&1 | tail -20
```

Expected: all pass, including `testTheEvalSuiteAsksForEveryInputAndEveryResult`.

- [ ] **Step 9: Commit**

```sh
git add Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift \
        Sources/Gizmate/Tools/GizmateTool.swift \
        Sources/Gizmate/MainWindow/ToolEditor.swift \
        Sources/Gizmate/App/ToolEvalMode.swift \
        Tests/GizmateTests/ToolProtocolEnumParityTests.swift
git commit -m "Let a result mean the screen edge"
```

---

### Task 2: The layout tree type

**Files:**

- Create: `Sources/GizmateToolAgentCore/ToolAgentLayoutV1.swift`
- Test: `Tests/GizmateToolAgentCoreTests/ToolAgentLayoutTests.swift`

**Interfaces:**

- Consumes: `ToolAgentFailureCodeV1.invalidProtocol`, `ToolAgentDynamicCodingKeyV1` (both in `GizmateToolAgentCore`).
- Produces:
  - `public indirect enum ToolAgentLayoutV1: Codable, Equatable, Sendable` with cases `grid(cell:minimumWidth:empty:)`, `list(row:empty:)`, `card(title:subtitle:icon:drag:tap:)`, `text(ToolAgentLayoutBindingV1)`
  - `public enum ToolAgentLayoutBindingV1 { case key(String), literal(String) }`
  - `public enum ToolAgentLayoutIconV1 { case file(key: String), symbol(String) }`
  - `public enum ToolAgentLayoutDragV1 { case file(key: String), text(key: String) }`
  - `public enum ToolAgentLayoutTapV1 { case open(key: String), reveal(key: String) }`
  - `public var referencedKeys: Set<String>` and `public var fileKeys: Set<String>` on `ToolAgentLayoutV1`
  - `public static let maximumDepth = 3`

**Wire format.** Nodes are tagged objects with a `node` discriminator. Modifiers are short prefixed strings, not nested objects — the model writes this JSON by hand and `"drag": "file:$path"` survives that far better than a third level of nesting. This is a two-token grammar, not an expression language: prefix, then a binding.

```json
{
  "node": "grid",
  "minimumWidth": 96,
  "empty": "Nothing in Downloads",
  "cell": {
    "node": "card",
    "title": "$name",
    "subtitle": "$size",
    "icon": "file:$path",
    "drag": "file:$path",
    "tap": "reveal:$path"
  }
}
```

A binding is `"$key"`; anything else is a literal. Prefixes: `icon` takes `file:` or `symbol:`, `drag` takes `file:` or `text:`, `tap` takes `open:` or `reveal:`. `file:`, `text:`, `open:` and `reveal:` require a `$key`; `symbol:` takes a literal glyph name.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import GizmateToolAgentCore

final class ToolAgentLayoutTests: XCTestCase {
    private let folderHub = """
    {"node":"grid","minimumWidth":96,"empty":"Nothing in Downloads",
     "cell":{"node":"card","title":"$name","subtitle":"$size",
             "icon":"file:$path","drag":"file:$path","tap":"reveal:$path"}}
    """

    func testTheFolderHubDecodesAndReEncodes() throws {
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(folderHub.utf8))
        guard case let .grid(cell, minimumWidth, empty) = layout else {
            return XCTFail("expected a grid")
        }
        XCTAssertEqual(minimumWidth, 96)
        XCTAssertEqual(empty, "Nothing in Downloads")
        guard case let .card(title, subtitle, icon, drag, tap) = cell else {
            return XCTFail("expected a card")
        }
        XCTAssertEqual(title, .key("name"))
        XCTAssertEqual(subtitle, .key("size"))
        XCTAssertEqual(icon, .file(key: "path"))
        XCTAssertEqual(drag, .file(key: "path"))
        XCTAssertEqual(tap, .reveal(key: "path"))

        let round = try JSONDecoder().decode(
            ToolAgentLayoutV1.self,
            from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(round, layout)
    }

    func testKeysTheLayoutReferences() throws {
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(folderHub.utf8))
        XCTAssertEqual(layout.referencedKeys, ["name", "size", "path"])
        XCTAssertEqual(layout.fileKeys, ["path"])
    }

    func testALiteralTitleIsNotAKey() throws {
        let json = #"{"node":"text","value":"Downloads"}"#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        XCTAssertEqual(layout, .text(.literal("Downloads")))
        XCTAssertEqual(layout.referencedKeys, [])
    }

    /// Strict keys, the same contract `ToolAgentAskUserRequestV1` holds: a
    /// field the model invented is a misunderstanding, not a nicety to ignore.
    func testAnUnknownKeyIsRejected() {
        let json = #"{"node":"text","value":"x","colour":"red"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    func testAnUnknownNodeIsRejected() {
        let json = #"{"node":"webview","url":"https://example.com"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    func testAnUnknownModifierPrefixIsRejected() {
        let json = #"{"node":"card","title":"$n","drag":"folder:$path"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    /// A modifier that acts on a file needs a key to read the path out of, so a
    /// literal there is a candidate that would draw a card nothing can drag.
    func testAFileModifierWithoutAKeyIsRejected() {
        let json = #"{"node":"card","title":"$n","drag":"file:Downloads"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    func testNestingDeeperThanThreeIsRejected() {
        let deep = #"{"node":"grid","minimumWidth":96,"empty":"","cell":"#
            + #"{"node":"list","empty":"","row":"#
            + #"{"node":"list","empty":"","row":{"node":"text","value":"x"}}}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(deep.utf8))
        )
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter ToolAgentLayoutTests 2>&1 | tail -20
```

Expected: "cannot find 'ToolAgentLayoutV1' in scope".

- [ ] **Step 3: Write the type**

`Sources/GizmateToolAgentCore/ToolAgentLayoutV1.swift`. Follow the strict-key decoding pattern `ToolAgentAskUserRequestV1` uses in `ToolAgentProtocolTypes.swift:102`: read `container.allKeys`, compare the set, throw `.invalidProtocol` on anything unexpected.

```swift
import Foundation

/// What a surface gizmo draws, composed by the agent out of components Gizmate
/// ships and nothing else.
///
/// Four nodes. `grid` and `list` repeat their child once per row of data;
/// `card` and `text` are leaves. There is deliberately no node for an empty
/// state — only a repeater can have zero children, so the copy is its
/// property, and a sibling node could never be reached anyway.
public indirect enum ToolAgentLayoutV1: Equatable, Sendable {
    case grid(cell: ToolAgentLayoutV1, minimumWidth: Int, empty: String)
    case list(row: ToolAgentLayoutV1, empty: String)
    case card(
        title: ToolAgentLayoutBindingV1,
        subtitle: ToolAgentLayoutBindingV1?,
        icon: ToolAgentLayoutIconV1?,
        drag: ToolAgentLayoutDragV1?,
        tap: ToolAgentLayoutTapV1?
    )
    case text(ToolAgentLayoutBindingV1)

    /// A surface is a strip on a screen edge, not a document.
    public static let maximumDepth = 3
    public static let minimumGridWidth = 48
    public static let maximumGridWidth = 400
    public static let maximumEmptyBytes = 120

    /// Every row key the tree reads. `CandidateValidation` checks these against
    /// keys the script really printed, so a binding that names nothing is
    /// refused before the user ever docks the gizmo.
    public var referencedKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.referencedKeys
        case let .list(row, _): return row.referencedKeys
        case let .card(title, subtitle, icon, drag, tap):
            var keys = title.key.map { Set([$0]) } ?? []
            subtitle?.key.map { keys.insert($0) }
            icon?.key.map { keys.insert($0) }
            drag?.key.map { keys.insert($0) }
            tap?.key.map { keys.insert($0) }
            return keys
        case let .text(binding): return binding.key.map { Set([$0]) } ?? []
        }
    }

    /// The subset of `referencedKeys` that has to hold a file URL.
    public var fileKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.fileKeys
        case let .list(row, _): return row.fileKeys
        case let .card(_, _, icon, drag, tap):
            var keys: Set<String> = []
            if case let .file(key) = icon { keys.insert(key) }
            if case let .file(key) = drag { keys.insert(key) }
            if let tap { keys.insert(tap.key) }
            return keys
        case .text: return []
        }
    }

    public var isRepeater: Bool {
        switch self {
        case .grid, .list: return true
        case .card, .text: return false
        }
    }
}

public enum ToolAgentLayoutBindingV1: Equatable, Sendable {
    case key(String)
    case literal(String)

    public var key: String? {
        if case let .key(name) = self { return name }
        return nil
    }

    /// `"$name"` is a key, anything else is the text itself. `"$"` alone is
    /// neither and throws.
    public init(wire: String) throws {
        guard wire.hasPrefix("$") else {
            self = .literal(wire)
            return
        }
        let name = String(wire.dropFirst())
        guard !name.isEmpty else { throw ToolAgentFailureCodeV1.invalidProtocol }
        self = .key(name)
    }

    public var wire: String {
        switch self {
        case let .key(name): return "$" + name
        case let .literal(text): return text
        }
    }
}
```

`ToolAgentLayoutIconV1`, `ToolAgentLayoutDragV1` and `ToolAgentLayoutTapV1` follow the same `init(wire:)` / `var wire` shape, splitting on the first `:` and requiring a `$key` for every prefix but `symbol:`. Each exposes `var key: String?` (`ToolAgentLayoutTapV1.key` is non-optional — both its cases take one).

`Codable` is written by hand on `ToolAgentLayoutV1`: decode `node`, switch on it, assert the exact key set for that node, and recurse with a depth counter carried in `decoder.userInfo` under a private `CodingUserInfoKey`. Throw `ToolAgentFailureCodeV1.invalidProtocol` for an unknown node, an unexpected key, a `minimumWidth` outside `48...400`, an `empty` string over 120 bytes, or a depth over 3.

- [ ] **Step 4: Run the tests**

```sh
swift test --filter ToolAgentLayoutTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add Sources/GizmateToolAgentCore/ToolAgentLayoutV1.swift \
        Tests/GizmateToolAgentCoreTests/ToolAgentLayoutTests.swift
git commit -m "Give a surface four nodes to be built out of"
```

---

### Task 3: The candidate carries a layout

**Files:**

- Modify: `Sources/GizmateToolAgentCore/ToolAgentModels.swift:17-57` (fields), its `init`, `CodingKeys` and `validate`
- Modify: `ToolAgent/src/protocol.ts` (the `output` z.enum at lines 91, 178, 256, 325; the python candidate object)
- Modify: `ToolAgent/src/tools.ts:47,120`
- Test: `Tests/GizmateToolAgentCoreTests/ToolAgentProtocolTests.swift`

**Interfaces:**

- Consumes: `ToolAgentLayoutV1` (Task 2), `ToolAgentCandidateOutputV1.surface` (Task 1).
- Produces: `ToolAgentCandidateV1.layout: ToolAgentLayoutV1?`, and the rule that it is present iff `output == .surface`.

**Critical:** `ToolAgentModelActionValidator` accepts a candidate by re-encoding it and comparing byte for byte against what the model sent. `layout` must therefore be a true `Optional` that encodes to an absent key when `nil` — the same reasoning `options` and `secretNames` carry in their doc comments. Never give it a default value.

- [ ] **Step 1: Write the failing test**

```swift
func testASurfaceCandidateMustCarryALayout() {
    XCTAssertThrowsError(try ToolAgentCandidateV1(
        kind: .python, name: "Downloads", brief: "Shows my downloads.",
        symbolName: "tray", input: .none, output: .surface, trigger: .always,
        source: "print('{\"rows\":[]}')"
    ))
}

func testALayoutOnANonSurfaceCandidateIsRejected() {
    XCTAssertThrowsError(try ToolAgentCandidateV1(
        kind: .python, name: "Slug", brief: "Slugifies.", symbolName: "link",
        input: .selection, output: .clipboard, trigger: .selection,
        source: "print('x')", layout: .text(.literal("x"))
    ))
}

func testOnlyAScriptCanBeASurface() {
    for kind in [ToolAgentCandidateKindV1.prompt, .native, .agent] {
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: kind, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .none, output: .surface,
            trigger: .always, prompt: "list files",
            layout: .text(.literal("x"))
        ), "\(kind.rawValue) has no script to print rows")
    }
}

/// A surface is never handed anything and is never conditional — it is on an
/// edge, showing what it shows.
func testASurfaceTakesNoInputAndAlwaysApplies() {
    XCTAssertThrowsError(try ToolAgentCandidateV1(
        kind: .python, name: "Downloads", brief: "Shows my downloads.",
        symbolName: "tray", input: .selection, output: .surface,
        trigger: .always, source: "print('{}')",
        layout: .text(.literal("x"))
    ))
    XCTAssertThrowsError(try ToolAgentCandidateV1(
        kind: .python, name: "Downloads", brief: "Shows my downloads.",
        symbolName: "tray", input: .none, output: .surface,
        trigger: .files, source: "print('{}')",
        layout: .text(.literal("x"))
    ))
}

/// The root has to repeat, or there is nowhere for rows to go.
func testASurfaceLayoutRootMustBeARepeater() {
    XCTAssertThrowsError(try ToolAgentCandidateV1(
        kind: .python, name: "Downloads", brief: "Shows my downloads.",
        symbolName: "tray", input: .none, output: .surface, trigger: .always,
        source: "print('{}')", layout: .text(.key("name"))
    ))
}

func testTheFolderHubCandidateIsAccepted() throws {
    XCTAssertNoThrow(try ToolAgentCandidateV1(
        kind: .python, name: "Downloads", brief: "Shows my downloads.",
        symbolName: "tray", input: .none, output: .surface, trigger: .always,
        source: "print('{\"rows\":[]}')",
        layout: .grid(
            cell: .card(title: .key("name"), subtitle: .key("size"),
                        icon: .file(key: "path"), drag: .file(key: "path"),
                        tap: .reveal(key: "path")),
            minimumWidth: 96,
            empty: "Nothing in Downloads"
        )
    ))
}

/// nil must not survive as an empty key, or the byte-for-byte re-encode in
/// `ToolAgentModelActionValidator` rejects every candidate that has no layout.
func testACandidateWithoutALayoutEncodesNoLayoutKey() throws {
    let candidate = try ToolAgentCandidateV1(
        kind: .python, name: "Slug", brief: "Slugifies.", symbolName: "link",
        input: .selection, output: .clipboard, trigger: .selection,
        source: "print('x')"
    )
    let json = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(candidate)
    ) as? [String: Any]
    XCTAssertNil(json?["layout"])
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter ToolAgentProtocolTests 2>&1 | tail -20
```

Expected: "extra argument 'layout' in call".

- [ ] **Step 3: Add the field and the rules**

Add to `ToolAgentCandidateV1`, beside `secretNames`:

```swift
    /// What a surface gizmo draws. Present exactly when `output == .surface`.
    ///
    /// Optional for the same reason `options` and `secretNames` are: the
    /// validator re-encodes a candidate and compares byte for byte, and an
    /// absent key must stay absent on the way back.
    public let layout: ToolAgentLayoutV1?
```

Add `layout: ToolAgentLayoutV1? = nil` to `init` (last parameter, so no call site moves), assign it, add it to `CodingKeys`, and add to `validate`:

```swift
        if output == .surface {
            guard kind == .python else { throw ToolAgentFailureCodeV1.invalidCandidate }
            guard input == .none, trigger == .always else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
            guard let layout, layout.isRepeater else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        } else if layout != nil {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }
```

- [ ] **Step 4: Mirror it in the sidecar**

In `ToolAgent/src/protocol.ts`, add `"surface"` to the `output` enums at lines 91 and 256 (the full lists) and **not** to 178 and 325 (the narrowed native lists — check each before editing; the comment above each says which it is). Add to the python candidate object only:

```ts
const layoutNode: z.ZodType<unknown> = z.lazy(() =>
  z.discriminatedUnion("node", [
    z
      .object({
        node: z.literal("grid"),
        cell: layoutNode,
        minimumWidth: z.number().int().min(48).max(400),
        empty: byteString(LIMITS.layoutEmptyBytes),
      })
      .strict(),
    z
      .object({
        node: z.literal("list"),
        row: layoutNode,
        empty: byteString(LIMITS.layoutEmptyBytes),
      })
      .strict(),
    z
      .object({
        node: z.literal("card"),
        title: z.string(),
        subtitle: z.string().optional(),
        icon: z
          .string()
          .regex(/^(file:\$|symbol:)/)
          .optional(),
        drag: z
          .string()
          .regex(/^(file|text):\$/)
          .optional(),
        tap: z
          .string()
          .regex(/^(open|reveal):\$/)
          .optional(),
      })
      .strict(),
    z.object({ node: z.literal("text"), value: z.string() }).strict(),
  ]),
);
```

and `layout: layoutNode.optional()` on the python candidate. Add `layoutEmptyBytes: 120` to `LIMITS`, mirroring `ToolAgentLayoutV1.maximumEmptyBytes`. In `tools.ts:47,120`, add `Type.Literal("surface")` to the output literal unions.

Build the sidecar:

```sh
cd ToolAgent && pnpm build && pnpm test 2>&1 | tail -20
```

- [ ] **Step 5: Run the Swift tests**

```sh
swift test --filter ToolAgentProtocolTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 6: Commit**

```sh
git status --short   # confirm model-bridge.ts WIP is untouched
git add Sources/GizmateToolAgentCore/ToolAgentModels.swift \
        Tests/GizmateToolAgentCoreTests/ToolAgentProtocolTests.swift \
        ToolAgent/src/protocol.ts ToolAgent/src/tools.ts
git commit -m "Make a surface candidate carry the thing it draws"
```

---

### Task 4: The saved gizmo remembers its layout

**Files:**

- Modify: `Sources/Gizmate/Tools/GizmateTool.swift:254-450` (field, `CodingKeys`, decoder, `isUsable`)
- Modify: `Sources/Gizmate/App/ToolAgentLiveBuilder.swift` (both directions of the conversion)
- Test: `Tests/GizmateTests/ToolsStoreTests.swift`

**Interfaces:**

- Consumes: `ToolAgentLayoutV1` (Task 2), `ToolAgentCandidateV1.layout` (Task 3).
- Produces: `GizmateTool.layout: ToolAgentLayoutV1?`, surviving a save/load round trip and the builder round trip.

`GizmateTool` decodes leniently — an unknown value falls back rather than throwing, so one bad field cannot wipe a user's whole tool list. A layout that fails to decode must leave the rest of the tool intact and come back `nil`.

- [ ] **Step 1: Write the failing test**

```swift
func testASurfaceGizmoKeepsItsLayoutAcrossASaveAndLoad() throws {
    let layout = ToolAgentLayoutV1.grid(
        cell: .card(title: .key("name"), subtitle: nil, icon: .file(key: "path"),
                    drag: .file(key: "path"), tap: .reveal(key: "path")),
        minimumWidth: 96, empty: "Nothing here"
    )
    var tool = GizmateTool.empty()
    tool.name = "Downloads"
    tool.kind = .python
    tool.input = .none
    tool.output = .surface
    tool.layout = layout

    let reloaded = try JSONDecoder().decode(
        GizmateTool.self, from: JSONEncoder().encode(tool)
    )
    XCTAssertEqual(reloaded.layout, layout)
    XCTAssertEqual(reloaded.output, .surface)
}

/// Lenient, like every other field here: a layout this version cannot read
/// must not take the gizmo's name, script and secrets down with it.
func testAnUnreadableLayoutLeavesTheRestOfTheGizmoIntact() throws {
    let json = #"{"id":"\#(UUID().uuidString)","name":"Downloads","kind":"python","#
        + #""input":"none","output":"surface","layout":{"node":"webview"},"#
        + #""prompt":"","target":"","brief":"","symbolName":"tray","#
        + #""timeoutSeconds":120,"createdAt":0}"#
    let tool = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
    XCTAssertEqual(tool.name, "Downloads")
    XCTAssertNil(tool.layout)
}

/// A surface with no layout cannot draw. `isUsable` is what keeps it out of
/// the dock catalog rather than a crash at render time.
func testASurfaceWithoutALayoutIsNotUsable() {
    var tool = GizmateTool.empty()
    tool.kind = .python
    tool.output = .surface
    tool.layout = nil
    XCTAssertFalse(tool.isUsable)
}
```

If `GizmateTool.empty()` does not exist, use whatever the existing tests in `ToolsStoreTests.swift` use to build a tool and match it.

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter ToolsStoreTests 2>&1 | tail -20
```

Expected: "value of type 'GizmateTool' has no member 'layout'".

- [ ] **Step 3: Add the field**

```swift
    /// What a `.surface` gizmo draws. nil for every other result.
    var layout: ToolAgentLayoutV1?
```

Add `case layout` to `CodingKeys`. In the custom decoder, decode it leniently:

```swift
        // Lenient for the same reason the rest of this initialiser is: a
        // layout written by a newer build must cost the user this gizmo's
        // surface, not the gizmo.
        layout = try? c.decodeIfPresent(ToolAgentLayoutV1.self, forKey: .layout)
```

Extend `isUsable`:

```swift
        if output == .surface, layout == nil { return false }
```

In `ToolAgentLiveBuilder`, carry `layout` both ways alongside `output` — candidate → tool and tool → candidate.

- [ ] **Step 4: Run the tests**

```sh
swift test --filter "ToolsStoreTests|ToolAgentLiveBuilderTests" 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/Tools/GizmateTool.swift \
        Sources/Gizmate/App/ToolAgentLiveBuilder.swift \
        Tests/GizmateTests/ToolsStoreTests.swift
git commit -m "Persist what a surface gizmo draws"
```

---

### Task 5: Rows out of a script's stdout

**Files:**

- Create: `Sources/Gizmate/Dock/Surface/SurfaceRows.swift`
- Test: `Tests/GizmateTests/SurfaceRowsTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `struct SurfaceRow: Equatable { let id: String; let values: [String: String]; subscript(key: String) -> String? }`
  - `enum SurfaceRows { static func decode(stdout: String) throws -> [SurfaceRow] }`
  - `enum SurfaceRowsError: LocalizedError { case notJSON, missingRows, tooMany, valueTooLong }`
  - `SurfaceRows.maximumRows = 500`, `maximumKeysPerRow = 32`, `maximumValueBytes = 1024`, `maximumStdoutBytes = 262_144`

A row is a flat dictionary of strings. A non-string value is coerced with `String(describing:)` for numbers and booleans and rejected for arrays and objects — a script printing `{"size": 4096}` is being reasonable, one printing `{"tags": [...]}` is not, and the difference matters because bindings render one string.

- [ ] **Step 1: Write the failing test**

```swift
final class SurfaceRowsTests: XCTestCase {
    func testItReadsTheRowsAScriptPrinted() throws {
        let rows = try SurfaceRows.decode(stdout: #"""
        {"rows":[{"id":"1","name":"cv.pdf","path":"/tmp/cv.pdf"}]}
        """#)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "1")
        XCTAssertEqual(rows[0]["name"], "cv.pdf")
    }

    /// A script that printed a log line before its JSON is doing something
    /// reasonable, and failing it would send the model repairing a tool that
    /// works. The last line that parses wins.
    func testChatterBeforeTheJSONIsIgnored() throws {
        let rows = try SurfaceRows.decode(stdout: """
        scanning ~/Downloads
        {"rows":[{"id":"1","name":"a.txt"}]}
        """)
        XCTAssertEqual(rows.count, 1)
    }

    func testNumbersBecomeStrings() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","size":4096}]}"#)
        XCTAssertEqual(rows[0]["size"], "4096")
    }

    func testNestedValuesAreRejected() {
        XCTAssertThrowsError(
            try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","tags":["a"]}]}"#)
        )
    }

    /// No id means nothing survives a refresh — rows would reshuffle under the
    /// pointer. The index is a fair fallback and cheaper than failing the tool.
    func testAMissingIdFallsBackToThePosition() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"name":"a"},{"name":"b"}]}"#)
        XCTAssertEqual(rows.map(\.id), ["0", "1"])
    }

    func testEmptyRowsAreFine() throws {
        XCTAssertEqual(try SurfaceRows.decode(stdout: #"{"rows":[]}"#), [])
    }

    func testTextThatIsNotJSONFails() {
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: "Traceback (most recent call last):"))
    }

    func testMoreThanFiveHundredRowsFails() {
        let many = (0..<501).map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: #"{"rows":[\#(many)]}"#))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter SurfaceRowsTests 2>&1 | tail -20
```

Expected: "cannot find 'SurfaceRows' in scope".

- [ ] **Step 3: Write the decoder**

Walk the stdout lines from the last to the first, trying `JSONSerialization` on each; take the first that parses to a dictionary with a `rows` array. Enforce the four limits, coerce `NSNumber` via `String(describing:)`, reject arrays and dictionaries, fall back to the index for a missing `id`.

- [ ] **Step 4: Run the tests**

```sh
swift test --filter SurfaceRowsTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/Dock/Surface/SurfaceRows.swift \
        Tests/GizmateTests/SurfaceRowsTests.swift
git commit -m "Read the rows a surface script printed"
```

---

### Task 6: The components

**Files:**

- Create: `Sources/Gizmate/Dock/Surface/SurfaceView.swift`
- Create: `Sources/Gizmate/Dock/Surface/SurfaceCard.swift`
- Test: `Tests/GizmateTests/SurfaceBindingTests.swift`

**Interfaces:**

- Consumes: `SurfaceRow` (Task 5), `ToolAgentLayoutV1` (Task 2), `FlowTheme`, `OverlayScrollHost`, `RingIconKind`.
- Produces:
  - `struct SurfaceView: View { let layout: ToolAgentLayoutV1; let rows: [SurfaceRow]; let isStale: Bool }`
  - `struct SurfaceCard: View`
  - `enum SurfaceBinding { static func resolve(_ binding: ToolAgentLayoutBindingV1, in row: SurfaceRow) -> String }`

The pure part — resolving a binding against a row — is what gets tested. SwiftUI views are not snapshot-tested here; the project has no snapshot harness and adding one for four views is not worth it.

Per `DESIGN.md` §12, reuse before variants: the grid uses the same `GridItem(.adaptive(minimum:))` shape `NotesGrid` uses, and the scroll host is `OverlayScrollHost` because this renders inside a borderless panel where AppKit reverts a set-by-property overlay scroller.

- [ ] **Step 1: Write the failing test**

```swift
final class SurfaceBindingTests: XCTestCase {
    private let row = SurfaceRow(id: "1", values: ["name": "cv.pdf", "size": "4 KB"])

    func testAKeyResolvesToItsValue() {
        XCTAssertEqual(SurfaceBinding.resolve(.key("name"), in: row), "cv.pdf")
    }

    func testALiteralIsItself() {
        XCTAssertEqual(SurfaceBinding.resolve(.literal("Downloads"), in: row), "Downloads")
    }

    /// Validation rejects a layout naming a key the rows do not have, so this
    /// is only reachable when a script's output changed after the tool was
    /// built. Empty, not "nil" or a crash: a card missing its subtitle should
    /// lose the line, not the card.
    func testAMissingKeyResolvesToNothing() {
        XCTAssertEqual(SurfaceBinding.resolve(.key("author"), in: row), "")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter SurfaceBindingTests 2>&1 | tail -20
```

Expected: "cannot find 'SurfaceBinding' in scope".

- [ ] **Step 3: Write the views**

`SurfaceCard` — icon over title over optional subtitle, `FlowTheme.ink` / `FlowTheme.inkSecondary`, 12px and 11px, `FlowTheme.subtleFill` behind a `RoundedRectangle(cornerRadius: 10, style: .continuous)`. No shadow (`DESIGN.md` §7).

Drag, when the layout declares one:

```swift
    .onDrag {
        // A real file URL, so the drop lands as a file in Finder, Slack or
        // anything else — this is the whole point of a surface, and it is
        // native-only: no web view can hand a file to another app.
        NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
    }
```

Tap:

```swift
    .onTapGesture {
        switch tap {
        case .open: NSWorkspace.shared.open(url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
```

Icons: `.file(key)` → `NSWorkspace.shared.icon(forFile: path)`, which is the icon Finder shows including document thumbnails; `.symbol(name)` → `RingIconKind.phosphor(name).image(pointSize:)` so a surface cannot draw art the ring cannot.

`SurfaceView` switches on the node, renders the repeater's `empty` copy centred in `FlowTheme.inkSecondary` when `rows.isEmpty`, and wraps everything in `OverlayScrollHost`. When `isStale`, put a single `FlowTheme.inkTertiary` caption at the bottom: `"Couldn't refresh — showing what was here last."`

- [ ] **Step 4: Run the tests and build**

```sh
swift test --filter SurfaceBindingTests 2>&1 | tail -20 && swift build 2>&1 | tail -5
```

Expected: tests pass, build clean.

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/Dock/Surface/ Tests/GizmateTests/SurfaceBindingTests.swift
git commit -m "Draw a surface out of Gizmate's own parts"
```

---

### Task 7: The rows cache

**Files:**

- Create: `Sources/Gizmate/Dock/Surface/SurfaceRowsCache.swift`
- Test: `Tests/GizmateTests/SurfaceRowsCacheTests.swift`

**Interfaces:**

- Consumes: `SurfaceRow` (Task 5), `GizmatePaths`.
- Produces: `@MainActor final class SurfaceRowsCache { init(directory: URL = GizmatePaths.cache); func rows(for id: UUID) -> [SurfaceRow]; func store(_ rows: [SurfaceRow], for id: UUID) }`

Injectable directory so tests run against a scratch path, the pattern `DockStore` uses for `UserDefaults`. On disk rather than in `UserDefaults`: 500 rows × 32 keys is not a defaults-sized object, and `GizmatePaths.cache` already exists for exactly this.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class SurfaceRowsCacheTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testItGivesBackWhatItWasGiven() throws {
        let cache = SurfaceRowsCache(directory: try scratch())
        let id = UUID()
        cache.store([SurfaceRow(id: "1", values: ["name": "a.txt"])], for: id)
        XCTAssertEqual(cache.rows(for: id).first?["name"], "a.txt")
    }

    func testAnUnknownGizmoHasNoRows() throws {
        XCTAssertEqual(SurfaceRowsCache(directory: try scratch()).rows(for: UUID()), [])
    }

    /// The cache is what the dock draws before the script has finished. A file
    /// left behind by an older build must read as "nothing cached", never as a
    /// throw on the render path.
    func testUnreadableCacheReadsAsEmpty() throws {
        let directory = try scratch()
        let id = UUID()
        try Data("not json".utf8).write(
            to: directory.appending(path: "surface-\(id.uuidString).json")
        )
        XCTAssertEqual(SurfaceRowsCache(directory: directory).rows(for: id), [])
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter SurfaceRowsCacheTests 2>&1 | tail -20
```

Expected: "cannot find 'SurfaceRowsCache' in scope".

- [ ] **Step 3: Write the cache**

One JSON file per gizmo at `directory/surface-<uuid>.json`, an in-memory dictionary in front of it, every read failure swallowed to `[]`.

- [ ] **Step 4: Run the tests**

```sh
swift test --filter SurfaceRowsCacheTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/Dock/Surface/SurfaceRowsCache.swift \
        Tests/GizmateTests/SurfaceRowsCacheTests.swift
git commit -m "Keep the last rows so a dock opens full"
```

---

### Task 8: Refreshing a surface

**Files:**

- Create: `Sources/Gizmate/App/GizmateApp+Surfaces.swift`
- Modify: `Sources/Gizmate/MainWindow/Core/SettingsContracts.swift:98-130` (add to `SettingsHost`)
- Modify: `Sources/Gizmate/App/GizmateApp+ScriptTools.swift:578` (`.surface` delivers nothing)
- Test: `Tests/GizmateTests/SurfaceRefreshTests.swift`

**Interfaces:**

- Consumes: `ToolRunner.run(tool:script:arguments:uv:deliverOutputs:)`, `SurfaceRows` (Task 5), `SurfaceRowsCache` (Task 7), `ToolApprovals.isApproved(_:hash:)`, `ToolsStore.script(for:)`.
- Produces: on `SettingsHost` —
  - `var surfaceRows: SurfaceRowsCache { get }`
  - `func refreshSurface(_ tool: GizmateTool) async -> SurfaceRefreshOutcome`
  - `enum SurfaceRefreshOutcome: Equatable { case refreshed([SurfaceRow]); case unchanged; case failed(String) }`

**The approval rule.** `runScriptTool` gates on `ToolApprovals.isApproved` and shows a modal when it is not. A refresh cannot show a modal — it fires on pointer hover. So an unapproved surface **does not run**: it returns `.failed` and the dock shows its cached rows with the stale caption. Approval happens where it always did, when the user saves or runs the gizmo.

Also: `deliver` must learn `.surface` and do nothing. A surface gizmo run from the ring should not toast — its result is on the edge.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class SurfaceRefreshTests: XCTestCase {
    /// The one branch worth a test without a live uv: a gizmo the user never
    /// approved must not be executed by a pointer crossing a screen edge.
    func testAnUnapprovedSurfaceIsNotRun() async {
        var tool = GizmateTool.empty()
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        let outcome = await SurfaceRefresh.outcome(
            for: tool, isApproved: false, script: "print('{\"rows\":[]}')"
        ) { _ in XCTFail("an unapproved surface must not run"); return "" }
        guard case .failed = outcome else { return XCTFail("expected .failed") }
    }

    func testRowsThatDidNotChangeReportUnchanged() async {
        var tool = GizmateTool.empty()
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        let json = #"{"rows":[{"id":"1","name":"a.txt"}]}"#
        _ = await SurfaceRefresh.outcome(for: tool, isApproved: true, script: "x") { _ in json }
        let again = await SurfaceRefresh.outcome(
            for: tool, isApproved: true, script: "x", previous: [SurfaceRow(id: "1", values: ["name": "a.txt"])]
        ) { _ in json }
        XCTAssertEqual(again, .unchanged)
    }
}
```

Put the testable core in a `SurfaceRefresh` enum that takes the run as a closure, and keep `GizmateApp+Surfaces.swift` as the thin wiring that passes the real `ToolRunner` call in. That is what makes this task testable without uv, a worker, or an app.

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter SurfaceRefreshTests 2>&1 | tail -20
```

Expected: "cannot find 'SurfaceRefresh' in scope".

- [ ] **Step 3: Write the refresher**

`SurfaceRefresh.outcome` checks approval, runs the closure, decodes with `SurfaceRows.decode`, compares to `previous`, and returns. `GizmateApp+Surfaces.swift` implements `refreshSurface` on top of it, resolving `uv`, the script and the approval hash exactly the way `runScriptTool` does at `GizmateApp+ScriptTools.swift:274-310` — but never presenting the approval sheet.

In `deliver`, add:

```swift
        case .surface:
            // A surface has no result to deliver; its rows are already on the
            // edge. Toasting here would report an answer that is not one.
            break
```

- [ ] **Step 4: Run the tests and build**

```sh
swift test --filter SurfaceRefreshTests 2>&1 | tail -20 && swift build 2>&1 | tail -5
```

Expected: tests pass, build clean.

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/App/GizmateApp+Surfaces.swift \
        Sources/Gizmate/App/GizmateApp+ScriptTools.swift \
        Sources/Gizmate/MainWindow/Core/SettingsContracts.swift \
        Tests/GizmateTests/SurfaceRefreshTests.swift
git commit -m "Refresh a surface without asking the user mid-hover"
```

---

### Task 9: Surfaces reach the dock

**Files:**

- Modify: `Sources/Gizmate/Dock/DockItem.swift:61-69` (`gizmos`, `residentBuiltIns` comment)
- Create: `Sources/Gizmate/Dock/Surface/SurfaceHostView.swift`
- Test: `Tests/GizmateTests/DockCatalogSurfaceTests.swift`

**Interfaces:**

- Consumes: `SurfaceView` (Task 6), `SurfaceRowsCache` (Task 7), `refreshSurface` (Task 8), `ToolsStore.usableTools()`.
- Produces: `DockCatalog.gizmos(host:)` returning one `DockItem` per usable `.surface` gizmo; `struct SurfaceHostView: View` owning the draw-cached-then-refresh cycle.

This is the line the edge-dock spec left for this one: _"A gizmo with `output == .panel` earns a placement choice as soon as the result panel is a view rather than a window; until then the only honest answer is that it has none."_ The answer turned out to be a different output.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class DockCatalogSurfaceTests: XCTestCase {
    func testASurfaceGizmoIsDockable() {
        let host = StubSettingsHost()      // reuse the stub the dock tests already have
        var tool = GizmateTool.empty()
        tool.name = "Downloads"
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        host.tools.add(tool)               // or whatever ToolsStore's add is called

        let ids = DockCatalog.gizmos(host: host).map(\.id)
        XCTAssertEqual(ids, [ToolRef.generated(tool.id).storageID])
    }

    /// Every other result is still summoned. A run button on an edge is a
    /// second launcher, which is what the dock replaced.
    func testANonSurfaceGizmoIsNotDockable() {
        let host = StubSettingsHost()
        var tool = GizmateTool.empty()
        tool.kind = .python
        tool.output = .clipboard
        host.tools.add(tool)
        XCTAssertEqual(DockCatalog.gizmos(host: host).count, 0)
    }
}
```

If no `StubSettingsHost` exists, build the smallest one that satisfies `SettingsHost` in the test file and reuse it.

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter DockCatalogSurfaceTests 2>&1 | tail -20
```

Expected: `gizmos` returns `[]`, so the first test fails on an empty id list.

- [ ] **Step 3: Implement `gizmos`**

```swift
    /// Every usable surface gizmo. This is the whole gizmo half of the dock:
    /// a surface is the one result that exists while nothing is running, and
    /// every other result is still something you summon.
    static func gizmos(host: any SettingsHost) -> [DockItem] {
        host.tools.usableTools()
            .filter { $0.output == .surface }
            .map { tool in
                DockItem(
                    id: ToolRef.generated(tool.id).storageID,
                    title: tool.name,
                    icon: .phosphor(tool.resolvedSymbolName)
                ) { [weak host] in
                    guard let host else { return NSView() }
                    return hosted(AnyView(SurfaceHostView(tool: tool, host: host)))
                }
            }
    }
```

`SurfaceHostView` draws `SurfaceView(layout:rows:isStale:)` from `host.surfaceRows.rows(for:)` immediately, then `.task { await refresh() }` calls `host.refreshSurface(tool)` and swaps the rows in. On `.failed` it keeps the cached rows and sets `isStale`.

`residentBuiltIns`' doc comment says the dock holds only Note "because the notes list is the one surface that already exists as a view" — update it to say surfaces now join it.

- [ ] **Step 4: Run the tests and see it for real**

```sh
swift test --filter "DockCatalogSurfaceTests|DockStoreTests" 2>&1 | tail -20
pkill -f 'Gizmate' ; swift run Gizmate
```

Build a `.surface` gizmo by hand in the editor with this script, dock it to the right edge, hover the edge, and drag a file out into Finder:

```python
import json, os, pathlib
d = pathlib.Path.home() / "Downloads"
rows = [{"id": p.name, "name": p.name, "size": f"{p.stat().st_size // 1024} KB",
         "path": str(p)}
        for p in sorted(d.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)[:40]
        if p.is_file()]
print(json.dumps({"rows": rows}))
```

- [ ] **Step 5: Commit**

```sh
git add Sources/Gizmate/Dock/DockItem.swift \
        Sources/Gizmate/Dock/Surface/SurfaceHostView.swift \
        Tests/GizmateTests/DockCatalogSurfaceTests.swift
git commit -m "Let a surface gizmo take a place on the edge"
```

---

### Task 10: Validate a layout against rows the script really printed

**Files:**

- Modify: `Sources/Gizmate/Tools/CandidateValidation.swift:112-157`
- Modify: `ToolAgent/src/model-bridge.ts` (the result descriptions around line 315)
- Test: `Tests/GizmateTests/SurfaceCandidateValidationTests.swift`

**Interfaces:**

- Consumes: `SurfaceRows` (Task 5), `ToolAgentLayoutV1.referencedKeys` / `.fileKeys` (Task 2), and the `result-surface-downloads` eval case added in Task 1.
- Produces: a `.invalidOutput` failure with a diagnostic naming the missing key, and the first run of that eval case that can actually pass.

This is the check that makes the whole thing hold together: the layout is validated against rows produced by **really running the script**, not against a declared fixture. A binding that names nothing, or a `drag: file` pointing at a key that is not a path, is refused before the user ever docks it — and the diagnostic names the key, so the model can repair rather than guess.

- [ ] **Step 1: Write the failing test**

```swift
final class SurfaceCandidateValidationTests: XCTestCase {
    private let rows = [SurfaceRow(id: "1", values: ["name": "a.txt", "path": "/tmp/a.txt"])]

    func testALayoutWhoseKeysAllExistPasses() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(title: .key("name"), subtitle: nil, icon: nil,
                       drag: .file(key: "path"), tap: nil),
            empty: "Nothing"
        )
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    func testAKeyNoRowHasIsNamedInTheDiagnostic() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(title: .key("filename"), subtitle: nil, icon: nil, drag: nil, tap: nil),
            empty: "Nothing"
        )
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("filename"))
        XCTAssertTrue(diagnostic!.contains("name"), "the diagnostic should list the keys that do exist")
    }

    func testAFileKeyHoldingSomethingThatIsNotAPathIsRefused() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(title: .key("name"), subtitle: nil, icon: nil,
                       drag: .file(key: "name"), tap: nil),
            empty: "Nothing"
        )
        XCTAssertNotNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    /// A script that legitimately has nothing to show today cannot be checked
    /// against its keys, and failing the build for an empty Downloads folder
    /// would be absurd. It passes and grades as a smoke run.
    func testNoRowsIsNotAFailure() {
        let layout = ToolAgentLayoutV1.list(row: .text(.key("name")), empty: "Nothing")
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: []))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
swift test --filter SurfaceCandidateValidationTests 2>&1 | tail -20
```

Expected: "cannot find 'SurfaceLayoutCheck' in scope".

- [ ] **Step 3: Write the check and wire it in**

Put `SurfaceLayoutCheck` in `Sources/Gizmate/Dock/Surface/SurfaceLayoutCheck.swift` — it is a pure function over a layout and rows, and it is used from both validation and tests. A file key passes when every row's value for it is an absolute path that exists, or the rows are empty.

In `CandidateValidation.run`, after the `.files` check at line 128:

```swift
        if candidate.output == .surface {
            // `layout` is non-nil for a surface by `ToolAgentCandidateV1.validate`,
            // so this is the belt to that braces rather than a real branch.
            guard let layout = candidate.layout else {
                return .failed(try report(input, fixtureIndex: fixtureIndex,
                                          failure: .invalidCandidate, started: started))
            }
            let rows: [SurfaceRow]
            do {
                rows = try SurfaceRows.decode(stdout: result.stdout)
            } catch {
                return .failed(try report(
                    input, fixtureIndex: fixtureIndex, failure: .invalidOutput,
                    stderrDetail: "A surface gizmo has to print "
                        + #"{"rows":[{"id":"…","name":"…"}]} and nothing else. "#
                        + error.localizedDescription,
                    exitCode: result.exitCode, started: started
                ))
            }
            if let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows) {
                return .failed(try report(
                    input, fixtureIndex: fixtureIndex, failure: .invalidOutput,
                    stderrDetail: diagnostic, exitCode: result.exitCode, started: started
                ))
            }
        }
```

A surface's fixtures carry no `expectedOutput` — a folder listing is never byte-stable — so it grades `.smoke`, which the existing `ranWithoutComparison` path already produces.

- [ ] **Step 4: Describe the result to the model**

`git status` first — this file holds user WIP. In `ToolAgent/src/model-bridge.ts`, beside the other result descriptions near line 315:

```
- "surface": sits on a screen edge and shows a list the script prints, instead
  of finishing with an answer. Script gizmos only, input "none", trigger
  "always". The script prints {"rows":[{"id":"…","name":"…","path":"…"}]} and
  nothing else, and "layout" says how a row is drawn. Reach for it when the
  user asks to *see* something rather than to *do* something — "show me", "keep
  it on the side", "so I can drag them out".
```

plus the four nodes and the modifier prefixes, one line each. Describe the vocabulary, never a specific answer: a recipe in the prompt proves the prompt can hold a recipe.

- [ ] **Step 5: Run everything**

```sh
swift test 2>&1 | tail -30
```

Expected: green.

```sh
Scripts/tool-eval.sh result-surface-downloads
```

This is the first time the eval case added in Task 1 can actually pass — the vocabulary now exists, is described to the model, and renders. Expected: pass. If it fails, read `.build/tool-eval/report.json` and its `.attempts` trail before concluding anything — the finished `kind` is only the last thing the model tried, and a case reporting `python` may have written something else first and been refused by the host. Fix the generic machinery, never the prompt's knowledge of this specific answer.

- [ ] **Step 6: Commit**

```sh
git status --short
git add Sources/Gizmate/Dock/Surface/SurfaceLayoutCheck.swift \
        Sources/Gizmate/Tools/CandidateValidation.swift \
        ToolAgent/src/model-bridge.ts \
        Tests/GizmateTests/SurfaceCandidateValidationTests.swift
git commit -m "Check a layout against rows the script actually printed"
```

---

## Self-Review

**Spec coverage.** Protocol (`.surface`, `layout`) → Tasks 1, 3. Layout tree and the four components → Tasks 2, 6. Script contract and row limits → Task 5. Rendering, cache and refresh-on-reveal → Tasks 7, 8, 9. Drag-out and tap → Task 6. Approval and trust → Task 8. Validation and eval → Task 10. Files list → matches the spec's, plus `SurfaceLayoutCheck.swift` and `GizmateApp+Surfaces.swift`, which the spec folded into other files and which are cleaner apart.

**Not covered, deliberately.** The spec's "What v2 adds" — action buttons, drop-in, FSEvents. Each is additive and none changes v1's shapes.

**Type consistency.** `ToolAgentLayoutV1` case labels (`cell:minimumWidth:empty:`, `row:empty:`, `title:subtitle:icon:drag:tap:`) are used identically in Tasks 2, 3, 4, 9 and 10. `SurfaceRow(id:values:)` is constructed the same way in Tasks 5, 6, 7 and 10. `refreshSurface` returns `SurfaceRefreshOutcome` in Tasks 8 and 9.

**One known deviation from the spec.** The spec says validation checks bindings against "the candidate's fixture rows". Task 10 checks them against rows from the real validation run instead, which is strictly stronger and needs no fixture the model might write to suit itself.
