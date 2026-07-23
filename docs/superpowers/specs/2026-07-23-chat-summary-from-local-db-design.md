# Chat Summary from Local DB — Design

Date: 2026-07-23. Approved direction: decrypt the messenger's local SQLCipher
database, surface the entry point as a contextual button in the radial ring.
**Scope narrowed 2026-07-23: KakaoTalk ships first; Telegram is a separate
follow-up plan** (see Scope for why).

## Problem

Users want to summarize a KakaoTalk conversation without leaving the app.
KakaoTalk exposes no official API to read personal chat history, and its
Accessibility tree is opaque (Nugumi's canonical "AX-fails-clipboard-rescues"
case), so on-screen scraping cannot bulk-read messages. It does, however, keep
the full history in a **local SQLCipher-encrypted SQLite database** that is
decryptable on-device. This feature reads that database, pulls the last N
messages of the open chat, and runs them through the existing LLM path to
produce a summary.

## Scope

- **v1: KakaoTalk only** (`com.kakao.KakaoTalkMac`). Once its SQLCipher pages
  are decrypted, message bodies are **plaintext** in a normal SQLite table
  (`NTChatMessage.message`), read with ordinary SQL joins — a direct port.
- **Follow-up plan: Telegram for macOS** (`ru.keepcoder.Telegram`). It uses the
  same SQLCipher wrapper, but its Postbox store is a key-value schema
  (`t0/t2/t6/t7`, `(key,value)` BLOB columns) whose message payload is a
  **bespoke recursive binary serialization** — a hundreds-of-lines custom
  parser, materially larger and more fragile than Kakao. It reuses this v1's
  UI/permission/mode scaffolding and slots in behind the same `ChatArchive`
  protocol. Deferred deliberately so it can't block the Kakao release.
- **Out:** Telegram Desktop (`org.telegram.desktop`) — its `tdata` store has no
  recoverable transcripts. Any network/API path (TDLib, MTProto, Kakao API) —
  local read only, nothing hits messenger servers.

## Decisions (confirmed with Vadim)

- **KakaoTalk first**, Telegram as a separate later plan (effort asymmetry
  above). The `ChatArchive` protocol is designed now so Telegram is a drop-in.
