# Ring slots 7–8: Live + Dictation — design

2026-07-24 · branch `chat-summary` · decisions by Vadim (engine: OpenAI realtime; output: per-phrase insertion)

## What

The two free ring slots (top, top-left) gain always-present buttons in all
three rings (quick-menu, pet, floating button):

- **Live** — toggles the existing live captions (`toggleLiveTranslation()`).
- **Dictate** — plain speech-to-text: mic → OpenAI realtime transcription
  (`intent=transcription`, `gpt-4o-transcribe`, server VAD) → each completed
  phrase is typed into the field holding the caret via the existing ⌘V
  machinery. Language auto-detected — no dictation-language setting.

## How

- `RealtimeTranscriptionSession` + `DictationController` live in
  LiveTranslation.swift (the audio/realtime subsystem file), reusing
  `AudioBatcher`, `MicrophoneCapture`, `RecordIndicatorView`, and the same
  OpenAI-Safety-Identifier install id.
- Clipboard: snapshotted once at dictation start, each phrase pastes
  `text + " "`, snapshot restored 0.6 s after stop if nothing else claimed
  the pasteboard. (Deliberately NOT `PasteboardTextInserter` — its per-call
  snapshot/restore races when phrases arrive faster than its 0.55 s window.)
- A floating glass REC pill (клик = stop) sits above the live pill's
  default bottom-right spot; elapsed-time ticker.
- Same key gate and mic-permission alerts as live captions
  (`presentLiveTranslationAPIKeyAlert(feature:)` parameterized).
- Ring icons: SF Symbols `waveform`/`mic` until matching Phosphor PNGs are
  bundled (the ring just migrated to Phosphor).

## Out of scope

Partial (in-progress) text preview; smart spacing/punctuation around
inserted phrases; stopping dictation when live captions grab the mic.
