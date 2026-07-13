# Auto-insert for Rewrite and Reply

**Date:** 2026-07-13
**Status:** Approved

## Problem

- Rewrite is governed by a `replacementMode` setting (`instantInsert` default / `showPanel`). Instant insert blindly synthesizes Cmd+V; if focus is not in an editable field, the result is silently lost.
- Reply always opens the result panel, even when the chat compose box is focused and the reply could land directly in it.

## Behavior

At trigger time (before the LLM call), check via Accessibility whether the **focused** element — the element a synthesized Cmd+V would paste into — is editable. Three outcomes:

|             | `editable`                | `notEditable` | `unknown` (AX unreadable, e.g. KakaoTalk)                                         |
| ----------- | ------------------------- | ------------- | --------------------------------------------------------------------------------- |
| **Rewrite** | insert in place           | show panel    | **insert** (preserves current blind-paste behavior)                               |
| **Reply**   | insert into focused field | show panel    | **panel** (preserves current behavior; reply must never be lost to a blind paste) |

The asymmetry on `unknown` keeps both modes behaving exactly as today in AX-broken apps — zero regression in KakaoTalk, the canonical test case.

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
