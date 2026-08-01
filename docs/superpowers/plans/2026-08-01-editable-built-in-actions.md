# Editable Built-In Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user rename, re-icon, re-prompt, rebind, or switch off any of the nine built-in ring actions, the same way they already can with their own gizmos.

**Architecture:** A `BuiltInOverridesStore` holds sparse per-action overrides in UserDefaults; `nil` fields mean "use what shipped". The ring, the hotkey registrar and the slot picker read resolved values through that store. Prompt overrides reach the LLM clients through a mutable static (`TranslationMode.promptOverrides`) rather than a signature change, and the three overridable prompts become token templates so a user's text keeps the target-language / app-category / writing-style layers.

**Tech Stack:** Swift 5.9+, SwiftUI + AppKit, SwiftPM, XCTest. macOS 14 deployment target.

## Global Constraints

- **Never change identity strings.** Bundle ID stays `com.nugumi.app`; existing shortcut defaults keys stay `globalShortcut.<rawValue>`; existing `RingActionID` raw values are persisted inside saved ring layouts and must never be renamed. New storage is additive under a new key.
- **New UserDefaults key:** `builtInOverrides.v1`. An install that predates this feature reads back an empty dictionary and behaves exactly as today.
- **User-facing copy must avoid the words "translate" / "translation" / "translator".** Prefer "results", "replies", "output". Code identifiers are exempt.
- **One subsystem per file**, target under ~400 lines, extensions named `Type+Feature.swift`. Never create `main.swift`.
- **Build must be green after every task:** `swift build`. Baseline at plan time is green.
- **Test command:** `swift test --filter <TestClassName>`.
- **Commit after every task.** Stage by explicit path — never `git add -A` or `git add .`. The maintainer edits this same worktree concurrently, and `git status` routinely holds unrelated WIP. Run `git diff --cached --stat` before committing; if it holds files you did not touch, commit with an explicit pathspec instead: `git commit -m "msg" -- path1 path2`.

---

### Task 1: Override model and store

**Files:**

- Create: `Sources/Gizmate/Ring/BuiltInOverrides.swift`
- Modify: `Sources/Gizmate/MainWindow/Core/SettingsContracts.swift` (add to `SettingsHost`, near `var ringLayout: RingLayoutStore { get }` at line 105)
- Modify: `Sources/Gizmate/MainWindow/Core/GizmateSettingsBridge.swift` (add stored property + init assignment, alongside `ringLayout`)
- Modify: `Sources/Gizmate/App/GizmateApp.swift` (own the store)
- Modify: `Sources/Gizmate/App/GizmateApp+Settings.swift` (satisfy the protocol requirement)
- Test: `Tests/GizmateTests/BuiltInOverridesTests.swift`

**Interfaces:**

- Consumes: `RingActionID` (`Ring/RingCatalog.swift:17`), `RingIconKind` (same file, line 7).
- Produces:
  - `struct BuiltInOverride: Codable, Equatable` with `name: String?`, `symbol: String?`, `prompt: String?`, `isEnabled: Bool`
  - `@MainActor final class BuiltInOverridesStore: ObservableObject` with `init(defaults: UserDefaults = .standard)`, `overrides: [RingActionID: BuiltInOverride]`, `onChange: (() -> Void)?`, and read/write methods `name(for:) -> String`, `displayName(for:) -> String`, `icon(for:) -> RingIconKind`, `prompt(for:) -> String?`, `isEnabled(_:) -> Bool`, `save(_:for:)`, `resetToDefault(_:)`
  - `GizmateApp.builtInOverridesStore` and `SettingsHost.builtInOverrides`
  - `GizmateSettingsBridge.builtInOverrides`

- [ ] **Step 1: Write the failing test**

Create `Tests/GizmateTests/BuiltInOverridesTests.swift`:

```swift
import XCTest
@testable import Gizmate

/// The store's whole job is "sparse overrides on top of shipped values", so what
/// is worth pinning down is that an unset field falls through to what shipped and
/// that a reset really removes rather than freezes today's default.
final class BuiltInOverridesTests: XCTestCase {

    @MainActor
    private func store() -> (BuiltInOverridesStore, () -> Void) {
        let suiteName = "BuiltInOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (BuiltInOverridesStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    @MainActor
    func testUntouchedActionReturnsShippedValues() {
        let (store, cleanup) = store()
        defer { cleanup() }

        XCTAssertEqual(store.name(for: .dictate), RingActionID.dictate.label)
        XCTAssertEqual(store.icon(for: .explain), RingActionID.explain.icon)
        XCTAssertNil(store.prompt(for: .explain))
        XCTAssertTrue(store.isEnabled(.dictate))
    }

    @MainActor
    func testSavedOverrideWinsOverShippedValue() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(
            BuiltInOverride(name: "Speak", symbol: "waveform.circle", isEnabled: false),
            for: .dictate
        )

        XCTAssertEqual(store.name(for: .dictate), "Speak")
        XCTAssertEqual(store.icon(for: .dictate), .symbol("waveform.circle"))
        XCTAssertFalse(store.isEnabled(.dictate))
    }

    /// An unset field must fall through even when its neighbours are set —
    /// this is what makes a partial edit partial.
    @MainActor
    func testUnsetFieldsStillFallThrough() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(BuiltInOverride(name: "Speak"), for: .dictate)

        XCTAssertEqual(store.name(for: .dictate), "Speak")
        XCTAssertEqual(store.icon(for: .dictate), RingActionID.dictate.icon)
        XCTAssertTrue(store.isEnabled(.dictate))
    }

    @MainActor
    func testOverridesSurviveAReload() {
        let suiteName = "BuiltInOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        BuiltInOverridesStore(defaults: defaults)
            .save(BuiltInOverride(name: "Speak"), for: .dictate)

        XCTAssertEqual(BuiltInOverridesStore(defaults: defaults).name(for: .dictate), "Speak")
    }

    @MainActor
    func testResetRestoresShippedValues() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(BuiltInOverride(name: "Speak", isEnabled: false), for: .dictate)
        store.resetToDefault(.dictate)

        XCTAssertEqual(store.name(for: .dictate), RingActionID.dictate.label)
        XCTAssertTrue(store.isEnabled(.dictate))
        XCTAssertNil(store.overrides[.dictate])
    }

    /// Summarize's hover label is deliberately empty (its live button wears the
    /// source app's icon), so the settings-facing name has to come from
    /// `displayName`, not `label`.
    @MainActor
    func testSummarizeFallsBackToDisplayName() {
        let (store, cleanup) = store()
        defer { cleanup() }

        XCTAssertEqual(store.displayName(for: .summarize), "Summarize")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuiltInOverridesTests`
