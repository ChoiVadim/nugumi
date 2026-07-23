# Chat Summary from Local DB — Design

Date: 2026-07-23. Approved direction: decrypt the messenger's local SQLCipher
database, surface the entry point as a contextual button in the radial ring.

## Problem

Users want to summarize a KakaoTalk or Telegram conversation without leaving the
app. Neither messenger exposes an official API to read personal chat history,
and KakaoTalk's Accessibility tree is opaque (Nugumi's canonical
"AX-fails-clipboard-rescues" case), so on-screen scraping cannot bulk-read
messages. Both apps do, however, keep the full history in a **local
SQLCipher-encrypted SQLite database** that is decryptable on-device. This
feature reads that database, pulls the last N messages of the open chat, and
runs them through the existing LLM path to produce a summary.

## Scope

- **In:** KakaoTalk (`com.kakao.KakaoTalkMac`) and Telegram for macOS — the
  native AppKit app (`ru.keepcoder.Telegram`). Both use SQLCipher.
- **Out (v1):** Telegram Desktop (`org.telegram.desktop`) — its `tdata` store
  holds sessions/settings/cache but **not** recoverable message transcripts, so
  it is a dead end and is not detected as a summarizable app.
- **Out:** any network/API path (TDLib, MTProto, Kakao API). Local read only —
  nothing hits messenger servers, which keeps us off account-ban surface.

## Decisions (confirmed with Vadim)

- **Both apps ship in v1** (separate key derivation + schema each).
- **Open chat is identified by the frontmost window title** (AX `AXTitle` of the
  messenger's front window), matched against chat names in the DB. Best-effort;
  on no-match, fall back to the most-recently-active chat and note it in the
  result header.
- **Entry point is a contextual button in the radial ring**, on the free left
  arc, wearing the **frontmost messenger's app icon** (not an SF Symbol). Hover
  bubble: "Summarize KakaoTalk" / "Summarize Telegram". Only the frontmost
  messenger's button appears (you can only summarize the chat that's open).
- **Message count is chosen via a second ring layer**: clicking the messenger
  button morphs the ring into `50 · 100 · 200 · Max` buttons; picking one runs
  the summary. `Max` = most-recent messages that fit a token budget (cap ~1000
  messages / ~12k tokens, whichever is smaller).
- **Failures never crash** — every failure mode renders a human-readable message
  in the existing result panel (Vadim: "if it crashes just show the problem").
- Summary output goes through the existing `LLMBackend.translate(...)` and the
  existing result panel, in the user's target language.

## Architecture

### New unit boundary

Chat-DB decryption is an entire subsystem, so it earns its own file (the
single-file rule allows extraction for a whole subsystem):

- `Sources/Nugumi/ChatArchive.swift` — the subsystem. Contains:
  - `protocol ChatArchive` — `recentChats(limit:) -> [ChatSummary]` and
    `messages(chatID:limit:) -> [ChatLine]`, plus `isAvailable`.
  - `struct ChatSummary { id, title, lastActivity }`,
    `struct ChatLine { sender, text, date }`.
  - `KakaoArchive` and `TelegramArchive` implementations (paths + key
    derivation per app).
  - `ChatArchiveFactory.archive(forFrontmostBundleID:)` → the right archive or
    nil.
  - Window-title → chat matching helper.
- `Sources/CSQLCipher/` — vendored SQLCipher amalgamation as a **static C
  target** (`sqlite3.c`, `sqlite3.h`, module map). Compiled with
  `-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC` so it uses **Apple CommonCrypto**,
  not OpenSSL — nothing extra to bundle or sign; it links statically into the
  Nugumi binary. `Package.swift` gains the `CSQLCipher` target and Nugumi
  depends on it.

### KakaoArchive

- Container: `~/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac/`
- SQLCipher **compatibility mode 3**. Messages live in `NTChatMessage`.
- The DB **filename is itself** a PBKDF2 hash of `userId` + hardware UUID, and
  the SQLCipher key is a second PBKDF2-HMAC-SHA256 (100k iters) over a composed
  string of `hashedDeviceUUID`, `userId`, and UUID slices. Hardware UUID =
  `IOPlatformUUID` via `ioreg`. `userId` is auto-detected from the KakaoTalk
  container; if detection fails, surface an error (no silent path).
- Reference implementations: `silver-flight-group/kakaocli` (Swift, macOS,
  reads the DB read-only) and the `blluv` gist for the exact key derivation.

### TelegramArchive

