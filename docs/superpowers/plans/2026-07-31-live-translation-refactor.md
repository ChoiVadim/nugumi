# Live Translation Refactor Implementation Plan

**Status:** Implemented and verified. Checkboxes below preserve the original
pre-implementation contract; they are not a live progress tracker.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task by task.

**Goal:** Replace `LiveTranslation.swift` with focused files so live audio,
transport, captions, summarization, orchestration, and dictation can be edited
independently without changing behavior.

**Architecture:** Keep every declaration in the existing `Gizmate` target and
perform pure code motion along existing top-level declaration boundaries. No
access widening is required. One tightly stateful caption-panel controller
remains above the normal size guideline to preserve private state.

**Tech Stack:** Swift 5 language mode, AppKit, AVFoundation, ScreenCaptureKit,
Foundation, Carbon, Swift Package Manager, XCTest

## Global Constraints

- Deployment target remains macOS 14.
- `Package.swift`, dependencies, app identity, persistence keys, safety IDs,
  endpoints, JSON payloads, transport retry behavior, timing constants, cost
  calculations, UI copy, constraints, selectors, callbacks, and lifecycle
  ordering must not change.
- No new targets or dependencies.
- Preserve existing access levels; do not make declarations public.
- No UI redesign, formatting sweep, warning cleanup, feature work, or runtime
  rewrite.
- Run `swift build` and `git diff --check` after every extraction task.
- Do not split stateful types across files if it would expose private state.

---

### Task 1: Extract Models and Audio Pipeline

**Files:**

- Create: `Sources/Gizmate/Live/LiveTranslationModels.swift`
- Create: `Sources/Gizmate/Live/LiveAudioPipeline.swift`
- Modify: `Sources/Gizmate/Live/LiveTranslation.swift`

**Move unchanged:**

- `LiveTranslationLanguage`, `LiveDialogue`, and `LiveAudioSource` to
  `LiveTranslationModels.swift`.
- `AudioBatcher`, `PCM16Downsampler`, `MicrophoneCapture`,
  `SystemAudioCapture`, and the private `CMSampleBuffer` extension to
  `LiveAudioPipeline.swift`.

**Imports:**

- Models: `Foundation`.
- Audio pipeline: `AVFoundation`, `Foundation`, and `ScreenCaptureKit`.

- [ ] Preserve every declaration body and access level exactly.
- [ ] Keep the sample-buffer extension private.
- [ ] Remove only the moved declarations from the original.
- [ ] Run `swift build` and `git diff --check`.
- [ ] Commit with `Split live translation models and audio pipeline`.

---

### Task 2: Extract Translation Transport and Summarization

**Files:**

- Create: `Sources/Gizmate/Live/RealtimeTranslationSession.swift`
- Create: `Sources/Gizmate/Live/LiveSummarizer.swift`
- Modify: `Sources/Gizmate/Live/LiveTranslation.swift`

**Move unchanged:**

- `LiveTranslationDebug`, `RealtimeServerEvent`, and
  `RealtimeTranslationSession` to `RealtimeTranslationSession.swift`.
- `LiveSummarizer` to `LiveSummarizer.swift`.

**Imports:** `Foundation` in both files.

- [ ] Preserve WebSocket payloads, delegate callbacks, locks, and reconnect
  timing exactly.
- [ ] Preserve summary prompts, endpoint, headers, and decoding exactly.
- [ ] Remove only the moved declarations from the original.
- [ ] Run `swift build`, `swift test --filter LiveTranslationTests`, and
  `git diff --check`.
- [ ] Commit with `Split live translation transport and summarizer`.

---

### Task 3: Extract Caption Views and Panel Controller

**Files:**

- Create: `Sources/Gizmate/Live/LiveCaptionViews.swift`
- Create: `Sources/Gizmate/Live/LiveCaptionPanelController.swift`
- Modify: `Sources/Gizmate/Live/LiveTranslation.swift`

**Move unchanged:**

- `RecordIndicatorView`, `OverlayScrollView`, `KeyableLivePanel`,
  `HoverIconButton`, and `DragHandleView` to `LiveCaptionViews.swift`.
- `LiveCaptionPanelController` and its `NSTextFieldDelegate` extension to
  `LiveCaptionPanelController.swift`.

**Imports:** `AppKit` and `Foundation` as required.

- [ ] Preserve all constraints, selectors, animation setup, palette constants,
  summary-side logic, rendering, and callbacks.
- [ ] Keep `LiveCaptionPanelController` as one class body; do not widen its
  private state to force a smaller file.
- [ ] Remove only the moved declarations from the original.
- [ ] Run `swift build`, `swift test --filter LiveTranslationTests`, and
  `git diff --check`.
- [ ] Commit with `Split live caption views and panel controller`.

---

### Task 4: Extract Live Translation Orchestration

**Files:**

- Create: `Sources/Gizmate/Live/LiveTranslationController.swift`
- Modify: `Sources/Gizmate/Live/LiveTranslation.swift`

**Move unchanged:** `LiveTranslationController`.

**Imports:** `Foundation`.

- [ ] Preserve source defaults, callback wiring, generation guards, pause and
  restart behavior, teardown order, cost accounting, status text, and safety
  identifier exactly.
- [ ] Remove only the complete controller declaration.
- [ ] Run `swift build`, `swift test --filter LiveTranslationTests`, and
  `git diff --check`.
- [ ] Commit with `Split live translation orchestration`.

---

### Task 5: Extract Dictation and Remove the Catch-All

**Files:**

- Create: `Sources/Gizmate/Live/RealtimeTranscriptionSession.swift`
- Create: `Sources/Gizmate/Live/DictationController.swift`
- Delete: `Sources/Gizmate/Live/LiveTranslation.swift`

**Move unchanged:**

- `RealtimeTranscriptionSession` to its named file.
- `DictationController` to its named file.

**Imports:**

- Transcription session: `Foundation`.
- Dictation controller: `AppKit`, `Carbon`, and `Foundation`.

- [ ] Preserve transcription payloads, reconnect behavior, microphone
  permission flow, pasteboard preservation, synthetic paste event, timer, pill
  layout, and safety identifier exactly.
- [ ] Delete the original only after it contains no declarations.
- [ ] Run `swift build`, `swift test --filter LiveTranslationTests`, and
  `git diff --check`.
- [ ] Confirm `LiveTranslation.swift` is absent.
- [ ] Commit with `Finish live translation split`.

---

### Task 6: Final Verification and Review

- [ ] Run full `swift test`.
- [ ] Confirm all focused tests pass and note the executed/skipped/failure
  counts.
- [ ] Run `git diff --check`.
- [ ] Audit the tranche diff against its base and confirm no files outside
  `Sources/Gizmate/Live/` plus these plan/design documents changed.
- [ ] Compare original and replacement declarations for presence, uniqueness,
  body exactness, annotations, and access levels.
- [ ] Run `wc -l Sources/Gizmate/Live/*.swift` and confirm the documented
  caption-panel controller is the only new file above roughly 400 lines.
- [ ] Request an independent read-only code review.