Expected: FAIL — `cannot find 'BuiltInOverridesStore' in scope`.

- [ ] **Step 3: Write the store**

Create `Sources/Gizmate/Ring/BuiltInOverrides.swift`:

```swift
import Foundation

/// What the user changed about one built-in ring action.
///
/// Every field is optional and `nil` means "use what shipped". That is the whole
/// point of the shape: "Reset to default" is a removal rather than a copy of
/// today's defaults back over the top, so a user who never touched Explain's
/// prompt still picks up improvements to it in a later release.
struct BuiltInOverride: Codable, Equatable {
    var name: String?
    /// An SF Symbol name, picked with the same `IconGrid` gizmos use. Set, it
    /// replaces the bundled Phosphor glyph on the built-ins that ship one.
    var symbol: String?
    /// Token template replacing the shipped prompt. Only Explain, Rewrite and
    /// Reply have one — see `RingActionID.promptMode`.
    var prompt: String?
    var isEnabled: Bool = true

    /// Nothing set and still switched on is indistinguishable from never having
    /// been edited, so saving one is stored as a removal.
    var isShipped: Bool {
        name == nil && symbol == nil && prompt == nil && isEnabled
    }
}

/// The user's edits to the built-in ring actions, persisted in UserDefaults.
/// Same `@Published` + `onChange` + injectable-defaults contract as
/// `RingLayoutStore` and `ToolsStore`, so the bridge wires it identically.
@MainActor
final class BuiltInOverridesStore: ObservableObject {
    @Published private(set) var overrides: [RingActionID: BuiltInOverride] = [:]
    var onChange: (() -> Void)?

    private static let defaultsKey = "builtInOverrides.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Resolved reads

    /// The ring's hover label. Empty for Summarize by design — its live button
    /// wears the frontmost app's icon, which already names it.
    func name(for id: RingActionID) -> String {
        overrides[id]?.name ?? id.label
    }

    /// The name a settings screen shows, which needs a real word for Summarize.
    func displayName(for id: RingActionID) -> String {
        overrides[id]?.name ?? id.displayName
    }

    func icon(for id: RingActionID) -> RingIconKind {
        overrides[id]?.symbol.map { .symbol($0) } ?? id.icon
    }

    /// nil when the user has not written one — the caller falls back to the
    /// shipped template.
    func prompt(for id: RingActionID) -> String? {
        overrides[id]?.prompt
    }

    func isEnabled(_ id: RingActionID) -> Bool {
        overrides[id]?.isEnabled ?? true
    }

    /// Every prompt the user has written, in the shape `TranslationMode` reads.
    func promptOverrides() -> [RingActionID: String] {
        overrides.compactMapValues(\.prompt)
    }

    // MARK: - Writes

    func save(_ override: BuiltInOverride, for id: RingActionID) {
        if override.isShipped {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = override
        }
        persist()
    }

    func resetToDefault(_ id: RingActionID) {
        overrides.removeValue(forKey: id)
        persist()
    }

    // MARK: - Storage

    /// Stored keyed by raw value rather than by `RingActionID` so the JSON stays
    /// readable and an action retired in a later build decodes as a skipped key
    /// instead of failing the whole blob.
    private func persist() {
        let raw = Dictionary(
            uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        onChange?()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let raw = try? JSONDecoder().decode([String: BuiltInOverride].self, from: data)
        else { return }
        overrides = Dictionary(
            uniqueKeysWithValues: raw.compactMap { key, value in
                RingActionID(rawValue: key).map { ($0, value) }
            }
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BuiltInOverridesTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Wire the store into the host and bridge**

In `Sources/Gizmate/MainWindow/Core/SettingsContracts.swift`, add to the `SettingsHost` protocol immediately after `var ringLayout: RingLayoutStore { get }`:

```swift
    var builtInOverrides: BuiltInOverridesStore { get }
```

In `Sources/Gizmate/MainWindow/Core/GizmateSettingsBridge.swift`, add the stored property after `let ringLayout: RingLayoutStore`:

```swift
    let builtInOverrides: BuiltInOverridesStore
```

and in `init(host:)`, after `self.ringLayout = host.ringLayout`:

```swift
        self.builtInOverrides = host.builtInOverrides
```

In `Sources/Gizmate/App/GizmateApp.swift`, declare the store next to `ringLayoutStore`:

```swift
    let builtInOverridesStore = BuiltInOverridesStore()
```

In `Sources/Gizmate/App/GizmateApp+Settings.swift`, satisfy the protocol next to the existing `var ringLayout: RingLayoutStore { ringLayoutStore }` accessor:

```swift
    var builtInOverrides: BuiltInOverridesStore { builtInOverridesStore }
```

If `GizmateApp+Settings.swift` exposes `ringLayout` differently (e.g. the stored property is named identically and no accessor exists), match whatever shape `ringLayout` uses rather than introducing a new one.

- [ ] **Step 6: Verify the build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/Gizmate/Ring/BuiltInOverrides.swift \
        Sources/Gizmate/MainWindow/Core/SettingsContracts.swift \
        Sources/Gizmate/MainWindow/Core/GizmateSettingsBridge.swift \
        Sources/Gizmate/App/GizmateApp.swift \
        Sources/Gizmate/App/GizmateApp+Settings.swift \
        Tests/GizmateTests/BuiltInOverridesTests.swift
git diff --cached --stat   # confirm only the files above
git commit -m "Add a store for built-in action overrides"
```

---

### Task 2: Turn the three overridable prompts into token templates

This is a pure refactor. Behaviour must not change by a single byte — the test is the whole point of the task.

**Files:**

- Modify: `Sources/Gizmate/Panels/TranslationModes.swift` (the `.selection`, `.draftMessage` and `.smartReply` arms of `systemPrompt(targetLanguage:appCategory:composition:)`, currently lines 150–200)
- Modify: `Sources/Gizmate/Ring/RingCatalog.swift` (add `promptMode`)
- Test: `Tests/GizmateTests/BuiltInPromptTemplateTests.swift`

**Interfaces:**

- Consumes: `BuiltInOverridesStore` is _not_ used here — this task only reshapes the shipped prompts.
- Produces:
  - `RingActionID.promptMode: TranslationMode?` — `.explain → .selection`, `.rewrite → .draftMessage`, `.reply → .smartReply`, everything else `nil`
  - `TranslationMode.shippedPromptTemplate: String?` — the token template for the three, `nil` otherwise
  - `TranslationMode.renderPrompt(_ template: String, targetLanguage:appCategory:composition:) -> String`

- [ ] **Step 1: Capture the current output as a fixture**

Before editing any prompt text, add a throwaway test that prints what ships today, so the fidelity test compares against reality rather than against a retyped copy.

