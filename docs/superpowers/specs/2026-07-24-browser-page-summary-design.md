# Browser page summary — design

2026-07-24 · branch `chat-summary` · approved by Vadim

## What

The ring's contextual "Summarize" button, which today appears only for
messengers (KakaoTalk, Telegram), also appears when the frontmost app is a
web browser. Clicking it summarizes the page open in the focused browser
window. No time-range sub-ring (Today/Week/Month) — a page has no time axis;
the button fires immediately.

## How

- **Page text via Accessibility**, not Apple Events. Nugumi already holds the
  Accessibility permission; AppleScript would need a new entitlement, a TCC
  Automation prompt per browser, and the user manually enabling "Allow
  JavaScript from Apple Events". `BrowserPageReader` (in App.swift) finds the
  largest `AXWebArea` in the focused window and collects `AXStaticText`
  values top-to-bottom, with node/char budgets (~12k tokens, same as chat).
- **Chromium browsers** (Chrome, Edge, Brave, Arc, Whale, Vivaldi, Opera)
  build their AX tree lazily: set `AXManualAccessibility = true` first
  (Chromium's "assistive client" switch), fall back to
  `AXEnhancedUserInterface` after a few polls. Safari needs neither.
- **New `TranslationMode.summarizePage`** — page-oriented system prompt
  (tolerates nav/ads boilerplate); mirrors `.summarizeChat` everywhere else:
  never persisted to history, revise/follow-up uses `.revise`, no
  composition settings, "Summary" label, "Summarizing" placeholder.
- **`RingSummarizeOption`** gains an alternative `runDirect` closure; the
  three ring-building sites render it as a single button instead of the
  time-range sub-ring.
- **Consent**: same one-time `SummaryConsent` gate before cloud backends,
  with page-appropriate alert copy ("Send this page…").
- Window title (= page title) is prepended as the first transcript line.

## Out of scope

Reading a specific tab other than the focused one; PDFs in the browser;
Firefox reader-mode niceties. If the AX walk finds no web area, the user
gets the existing plain-alert error path ("Couldn't summarize the page").
