# Conversational Tool Builder Design

## Goal

Make **New tool** behave like a normal chat. The user describes the tool in
the composer, the same Pi session may ask missing questions, Nugumi shows a
small safe activity trace, and the verified result remains a draft until the
user explicitly presses **Save**.

## Product contract

- The first visible message is from Nugumi. It explains that the user can
  describe the outcome, that Nugumi may ask questions, and that nothing is
  saved automatically.
- The user sends the first request from a chat composer using the send button
  or Command+Return.
- Pi may ask up to three plain-text clarification questions, one at a time.
- A clarification is allowed only for `create`, before the first candidate is
  written. `edit` and `fix` remain uninterrupted build sessions.
- While Pi works, the chat shows host-authored activity such as understanding,
  checking a macOS action, testing in the sandbox, repairing, and finishing.
  Raw model JSON, prompts, source, filesystem paths, and stderr are never shown
  in this activity surface.
- A verified candidate appears in the conversation as a preview card.
- The user may request another change in the same composer before saving.
- Generation never writes `tool.json`, `main.py`, approvals, or Ring layout.
  Only the existing footer **Save** action persists and assigns the draft.
- Cancel closes the panel, cancels Pi, and resolves any pending clarification
  wait so no task is left suspended.

## Conversation UI

The New Tool panel uses a 640 by 620 layout:

1. Compact header: `New tool` and `Build it with Nugumi`.
2. Scrollable transcript:
   - assistant messages align left;
   - user messages align right;
   - the current activity line is visible and the full bounded list is behind
     `Activity`;
   - a verified tool uses the existing summary card inside the transcript.
3. A bottom composer with a multiline text field, send button, and a quiet
   `Set up manually` escape hatch before a candidate exists.
4. The existing footer with Cancel and Save. Save is disabled until the draft
   is usable.

Existing-tool editing keeps its Overview and Details pages. The conversational
surface applies to a new tool from initial request through optional revisions
before its first save.

## Agent protocol

Add a fifth sequential Pi tool:

```text
ask_user({ question: String }) -> { answer: String }
```

Both strings are non-empty and limited to 1 KiB UTF-8. It uses the existing
`toolRequest` / `toolResponse` envelope, so no new top-level JSONL message is
needed. The supervisor charges the normal tool-call budget and additionally
enforces:

- operation is `create`;
- no candidate has been written;
- fewer than three questions have already been asked.

The sidecar system prompt tells Pi to ask only when a missing choice would
materially change input, action, destination, or output. It must not ask for
details it can safely infer. After the host returns the answer, the same Pi
session continues with its full conversation context and normal
write/validate/repair/attest flow.

## Host/UI bridge

`ToolBuildSupervisor` receives an asynchronous clarification handler.
`ToolAgentLiveBuilder`, `SettingsHost`, and `NugumiSettingsBridge` forward it
to `ToolEditorPanel`.

A MainActor chat-session object owns the visible messages and activity. A
small actor owns the single pending answer continuation. It supports exactly
one wait, one answer, and cancellation. This keeps continuations out of SwiftUI
value state and makes dismissal deterministic.

## Error handling

- If Pi fails, append a readable assistant error and keep the user's transcript.
- If the user cancels while Pi is awaiting an answer, resume the continuation
  with cancellation and cancel the build task.
- Invalid, empty, oversized, out-of-phase, or excess questions fail closed as
  protocol errors.
- If generation succeeds, apply the result only to the editor draft. Do not
  show a success toast until Save.

## Verification

- Swift and TypeScript protocol round trips for `ask_user`.
- UTF-8 bounds and strict unknown-key rejection for questions and answers.
- Supervisor allows bounded Create questions and rejects Edit/Fix, post-write,
  and fourth-question requests.
- Sidecar test proves the returned answer appears in the next Pi model context
  before a candidate is written.
- Chat-session tests cover initial copy, question/answer, activity de-duplication,
  and cancellation.
- Live packaged-app QA proves a question can be answered, a candidate preview
  appears, no tool is persisted before Save, and Save then persists/assigns it.