Create `Tests/GizmateTests/BuiltInPromptTemplateTests.swift`:

```swift
import XCTest
@testable import Gizmate

/// Tokenising three ~600-word prompts is a mechanical find-replace, and a
/// dropped token does not crash — it silently strips the target language or the
/// user's writing style out of every request. These tests are the only thing
/// that notices.
final class BuiltInPromptTemplateTests: XCTestCase {

    private let language = TranslationLanguage.language(id: "en")   // promptName "English"
    private let category = AppCategory.workMessages

    /// Every token-bearing block is deliberately non-empty, so a dropped token
    /// changes the output instead of resolving to "" and looking fine.
    /// No braces in the voice sample — the token assertions look for leftovers.
    private var composition: CompositionSettings {
        CompositionSettings(
            style: .casual,
            cleanup: .light,
            snippets: [],
            genZ: true,
            voiceSample: "Hi there,\n\nThanks!\n\nVadim"
        )
    }

    func testCaptureCurrentOutput() {
        for mode in [TranslationMode.selection, .draftMessage, .smartReply] {
            print("=== \(mode) ===")
            print(mode.systemPrompt(
                targetLanguage: language,
                appCategory: category,
                composition: composition
            ))
        }
    }
}
```

- [ ] **Step 2: Run it and save the output**

Run: `swift test --filter BuiltInPromptTemplateTests/testCaptureCurrentOutput 2>&1 | tee /tmp/prompt-baseline.txt`
Expected: PASS, with three prompt blocks printed.

Keep `/tmp/prompt-baseline.txt`. It is the reference for Step 6.

The fixture types are already verified against the tree: `CompositionSettings` is declared at `Sources/Gizmate/Selection/TextPipeline.swift:250` with the memberwise order `style, cleanup, snippets, genZ, voiceSample, customInstruction`; `WritingStyle` is `formal / polite / casual` and `CleanupLevel` is `none / light / medium / high`, both in `Sources/Gizmate/Panels/TranslationModes.swift`; `TranslationLanguage` is a struct with no static per-language members, so English comes from `TranslationLanguage.language(id: "en")`.

- [ ] **Step 3: Add `promptMode` to the catalog**

In `Sources/Gizmate/Ring/RingCatalog.swift`, inside `enum RingActionID`, after `var summary: String`:

```swift
    /// The mode whose prompt this built-in owns, for the three that have an
    /// editable one. Summarize is deliberately absent: one button stands in
    /// front of two prompts (`.summarizeChat` and `.summarizePage`), so a single
    /// text field could not honestly represent it.
    var promptMode: TranslationMode? {
        switch self {
        case .explain: return .selection
        case .rewrite: return .draftMessage
        case .reply:   return .smartReply
        case .ask, .capture, .summarize, .dictate, .live, .saveNote: return nil
        }
    }
```

- [ ] **Step 4: Add the template accessor and the renderer**

In `Sources/Gizmate/Panels/TranslationModes.swift`, inside `extension TranslationMode` (or the enum body, matching where `systemPrompt` lives), add:

```swift
    /// The shipped prompt as an editable template. Tokens stand in for the
    /// values `systemPrompt` splices — a user override is plain text, so without
    /// them an edited Explain would stop targeting the writing language.
    ///
    /// nil for every mode that is not an editable built-in; those keep their
    /// interpolated form.
    var shippedPromptTemplate: String? {
        switch self {
        case .selection:    return Self.selectionTemplate
        case .draftMessage: return Self.draftMessageTemplate
        case .smartReply:   return Self.smartReplyTemplate
        default:            return nil
        }
    }

    /// Substitutes `{token}` placeholders in a single pass over the template.
    ///
    /// Single pass, not a `reduce` of `replacingOccurrences`, because the values
    /// being spliced in are user content: a glossary snippet or voice sample
    /// containing the literal text `{language}` would be rescanned and
    /// substituted by a later iteration. One pass means a value is never
    /// re-examined once written.
    ///
    /// An unknown token is left verbatim rather than erased, so a typo in a
    /// user's override shows up in the output instead of silently vanishing.
    static func renderPrompt(
        _ template: String,
        tokens: [String: String]
    ) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[rest.startIndex..<open]
            rest = rest[rest.index(after: open)...]
            guard let close = rest.firstIndex(of: "}"),
                  let value = tokens[String(rest[rest.startIndex..<close])]
            else {
                result += "{"
                continue
            }
            result += value
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// Built per mode, not once globally: `.draftMessage` splices
    /// `cleanupSection(for:)`, which emits its own "\n\nCleanup — " heading,
    /// while `.smartReply` has that heading written into the prompt and splices
    /// only `cleanup.promptDescription`. Same concept, different spelling —
    /// keeping the maps separate is what makes both byte-identical.
    private func promptTokens(
        targetLanguage: TranslationLanguage,
        appCategory: AppCategory,
        composition: CompositionSettings?
    ) -> [String: String] {
        var tokens: [String: String] = [
            "language": targetLanguage.promptName,
            "app": appCategory.promptHint,
            "genZ": Self.genZSection(
                for: targetLanguage.id,
                enabled: composition?.genZ ?? false
            ),
        ]
        switch self {
        case .draftMessage:
            tokens["writingStyle"] = composition?.writingStyleDirective(for: targetLanguage.id) ?? ""
            tokens["voice"] = Self.voiceSampleSection(for: composition?.voiceSample)
            tokens["cleanup"] = Self.cleanupSection(for: composition?.cleanup)
            tokens["glossary"] = Self.glossarySection(
                for: composition?.snippets ?? [],
                includeSnippets: true
            )
        case .smartReply:
            tokens["writingStyle"] = composition?.writingStyleDirective(for: targetLanguage.id) ?? ""
            tokens["voice"] = Self.voiceSampleSection(for: composition?.voiceSample)
            tokens["cleanup"] = composition?.cleanup.promptDescription ?? ""
            tokens["glossary"] = Self.glossarySection(
                for: composition?.snippets ?? [],
                includeSnippets: true
            )
        default:
            break
        }
        return tokens
    }
```

`genZSection`, `cleanupSection`, `voiceSampleSection` and `glossarySection` are currently `private static` on this type. They stay private — `promptTokens` is a member of the same type.

- [ ] **Step 5: Move the three prompts into templates**

Cut the three multi-line string literals out of the `switch self` in `systemPrompt` and paste each into a `private static let` on the same type, replacing every interpolation with its token:

| was                                                                                           | becomes          |
| --------------------------------------------------------------------------------------------- | ---------------- |
| `\(targetLanguage.promptName)`                                                                | `{language}`     |
| `\(appCategory.promptHint)`                                                                   | `{app}`          |
| `\(composition?.writingStyleDirective(for: targetLanguage.id) ?? "")`                         | `{writingStyle}` |
| `\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))` | `{genZ}`         |
| `\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))`                        | `{voice}`        |
| `\(TranslationMode.cleanupSection(for: composition?.cleanup))`                                | `{cleanup}`      |
| `\(composition?.cleanup.promptDescription ?? "")`                                             | `{cleanup}`      |
| `\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))` | `{glossary}`     |

So, for example:

```swift
    private static let selectionTemplate = """
        Translate the user's text into plain, accessible {language} aimed at a curious ~12-year-old reader ...
        """
```

Take care with two details that are easy to lose:

- `.selection` interpolates `{language}` in six separate places. Replace all of them.
- The `.summarizeChat` / `.summarizePage` literals use `\` line-continuations. They are **not** being converted — leave those two arms untouched.

Then rewrite the head of `systemPrompt` so the three tokenized modes render, and every other mode keeps its existing interpolated arm verbatim:

```swift
    func systemPrompt(
        targetLanguage: TranslationLanguage,
        appCategory: AppCategory,
        composition: CompositionSettings?
    ) -> String {
        if let template = shippedPromptTemplate {
            return UserAboutContext.appending(to: TranslationMode.renderPrompt(
                template,
                tokens: promptTokens(
                    targetLanguage: targetLanguage,
                    appCategory: appCategory,
                    composition: composition
                )
            ))
        }
        let base: String = switch self {
        case .revise:
            // ... unchanged
        case .reviseMessage:
            // ... unchanged
        case .summarizeChat:
            // ... unchanged
        case .summarizePage:
            // ... unchanged
        case .custom(let tool):
            // ... unchanged
        case .selection, .draftMessage, .smartReply:
            // Handled above by the template path; unreachable.
            ""
        }
        return UserAboutContext.appending(to: base)
    }
```

- [ ] **Step 6: Replace the capture test with the fidelity assertion**

Read `/tmp/prompt-baseline.txt`. Replace `testCaptureCurrentOutput` in `Tests/GizmateTests/BuiltInPromptTemplateTests.swift` with assertions that pin the parts a dropped token would destroy, using the exact strings from the baseline file:

```swift
    private static let tokenNames = [
        "language", "app", "writingStyle", "genZ", "voice", "cleanup", "glossary",
    ]

    /// Every token must actually resolve. A surviving `{language}` means the map
    /// is missing that key for this mode.
    func testNoTokenSurvivesRendering() {
        for mode in [TranslationMode.selection, .draftMessage, .smartReply] {
            let rendered = mode.systemPrompt(
                targetLanguage: language,
                appCategory: category,
                composition: composition
            )
            for token in Self.tokenNames {
                XCTAssertFalse(
                    rendered.contains("{\(token)}"),
                    "\(mode) left {\(token)} unresolved"
                )
            }
        }
    }

    /// The language name has to reach every place the shipped prompt put it —
    /// eight times in `.selection`, counted from the pre-refactor source.
    /// Counting is what catches "replaced the first one and moved on".
    func testSelectionCarriesLanguageEverywhere() {
        let rendered = TranslationMode.selection.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )
        XCTAssertEqual(
            rendered.components(separatedBy: language.promptName).count - 1,
            8
        )
    }

    /// The composition blocks are spliced into the middle of the prompt, not
    /// appended, so a lost token is invisible unless the block is looked for.
    func testDraftMessageCarriesEveryCompositionBlock() {
        let rendered = TranslationMode.draftMessage.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )
        XCTAssertTrue(rendered.contains("Writing style — "))
        XCTAssertTrue(rendered.contains("Cleanup — "))
        XCTAssertTrue(rendered.contains("Voice sample — "))
        XCTAssertTrue(rendered.contains(category.promptHint))
    }

    func testSmartReplyCarriesEveryCompositionBlock() {
        let rendered = TranslationMode.smartReply.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )
        XCTAssertTrue(rendered.contains("Writing style — "))
        XCTAssertTrue(rendered.contains("Cleanup — "))
        XCTAssertTrue(rendered.contains("Voice sample — "))
        XCTAssertTrue(rendered.contains(category.promptHint))
    }
```

The expected count of `8` is not a guess — it is `\(targetLanguage.promptName)` counted in the pre-refactor `.selection` literal:

```bash
git show HEAD:Sources/Gizmate/Panels/TranslationModes.swift \
  | awk 'NR>=151 && NR<=168' | grep -o 'targetLanguage\.promptName' | wc -l   # 8
```

If the `.selection` prompt has been edited since this plan was written, re-run that command against the pre-refactor revision and use what it prints.

- [ ] **Step 7: Prove byte-for-byte fidelity against the baseline**

Re-run the capture with the same fixture and diff it against the pre-refactor output:

```bash
swift test --filter BuiltInPromptTemplateTests 2>&1 | tee /tmp/prompt-after.txt
diff <(grep -A9999 '=== selection ===' /tmp/prompt-baseline.txt) \
     <(grep -A9999 '=== selection ===' /tmp/prompt-after.txt)
```

Expected: the assertions pass. If the capture test was removed in Step 6, re-add it temporarily for this diff, confirm zero differences, then remove it again. **A non-empty diff means a token was dropped — fix it before continuing.** This is the single most important check in the plan.

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: no new failures versus the pre-task baseline.

- [ ] **Step 9: Commit**

```bash
git add Sources/Gizmate/Panels/TranslationModes.swift \
        Sources/Gizmate/Ring/RingCatalog.swift \
        Tests/GizmateTests/BuiltInPromptTemplateTests.swift
git diff --cached --stat
git commit -m "Turn the three editable built-in prompts into token templates"
```

---

### Task 3: Apply the user's prompt override

**Files:**

- Modify: `Sources/Gizmate/Panels/TranslationModes.swift`
- Modify: `Sources/Gizmate/App/GizmateApp.swift` (keep the static in sync)
- Test: `Tests/GizmateTests/BuiltInPromptTemplateTests.swift` (extend)

**Interfaces:**

- Consumes: `RingActionID.promptMode` and `TranslationMode.shippedPromptTemplate` (Task 2), `BuiltInOverridesStore.promptOverrides()` (Task 1).
- Produces: `TranslationMode.promptOverrides: [RingActionID: String]`, a mutable static kept in sync by `GizmateApp`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GizmateTests/BuiltInPromptTemplateTests.swift`:

```swift
    /// A user override replaces the shipped instruction but keeps every layer
    /// wrapped around it — that is the entire reason the templates carry tokens.
    func testOverrideReplacesTheBodyButKeepsTheLanguage() {
        TranslationMode.promptOverrides = [.explain: "Summarise this in {language}."]
        defer { TranslationMode.promptOverrides = [:] }

        let rendered = TranslationMode.selection.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )

        XCTAssertTrue(rendered.hasPrefix("Summarise this in English."))
        XCTAssertFalse(rendered.contains("curious ~12-year-old"))
    }

    /// An override on one built-in must not leak into another.
    func testOverrideIsScopedToItsOwnMode() {
        TranslationMode.promptOverrides = [.explain: "Overridden."]
        defer { TranslationMode.promptOverrides = [:] }

        let reply = TranslationMode.smartReply.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )

        XCTAssertFalse(reply.contains("Overridden."))
    }

    /// An empty or whitespace-only override is a user who cleared the field, not
    /// a request for an empty system prompt.
    func testBlankOverrideFallsBackToShipped() {
        TranslationMode.promptOverrides = [.explain: "   \n  "]
        defer { TranslationMode.promptOverrides = [:] }

        let rendered = TranslationMode.selection.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )

        XCTAssertTrue(rendered.contains("curious ~12-year-old"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuiltInPromptTemplateTests`
Expected: FAIL — `type 'TranslationMode' has no member 'promptOverrides'`.

- [ ] **Step 3: Add the static and consult it**

In `Sources/Gizmate/Panels/TranslationModes.swift`, next to `shippedPromptTemplate`:

```swift
    /// Prompt templates the user wrote, keyed by the built-in that owns them.
    /// Kept in sync by `GizmateApp` from `BuiltInOverridesStore` — the same
    /// arrangement as `AppCategoryClassifier.userOverrides`, and for the same
    /// reason: `systemPrompt` is called from four LLM clients, none of which
    /// should have to learn about built-in overrides to pass one through.
    static var promptOverrides: [RingActionID: String] = [:]

    /// The template actually used: the user's, or the shipped one. A blank
    /// override is a cleared field, not a request for an empty system prompt.
    var promptTemplate: String? {
        let userWritten = RingActionID.allCases
            .first { $0.promptMode == self }
            .flatMap { Self.promptOverrides[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let userWritten, !userWritten.isEmpty { return userWritten }
        return shippedPromptTemplate
    }
```

Then change the template branch in `systemPrompt` from `if let template = shippedPromptTemplate` to:

```swift
        if let template = promptTemplate {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BuiltInPromptTemplateTests`
Expected: PASS.

- [ ] **Step 5: Keep the static in sync from the app**

In `Sources/Gizmate/App/GizmateApp.swift`, in `applicationDidFinishLaunching` beside the existing `RingConfigurationProvider.current = { ... }` assignment (around line 349):

```swift
        // The prompt path is not @MainActor and is reached from four LLM
        // clients, so overrides arrive through a static that the store keeps
        // current rather than through every call signature.
        TranslationMode.promptOverrides = builtInOverridesStore.promptOverrides()
        builtInOverridesStore.onChange = { [weak self] in
            guard let self else { return }
            TranslationMode.promptOverrides = self.builtInOverridesStore.promptOverrides()
        }
```

- [ ] **Step 6: Verify the build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/Gizmate/Panels/TranslationModes.swift \
        Sources/Gizmate/App/GizmateApp.swift \
        Tests/GizmateTests/BuiltInPromptTemplateTests.swift
git diff --cached --stat
git commit -m "Let a built-in's prompt be overridden"
```

---

### Task 4: Resolve name and icon in the ring, and skip disabled built-ins

**Files:**

- Modify: `Sources/Gizmate/Ring/RingLayout.swift:164-172` (`RingConfiguration`)
- Modify: `Sources/Gizmate/Ring/RingBuilder.swift:127-156` (`builtInItem`)
- Modify: `Sources/Gizmate/App/GizmateApp.swift:349` (`RingConfigurationProvider.current`)
- Test: `Tests/GizmateTests/BuiltInOverridesTests.swift` (extend)

**Interfaces:**

- Consumes: `BuiltInOverride` (Task 1).
- Produces: `RingConfiguration.overrides: [RingActionID: BuiltInOverride]`, defaulting to `[:]` so every existing construction site keeps compiling.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GizmateTests/BuiltInOverridesTests.swift`:

```swift
    // MARK: - Ring integration

    private var allHandlers: RingActionHandlers {
        RingActionHandlers(
            explain: {}, rewrite: {}, reply: {}, ask: {},
            capture: {}, dictate: {}, live: {}, saveNote: {}
        )
    }

    /// A disabled built-in leaves a gap. It must NOT shift the buttons after it
    /// along — the ring draws slot i at position i, and a shifting ring is a ring
    /// nobody can aim at from muscle memory.
    @MainActor
    func testDisabledBuiltInLeavesItsSlotEmpty() {
        let layout = RingLayout(slots: [
            .builtIn(.explain), .builtIn(.dictate), .builtIn(.reply),
        ])
        let configuration = RingConfiguration(
            layout: layout,
            tools: [],
            overrides: [.dictate: BuiltInOverride(isEnabled: false)]
        )

        let slots = RingBuilder.slots(
            configuration: configuration,
            handlers: allHandlers,
            dismiss: {}
        )

        XCTAssertEqual(slots[0]?.label, RingActionID.explain.label)
        XCTAssertNil(slots[1])
        XCTAssertEqual(slots[2]?.label, RingActionID.reply.label)
    }

    @MainActor
    func testRenamedBuiltInShowsItsNewLabel() {
        let configuration = RingConfiguration(
            layout: RingLayout(slots: [.builtIn(.dictate)]),
            tools: [],
            overrides: [.dictate: BuiltInOverride(name: "Speak")]
        )

        let slots = RingBuilder.slots(
            configuration: configuration,
            handlers: allHandlers,
            dismiss: {}
        )

        XCTAssertEqual(slots[0]?.label, "Speak")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuiltInOverridesTests`
Expected: FAIL — `extra argument 'overrides' in call`.

- [ ] **Step 3: Add the field to `RingConfiguration`**

In `Sources/Gizmate/Ring/RingLayout.swift`, inside `struct RingConfiguration`, after `var folders: [RingFolder] = []`:

```swift
    /// The user's edits to the built-in actions. Defaulted so every existing
    /// construction site — including the tests — keeps compiling unchanged.
    var overrides: [RingActionID: BuiltInOverride] = [:]
```

- [ ] **Step 4: Read it in the builder**

In `Sources/Gizmate/Ring/RingBuilder.swift`, change `builtInItem` to take the overrides and consult them. Its call site in `items(in:depth:configuration:handlers:dismiss:)` becomes:

```swift
            case .builtIn(let id):
                return builtInItem(
                    id,
                    override: configuration.overrides[id],
                    handlers: handlers,
                    dismiss: dismiss
                )
```

