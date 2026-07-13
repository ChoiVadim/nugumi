# Auto-insert for Rewrite and Reply

**Date:** 2026-07-13
**Status:** Approved

## Problem

- Rewrite is governed by a `replacementMode` setting (`instantInsert` default / `showPanel`). Instant insert blindly synthesizes Cmd+V; if focus is not in an editable field, the result is silently lost.
- Reply always opens the result panel, even when the chat compose box is focused and the reply could land directly in it.

## Behavior

At trigger time (before the LLM call), check via Accessibility whether the **focused** element — the element a synthesized Cmd+V would paste into — is editable. Three outcomes:

|             | `editable`                | `notEditable`                                                                     | `unknown` (AX unreadable, e.g. KakaoTalk)           |
| ----------- | ------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------- |
| **Rewrite** | insert in place           | show panel                                                                        | **insert** (preserves current blind-paste behavior) |
| **Reply**   | insert into focused field | find + focus the compose field in the focused window, insert; panel if none found | **insert** (blind paste, same as rewrite)           |

**Amendment 1 (same day):** the focused element alone is the wrong gate for reply — selecting the incoming message moves AX focus onto the message list. `SelectionReader.focusEditableComposeField()` backs the `notEditable` case: a bounded (250-node) breadth-first walk of the frontmost app's focused window collects `AXTextArea`/`AXTextField` candidates (skipping `AXSearchField` subroles and whole `AXToolbar` subtrees — a browser's URL bar is an `AXTextField`), picks the bottom-most (compose boxes live at the bottom; search bars at the top), and focuses it via `kAXFocusedAttribute` so the synthesized Cmd+V lands there. Any failure → panel.

**Amendment 2 (same day):** reply's `unknown` case now blind-pastes, symmetric with rewrite. Field evidence (Telegram): the app reports no readable AX focus at all (`unknown`) yet routes Cmd+V to its compose box regardless of focus — the same property that makes rewrite's blind paste work in KakaoTalk. Panelling on `unknown` made reply dead in exactly the apps where insertion works best. The reply is recorded to history before pasting, so a paste that lands nowhere is still recoverable.

The `replacementMode` setting is **removed entirely**; behavior is always automatic.

## Changes (all in `Sources/Nugumi/`)

1. **`SelectionReader.focusedElementEditability()`** — new tri-state helper. Starts at the focused element, walks up to 6 ancestors looking for `editableTextRoles` (existing set). Returns `.editable` on a role match; `.unknown` if no focused element is readable or no role could be read at all; `.notEditable` otherwise.
2. **`rewriteSelectedDraftText`** — replace `switch replacementMode` with the editability check: `.notEditable` → panel path, otherwise → `runInstantTranslation`.
3. **`replyToSelection`** — when `.editable`: set `lastReplacementSourcePID`, run the instant path (paste via existing `replaceCurrentSelection`, which reactivates the source app first). Otherwise: existing panel path, unchanged.
4. **`runInstantTranslation`** — gains a `mode` parameter (`.draftMessage` / `.smartReply`) driving the translate call, `usageKind`, `recordTranslation` kind, and the analytics error context (`instant_rewrite` / `instant_reply`).
5. **Setting removal** — delete `ReplacementMode` enum, the `replacementMode` computed property, `MenuItemTag.replacementMode`, `SettingsSnapshot.replacementMode`, `.setReplacementMode` action + handler, and the "Replace action" row in `MainWindowSections.swift`. Keep the `"replacementMode"` string in the reset-to-defaults wipe list so stale keys on existing installs get cleaned.

## Out of scope

- Screenshot-reply keeps the panel (source is a screen area; no meaningful insert target).
- The revise/follow-up flow, panel Replace button, and clipboard-fallback selection reading are untouched.

## Error handling

- Instant reply path reuses `runInstantTranslation`'s existing failure handling (loading bar teardown, onboarding routing, error toast).
- Focus check happens once at trigger time; focus drift during the LLM call is already handled by `replaceCurrentSelection` reactivating `lastReplacementSourcePID`.

## Testing

- `swift build` passes; no references to `ReplacementMode` remain.
- Manual: rewrite own draft in an editable field → in-place replace; rewrite selection on a static web page → panel; reply with compose box focused (Slack/Telegram) → reply lands in compose box; reply on static page → panel; KakaoTalk rewrite still inserts, KakaoTalk reply still panels.