- **Open chat is identified by the frontmost window title** (AX `AXTitle` of the
  messenger's front window), matched against chat names in the DB. Best-effort;
  on no-match, fall back to the most-recently-active chat and note it in the
  result header.
- **Entry point is a contextual button in the radial ring**, on the free left
  arc, wearing the **frontmost messenger's app icon** (not an SF Symbol). Hover
  bubble: "Summarize KakaoTalk". Appears only when the captured frontmost app is
  KakaoTalk.
- **Message count is chosen via a second ring layer**: clicking the messenger
  button morphs the ring into `50 · 100 · 200 · Max` buttons; picking one runs
  the summary. `Max` = most-recent messages that fit a token budget (cap 1000
  messages / ~12k tokens, whichever is smaller).
- **Failures never crash** — every failure mode renders a human-readable message
  in the existing result panel (Vadim: "if it crashes just show the problem").
- Summary output goes through the existing `LLMBackend.translate(...)` and the
  existing result panel, in the user's target language.

## Reference implementations (ported, not vendored)

The key derivation and schema are reverse-engineered. We **port and verify**
against these public references; we do **not** vendor their repos, and the
ported code is read for correctness/safety before integration (see Security):

- `silver-flight-group/kakaocli` (Swift, macOS) — key derivation, DB open,
  `NTChatMessage`/`NTChatRoom`/`NTUser` queries.
- `blluv` gist — canonical Python key derivation (cross-check).

## Architecture

### New unit boundary

Chat-DB decryption is an entire subsystem, so it earns its own file (the
single-file rule allows extraction for a whole subsystem):

- `Sources/Nugumi/ChatArchive.swift` — the subsystem:
  - `protocol ChatArchive` — `recentChats(limit:) -> [ChatSummary]`,
    `messages(chatID:limit:) -> [ChatLine]`, `isAvailable`.
  - `struct ChatSummary { id: Int64, title: String, lastActivity: Date? }`,
    `struct ChatLine { sender: String, text: String, date: Date }`.
  - `KakaoKeyDerivation` (ported: `platformUUID`, `hashedDeviceUUID`, `pbkdf2`,
    `databaseName`, `secureKey`), `KakaoUserID` (plist heuristics),
    `SQLCipherDatabase` (thin CSQLCipher wrapper), `KakaoArchive`.
  - `ChatArchiveFactory.archive(forFrontmostBundleID:)`.
  - Window-title → chat matching helper.
- `Sources/CSQLCipher/` — vendored SQLCipher amalgamation as a **static C
  target** (`sqlite3.c`, `sqlite3.h`, module map), compiled with
  `-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC` so it uses **Apple CommonCrypto**,
  not OpenSSL — nothing extra to bundle or sign; links statically into the
  Nugumi binary. `Package.swift` gains the `CSQLCipher` target; Nugumi depends
  on it and links `Security`/`Foundation`.

### KakaoArchive (confirmed details)

- Container: `~/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac/`
- DB filename is a 78-char hex slice of a PBKDF2 over `userId` + hardware UUID;
  the SQLCipher key is a second PBKDF2 (HMAC-SHA256, 100k iters, 128-byte out)
  over a composed string. Hardware UUID = `IOPlatformUUID` (uppercase, hashed
  raw). `PRAGMA cipher_default_compatibility` is tried **3 then 4** before
  `PRAGMA KEY='<256-hex passphrase>'` (passphrase form, not `x'…'` raw key).
- `userId` comes from KakaoTalk's preference plists (chicken-and-egg: needed to
  derive the filename/key before the DB can open). Heuristics ported from
  kakaocli; multiple candidate ids are tried against the DB until one opens.
- Messages: `NTChatMessage` — `message` is **plaintext UTF-8** post-decrypt;
  `authorId`, `sentAt` (epoch seconds), `chatId`. Sender name joined from
  `NTUser` (`displayName → friendNickName → nickName`, `AND linkId = 0`).
- Chats: `NTChatRoom` — group title `chatName`, direct chats resolve to the
  friend via `directChatMemberUserId → NTUser`; sort by `lastUpdatedAt DESC`.

### Ring integration

The ring is currently hard-wired to 4 static actions and selection-gated. Two
contained changes:

1. **Dynamic, contextual action list.** `RadialActionMenuController` takes a
   built list of ring items instead of `RadialAction.allCases`. Each item is
   symbol-or-image + label + handler. `RadialMenuLayoutPolicy.buttonCenters()`
   becomes `buttonCenters(count:)` (left-arc positions added); the
   `RadialMenuLayoutTests` count assertion updates. The 4 selection actions
   appear when `selectedText != nil`; the summarize item appears when the
   captured frontmost app is KakaoTalk. The ring opens if **either** holds —
   `toggleRadialMenu`'s `guard selectedText != nil` (App.swift:7880) relaxes to
   `selectedText != nil || frontmostIsKakao`.
2. **Second layer for count.** Selecting the summarize item swaps the ring's
   buttons for `50 / 100 / 200 / Max` (reusing the same layout/animation), then
   runs the summary on pick. The center pet still dismisses.

The frontmost app and its front-window title must be **captured before Nugumi's
own UI takes focus** — reuse the existing frontmost tracking. Fallback is the
most-recent chat.

### Summary mode

New `TranslationMode.summarizeChat`: `resultLabel` "Summary",
`loadingPlaceholder` "Summarizing", `usesCompositionSettings = false`. Its
`systemPrompt` asks for a short TL;DR + key points + any action items, in the
target language, preserving names/dates/numbers, no invented content. The
formatted transcript (`sender: text` lines, oldest→newest, trimmed to the token
budget) is passed as the `text` argument — no transport changes to the four
backends.

## Permissions & onboarding