and the function itself:

```swift
    @MainActor
    private static func builtInItem(
        _ id: RingActionID,
        override: BuiltInOverride?,
        handlers: RingActionHandlers,
        dismiss: @escaping () -> Void
    ) -> RingItem? {
        // Switched off in the built-in's editor. Returning nil reuses the gap
        // the ring already draws for an unavailable action — no new path.
        guard override?.isEnabled ?? true else { return nil }
        // Summarize builds its own item: an app icon plus the time-range or
        // app-picker orbits behind it.
        if id == .summarize {
            guard let option = handlers.summarize else { return nil }
            return summarizeRingItem(option, dismiss: dismiss)
        }
        let handler: (() -> Void)?
        switch id {
        case .explain:   handler = handlers.explain
        case .rewrite:   handler = handlers.rewrite
        case .reply:     handler = handlers.reply
        case .ask:       handler = handlers.ask
        case .capture:   handler = handlers.capture
        case .dictate:   handler = handlers.dictate
        case .live:      handler = handlers.live
        case .saveNote:  handler = handlers.saveNote
        case .summarize: handler = nil
        }
        guard let handler else { return nil }
        let label = override?.name ?? id.label
        let icon = override?.symbol.map { RingIconKind.symbol($0) } ?? id.icon
        return RingItem(label: label, image: icon.image()) {
            dismiss()
            handler()
        }
    }
```

Note Summarize is checked _after_ the enabled guard, so switching Summarize off hides it even in a supported app.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter BuiltInOverridesTests`
Expected: PASS.

- [ ] **Step 6: Feed the real store into the live ring**

In `Sources/Gizmate/App/GizmateApp.swift`, in the `RingConfigurationProvider.current` closure (around line 349), add the argument:

```swift
            return RingConfiguration(
                layout: self.ringLayoutStore.layout,
                tools: self.toolsStore.tools.filter(self.toolsStore.isRunnable),
                folders: self.ringLayoutStore.folders,
                overrides: self.builtInOverridesStore.overrides
            )
```

- [ ] **Step 7: Verify the build and the full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, no new failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/Gizmate/Ring/RingLayout.swift \
        Sources/Gizmate/Ring/RingBuilder.swift \
        Sources/Gizmate/App/GizmateApp.swift \
        Tests/GizmateTests/BuiltInOverridesTests.swift
git diff --cached --stat
git commit -m "Honour built-in overrides in the ring"
```

---

### Task 5: Give every built-in its own shortcut

**Files:**

- Modify: `Sources/Gizmate/App/Shortcuts/GlobalShortcutModels.swift` (4 new cases across `id`, `menuTitle`, `group`, `defaultShortcut`)
- Modify: `Sources/Gizmate/App/GizmateApp+HotKeysMenus.swift:29-37` (bindings) and the registration loop
- Modify: `Sources/Gizmate/Ring/RingCatalog.swift` (add `shortcutAction`)
- Test: `Tests/GizmateTests/BuiltInShortcutTests.swift`

**Interfaces:**

- Consumes: `RingActionID` (Task 2 added `promptMode` to the same enum), `BuiltInOverridesStore.isEnabled(_:)` (Task 1).
- Produces:
  - New `GlobalShortcutAction` cases: `explainSelection`, `replyToSelection`, `dictate`, `saveNote`
  - `RingActionID.shortcutAction: GlobalShortcutAction?`

- [ ] **Step 1: Write the failing test**

Create `Tests/GizmateTests/BuiltInShortcutTests.swift`:

```swift
import XCTest
@testable import Gizmate

/// Every built-in but Summarize owns exactly one shortcut, and no two actions
/// may ship the same default — a collision means one of them silently never
/// fires for anyone who never opens the settings.
final class BuiltInShortcutTests: XCTestCase {

    func testEveryBuiltInExceptSummarizeHasAShortcut() {
        for id in RingActionID.allCases where id != .summarize {
            XCTAssertNotNil(id.shortcutAction, "\(id) has no shortcut action")
        }
        XCTAssertNil(RingActionID.summarize.shortcutAction)
    }

    func testNoTwoBuiltInsShareAShortcutAction() {
        let actions = RingActionID.allCases.compactMap(\.shortcutAction)
        XCTAssertEqual(actions.count, Set(actions.map(\.rawValue)).count)
    }

    func testNoTwoActionsShipTheSameDefaultShortcut() {
        var seen: [GlobalShortcut] = []
        for action in GlobalShortcutAction.allCases {
            let shortcut = action.defaultShortcut
            XCTAssertFalse(
                seen.contains(shortcut),
                "\(action) ships a default already taken"
            )
            seen.append(shortcut)
        }
        XCTAssertFalse(
            seen.contains(GlobalShortcutAction.askGizmateAlias),
            "a default collides with the reserved ⌃⌥A Ask alias"
        )
    }

    func testActionIDsAreUniqueAndClearOfTheAliasID() {
        let ids = GlobalShortcutAction.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertFalse(ids.contains(100), "id 100 is reserved for the Ask alias")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuiltInShortcutTests`
Expected: FAIL — `value of type 'RingActionID' has no member 'shortcutAction'`.

- [ ] **Step 3: Add the four new shortcut actions**

In `Sources/Gizmate/App/Shortcuts/GlobalShortcutModels.swift`, add the cases and extend all four switches:

```swift
enum GlobalShortcutAction: String, CaseIterable {
    case translateOrReply
    case translateSelection
    case screenshotArea
    case toggleInvisibility
    case askGizmate
    case toggleWritingLanguage
    case liveTranslation
    case quickMenu
    /// Explain, pinned. `translateOrReply` follows `floatingDefaultMode` and so
    /// is not Explain's key — presenting it as one in the built-in editor would
    /// be a lie.
    case explainSelection
    case replyToSelection
    case dictate
    case saveNote
```

`id`, continuing the sequence and staying clear of the fixed id 100:

```swift
        case .explainSelection: return 9
        case .replyToSelection: return 10
        case .dictate: return 11
        case .saveNote: return 12
```

`menuTitle` — note the copy rule: no "translate"/"translation" in user-facing strings:

```swift
        case .explainSelection: return "Explain selected text"
        case .replyToSelection: return "Reply to selected text"
        case .dictate: return "Dictate"
        case .saveNote: return "Keep selection as a note"
```

`group` — these four belong to a built-in, not to the app chrome:

```swift
        case .explainSelection, .replyToSelection, .dictate, .saveNote:
            return .text
```

`defaultShortcut` — E, Y, D and N are unused by the existing set (T, R, S, I, G, L, the ⌃⌥A alias, double-⌃ and Mouse 3):

