# Editable built-in actions

**Date:** 2026-08-01
**Status:** approved, not yet implemented

## Problem

The nine built-in ring actions (`RingActionID`: Explain, Rewrite, Reply, Ask,
Capture, Summarize, Dictate, Live, Note) are a pure enum. Their name, icon and
prompt are hardcoded `switch` returns, and there is no way to turn one off.

Custom gizmos, by contrast, are `GizmateTool` values on disk that the slot picker
lets you edit and delete (pencil / trash rows, `RingSlotPicker.swift:261`).
Built-ins get neither button. A user who never dictates still carries Dictate in
every picker list and still has ⌃⌥-something registered for Live.

Separately, six global shortcuts are currently orphaned: `ShortcutsTab` filters to
`$0.group == .app` (`SettingsSection.swift:51`), so only _Toggle invisibility_ and
_Open quick menu_ are reachable from the UI. `askGizmate`, `liveTranslation`,
`screenshotArea`, `translateSelection`, `translateOrReply` and
`toggleWritingLanguage` still register hotkeys with nothing to rebind them from.
The code comment says they would be "bound from that tool's own settings" — that
screen does not exist.

## Goal

Make a built-in editable the way a gizmo is: rename it, change its icon, override
its prompt, rebind its shortcut, or switch it off entirely.

## Non-goals

- Reordering or restyling the ring itself. That is the Ring tab's job already.
- Editing `.revise` / `.reviseMessage` prompts — they are panel-only follow-up
  modes, not ring built-ins.
- A prompt field for the five action built-ins that have no prompt (Ask, Capture,
  Dictate, Live, Note).

## Design

### 1. Storage — `Sources/Gizmate/Ring/BuiltInOverrides.swift` (new)

```swift
struct BuiltInOverride: Codable, Equatable {
    var name: String?    // nil → shipped
    var symbol: String?  // SF Symbol name; nil → shipped icon
    var prompt: String?  // nil → shipped template
    var isEnabled = true
}
```

A `[String: BuiltInOverride]` keyed by `RingActionID.rawValue`, JSON-encoded into
UserDefaults under `builtInOverrides.v1`, behind

```swift
@MainActor final class BuiltInOverridesStore: ObservableObject {
    @Published private(set) var overrides: [RingActionID: BuiltInOverride]
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard)   // injectable for tests
}
```

Same `@Published` + `onChange` + injectable-defaults contract as `RingLayoutStore`
and `ToolsStore`, so `GizmateSettingsBridge` wires it identically.

Every field is optional and `nil` means "use what shipped". Two consequences that
are the reason for the shape:

- "Reset to default" is a dictionary removal, not a copy of default values back
  over the top.
- A user who never touched Explain's prompt still picks up improvements to it in
  future releases. Storing a materialised copy at first edit would freeze them on
  today's text forever.

`RingActionID` stays a payload-free enum. Its existing `label`, `displayName`,
`icon` and `summary` become the _shipped_ values; resolution lives on the store
(`store.name(for:)`, `store.icon(for:)`, `store.isEnabled(_:)`) so the catalog
does not gain a dependency on UserDefaults.

`symbol` is an SF Symbol name, chosen through the same `IconGrid` picker gizmos
use (`ToolEditor.swift:649`). A set `symbol` therefore always resolves to
`RingIconKind.symbol(name)`, replacing the bundled Phosphor glyph on the five
built-ins that ship one. `RingIconKind` itself is unchanged — only which case a
built-in resolves to can now differ from what shipped.

### 2. Prompt overrides — `Sources/Gizmate/Panels/TranslationModes.swift`

Four built-ins have a prompt, reached through `TranslationMode`:

| built-in  | mode                                  |
| --------- | ------------------------------------- |
| Explain   | `.selection`                          |
| Rewrite   | `.draftMessage`                       |
| Reply     | `.smartReply`                         |
| Summarize | `.summarizeChat` and `.summarizePage` |

Their prompts are not strings, they are interpolated templates. `.selection`
splices `\(targetLanguage.promptName)` in six places plus `\(appCategory.promptHint)`
and a Gen-Z block; `.draftMessage` and `.smartReply` additionally splice the
writing style, voice sample, cleanup and glossary blocks. A user override stored
as flat text would silently drop every one of those layers — Explain would stop
targeting the writing language.

So the shipped prompts become token templates, and `systemPrompt(...)` renders
whichever template is in play — shipped or overridden — through one substitution
pass:

| token            | replaces                                                    |
| ---------------- | ----------------------------------------------------------- |
| `{language}`     | `targetLanguage.promptName`                                 |
| `{app}`          | `appCategory.promptHint`                                    |
| `{writingStyle}` | `composition?.writingStyleDirective(for:)`                  |
| `{genZ}`         | `TranslationMode.genZSection(for:enabled:)`                 |
| `{voice}`        | `TranslationMode.voiceSampleSection(for:)`                  |
| `{cleanup}`      | `composition?.cleanup.promptDescription` / `cleanupSection` |
| `{glossary}`     | `TranslationMode.glossarySection(for:includeSnippets:)`     |

