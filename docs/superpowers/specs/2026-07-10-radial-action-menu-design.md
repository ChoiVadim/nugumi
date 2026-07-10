# Radial Action Menu — Design

Date: 2026-07-10. Approved direction: variant A (custom radial panel).

## Problem

The floating bar and the pet rely on invisible gestures: click = default mode,
right-click = Rewrite, Tab = toggle Translate/Reply. The tooltip tries to teach
all three in one line ("Translate selection - right-click to Rewrite, Tab to
switch to Reply"). Nobody discovers or remembers this. There is also a
"Floating button default mode" status-bar setting that exists only to decide
what a plain click does.

## Decisions (confirmed with Vadim)

- Clicking the floating bar or the pet **always** opens a radial menu — no
  one-click fast path. Mitigation for the extra click: the ring is centered on
  the clicked element, so travel distance is minimal.
- Menu actions, existing modes only (no new `TranslationMode` case):
  | Label (hover) | Invokes |
  |---|---|
  | **Explain** | `.selection` (the translate path — label deliberately avoids "translate" wording) |
  | **Rewrite** | `.draftMessage` |
  | **Reply** | `.smartReply` |
  | **Ask** | `startAskNugumiPrompt()` |
- Applies to **both surfaces** (floating bar and pet) — one shared component.
- Legacy gestures and the default-mode setting are **deleted**, not kept as
  shortcuts.

## Architecture

One new class in `App.swift` (single-file rule): `RadialActionMenuController`.

- API: `present(around anchor: NSPoint, onSelect: (RadialAction) -> Void,
onDismiss: () -> Void)` plus `close()`. `RadialAction` is a small enum
  (`explain`, `rewrite`, `reply`, `ask`) with per-case SF Symbol + label.
- Panel: borderless non-activating `NSPanel`, `.floating` level,
  `[.canJoinAllSpaces, .fullScreenAuxiliary]`, clear background,
  `InvisibilityState.apply(to:)` — same config as the sibling panels, so the
  menu stays out of screenshots in invisibility mode.
- Layout: 4 circular buttons on a ring (~64 pt radius) around the anchor at
  fixed angles. Near screen edges the whole ring shifts to stay inside
  `visibleFrame` (the bar/pet itself does not move).
- Center: **no ✕ button** — the existing bar/pet stays visible underneath and
  a second click on it toggles the menu closed.
- Visual: circular glass buttons (`NSVisualEffectView`), SF Symbol icons,
  hover = slight scale-up + text label under the button (Logi Options+ style).
- Animation: buttons scale/fade outward from the center, ~150 ms.
- Dismissal: second click on bar/pet, click outside (local + global event
  monitors), Escape. Selecting an action closes the menu first, then invokes
  the callback.

## Wiring

- `TranslateButtonController.onClick` → present the menu anchored on the
  button. `onSelect` maps to the existing `onTranslate` / `onRewrite` /
  `onSmartReply` callbacks with the already-captured `selectedText`; `ask`
  goes through a new `onAsk` callback wired to `startAskNugumiPrompt()`
  (which already closes the floating bar itself).
- `PetController.onClick` → same menu. The existing prompt/answer dismissal
  keeps priority: if the Ask prompt or an answer bubble is open, the click
  closes it exactly as today and no menu appears.
- Loading states, result panels, and all downstream behavior are unchanged —
  the menu only replaces the "which callback" decision.

## Deletions

- `onRightClick` handlers + `invokeRewriteMode` (both controllers).
- `TabKeyInterceptor` wiring + `toggleMode()` in `TranslateButtonController`
  and the pet's Tab handling; delete the class if no other users remain.
- `FloatingButtonDefaultMode` enum, `floatingDefaultMode` accessor, the
  status-bar menu item (`MenuItemTag.floatingDefaultMode`), the
  `"floatingButtonDefaultMode"` defaults key (including the reset-settings
  list), and `makeStatusBarIcon(for:)`'s dependence on it.
- Tooltip strings teaching right-click/Tab gestures.

## Edge cases

- **Screen edges:** ring clamps into `visibleFrame`.
- **Loading:** the bar/pet already sets `ignoresMouseEvents` while a request
  is in flight, so the menu cannot open mid-request.
- **Selection loss:** `selectedText` is captured when the bar appears; the
  menu's panels are non-activating, so opening it does not disturb focus or
  the selection.
- **Ask prompt open (pet):** click closes the prompt (existing behavior),
  menu does not stack on top.

## Testing

`swift build`, then manual verification via `swift run Nugumi`:

1. Floating bar: click → ring appears; each of the 4 actions fires the right
   mode; second click / Escape / outside click dismisses.
2. Pet mode: same, plus prompt-open click still dismisses the prompt.
3. Near screen edge: ring stays fully on-screen.
4. Status bar: default-mode item is gone; reset-settings still works.
