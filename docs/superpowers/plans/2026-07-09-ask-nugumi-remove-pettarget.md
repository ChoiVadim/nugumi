# Ask Nugumi petTarget Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the legacy petTarget single-point pointer end to end (schema, prompt, pill-mode flying pointer, pet-mode pixel marker, mapper overloads, tests) so `annotations` is the only pointing mechanism.

**Architecture:** Two atomic build units. Task 1 removes the App.swift UI consumers (pointer button, pet marker) while the schema stays intact — builds green. Task 2 removes the schema/prompt/mapper machinery from AskNugumi.swift, updates the four fallback constructor sites and the tests — builds green. Net-negative diff; no new abstractions. Spec: `docs/superpowers/specs/2026-07-09-ask-nugumi-remove-pettarget-design.md`.

**Tech Stack:** Swift / AppKit. No new dependencies.

## Global Constraints

- All app-code edits in `Sources/Nugumi/App.swift` and `Sources/Nugumi/AskNugumi.swift`; tests in `Tests/NugumiTests/`.
- `annotations` machinery (schema, prompt rules, renderer, `presentAskAnnotations` replace semantics, all its teardown points including `onAnswerDismissedByUser`) is UNTOUCHED except where this plan explicitly rewords a sentence.
- `FloatingTranslateButtonController` itself stays (selection button + Ask loading bar) — only pointer-specific members are deleted.
- `AskNugumiFloatingTargetPresentationPolicy.buttonSize/shadowPadding/totalSize` stay (loading bar + button geometry use them); only `pointerOffset`, `presentation(...)`, and its now-unused private clamp helpers are deleted.
- After Task 2, `grep -rn "petTarget\|PetTarget\|screenshot_normalized\|coordinateSpace" Sources Tests` must return ZERO matches.
- `swift build` after Task 1 is expected to have ZERO warnings (the only pre-existing warning lives in the deleted `targetMarkerGlideTimer` closure). If other warnings appear, report them verbatim — do not silence them.
- Locate edits by grep anchors, never line numbers. Signal-11 crash mentioning `_DarwinFoundation1 defined in both` → `rm -rf .build/clang-module-cache*`, retry. Never launch the app.

---

### Task 1: Remove the pointer UI (App.swift only; schema stays)

**Files:**

- Modify: `Sources/Nugumi/App.swift`

**Interfaces:**

- Consumes: existing code only.
- Produces: `PetController.showAnswer(_ message: String, emotion: AskNugumiEmotion?)` (markerTarget parameter gone) — Task 2 relies on `App.swift` no longer referencing `response.petTarget` anywhere except the four `AskNugumiResponse(message: "", petTarget: nil, emotion: nil)` fallback constructors, which Task 2 rewrites.

- [ ] **Step 1: Simplify the three answer paths**

(a) In `presentAskNugumiResult` (anchor: `func presentAskNugumiResult`), replace:

```swift
        if let target = response.petTarget {
            presentFloatingAskTargetPointer(for: target, capture: capture)
        } else {
            floatingTargetButton?.close()
            floatingTargetButton = nil
        }
        presentAskAnnotations(response.annotations, capture: capture)
```

with:

```swift
        presentAskAnnotations(response.annotations, capture: capture)
```

(b) In `submitAskNugumiFollowUp` (anchor: `func submitAskNugumiFollowUp`), replace the analogous block (self-qualified: `self.presentFloatingAskTargetPointer(...)` / `self.floatingTargetButton?.close()` / `self.floatingTargetButton = nil`) with:

```swift
                    self.presentAskAnnotations(response.annotations, capture: capture)
```

(c) Replace the whole body logic of `presentPetAskNugumiResult` (anchor: `func presentPetAskNugumiResult`) so the function becomes:

```swift
    @MainActor
    private func presentPetAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture
    ) {
        if petController == nil {
            petController = PetController(initialMode: .selection)
        }

        guard let petController else { return }

        petController.onAnswerDismissedByUser = { [weak self] in
            self?.closeAskAnnotationOverlay()
        }
        petController.showAnswer(response.message, emotion: response.emotion)
        presentAskAnnotations(response.annotations, capture: capture)
    }
```