```swift
        case .explainSelection:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_E), letter: "E")
        case .replyToSelection:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_Y), letter: "Y")
        case .dictate:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_D), letter: "D")
        case .saveNote:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_N), letter: "N")
```

- [ ] **Step 4: Map built-ins to their shortcut**

In `Sources/Gizmate/Ring/RingCatalog.swift`, inside `enum RingActionID`, after `promptMode`:

```swift
    /// The global hotkey this built-in owns, so its editor can rebind it and
    /// switching the built-in off can free the key.
    ///
    /// Summarize has none on purpose: it only exists in a supported chat app or
    /// browser, so a global key that does nothing most of the time is a bug
    /// report waiting to happen.
    var shortcutAction: GlobalShortcutAction? {
        switch self {
        case .explain:   return .explainSelection
        case .rewrite:   return .translateSelection
        case .reply:     return .replyToSelection
        case .ask:       return .askGizmate
        case .capture:   return .screenshotArea
        case .dictate:   return .dictate
        case .live:      return .liveTranslation
        case .saveNote:  return .saveNote
        case .summarize: return nil
        }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter BuiltInShortcutTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Register the new keys and skip disabled ones**

In `Sources/Gizmate/App/GizmateApp+HotKeysMenus.swift`, extend the `bindings` array in `setupGlobalHotKeys()`:

```swift
            (.explainSelection, { [weak self] in
                self?.startSelectionTranslateOrReply(forcing: .translate)
            }),
            (.replyToSelection, { [weak self] in
                self?.startSelectionTranslateOrReply(forcing: .smartReply)
            }),
            (.dictate, { [weak self] in self?.toggleDictation() }),
            // An empty string routes through the read-the-selection-now branch
            // in `saveSelectionToNote`, the same way the quick menu does.
            (.saveNote, { [weak self] in self?.saveSelectionToNote("") }),
```

Then, inside the `for (action, handler) in bindings` loop, add the skip as the first statement in the body:

```swift
            // A built-in switched off in its editor must free its key, not leave
            // a dead hotkey registered.
            let owner = RingActionID.allCases.first { $0.shortcutAction == action }
            if let owner, !builtInOverridesStore.isEnabled(owner) { continue }
```

`setupGlobalHotKeys()` already unregisters and rebuilds everything from scratch on each call, so re-running it after an edit is all that is needed to apply a change.

- [ ] **Step 7: Re-register when an override changes**

In `Sources/Gizmate/App/GizmateApp.swift`, extend the `builtInOverridesStore.onChange` closure added in Task 3 Step 5:

```swift
        builtInOverridesStore.onChange = { [weak self] in
            guard let self else { return }
            TranslationMode.promptOverrides = self.builtInOverridesStore.promptOverrides()
            // Switching a built-in off has to free its key immediately, not on
            // the next launch.
            self.setupGlobalHotKeys()
        }
```

- [ ] **Step 8: Surface the two app-level orphans in Settings**

`ShortcutsTab` filters to `group == .app`, which currently hides six registered hotkeys. Four of them now live in their built-in's editor. The remaining two — `translateOrReply` (follows the default mode) and `toggleWritingLanguage` — belong to no built-in, so move them into the app group in `GlobalShortcutModels.swift`:

```swift
    var group: ShortcutGroup {
        switch self {
        case .translateSelection:
            return .text
        case .explainSelection, .replyToSelection, .dictate, .saveNote:
            return .text
        case .screenshotArea, .liveTranslation:
            return .capture
        case .askGizmate:
            return .assistant
        case .toggleInvisibility, .quickMenu, .translateOrReply, .toggleWritingLanguage:
            return .app
        }
    }
```

After this, every registered hotkey is reachable from some screen: `.app` ones in Settings → Shortcuts, the rest in their built-in's editor.

- [ ] **Step 9: Verify the build and the full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, no new failures.

- [ ] **Step 10: Commit**

```bash
git add Sources/Gizmate/App/Shortcuts/GlobalShortcutModels.swift \
        Sources/Gizmate/App/GizmateApp+HotKeysMenus.swift \
        Sources/Gizmate/App/GizmateApp.swift \
        Sources/Gizmate/Ring/RingCatalog.swift \
        Tests/GizmateTests/BuiltInShortcutTests.swift
git diff --cached --stat
git commit -m "Give each built-in action its own shortcut"
```

---

### Task 6: The built-in editor panel

**Files:**

- Create: `Sources/Gizmate/MainWindow/BuiltInEditor.swift`
- Modify: `Sources/Gizmate/MainWindow/RingSlotPicker.swift:8-18` (`RingSheet`), `:32-39` (`RingSheetOverlay` switch), `:79-81` (`builtIns`), `:226-272` (`listColumn`)

**Interfaces:**

- Consumes: everything from Tasks 1–5 — `BuiltInOverride`, `BuiltInOverridesStore`, `RingActionID.promptMode`, `.shortcutAction`, `TranslationMode.shippedPromptTemplate`.
- Produces: `RingSheet.builtInEditor(RingActionID)`, `struct BuiltInEditorPanel: View`.

- [ ] **Step 1: Add the sheet case**

In `Sources/Gizmate/MainWindow/RingSlotPicker.swift`, extend `enum RingSheet`:

```swift
    /// Editing one of the shipped actions: name, icon, prompt, shortcut, on/off.
    case builtInEditor(RingActionID)
```

and the `RingSheetOverlay` switch:

```swift
            case .builtInEditor(let id):
                BuiltInEditorPanel(actionID: id)
```

- [ ] **Step 2: Show disabled built-ins as dimmed, and add the pencil**

In `RingSlotPickerPanel`, the built-in list currently offers no editing. Replace the `.builtIn` arm of `listColumn` with:

```swift
                case .builtIn:
                    ForEach(builtIns, id: \.self) { id in
                        let isOff = !bridge.builtInOverrides.isEnabled(id)
                        optionRow(
                            content: .builtIn(id),
                            symbolImage: AnyView(
                                Image(nsImage: bridge.builtInOverrides.icon(for: id).image(pointSize: 15))
                                    .renderingMode(.template)
                            ),
                            title: bridge.builtInOverrides.displayName(for: id),
                            detail: isOff ? "Switched off — open it to turn it back on." : id.summary,
                            onEdit: { bridge.ringSheet = .builtInEditor(id) }
                        )
                        .opacity(isOff ? 0.45 : 1)
                        // Assigning a switched-off action to a slot would put a
                        // permanent gap in the ring, which reads as a bug.
                        .allowsHitTesting(!isOff)
                    }
