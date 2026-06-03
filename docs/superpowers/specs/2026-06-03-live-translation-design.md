# Live Translation — Real-time speech-to-text captions

**Status:** Approved design, pre-implementation
**Date:** 2026-06-03
**Feature:** Two-way live translation captions powered by OpenAI `gpt-realtime-translate`.

## Summary

Add a real-time translation feature to Nugumi that listens to live audio and shows a
running, translated **transcript** (captions) in a floating panel. Two audio sources are
captured — the user's **microphone** and **system/app audio** (a call, a video) — and both
streams are translated into Nugumi's existing target-language setting via the OpenAI
Realtime translation model. No translated audio is played back; this is captions-only.

The feature is gated on an OpenAI API key (Realtime is not available through the
Codex/ChatGPT-subscription path).

## Goals

- Capture system audio and microphone audio in real time on macOS 14+.
- Stream each source to `gpt-realtime-translate` over the Realtime translation WebSocket.
- Render translated transcript deltas as live captions, labelled by speaker (`Them` / `Me`).
- Start/stop via a status-bar menu item **and** a global hotkey.
- Surface running cost (per-minute billing) and clear, actionable errors.

## Non-goals (v1)

- No translated-audio playback (no speech-to-speech output, no ducking/overlap handling).
- No per-direction target languages (both directions use the single existing target).
- No transcript persistence/export, no history across sessions.
- No local VAD silence-gating cost optimization (noted as future work).

## Decisions (from brainstorming)