Note: the `onAnswerDismissedByUser` wiring already exists in this function (added by the annotations feature) — keep it exactly as currently written if its placement differs; the point of this edit is only to drop the `petTarget`/`markerTarget` branch.

- [ ] **Step 2: Delete the pill-mode pointer**

1. Delete the whole `presentFloatingAskTargetPointer(for:capture:)` method (anchor: `func presentFloatingAskTargetPointer`).
2. Delete the property `private var floatingTargetButton: FloatingTranslateButtonController?` (anchor: `floatingTargetButton: FloatingTranslateButtonController?`).
3. Delete every remaining `floatingTargetButton?.close()` / `floatingTargetButton = nil` pair. Find them all with `grep -n "floatingTargetButton" Sources/Nugumi/App.swift` — expected sites: the `startAskNugumiPrompt` entry cleanup and `dismissAskNugumi` (the answer panel `onClose` pair and both follow-up/present sites disappear in Step 1). Keep the adjacent `closeAskAnnotationOverlay()` lines — they stay.
4. After this step `grep -c "floatingTargetButton" Sources/Nugumi/App.swift` must print `0`.

- [ ] **Step 3: Delete the pointer flight machinery in FloatingTranslateButtonController**

1. Delete `func pointAt(_ targetPoint: NSPoint, visibleFrame: NSRect)` (anchor: `func pointAt`) and `private func playArrivalPulse()` (anchor: `func playArrivalPulse`).
2. `grep -n "setTargetArrow" Sources/Nugumi/App.swift` — `pointAt` was its only caller as of planning. If the grep confirms the definition in `FloatingTranslateButtonView` (anchor: `func setTargetArrow`) is now unreferenced, delete it AND the arrow-rendering state it drives (the arrow image/rotation members used only by it — follow the members it touches; delete only what becomes unreferenced, verified by grep per member). If another caller exists, STOP and report NEEDS_CONTEXT.

- [ ] **Step 4: Delete the pet-mode pixel marker**

All inside `PetController` (anchor: `final class PetController`):

