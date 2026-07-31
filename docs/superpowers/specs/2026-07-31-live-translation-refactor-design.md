# Live Translation Refactor Design

## Goal

Replace the 2,563-line
`Sources/Gizmate/Live/LiveTranslation.swift` catch-all with focused files so
audio transport, capture, caption UI, translation orchestration, and dictation
can be edited independently without changing runtime behavior.

## Current Problem

The file currently combines nine distinct responsibilities:

- language, dialogue, and persisted audio-source models;
- PCM batching, conversion, microphone capture, and system-audio capture;
- Realtime translation WebSocket transport and event decoding;
- caption/recording AppKit view primitives;
- summary and grounded follow-up networking;
- caption-window construction and presentation;
- live-translation orchestration and cost accounting;
- Realtime transcription transport;
- dictation orchestration and pasteboard insertion.

Small changes force maintainers and coding agents to load unrelated networking,
audio, AppKit, and dictation code at once.

## Chosen Approach

Perform pure code-motion extraction inside the existing `Gizmate` SwiftPM
target. Preserve declaration names, access levels, callback wiring, JSON
payloads, UI copy, constraints, notification behavior, persistence keys,
timing constants, and lifecycle order.

The file already uses internal top-level types to communicate between these
responsibilities, so no access widening is required. Private helpers remain
beside the declaration that owns them.

## Target File Layout

Create these files under `Sources/Gizmate/Live/`:

| File | Responsibility |
| --- | --- |
| `LiveTranslationModels.swift` | `LiveTranslationLanguage`, `LiveDialogue`, and `LiveAudioSource` |
| `LiveAudioPipeline.swift` | `AudioBatcher`, PCM conversion, microphone/system capture, and the sample-buffer bridge |
| `RealtimeTranslationSession.swift` | debug event logging, event decoding, and translation WebSocket lifecycle |
| `LiveCaptionViews.swift` | recording indicator, scroll/panel subclasses, hover button, and drag handle |
| `LiveSummarizer.swift` | summary and grounded follow-up HTTP requests |
| `LiveCaptionPanelController.swift` | caption and summary window construction/presentation |
| `LiveTranslationController.swift` | live-session orchestration, source switching, pause/restart, and cost accounting |
| `RealtimeTranscriptionSession.swift` | dictation WebSocket lifecycle |
| `DictationController.swift` | microphone-to-caret dictation and recording-pill lifecycle |

Delete `LiveTranslation.swift` only after every declaration has moved and the
build succeeds. `Package.swift` remains unchanged because SwiftPM discovers the
new files recursively.

Most files will remain below 400 lines. `LiveCaptionPanelController.swift` is a
deliberate exception at roughly 890 lines: it is one tightly stateful AppKit
controller whose presentation helpers consume many private views, constraints,
and flags. Splitting that type across files would require broad access-level
widening or a behavioral collaborator redesign. Keeping one coherent,
privacy-preserving controller is safer and still removes roughly two-thirds of
the unrelated context from edits to it.

## Boundary Rules

1. Keep logic, UI copy, dimensions, constraints, selectors, callback order,
   transport payloads, retry behavior, timing, and cost calculations unchanged.
2. Preserve all persistence keys, safety-identifier behavior, API endpoints,
   session configuration, and app identity.
3. Preserve existing access levels. Do not make declarations public.
4. Keep the private `CMSampleBuffer` extension beside `SystemAudioCapture`.
5. Keep the `NSTextFieldDelegate` extension with
   `LiveCaptionPanelController`.
6. Do not split a class body into cross-file extensions if doing so would
   expose private state.
7. Do not add targets, dependencies, warning cleanup, UI redesign, or feature
   work.

## Extraction Sequence

1. Extract models and the audio pipeline.
2. Extract translation transport and summarization.
3. Extract caption view primitives and the caption panel controller.
4. Extract the live-translation orchestrator.
5. Extract transcription transport and dictation, then delete the original.

Run `swift build` and `git diff --check` after every step.

## Verification

Verification must include:

1. incremental builds after every extraction task;
2. `swift test --filter LiveTranslationTests`;
3. full `swift test`;
4. `git diff --check`;
5. a scope audit proving `Package.swift`, resources, tests, and production
   files outside `Live/` are unchanged by this tranche;
6. a declaration audit proving every original top-level and nested declaration
   remains present exactly once;
7. a code-motion audit proving declaration bodies and access levels did not
   change;
8. a source-size audit proving the catch-all is gone and the documented
   controller exception is the only replacement above roughly 400 lines.

The focused suite covers language mapping, event decoding, dialogue
segmentation, loop collapse, audio batching, PCM downsampling, and caption-panel
construction/rendering. Real microphone and ScreenCaptureKit permission flows
are not re-exercised because this tranche changes source organization only; no
TCC-sensitive code or app identity changes.

## Completion Criteria

- `LiveTranslation.swift` no longer exists.
- Its declarations compile from nine responsibility-focused files.
- No access-level or runtime-logic change was introduced.
- Focused and full tests pass with no new failures.
- Independent review confirms exact code motion and scope alignment.