```

`optionRow` already takes `onEdit`/`onDelete` and renders a `RowIconButton` for each; pass only `onEdit`. A built-in is never deleted, only switched off.

Also make the search include a renamed built-in — change `builtIns` to:

```swift
    private var builtIns: [RingActionID] {
        RingActionID.allCases.filter {
            matches(bridge.builtInOverrides.displayName(for: $0), $0.displayName, $0.summary)
        }
    }
```

- [ ] **Step 3: Write the editor panel**

Create `Sources/Gizmate/MainWindow/BuiltInEditor.swift`, following `RingFolderEditorPanel`'s shape (same frame treatment, same `loaded` guard, same responder handoff on dismiss):

```swift
import AppKit
import SwiftUI

/// Editing one of the shipped ring actions. Everything here is an override on
/// top of what shipped, so an untouched field stays `nil` and keeps following
/// the app — including future improvements to the prompt.
struct BuiltInEditorPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let actionID: RingActionID

    @State private var name = ""
    @State private var symbolName = ""
    @State private var prompt = ""
    @State private var isEnabled = true
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    private var shippedPrompt: String? {
        actionID.promptMode?.shippedPromptTemplate
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(FlowTheme.hairline)
            ScrollView { fields.padding(20) }
            Divider().background(FlowTheme.hairline)
            footer
        }
        .frame(width: 620, height: 620)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear {
            // First pass only: re-running on a redraw would undo whatever the
            // user has typed since.
            guard !loaded else { return }
            loaded = true
            let store = bridge.builtInOverrides
            name = store.displayName(for: actionID)
            symbolName = store.overrides[actionID]?.symbol ?? ""
            prompt = store.prompt(for: actionID) ?? shippedPrompt ?? ""
            isEnabled = store.isEnabled(actionID)
            nameFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bridge.builtInOverrides.displayName(for: actionID))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text(actionID.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close editor")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingRow("Enabled",
                       subtitle: "Off hides it from the ring and frees its shortcut.") {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }

            Divider().background(FlowTheme.hairline)

            SettingRow("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.ink)
                    .focused($nameFocused)
                    .frame(width: 220)
            }

            Divider().background(FlowTheme.hairline)

            if let action = actionID.shortcutAction {
                SettingRow("Shortcut") {
                    HStack(spacing: 8) {
                        KeyCap(text: bridge.settings.shortcut(for: action).displayString)
                        SecondaryButton(title: "Change") {
                            bridge.perform(.recordShortcut(action))
                        }
                    }
                }
            } else {
                SettingRow("Shortcut",
                           subtitle: "Ring only — it appears in supported apps, so a global key would do nothing elsewhere.") {
                    EmptyView()
                }
            }

            Divider().background(FlowTheme.hairline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                IconGrid(selection: $symbolName, height: 108)
            }

            if shippedPrompt != nil {
                Divider().background(FlowTheme.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    Text("Replaces the shipped instruction. Keep the {tokens} — they carry your language, app context and writing style into the result.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    PlainTextEditor(text: $prompt)
                        .frame(minHeight: 180)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            SecondaryButton(title: "Reset to default") { resetToDefault() }
            Spacer(minLength: 0)
            SecondaryButton(title: "Cancel") { dismiss() }
            Button(action: save) {
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(FlowTheme.raisedStrong)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(FlowTheme.edge, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Each field is stored only when it actually differs from what shipped, so
    /// an untouched name keeps following the app rather than freezing today's.
    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let shipped = shippedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        bridge.builtInOverrides.save(
            BuiltInOverride(
                name: (trimmedName.isEmpty || trimmedName == actionID.displayName) ? nil : trimmedName,
                symbol: symbolName.isEmpty ? nil : symbolName,
                prompt: (trimmedPrompt.isEmpty || trimmedPrompt == shipped) ? nil : trimmedPrompt,
                isEnabled: isEnabled
            ),
            for: actionID
        )
        dismiss()
    }

    private func resetToDefault() {
        bridge.builtInOverrides.resetToDefault(actionID)
        dismiss()
    }

    /// Same responder handoff the other Ring panels do: a text field losing the
    /// window's first responder while being torn down leaves the window
    /// ignoring clicks.
    private func dismiss() {
        nameFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        bridge.ringSheet = nil
    }
}
```

- [ ] **Step 4: Verify the build**

Run: `swift build`
Expected: `Build complete!`

If `SettingRow`, `KeyCap`, `SecondaryButton`, `PlainTextEditor` or `FlowTheme` members resolve differently, read `Sources/Gizmate/MainWindow/Core/MainWindowComponents.swift` and `Sources/Gizmate/MainWindow/Sections/SharedSectionControls.swift` and match the real signatures rather than inventing wrappers.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: no new failures.

- [ ] **Step 6: Verify by hand in the running app**

```bash
pkill -f 'Gizmate' ; swift run Gizmate
```

Walk through all of it — this is UI, and no test covers it:

1. Open the main window → Home (the ring) → click any slot → "Built-in actions".
2. Click the pencil on **Dictate**. Rename it to "Speak", pick a different icon, switch **Enabled** off, Save.
3. The picker row is dimmed and reads "Switched off". Reopen the ring (middle click): Dictate's slot is an empty gap and the buttons after it have **not** shifted.
4. Press ⌃⌥D. Nothing should happen — the key is freed.
5. Reopen the editor, switch it back on, Save. Ring shows "Speak" with the new icon; ⌃⌥D starts dictation again.
6. Click "Reset to default" — the name, icon and shortcut all return to what shipped.
7. Open **Explain**'s editor. The Prompt field is populated with the token template. Change the first sentence, keep `{language}`, Save. Select text somewhere, press ⌃⌥E, and confirm the answer follows the new instruction and is still in your writing language.
8. Open **Summarize**'s editor. It shows no Prompt field and the shortcut row reads "Ring only".

- [ ] **Step 7: Commit**

```bash
git add Sources/Gizmate/MainWindow/BuiltInEditor.swift \
        Sources/Gizmate/MainWindow/RingSlotPicker.swift
git diff --cached --stat
git commit -m "Add an editor for the built-in ring actions"
```

---

## Notes for the implementer

- **The maintainer edits this worktree while you work.** Before every commit, run `git status` and `git diff --cached --stat`. If the index holds files you did not touch, commit with an explicit pathspec (`git commit -m "msg" -- path1 path2`) rather than unstaging their work. A build broken by _their_ WIP is not a reason to skip your commit — commit your files and say the build is red for an unrelated reason. A build broken by _your_ change: fix it first.
- **Task 2 Step 7 is the load-bearing check.** Everything else in this plan fails loudly. A dropped prompt token fails silently, in production, in a way that looks like the model got worse.
- **Do not "finish the rename."** Anything spelled `nugumi` is deliberate — see the identity table in `CLAUDE.md`.