Reading another app's container requires **Full Disk Access**. macOS has no API
to query FDA; probe it by attempting to list the KakaoTalk container — success
means we can decrypt, a permission error means we can't (the gate and the
capability are the same op). Unlike Accessibility/Screen Recording, FDA cannot
be prompted — only deep-linked. `Onboarding.swift` gains a
`PermissionKind.fullDiskAccess` step that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
Until granted, the summarize button still appears but the action reports the
missing permission in the panel (no silent failure).

## Error handling (never crash)

Each failure maps to a panel message, wrapped so exceptions become text:

| Condition                                  | Message (in target language)                                      |
| ------------------------------------------ | ----------------------------------------------------------------- |
| No Full Disk Access                        | "Grant Full Disk Access to summarize chats." + open-settings hint |
| Kakao `userId` not found                   | "Couldn't read KakaoTalk account data."                           |
| SQLCipher open/key failed (all candidates) | "Couldn't open the chat database (it may have updated)."          |
| Schema/query mismatch                      | same as above (schema drift after a KakaoTalk update)             |
| Window title → no chat match               | fall back to most-recent chat; header notes it                    |
| Empty chat / no messages                   | "No messages to summarize in this chat."                          |

## Security

The ported derivation code is read for correctness and for anything malicious
(network calls, exfiltration, unexpected writes) before integration; downloaded
reference files are treated as read-only reference and are never executed. The
subsystem only ever **reads** the container (SQLite opened `READONLY`). This is
the user's own machine, own data, own app, with explicit consent gates — a
personal/defensive use, not third-party access.

## Privacy

Chat text (including other people's messages in group chats) is sent to the
selected LLM backend. When the active backend is a cloud provider, show a
one-time consent before the first summary; recommend the local Ollama backend
for this mode. No data leaves the machine on the local path.

## Edge cases

- **Ring opens with no selection in KakaoTalk:** only the summarize button
  shows; the 4 selection actions are absent.
- **Frontmost app is Nugumi when the ring opens:** use the last non-Nugumi
  frontmost app for detection (existing tracking).
- **Two chats with the same display name:** window-title match is ambiguous →
  pick the most-recently-active of the matches.
- **Menu-open focus theft:** window title read before the ring panel activates.
- **Large chat with `Max`:** trim to the token budget from the newest end.

## Testing

`swift build`, unit tests, then manual verification via a real `.app` bundle
(ring + AX + FDA need the signed bundle, not `swift run`):

1. Unit: key derivation determinism + shape (78-char filename, non-empty key)
   against a fixed input pair; `SQLCipherDatabase` round-trips an encrypted
   fixture DB it created; SQL queries run against a synthetic DB built with the
   `NTChatMessage`/`NTChatRoom`/`NTUser` schema; transcript trimming honors the
   count and token cap; `RadialMenuLayoutTests` updated for dynamic count.
2. KakaoTalk frontmost → ring shows the Kakao icon button → count layer →
   summary of the open chat appears in the panel.
3. Non-messenger frontmost → no summarize button; ring behaves as today.
4. FDA revoked → summarize reports the permission message, app does not crash.

## Open risks

- **Schema fragility:** the DB is reverse-engineered; a KakaoTalk update can
  break parsing. Mitigation: isolate all schema knowledge in `KakaoArchive`;
  failures degrade to a panel message. `kakaocli` is our canary.
- **Vendored SQLCipher size:** the amalgamation is a large (~9 MB) source blob
  checked into the repo. Accepted as the standard, offline-buildable path.
- **userId auto-detection** may need a manual-entry fallback if the container
  plist layout varies across KakaoTalk versions.
- **`message` plaintext assumption:** some KakaoTalk builds historically added a
  per-row layer for certain message types; verify against a real DB and skip
  rows we can't decode rather than crashing.

## Out of scope (future)

- Telegram for macOS (separate follow-up plan — bespoke Postbox binary parser).
- Telegram Desktop (no local transcripts).
- A recent-chats picker (window-title detection is v1; picker is the fallback).
- Streaming/incremental summaries; summarizing a selected date range.