1. `showAnswer` signature (anchor: `func showAnswer`) becomes `func showAnswer(_ message: String, emotion: AskNugumiEmotion?)`. Inside it, delete the marker presentation: the `AskNugumiPetAnswerTargetPanelMetrics`/`markerTarget` computation, `currentAnswerMarkerTarget` assignment, and the marker glide/panel calls — keep the bubble/emotion/answer-text logic and the `onDoubleClick` rebinding intact.
2. Delete `moveToAnswerTarget(...)` (anchor: `func moveToAnswerTarget`) — pre-existing dead code.
3. Delete the marker plumbing members and their uses: `targetMarkerPanel`, `targetMarkerGlideTimer`, `currentAnswerMarkerTarget`, the marker content view (anchor hints: `targetMarkerPanel = PetPanel(`, `targetMarkerPanel.contentView`), the glide animation function(s) that drive `targetMarkerGlideTimer`, and the `targetMarkerPanel.close()` teardown line. Also delete any private helper whose only purpose was marker frame math (they reference `AskNugumiTargetMarkerMetrics` / `AskNugumiPetAnswerTargetPanelMetrics` — the type definitions themselves are Task 2's).
4. After this step `grep -c "targetMarker\|markerTarget\|currentAnswerMarker" Sources/Nugumi/App.swift` must print `0`.

- [ ] **Step 5: Build, test, warning check**

Run: `swift build 2>&1 | grep -i warning; swift test`
Expected: build completes with ZERO warnings (the glide-timer Sendable warning is gone with the timer); full suite passes — the petTarget schema/prompt/mapper tests still pass because AskNugumi.swift is untouched in this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Remove petTarget pointer and pet marker UI in favor of annotations"
```

---

### Task 2: Remove the schema, prompt rules, mapper overloads, and tests

**Files:**

- Modify: `Sources/Nugumi/AskNugumi.swift`, `Sources/Nugumi/App.swift` (4 constructor sites), `Tests/NugumiTests/AskNugumiTests.swift`, `Tests/NugumiTests/AskNugumiAnnotationTests.swift`

**Interfaces:**

- Consumes: Task 1's guarantee that `App.swift` references `petTarget` only in the four fallback constructors.
- Produces: `AskNugumiResponse.init(message:emotion:annotations:)` (with `annotations: [AskNugumiAnnotation] = []`); `AskNugumiCoordinateMapper` exposing ONLY `exactScreenPoint(normalizedX:normalizedY:screenFrame:)` and `screenRect(centerX:centerY:normalizedWidth:normalizedHeight:screenFrame:)`.

- [ ] **Step 1: Update the tests to the post-removal contract (RED)**

In `Tests/NugumiTests/AskNugumiTests.swift`:

1. Delete every test function that references `petTarget`, `AskNugumiPetTarget`, `AskNugumiPetAnswerTargetPresentationPolicy`, or asserts petTarget parsing/validation/mapping (locate with `grep -n "petTarget\|PetTarget" Tests/NugumiTests/AskNugumiTests.swift` and delete the enclosing `func test...` blocks whole).
2. In the surviving system-prompt test, flip/trim assertions so the contract reads: the system prompt does NOT contain `petTarget` and does NOT contain `screenshot_normalized`; delete assertions on removed rule sentences (e.g. "Never include `petTarget` without a screenshot").

In `Tests/NugumiTests/AskNugumiAnnotationTests.swift`: 3. Delete `testPetTargetMappingStillDelegatesUnchanged` (its overload disappears). 4. In `testSystemPromptTeachesAnnotations`, replace the two petTarget-era assertions:

```swift
        // petTarget contract untouched.
        XCTAssertTrue(prompt.contains("screenshot_normalized"))
        XCTAssertTrue(prompt.contains("petTarget"))
```

with:

```swift
        // petTarget is gone: annotations are the only pointing mechanism.
        XCTAssertFalse(prompt.contains("petTarget"))
        XCTAssertFalse(prompt.contains("screenshot_normalized"))
```

- [ ] **Step 2: Run tests to verify the flips fail**

Run: `swift test --filter 'AskNugumiTests|AskNugumiAnnotationTests'`
Expected: FAIL — the flipped prompt assertions fail (prompt still teaches petTarget); everything referencing deleted funcs compiles because the types still exist.

- [ ] **Step 3: Remove the schema and mapper overloads (`Sources/Nugumi/AskNugumi.swift`)**

1. Delete `enum AskNugumiCoordinateSpace` and `struct AskNugumiPetTarget` (top of file).
2. In `AskNugumiResponse`: delete `let petTarget: AskNugumiPetTarget?`, the `case petTarget` CodingKey, the `let petTarget = try? container.decode(...)` line, the `try container.encodeIfPresent(petTarget, forKey: .petTarget)` line, and rewrite the memberwise init:

```swift
    init(
        message: String,
        emotion: AskNugumiEmotion?,
        annotations: [AskNugumiAnnotation] = []
    ) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emotion = emotion
        self.annotations = Array(annotations.filter(\.isValid).prefix(Self.maxAnnotations))
    }