| Question     | Decision                                                                         |
| ------------ | -------------------------------------------------------------------------------- |
| Audio source | **Both directions** — microphone + system audio.                                 |
| Output       | **Transcript-only captions** (ignore model's audio output).                      |
| Languages    | **Reuse the existing `targetLanguage` setting**; both streams translate into it. |
| UI surface   | **Menu item + global hotkey**, shared floating caption panel.                    |
| Build order  | **Incoming-first** (system audio) Phase 1, then **mic** Phase 2.                 |

## Realtime protocol (verified against OpenAI docs)

- **WebSocket URL:** `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`
- **Headers:** `Authorization: Bearer <OPENAI_API_KEY>`, `OpenAI-Safety-Identifier: <hashed-user-id>`
- **Configure target language** after open:
  ```json
  {
    "type": "session.update",
    "session": { "audio": { "output": { "language": "ko" } } }
  }
  ```
- **Input audio:** base64-encoded **24 kHz PCM16 mono**, sent as:
  ```json
  { "type": "session.input_audio_buffer.append", "audio": "<base64Pcm16>" }
  ```
- **Server events consumed:**
  - `session.output_transcript.delta` — translated transcript (**the captions we render**).
  - `session.input_transcript.delta` — source-language transcript (optional, may show faintly).
  - `session.output_audio.delta` — translated audio (**ignored** in v1).
- **Teardown handshake:** send `{ "type": "session.close" }`, keep reading until
  `session.closed`, then close the socket.

> The exact event-name set should be re-confirmed against the live API reference during
> implementation; the session decoder must tolerate unknown event types (ignore-and-continue).

### Language-code mapping

`TargetLanguage.id` maps 1:1 to the API ISO code for `ru/en/ko/ja/es/fr`. `zh-Hans` must be
mapped to `zh`. A small `apiLanguageCode(for:)` helper centralizes this; unknown ids fall
back to their raw `id`.

## Architecture

New file: `Sources/Nugumi/LiveTranslation.swift` (entire subsystem — justified per
`CLAUDE.md`, following the `Bootstrap.swift` precedent). Wire-up edits in `App.swift`
(menu item, hotkey registration) and `Resources/Info.plist` (microphone usage string).

```
┌─ Mic (AVAudioEngine tap) ─────→ PCM16Downsampler ─→ RealtimeTranslationSession A (WS) ─┐
│                                                                                         ├─→ LiveTranslationController ─→ Caption panel
└─ System audio (ScreenCaptureKit) → PCM16Downsampler → RealtimeTranslationSession B (WS)┘        (transcript model)        (Them / Me rows)
```

### Components

1. **`PCM16Downsampler`** — wraps `AVAudioConverter`. Converts arbitrary input format to
   24 kHz mono PCM16 little-endian `Data`. Shared by both capture sources.

2. **`SystemAudioCapture`** (Phase 1) — `SCStream` with `capturesAudio = true`,
   `excludesCurrentProcessAudio = true`, a minimal display content filter. Delivers
   `CMSampleBuffer` audio → `PCM16Downsampler` → `onPCM(Data)` callback. Reuses the
   existing screen-recording permission (`NSScreenCaptureUsageDescription`).

3. **`MicrophoneCapture`** (Phase 2) — `AVAudioEngine` input-node tap → `PCM16Downsampler`
   → `onPCM(Data)`. Requires new `NSMicrophoneUsageDescription` + `AVCaptureDevice`
   authorization for `.audio`.

4. **`RealtimeTranslationSession`** — wraps a `URLSessionWebSocketTask`.
   - `connect(language:)` opens the socket and sends `session.update`.
   - `append(_ pcm: Data)` batches ~100 ms of audio, base64-encodes, sends
     `session.input_audio_buffer.append`.
   - Receive loop decodes events; emits `onTranslatedDelta(String)`,
     optional `onSourceDelta(String)`, `onError(Error)`, `onClosed`.
   - `close()` performs the `session.close` → `session.closed` handshake.
   - Auto-reconnect with exponential backoff on unexpected drop.

5. **`LiveTranslationController`** — owns lifecycle and the transcript model.
   - `start()`: verify OpenAI API key present (else actionable error) → request required
     permission(s) → create capture(s) + session(s) → present panel.
   - `stop()`: close sessions (handshake), stop captures, keep panel showing the final
     transcript until dismissed.
   - Holds an ordered list of caption lines `{ speaker: Them|Me, text, finalized: Bool }`;
     output deltas update the current partial line; finalization rolls to a new line.
   - Tracks elapsed time and a running cost estimate (~$0.034/min × number of active
     sessions).

6. **Caption panel** — floating non-activating `NSPanel` (`.floating` level,
   drag-by-background), matching app styling. Contains:
   - Status header: Connecting / Listening / Error, plus target-language label.
   - Scrolling transcript: speaker-labelled rows; the last row updates live from deltas.
   - Footer: elapsed time + estimated cost, Start/Stop control, close button.

### Entry points

- New **"Live Translation…"** item in the status-bar menu (toggles the controller).
- A **global hotkey** registered through the existing hotkey infrastructure, backed by a
  new `Defaults` key for the shortcut. Both invoke the same `LiveTranslationController`.

## Permissions

- **Microphone:** add `NSMicrophoneUsageDescription` to `Info.plist`; request via
  `AVCaptureDevice.requestAccess(for: .audio)` on first start (deferred, mirroring the
  app's existing deferred-permission approach — not at launch).
- **System audio:** reuses the existing `NSScreenCaptureUsageDescription`; the
  ScreenCaptureKit stream triggers the screen-recording prompt on first start.
- No silent failure paths: a denied permission shows a message with a System Settings
  deep link (reusing existing helpers).

## Error handling

- **No API key** → message routing the user to API-key settings; do not start capture.
- **Permission denied** → message + System Settings deep link; do not start that source.
- **WebSocket drop** → panel status reflects reconnecting; exponential backoff; surface a
  persistent error only after repeated failures.
- **Capture failure** → stop that source with a clear message; the other source continues.

## Cost / billing safety

Realtime translation is billed ~**$0.034 per minute of audio per session**, so two active
sessions ≈ **$0.068/min**. The panel always shows elapsed time and a running cost estimate.
Future optimization (out of scope): local VAD to avoid streaming silence, and/or idle
auto-pause.

## Known semantic

Because both directions translate into the single existing target language, speaking the
target language into the mic is a near-no-op. With target = the user's native language this
reads naturally as "caption everyone, including me, in my language." Speaker labels keep it
legible. A per-direction target language is a straightforward future addition.

## Testing

- **Unit:** `apiLanguageCode(for:)` mapping; server-event JSON decoding (incl.
  unknown-event tolerance); downsampler chunk sizing. The session decoder is exercised with
  a mock WebSocket feed.
- **Manual E2E:** play a foreign-language video → verify live captions appear and finalize
  correctly; toggle via menu and hotkey; deny/grant permissions; pull network mid-session to
  verify reconnect.
- **Bundle requirement:** mic/screen-recording permission identity is stable only in the
  signed bundle (designated requirement pinned to `com.nugumi.app`). Final verification runs
  `bash Scripts/build-app-bundle.sh` → `dist/Nugumi.app`, not `swift run`.

## Phasing

- **Phase 1 — Incoming:** `PCM16Downsampler`, `SystemAudioCapture`,
  `RealtimeTranslationSession`, `LiveTranslationController` (single session), caption panel,
  menu item + hotkey, language-code mapping, error/permission handling. End-to-end testable
  by captioning system audio.
- **Phase 2 — Mic:** `MicrophoneCapture`, second session, `Me` speaker labelling,
  `NSMicrophoneUsageDescription`, mic permission flow, two-session cost display.