Substitution is a `reduce` over a `[String: String]` built from the same three
arguments `systemPrompt` already takes. Unknown tokens are left verbatim rather
than erased, so a typo in an override shows up in the output instead of vanishing.

`UserAboutContext.appending(to:)` still wraps the result, and `.revise`,
`.reviseMessage` and `.custom` keep their current interpolated form untouched.

The editor seeds its text view with the token template, so what you edit is what
ships, and "Reset to default" restores it exactly.

### 3. Turning a built-in off

Three places have to agree, or a disabled action stays half-alive:

- **Ring** — `RingConfiguration` (`Ring/RingLayout.swift:138`) gains
  `overrides: [RingActionID: BuiltInOverride]`, populated by
  `RingConfigurationProvider.current` in `GizmateApp.swift:349`.
  `RingBuilder.builtInItem` returns `nil` when the action is disabled. No new
  rendering path: a `nil` item is already drawn as a gap, which is how the
  contextual Summarize button works today.
- **Hotkey** — `setupGlobalHotKeys` (`GizmateApp+HotKeysMenus.swift:22`) skips a
  binding whose owning `RingActionID` is disabled, so switching Dictate off
  actually frees ⌃⌥D rather than leaving a dead key registered.
- **Slot picker** — disabled built-ins stay in the list, dimmed, with the assign
  button inert. Hiding them would leave a user who disabled something with no way
  to find it again.

### 4. Shortcuts

`GlobalShortcutAction` covers only part of the ring today, and one of its cases is
mode-following rather than action-specific: `translateOrReply` fires whatever
`floatingDefaultMode` currently is, so it is not Explain's shortcut and must not be
presented as one.

`startSelectionTranslateOrReply` already accepts `forcing: FloatingButtonDefaultMode?`
(`GizmateApp+Replacement.swift:17`), so pinning a mode per shortcut costs nothing.

Final mapping:

| built-in  | `GlobalShortcutAction`                              | default      |
| --------- | --------------------------------------------------- | ------------ |
| Explain   | `explainSelection` (**new**, `forcing: .translate`) | ⌃⌥E          |
| Rewrite   | `translateSelection` (existing)                     | ⌃⌥R          |
| Reply     | `replyToSelection` (**new**, `forcing: .reply`)     | ⌃⌥Y          |
| Ask       | `askGizmate` (existing)                             | double-tap ⌃ |
| Capture   | `screenshotArea` (existing)                         | ⌃⌥S          |
| Live      | `liveTranslation` (existing)                        | ⌃⌥L          |
| Dictate   | `dictate` (**new**)                                 | ⌃⌥D          |
| Note      | `saveNote` (**new**)                                | ⌃⌥N          |
| Summarize | none                                                | —            |

E, Y, D and N are unused by the existing set (T, R, S, I, G, L, A-alias,
double-⌃, Mouse 3), so no default collides. New ids continue the sequence at
9…12, clear of the fixed id 100 used by the ⌃⌥A Ask alias.

Summarize gets no hotkey. It only exists in a supported chat app or browser, so a
global key that does nothing most of the time is a bug report waiting to happen.
Its editor row reads "Ring only — no hotkey."

`translateOrReply` and `toggleWritingLanguage` survive as app-level keys. They are
not ring built-ins, so they move into `ShortcutGroup.app` and become visible in
Settings → Shortcuts alongside invisibility and the quick menu — which also
retires the orphaned-shortcut problem entirely: every registered hotkey is now
reachable from some screen.

### 5. UI

- `RingSheet` gains `case builtInEditor(RingActionID)` (`RingSlotPicker.swift:8`).
- Built-in rows in the slot picker get the pencil button gizmo rows already have,
  opening that sheet. No trash button — a built-in is disabled, never deleted.
- `Sources/Gizmate/MainWindow/BuiltInEditor.swift` (new), styled after
  `RingFolderEditor` since both are small single-purpose panels. Fields: Name,
  Icon, Enabled, Shortcut, and Prompt for the four that have one. One "Reset to
  default" clears the whole override.
- The Shortcut row reuses `bridge.perform(.recordShortcut(action))` and the
  existing `KeyCap` + "Change" pairing from `ShortcutsTab`, so conflict checking
  (`GizmateApp+HotKeysMenus.swift:389`) applies unchanged.

## Testing

- **Template fidelity (the important one).** For each of the five rewritten
  prompts, assert that the tokenized template rendered with a fixed
  `(targetLanguage, appCategory, composition)` equals the exact string the old
  interpolated version produced. This is a mechanical find-replace across roughly
  2,000 words of prompt; without this test a dropped token degrades Explain
  silently and nothing fails.
- **Store round-trip.** Save an override against a scratch `UserDefaults` suite,
  read it back, clear it, confirm the shipped value returns.
- **Disable propagation.** `RingBuilder.slots` omits a disabled built-in and
  leaves its slot as a gap rather than shifting later slots.

## Identity notes

Nothing here touches the bundle ID, the UserDefaults domain, existing shortcut
keys (`globalShortcut.<rawValue>`), or any persisted `RingActionID` raw value. New
storage is additive under a new key; an install that predates this feature reads
back an empty dictionary and behaves exactly as it does today.