```

and update `init(from decoder:)`'s trailing call to `self.init(message: message, emotion: emotion, annotations: annotations)`. Update the two internal fallback constructions in `parse`/`parseJSONResponse` to `AskNugumiResponse(message: trimmed, emotion: nil)` / `(message: "", emotion: nil)`. 3. In `AskNugumiCoordinateMapper`: delete `exactScreenPoint(for:screenFrame:)` and `screenPoint(for:screenFrame:visibleFrame:)`. Keep the two raw-coordinate functions. 4. Delete the pet-marker geometry types wholesale: `AskNugumiTargetMarkerMetrics`, `AskNugumiPetAnswerTargetPanelPresentation`, `AskNugumiPetAnswerTargetPanelMetrics`, `AskNugumiPetAnswerTargetPresentation`, `AskNugumiPetAnswerTargetPresentationPolicy`. 5. In `AskNugumiFloatingTargetPresentationPolicy`: delete `pointerOffset`, `presentation(targetPoint:visibleFrame:)`, and its private `clampedOrigin`/`clamped` helpers if now unreferenced (grep within the enum). Keep `buttonSize`, `shadowPadding`, `totalSize`.

- [ ] **Step 4: Rewrite the prompts (`AskNugumiPromptBuilder`)**

In `systemPromptBase`:

1. Delete the petTarget example paragraph:

```
When a screenshot is attached AND pointing at a specific visible element helps the user, use this shape:
{"message":"short helpful answer","emotion":"neutral","petTarget":{"x":0.0,"y":0.0,"coordinateSpace":"screenshot_normalized"}}
```

(The annotations example paragraph stays and is now the only screenshot-specific shape.) 2. In the `Rules:` list, delete these petTarget bullets:

- "Include `petTarget` only when a screenshot is attached AND ..."
- "When a screenshot is attached, the user message includes a coordinate guide; follow it when computing `petTarget`."
- "`petTarget.x` and `petTarget.y` are normalized 0.0–1.0 ..."
- "Aim at the geometric center of the target element, never the top-left of a text label."
- "Use coordinateSpace exactly \"screenshot_normalized\"."
- "If uncertain about a location, omit `petTarget` and describe what to look for in `message`." (the annotations twin of this rule already exists — keep that one)
  Keep: the `message`/`emotion` bullets, "Do not click, automate, or claim you took an action.", and ALL annotations bullets.

3. In the annotations rule that reads "Shapes use the same normalized 0.0–1.0 screenshot coordinates as `petTarget`.", reword to:

```
- `annotations` is optional and only allowed when a screenshot is attached. Shapes use normalized 0.0–1.0 screenshot coordinates (x left-to-right, y top-to-bottom).
```

In `prompt(question:hasImage:)`, replace the whole coordinate-guide block (everything from `Coordinate guide for petTarget and annotations:` to the end of the returned string) with:

```
Coordinate guide for annotations:
- All coordinates (`cx`/`cy`, `fromX`/`fromY`/`toX`/`toY`, `x`/`y`) are normalized from 0.0 to 1.0 over the attached screenshot. x is the horizontal fraction from the left edge; y is the vertical fraction from the top edge.
- Aim shapes at the geometric center of the target element's visible bounding box (button, icon, control, or input). Never anchor to the top-left of a text label — in a vertical list of buttons or menu items, a label's top-left sits inside the previous row.
- For small menu bar or status icons, aim at the icon glyph's visual center, not the surrounding hit area.
- Before choosing coordinates, identify the target's row/column context in `message` (for example: "the third item in the left sidebar, below New chat and above Artifacts") so you anchor to the correct sibling among visually similar elements.
```

- [ ] **Step 5: Update the four App.swift fallback constructors**

`grep -n 'AskNugumiResponse(message: "", petTarget: nil, emotion: nil)' Sources/Nugumi/App.swift` — rewrite each of the four sites to:

```swift
            return AskNugumiResponse(message: "", emotion: nil)
```

- [ ] **Step 6: Build, full test suite, zero-reference check**

Run: `swift build && swift test`
Expected: build complete, all tests pass.
Then: `grep -rn "petTarget\|PetTarget\|screenshot_normalized\|coordinateSpace" Sources Tests`
Expected: zero matches. If any remain, they are missed edits — fix before committing.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nugumi/AskNugumi.swift Sources/Nugumi/App.swift Tests/NugumiTests/AskNugumiTests.swift Tests/NugumiTests/AskNugumiAnnotationTests.swift
git commit -m "Remove petTarget schema, prompt rules, and mapper overloads"
```

---

### Task 3: Manual QA (performed by the maintainer — do not launch the app yourself)

**Files:** none.

- [ ] **Step 1: Build for the maintainer**

Run: `swift build`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 2: Hand the maintainer this checklist**

(`bash Scripts/build-app-bundle.sh`, run `dist/Nugumi.app` themselves, capable cloud vision model selected):

1. Ask "where is the save button?" → the model points with an annotation arrow/ellipse; no flying pointer button appears anywhere.
2. Pet mode: answer bubble + emotion still work; no pixel marker; annotations render and clear on bubble dismiss.
3. Loading bar still appears while a question is in flight (it shares geometry constants with the deleted pointer).
4. Selection floating button (translate/rewrite flows) completely unaffected.
5. Follow-up answers still replace annotations.

- [ ] **Step 3: Fix anything surfaced, then commit fixes**

```bash
git add -A Sources Tests
git commit -m "Fix petTarget removal QA findings"
```

(Skip if clean.)