- DB: `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-*/postbox/db/db_sqlite`
- SQLCipher. Key comes from `.tempkeyEncrypted`, decrypted with **AES-256-CBC
  using the constant password `"no-matter-key"`** when no Passcode Lock is set.
  If the user has a Passcode Lock, the constant fails → we cannot decrypt
  without their passcode (v1: report it, don't prompt).
- Postbox schema is undocumented/reverse-engineered; peers + messages come from
  its tables. Reference: `soakes/telegram-message-exporter`,
  `openclaw/telecrawl`, the `stek29` gist.

### Ring integration

The ring is currently hard-wired to 4 static actions and selection-gated. Two
contained changes:

1. **Dynamic, contextual action list.** `RadialActionMenuController` takes a
   built list of ring items instead of `RadialAction.allCases`. Each item is
   symbol-or-image + label + handler. `RadialMenuLayoutPolicy.buttonCenters()`
   becomes `buttonCenters(count:)` (left arc positions added); the
   `RadialMenuLayoutTests` count assertion updates to match. The 4 selection
   actions appear when `selectedText != nil`; the summarize item appears when
   the captured frontmost app is a supported messenger. The ring opens if
   **either** holds — `toggleRadialMenu`'s `guard selectedText != nil` relaxes
   to `selectedText != nil || frontmostIsSupportedMessenger`.
2. **Second layer for count.** Selecting the summarize item swaps the ring's
   buttons for `50 / 100 / 200 / Max` (reusing the same layout/animation),
   then runs the summary on pick. The center ✕/pet still dismisses.

The frontmost messenger and its front-window title must be **captured before
Nugumi's own UI takes focus** — reuse the existing frontmost-app tracking
(`lastReplacementSourcePID` and the selection-time capture). Exact capture
point is an implementation detail to verify; fallback is most-recent chat.

### Summary mode

New `TranslationMode.summarizeChat`: `resultLabel` "Summary",
`loadingPlaceholder` "Summarizing", `usesCompositionSettings = false`. Its
`systemPrompt` asks for a short TL;DR + key points + any action items, in the
target language, preserving names/dates/numbers, no invented content. The
formatted transcript (`sender: text` lines, oldest→newest, trimmed to the token
budget) is passed as the `text` argument — no transport changes to the four
backends.

## Permissions & onboarding

Reading another app's container requires **Full Disk Access**. Unlike
Accessibility/Screen Recording, FDA cannot be requested via a prompt — only
deep-linked. Onboarding/Settings gains a "Grant Full Disk Access (for chat
summaries)" step that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
Until granted, the summarize button still appears but the action reports the
missing permission in the panel (no silent failure).

## Error handling (never crash)

Each failure maps to a panel message, wrapped so exceptions become text:

| Condition                    | Message (in target language)                                      |
| ---------------------------- | ----------------------------------------------------------------- |
| No Full Disk Access          | "Grant Full Disk Access to summarize chats." + open-settings hint |
| Kakao `userId` not found     | "Couldn't read KakaoTalk account data."                           |
| Telegram Passcode Lock set   | "Telegram is passcode-locked; can't read history."                |
| SQLCipher open/key failed    | "Couldn't open the chat database (it may have updated)."          |
| Schema/query mismatch        | same as above (schema drift after messenger update)               |
| Window title → no chat match | fall back to most-recent chat; header notes it                    |
| Empty chat / no messages     | "No messages to summarize in this chat."                          |

## Privacy

Chat text (including other people's messages in group chats) is sent to the
selected LLM backend. When the active backend is a cloud provider, show a
one-time consent before the first summary; recommend the local Ollama backend
for this mode. No data leaves the machine on the local path.

## Edge cases

- **Ring opens with no selection in a messenger:** only the summarize button
  shows; the 4 selection actions are absent.
- **Frontmost app is Nugumi when the ring opens:** use the last non-Nugumi
  frontmost app for messenger detection (existing tracking).
- **Two chats with the same display name:** window-title match is ambiguous →
  pick the most-recently-active of the matches; the picker fallback covers the
  rest in a later iteration.
- **Menu-open focus theft:** window title must be read before the ring panel
  activates; verify against the existing capture timing.
- **Large chat with `Max`:** trim to the token budget from the newest end.

## Testing

`swift build`, unit tests, then manual verification via a real `.app` bundle
(the ring + AX + FDA need the signed bundle, not `swift run`):

1. Unit: `RadialMenuLayoutTests` updated for dynamic button count; key
   derivation has a fixed-vector test (known userId+UUID → known filename/key)
   so a broken derivation fails loudly.
2. KakaoTalk frontmost → ring shows the Kakao icon button → count layer →
   summary of the open chat appears in the panel.
3. Telegram-native frontmost → same with the Telegram icon.
4. Non-messenger frontmost → no summarize button; ring behaves as today.
5. FDA revoked → summarize reports the permission message, app does not crash.
6. Passcode-locked Telegram → reports the locked message.

## Open risks

- **Schema fragility:** both DBs are reverse-engineered and undocumented; a
  messenger update can break parsing. Mitigation: isolate all schema knowledge
  in the two archive types; failures degrade to a panel message. `kakaocli` /
  the Telegram exporters are our canaries for schema changes.
- **Vendored SQLCipher size:** the amalgamation is a large (~9 MB) source blob
  checked into the repo. Accepted as the standard, offline-buildable path.
- **userId auto-detection** on KakaoTalk may need a fallback input field if the
  container layout varies across versions.

## Out of scope (future)

- Telegram Desktop support (no local transcripts).
- A recent-chats picker (window-title detection is v1; picker is the fallback
  UX if detection proves unreliable).
- Passcode-locked Telegram (would need to prompt for and handle the passcode).
- Streaming/incremental summaries; summarizing a selected date range.
