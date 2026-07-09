# Ask Nugumi Model Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the model draw shapes (ellipse, rect, arrow, label) over the user's screen to explain its Ask Nugumi answers, with every answer fully replacing the previous annotation layer.

**Architecture:** Extend the structured Ask response (`AskNugumi.swift`) with a validated, capped `annotations` array in the same normalized screenshot coordinates as `petTarget`; render natively on a click-through transparent panel (`AskAnnotationOverlayController` in `App.swift`) using the accent color with a white halo; wire replace-on-every-answer semantics into the three answer presentation paths and the existing teardown points. Spec: `docs/superpowers/specs/2026-07-09-ask-nugumi-model-annotations-design.md`.

**Tech Stack:** Swift / AppKit / CoreGraphics only. No new dependencies.

## Global Constraints

- App code lives in `Sources/Nugumi/App.swift`; the Ask Nugumi pure-logic subsystem lives in `Sources/Nugumi/AskNugumi.swift` (schema, prompt, mapping go THERE). Tests in `Tests/NugumiTests/`.
- Deployment target macOS 14; no new SPM dependencies.
- Never use "translate/translation/translator" in user-facing strings.
- Validation values from the spec, verbatim: at most **12** valid annotations kept; positions in `0...1`; `w`/`h` in `(0...1]`; label text non-empty after trimming and ≤ **60** characters.
- Any `sharingType` clamp uses the super-delegating setter (`set { super.sharingType = .none }`) — NEVER an empty `set {}` (an empty setter never pushes `.none` to the window server; see `tasks/lessons.md`).
- Coordinate-mapping tests must use asymmetric y positions that distinguish a correct mapping from a y-flipped one (see `tasks/lessons.md`).
- Locate all edit points by grep anchors, never line numbers (`App.swift` is ~16k lines and drifts).
- If `swift build`/`swift test` crashes with swift-frontend signal 11 mentioning `_DarwinFoundation1 defined in both`: `rm -rf .build/clang-module-cache*` and rebuild — stale module cache, not a code bug.
- Never launch the app (`swift run Nugumi` or Nugumi.app) — TCC permission misattribution. Build/test only; manual QA is the maintainer's.

---

### Task 1: Schema — `AskNugumiAnnotation` with lenient parsing

**Files:**

- Modify: `Sources/Nugumi/AskNugumi.swift` (anchor: `struct AskNugumiResponse`)
- Test: `Tests/NugumiTests/AskNugumiAnnotationTests.swift` (create)

**Interfaces:**

- Consumes: existing `AskNugumiResponse`, `AskNugumiPetTarget` patterns.
- Produces (used verbatim by Tasks 2, 4, 5):
  - `enum AskNugumiAnnotationType: String, Codable, Equatable { case ellipse, rect, arrow, label }`
  - `struct AskNugumiAnnotation: Codable, Equatable` with fields `type: AskNugumiAnnotationType`, `cx, cy, w, h: Double?`, `fromX, fromY, toX, toY: Double?`, `x, y: Double?`, `text: String?`, and `var isValid: Bool`
  - `AskNugumiResponse.annotations: [AskNugumiAnnotation]` (never nil; pre-filtered to valid, capped at 12)
  - `AskNugumiResponse.init(message:petTarget:emotion:annotations:)` with `annotations: [AskNugumiAnnotation] = []` (existing three-argument call sites keep compiling)

- [ ] **Step 1: Write the failing tests**

Create `Tests/NugumiTests/AskNugumiAnnotationTests.swift`:

```swift
import XCTest

@testable import Nugumi

final class AskNugumiAnnotationTests: XCTestCase {
    private func parse(_ annotationsJSON: String) -> AskNugumiResponse {
        AskNugumiResponse.parse(
            "{\"message\":\"here\",\"annotations\":\(annotationsJSON)}"
        )
    }

    func testParsesAllFourShapeTypes() {
        let response = parse("""
        [{"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05},
         {"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10},
         {"type":"arrow","fromX":0.42,"fromY":0.45,"toX":0.55,"toY":0.32},
         {"type":"label","x":0.42,"y":0.50,"text":"click here"}]
        """)
        XCTAssertEqual(response.annotations.count, 4)
        XCTAssertEqual(response.annotations[0].type, .ellipse)
        XCTAssertEqual(response.annotations[1].type, .rect)
        XCTAssertEqual(response.annotations[2].type, .arrow)
        XCTAssertEqual(response.annotations[3].type, .label)
        XCTAssertEqual(response.annotations[3].text, "click here")
    }

    func testAbsentAnnotationsFieldYieldsEmptyArray() {
        let response = AskNugumiResponse.parse("{\"message\":\"plain\"}")
        XCTAssertEqual(response.annotations, [])
    }

    func testUnknownTypeIsDroppedOthersSurvive() {
        let response = parse("""
        [{"type":"starburst","cx":0.5,"cy":0.5,"w":0.1,"h":0.1},
         {"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05}]
        """)
        XCTAssertEqual(response.annotations.count, 1)
        XCTAssertEqual(response.annotations[0].type, .ellipse)
    }

    func testOutOfRangeAndMissingFieldsAreDropped() {
        let response = parse("""
        [{"type":"ellipse","cx":1.42,"cy":0.31,"w":0.10,"h":0.05},
         {"type":"ellipse","cx":0.42,"cy":0.31,"w":0.0,"h":0.05},
         {"type":"arrow","fromX":0.42,"fromY":0.45},
         {"type":"label","x":0.42,"y":0.50,"text":"   "},
         {"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10}]
        """)
        XCTAssertEqual(response.annotations.count, 1)
        XCTAssertEqual(response.annotations[0].type, .rect)
    }

    func testWrongFieldTypeDropsOnlyThatElement() {
        let response = parse("""
        [{"type":"ellipse","cx":"middle","cy":0.31,"w":0.10,"h":0.05},
         {"type":"arrow","fromX":0.1,"fromY":0.1,"toX":0.9,"toY":0.9}]
        """)
        XCTAssertEqual(response.annotations.count, 1)
        XCTAssertEqual(response.annotations[0].type, .arrow)
    }

    func testLabelLongerThan60CharactersIsDropped() {
        let longText = String(repeating: "a", count: 61)
        let response = parse(
            "[{\"type\":\"label\",\"x\":0.5,\"y\":0.5,\"text\":\"\(longText)\"}]"
        )
        XCTAssertEqual(response.annotations, [])
    }

    func testAnnotationsCappedAtTwelve() {
        let one = "{\"type\":\"ellipse\",\"cx\":0.5,\"cy\":0.5,\"w\":0.1,\"h\":0.1}"
        let fifteen = "[" + Array(repeating: one, count: 15).joined(separator: ",") + "]"
        let response = parse(fifteen)
        XCTAssertEqual(response.annotations.count, 12)
    }

    func testRoundTripPreservesValidAnnotations() throws {
        let original = AskNugumiResponse(
            message: "look",
            petTarget: nil,
            emotion: .happy,
            annotations: [
                AskNugumiAnnotation(
                    type: .arrow,
                    cx: nil, cy: nil, w: nil, h: nil,
                    fromX: 0.1, fromY: 0.2, toX: 0.8, toY: 0.9,
                    x: nil, y: nil, text: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AskNugumiResponse.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMalformedAnnotationsFieldFallsBackToEmpty() {
        let response = AskNugumiResponse.parse(
            "{\"message\":\"ok\",\"annotations\":\"not an array\"}"
        )
        XCTAssertEqual(response.annotations, [])
        XCTAssertEqual(response.message, "ok")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AskNugumiAnnotationTests`
Expected: BUILD FAILURE — `cannot find 'AskNugumiAnnotation' in scope` / no member `annotations`

- [ ] **Step 3: Write the implementation**

In `Sources/Nugumi/AskNugumi.swift`, directly above `struct AskNugumiResponse` (anchor: `struct AskNugumiResponse`), add:

```swift
enum AskNugumiAnnotationType: String, Codable, Equatable {
    case ellipse
    case rect
    case arrow
    case label
}

/// One model-drawn shape over the screenshot, in the same normalized
/// 0.0–1.0 coordinate space as `AskNugumiPetTarget` (x left-to-right,
/// y top-to-bottom). Flat optional fields instead of a polymorphic decoder;
/// `isValid` enforces the per-type contract.
struct AskNugumiAnnotation: Codable, Equatable {
    let type: AskNugumiAnnotationType
    // ellipse/rect: center + normalized size
    let cx: Double?
    let cy: Double?
    let w: Double?
    let h: Double?
    // arrow
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    // label
    let x: Double?
    let y: Double?
    let text: String?

    var isValid: Bool {
        switch type {
        case .ellipse, .rect:
            guard let cx, let cy, let w, let h else { return false }
            return [cx, cy, w, h].allSatisfy(\.isFinite)
                && (0...1).contains(cx) && (0...1).contains(cy)
                && w > 0 && w <= 1 && h > 0 && h <= 1
        case .arrow:
            guard let fromX, let fromY, let toX, let toY else { return false }
            return [fromX, fromY, toX, toY].allSatisfy { $0.isFinite && (0...1).contains($0) }
        case .label:
            guard let x, let y, let text else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return x.isFinite && y.isFinite
                && (0...1).contains(x) && (0...1).contains(y)
                && !trimmed.isEmpty && trimmed.count <= 60
        }
    }
}

/// Wrapper that turns a per-element decode failure into `nil` instead of
/// failing the whole array — weak local models emit partially-broken shapes.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}
```

Then modify `AskNugumiResponse`:

1. Add the stored property after `let emotion: AskNugumiEmotion?`:

```swift
    let annotations: [AskNugumiAnnotation]
```

2. Add `case annotations` to `CodingKeys`.

3. Replace the memberwise init with (existing three-argument call sites keep compiling via the default):

```swift
    static let maxAnnotations = 12

    init(
        message: String,
        petTarget: AskNugumiPetTarget?,
        emotion: AskNugumiEmotion?,
        annotations: [AskNugumiAnnotation] = []
    ) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.petTarget = petTarget?.isValid == true ? petTarget : nil
        self.emotion = emotion
        self.annotations = Array(annotations.filter(\.isValid).prefix(Self.maxAnnotations))
    }
```

4. In `init(from decoder:)`, decode leniently and pass through the validating init:

```swift
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        let petTarget = try? container.decode(AskNugumiPetTarget.self, forKey: .petTarget)
        let emotion = try? container.decode(AskNugumiEmotion.self, forKey: .emotion)
        let annotations = (try? container.decode(
            [FailableDecodable<AskNugumiAnnotation>].self,
            forKey: .annotations
        ))?.compactMap(\.value) ?? []

        self.init(message: message, petTarget: petTarget, emotion: emotion, annotations: annotations)
    }
```

5. In `encode(to:)`, add (only when non-empty, so legacy payloads stay byte-identical):

```swift
        if !annotations.isEmpty {
            try container.encode(annotations, forKey: .annotations)
        }
```

Note: the empty-message early return inside `parseJSONResponse` constructs `AskNugumiResponse(message: "", petTarget: nil, emotion: nil)` — the new default parameter covers it; do not change those call sites.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AskNugumiAnnotationTests`
Expected: `Executed 9 tests, with 0 failures`
Then run the full suite once: `swift test`
Expected: all tests pass (the pre-existing `AskNugumiTests` must be untouched by the schema change).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/AskNugumi.swift Tests/NugumiTests/AskNugumiAnnotationTests.swift
git commit -m "Add validated annotations array to Ask Nugumi response schema"
```

---

### Task 2: Coordinate mapping — normalized shapes → screen geometry

**Files:**

- Modify: `Sources/Nugumi/AskNugumi.swift` (anchor: `enum AskNugumiCoordinateMapper`)
- Test: `Tests/NugumiTests/AskNugumiAnnotationTests.swift` (extend)

**Interfaces:**

- Consumes: existing `AskNugumiCoordinateMapper.exactScreenPoint(for:screenFrame:)`.
- Produces (used verbatim by Task 4):
  - `AskNugumiCoordinateMapper.exactScreenPoint(normalizedX: Double, normalizedY: Double, screenFrame: CGRect) -> CGPoint`
  - `AskNugumiCoordinateMapper.screenRect(centerX: Double, centerY: Double, normalizedWidth: Double, normalizedHeight: Double, screenFrame: CGRect) -> CGRect`

- [ ] **Step 1: Write the failing tests**

Append inside `final class AskNugumiAnnotationTests`:

```swift
    // Non-zero-origin frame (second monitor) + asymmetric y so a y-flip
    // regression fails loudly: normalized y is top-to-bottom, AppKit y is
    // bottom-up.
    private let frame = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testExactScreenPointMapsAsymmetricPoint() {
        let point = AskNugumiCoordinateMapper.exactScreenPoint(
            normalizedX: 0.25,
            normalizedY: 0.10,
            screenFrame: frame
        )
        // x: 100 + 0.25 * 400 = 200. y: near the TOP of the screen →
        // AppKit y near maxY: 500 - 0.10 * 300 = 470 (a flip would give 230).
        XCTAssertEqual(point.x, 200, accuracy: 0.001)
        XCTAssertEqual(point.y, 470, accuracy: 0.001)
    }

    func testExactScreenPointClampsToFrame() {
        let point = AskNugumiCoordinateMapper.exactScreenPoint(
            normalizedX: 1.0,
            normalizedY: 0.0,
            screenFrame: frame
        )
        XCTAssertEqual(point.x, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(point.y, frame.maxY, accuracy: 0.001)
    }

    func testScreenRectCentersOnMappedPoint() {
        let rect = AskNugumiCoordinateMapper.screenRect(
            centerX: 0.5,
            centerY: 0.25,
            normalizedWidth: 0.1,
            normalizedHeight: 0.2,
            screenFrame: frame
        )
        // Center: x = 300, y = 500 - 0.25*300 = 425. Size: 40 × 60.
        XCTAssertEqual(rect.midX, 300, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 425, accuracy: 0.001)
        XCTAssertEqual(rect.width, 40, accuracy: 0.001)
        XCTAssertEqual(rect.height, 60, accuracy: 0.001)
    }

    func testPetTargetMappingStillDelegatesUnchanged() {
        let target = AskNugumiPetTarget(x: 0.25, y: 0.10, coordinateSpace: .screenshotNormalized)
        let viaTarget = AskNugumiCoordinateMapper.exactScreenPoint(for: target, screenFrame: frame)
        let viaRaw = AskNugumiCoordinateMapper.exactScreenPoint(
            normalizedX: 0.25, normalizedY: 0.10, screenFrame: frame
        )
        XCTAssertEqual(viaTarget, viaRaw)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AskNugumiAnnotationTests`
Expected: BUILD FAILURE — no member `exactScreenPoint(normalizedX:normalizedY:screenFrame:)`

- [ ] **Step 3: Write the implementation**

In `enum AskNugumiCoordinateMapper`, add the raw-coordinate overloads and refactor the existing `exactScreenPoint(for:screenFrame:)` to delegate (behavior identical):

```swift
enum AskNugumiCoordinateMapper {
    static func exactScreenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect
    ) -> CGPoint {
        exactScreenPoint(
            normalizedX: target.x,
            normalizedY: target.y,
            screenFrame: screenFrame
        )
    }

    /// Normalized screenshot coordinates (x left-to-right, y top-to-bottom)
    /// to AppKit screen points (y bottom-up), clamped into the frame.
    static func exactScreenPoint(
        normalizedX: Double,
        normalizedY: Double,
        screenFrame: CGRect
    ) -> CGPoint {
        let mappedX = screenFrame.minX + CGFloat(normalizedX) * screenFrame.width
        let mappedY = screenFrame.maxY - CGFloat(normalizedY) * screenFrame.height

        return CGPoint(
            x: min(max(mappedX, screenFrame.minX), screenFrame.maxX),
            y: min(max(mappedY, screenFrame.minY), screenFrame.maxY)
        )
    }

    /// Center-based normalized rect (as emitted in `annotations`) to an
    /// AppKit screen rect. The center is clamped into the frame; the size
    /// is a direct fraction of the frame.
    static func screenRect(
        centerX: Double,
        centerY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        screenFrame: CGRect
    ) -> CGRect {
        let center = exactScreenPoint(
            normalizedX: centerX,
            normalizedY: centerY,
            screenFrame: screenFrame
        )
        let size = CGSize(
            width: CGFloat(normalizedWidth) * screenFrame.width,
            height: CGFloat(normalizedHeight) * screenFrame.height
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func screenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let point = exactScreenPoint(for: target, screenFrame: screenFrame)

        return CGPoint(
            x: min(max(point.x, visibleFrame.minX), visibleFrame.maxX),
            y: min(max(point.y, visibleFrame.minY), visibleFrame.maxY)
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AskNugumiAnnotationTests`
Expected: `Executed 13 tests, with 0 failures`
Then: `swift test` — full suite passes (pet-target mapping tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/AskNugumi.swift Tests/NugumiTests/AskNugumiAnnotationTests.swift
git commit -m "Add normalized-to-screen mapping for annotation shapes"
```

---

### Task 3: Prompt — teach the model the annotation vocabulary

**Files:**

- Modify: `Sources/Nugumi/AskNugumi.swift` (anchors: `systemPromptBase`, `static func prompt(question:hasImage:)`)
- Test: `Tests/NugumiTests/AskNugumiAnnotationTests.swift` (extend)

**Interfaces:**

- Consumes: nothing new.
- Produces: prompt text only; no API changes. `petTarget` rules must remain byte-identical.

- [ ] **Step 1: Write the failing tests**

Append inside `final class AskNugumiAnnotationTests`:

```swift
    func testSystemPromptTeachesAnnotations() {
        let prompt = AskNugumiPromptBuilder.systemPrompt(genZ: false)
        XCTAssertTrue(prompt.contains("\"annotations\""))
        XCTAssertTrue(prompt.contains("\"type\":\"ellipse\""))
        XCTAssertTrue(prompt.contains("\"type\":\"arrow\""))
        XCTAssertTrue(prompt.contains("erased with every new answer"))
        // petTarget contract untouched.
        XCTAssertTrue(prompt.contains("screenshot_normalized"))
        XCTAssertTrue(prompt.contains("petTarget"))
    }

    func testCoordinateGuideCoversAnnotations() {
        let withImage = AskNugumiPromptBuilder.prompt(question: "where?", hasImage: true)
        XCTAssertTrue(withImage.contains("annotations"))

        let withoutImage = AskNugumiPromptBuilder.prompt(question: "where?", hasImage: false)
        XCTAssertFalse(withoutImage.contains("annotations"))
        XCTAssertEqual(withoutImage, "where?")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AskNugumiAnnotationTests`
Expected: FAIL — `testSystemPromptTeachesAnnotations` and `testCoordinateGuideCoversAnnotations` assert false.

- [ ] **Step 3: Extend the prompts**

In `systemPromptBase`, insert the following block AFTER the petTarget example line (`{"message":"short helpful answer","emotion":"neutral","petTarget":...}`) and BEFORE the `Rules:` line:

```
When a screenshot is attached AND drawing on top of it explains better than words alone, you may also add "annotations" — simple shapes rendered over the user's screen:
{"message":"short helpful answer","emotion":"neutral","annotations":[{"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05},{"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10},{"type":"arrow","fromX":0.42,"fromY":0.45,"toX":0.55,"toY":0.32},{"type":"label","x":0.42,"y":0.50,"text":"click here"}]}
```

Then append these lines to the existing `Rules:` list (do not modify the existing petTarget rules):

```
- `annotations` is optional and only allowed when a screenshot is attached. Shapes use the same normalized 0.0–1.0 screenshot coordinates as `petTarget`.
- `ellipse` and `rect` use the CENTER (`cx`, `cy`) plus width/height fractions (`w`, `h`). `arrow` goes from (`fromX`, `fromY`) to (`toX`, `toY`). `label` anchors its `text` (five words or fewer) at (`x`, `y`).
- A few precise shapes beat many: circle one element, draw one arrow for a direction or relationship, box one region. Never more than 12 shapes.
- If uncertain about a location, omit the shape and describe it in `message` instead.
- Your previous annotations are erased with every new answer. To keep pointing at something across a follow-up, include its shapes again.
```

In `prompt(question:hasImage:)`, change the heading line of the coordinate guide from:

```
Coordinate guide for petTarget:
```

to:

```
Coordinate guide for petTarget and annotations:
```

and append one bullet to that guide:

```
- The same normalized coordinates apply to every `annotations` field (`cx`/`cy`, `fromX`/`fromY`/`toX`/`toY`, `x`/`y`).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AskNugumiAnnotationTests`
Expected: `Executed 15 tests, with 0 failures`
Then: `swift test` — full suite passes. If a pre-existing `AskNugumiTests` prompt assertion fails, STOP and report (do not weaken existing assertions).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/AskNugumi.swift Tests/NugumiTests/AskNugumiAnnotationTests.swift
git commit -m "Teach Ask Nugumi prompt the annotation shape vocabulary"
```

---

### Task 4: Renderer — `AskAnnotationOverlayController`

**Files:**

- Modify: `Sources/Nugumi/App.swift` — insert the class directly above `final class AskDrawingOverlayController` (anchor: `final class AskDrawingOverlayController`)

**Interfaces:**

- Consumes: `AskNugumiAnnotation` (Task 1), `AskNugumiCoordinateMapper.exactScreenPoint(normalizedX:normalizedY:screenFrame:)` and `.screenRect(...)` (Task 2), `NSColor.nugumiAccent` (exists in `Bootstrap.swift`).
- Produces (used verbatim by Task 5):
  - `@MainActor final class AskAnnotationOverlayController`
  - `init(screenFrame: NSRect)`
  - `let screenFrame: NSRect` (exposed for reuse checks)
  - `func show(_ annotations: [AskNugumiAnnotation])` — replaces current content
  - `func close()` — idempotent

- [ ] **Step 1: Write the class**

Insert above `final class AskDrawingOverlayController`:

```swift
/// Click-through overlay that renders the model's explanation shapes
/// (`annotations` in the Ask response) over the captured screen. Purely
/// visual: it never takes mouse or keyboard input, so the user keeps
/// working "through" it. Every answer replaces the whole layer.
@MainActor
final class AskAnnotationOverlayController {
    private final class AnnotationPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        // Blanket updates (InvisibilityState.applyToAllOpenWindows, sharing
        // snapshot/restore) must never make the annotation layer capturable:
        // clamp every assignment to .none. The super call is load-bearing —
        // an empty setter would never push .none to the window server at all.
        override var sharingType: NSWindow.SharingType {
            get { super.sharingType }
            set { super.sharingType = .none }
        }
    }

    private final class AnnotationCanvasView: NSView {
        var screenFrame: NSRect = .zero
        var annotations: [AskNugumiAnnotation] = [] {
            didSet { needsDisplay = true }
        }

        private static let strokeWidth: CGFloat = 3
        private static let haloWidth: CGFloat = 5.5
        private static let haloColor = NSColor.white.withAlphaComponent(0.9)

        override func draw(_ dirtyRect: NSRect) {
            for annotation in annotations {
                switch annotation.type {
                case .ellipse:
                    if let rect = localRect(for: annotation) {
                        strokeWithHalo(NSBezierPath(ovalIn: rect))
                    }
                case .rect:
                    if let rect = localRect(for: annotation) {
                        strokeWithHalo(NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6))
                    }
                case .arrow:
                    drawArrow(annotation)
                case .label:
                    drawLabel(annotation)
                }
            }
        }

        // Window covers `screenFrame`, so view-local = screen − frame origin.
        private func localPoint(_ screenPoint: CGPoint) -> CGPoint {
            CGPoint(x: screenPoint.x - screenFrame.minX, y: screenPoint.y - screenFrame.minY)
        }

        private func localRect(for annotation: AskNugumiAnnotation) -> CGRect? {
            guard let cx = annotation.cx, let cy = annotation.cy,
                  let w = annotation.w, let h = annotation.h
            else { return nil }
            let screenRect = AskNugumiCoordinateMapper.screenRect(
                centerX: cx,
                centerY: cy,
                normalizedWidth: w,
                normalizedHeight: h,
                screenFrame: screenFrame
            )
            return CGRect(
                origin: localPoint(screenRect.origin),
                size: screenRect.size
            )
        }

        private func strokeWithHalo(_ path: NSBezierPath) {
            path.lineWidth = Self.haloWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Self.haloColor.setStroke()
            path.stroke()
            path.lineWidth = Self.strokeWidth
            NSColor.nugumiAccent.setStroke()
            path.stroke()
        }

        private func drawArrow(_ annotation: AskNugumiAnnotation) {
            guard let fromX = annotation.fromX, let fromY = annotation.fromY,
                  let toX = annotation.toX, let toY = annotation.toY
            else { return }
            let from = localPoint(AskNugumiCoordinateMapper.exactScreenPoint(
                normalizedX: fromX, normalizedY: fromY, screenFrame: screenFrame
            ))
            let to = localPoint(AskNugumiCoordinateMapper.exactScreenPoint(
                normalizedX: toX, normalizedY: toY, screenFrame: screenFrame
            ))

            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength: CGFloat = 14
            let headWidth: CGFloat = 11
            let shaftEnd = CGPoint(
                x: to.x - cos(angle) * headLength,
                y: to.y - sin(angle) * headLength
            )

            let shaft = NSBezierPath()
            shaft.move(to: from)
            shaft.line(to: shaftEnd)
            strokeWithHalo(shaft)

            let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: CGPoint(
                x: shaftEnd.x + perpendicular.x * headWidth / 2,
                y: shaftEnd.y + perpendicular.y * headWidth / 2
            ))
            head.line(to: CGPoint(
                x: shaftEnd.x - perpendicular.x * headWidth / 2,
                y: shaftEnd.y - perpendicular.y * headWidth / 2
            ))
            head.close()
            head.lineWidth = 2.5
            Self.haloColor.setStroke()
            head.stroke()
            NSColor.nugumiAccent.setFill()
            head.fill()
        }

        private func drawLabel(_ annotation: AskNugumiAnnotation) {
            guard let x = annotation.x, let y = annotation.y,
                  let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            let anchor = localPoint(AskNugumiCoordinateMapper.exactScreenPoint(
                normalizedX: x, normalizedY: y, screenFrame: screenFrame
            ))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            let paddingX: CGFloat = 8
            let paddingY: CGFloat = 4
            var pill = CGRect(
                x: anchor.x - textSize.width / 2 - paddingX,
                y: anchor.y - textSize.height / 2 - paddingY,
                width: textSize.width + paddingX * 2,
                height: textSize.height + paddingY * 2
            )
            // Keep the pill on screen even for edge anchors.
            pill.origin.x = min(max(pill.origin.x, 2), bounds.maxX - pill.width - 2)
            pill.origin.y = min(max(pill.origin.y, 2), bounds.maxY - pill.height - 2)

            let background = NSBezierPath(
                roundedRect: pill,
                xRadius: pill.height / 2,
                yRadius: pill.height / 2
            )
            background.lineWidth = 2
            Self.haloColor.setStroke()
            background.stroke()
            NSColor.nugumiAccent.setFill()
            background.fill()
            string.draw(at: CGPoint(
                x: pill.midX - textSize.width / 2,
                y: pill.midY - textSize.height / 2
            ))
        }
    }

    private let panel: AnnotationPanel
    private let canvas: AnnotationCanvasView
    private var didClose = false

    let screenFrame: NSRect

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        canvas.screenFrame = screenFrame
        panel = AnnotationPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Same shelf as the drawing canvas: below the .floating Ask panels.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        // Purely visual layer: the user clicks straight through it.
        panel.ignoresMouseEvents = true
        panel.contentView = canvas
        panel.orderFrontRegardless()
    }

    /// Replaces the whole layer with this answer's shapes.
    func show(_ annotations: [AskNugumiAnnotation]) {
        canvas.annotations = annotations
    }

    /// Idempotent: teardown paths overlap.
    func close() {
        guard !didClose else { return }
        didClose = true
        panel.close()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` (class is intentionally unreferenced until Task 5; report any new warnings verbatim)

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add click-through renderer for model annotation shapes"
```

---

### Task 5: Lifecycle wiring — replace on every answer, die with the answer

**Files:**

- Modify: `Sources/Nugumi/App.swift` — six anchored edits.

**Interfaces:**

- Consumes: `AskAnnotationOverlayController` (Task 4), `AskNugumiResponse.annotations` (Task 1).
- Produces: `private var askAnnotationOverlay: AskAnnotationOverlayController?`, `presentAskAnnotations(_:capture:)`, `closeAskAnnotationOverlay()` on the app delegate.

- [ ] **Step 1: Add state + helpers**

Below the existing property `private var floatingTargetButton: FloatingTranslateButtonController?` (anchor: `floatingTargetButton: FloatingTranslateButtonController?`), add:

```swift
    /// Click-through layer with the model's explanation shapes; replaced on
    /// every Ask answer, torn down with the answer UI.
    private var askAnnotationOverlay: AskAnnotationOverlayController?
```

Directly after `presentFloatingAskTargetPointer` (anchor: `func presentFloatingAskTargetPointer`), add:

```swift
    /// Replace-on-every-answer semantics: new shapes redraw the layer, an
    /// empty list clears it — mirroring how the petTarget pointer already
    /// moves or closes with each answer.
    @MainActor
    private func presentAskAnnotations(
        _ annotations: [AskNugumiAnnotation],
        capture: AskNugumiScreenCapture
    ) {
        guard !annotations.isEmpty else {
            closeAskAnnotationOverlay()
            return
        }
        if let existing = askAnnotationOverlay, existing.screenFrame == capture.screenFrame {
            existing.show(annotations)
        } else {
            askAnnotationOverlay?.close()
            let overlay = AskAnnotationOverlayController(screenFrame: capture.screenFrame)
            overlay.show(annotations)
            askAnnotationOverlay = overlay
        }
    }

    @MainActor
    private func closeAskAnnotationOverlay() {
        askAnnotationOverlay?.close()
        askAnnotationOverlay = nil
    }
```

- [ ] **Step 2: Present at the three answer paths**

(a) In `presentAskNugumiResult` (anchor: `func presentAskNugumiResult`), the pill branch ends with the petTarget if/else. Add the annotations call right after it, so the block reads:

```swift
        if let target = response.petTarget {
            presentFloatingAskTargetPointer(for: target, capture: capture)
        } else {
            floatingTargetButton?.close()
            floatingTargetButton = nil
        }
        presentAskAnnotations(response.annotations, capture: capture)
```

(b) In `presentPetAskNugumiResult` (anchor: `func presentPetAskNugumiResult`), add as the LAST line of the function body (after the `if let target ... else ... showAnswer` block):

```swift
        presentAskAnnotations(response.annotations, capture: capture)
```

(c) In `submitAskNugumiFollowUp` (anchor: `func submitAskNugumiFollowUp`), inside the success `MainActor.run` block, the petTarget if/else currently reads:

```swift
                    if let target = response.petTarget {
                        self.presentFloatingAskTargetPointer(for: target, capture: capture)
                    } else {
                        self.floatingTargetButton?.close()
                        self.floatingTargetButton = nil
                    }
```

Add directly after it:

```swift
                    self.presentAskAnnotations(response.annotations, capture: capture)
```

- [ ] **Step 3: Tear down everywhere the target pointer dies**

Add `closeAskAnnotationOverlay()` at each of these four anchored spots, immediately after the existing `floatingTargetButton?.close(); floatingTargetButton = nil` pair (or the stated line):

1. `startAskNugumiPrompt()` — the entry cleanup block (anchor: `translateButtonController?.close()` inside that function):

```swift
        floatingTargetButton?.close()
        floatingTargetButton = nil
        closeAskAnnotationOverlay()
```

2. The answer panel's `onClose:` inside `presentAskNugumiResult`:

```swift
            onClose: { [weak self] in
                guard let self else { return }
                if self.isAskNugumiRunning { self.cancelAskNugumiRequest() }
                self.translationPanelController = nil
                self.floatingTargetButton?.close()
                self.floatingTargetButton = nil
                self.closeAskAnnotationOverlay()
                self.petController?.clearReady()
            }
```

3. `dismissAskNugumi()` (anchor: `func dismissAskNugumi`), after its `floatingTargetButton` pair:

```swift
        floatingTargetButton?.close()
        floatingTargetButton = nil
        closeAskAnnotationOverlay()
```

4. `presentPetAskPrompt()`'s `onClose:` (anchor: `func presentPetAskPrompt`), after the existing `closeAskDrawingOverlay()` line:

```swift
                self.closeAskDrawingOverlay()
                self.closeAskAnnotationOverlay()
```

- [ ] **Step 4: Verify pet answer dismissal reaches a teardown**

The pet-mode answer can be dismissed by clicking the pet (`petView.onClick` → `closePromptFromUser`) and by its Escape monitor. Trace `closePromptFromUser` in `PetController` (grep anchor: `func closePromptFromUser`) and confirm it invokes the `onPromptClose`/`onClose` callback that `presentPetAskPrompt` registered (which now calls `closeAskAnnotationOverlay()`). If pet ANSWER dismissal does NOT route through that callback, find the actual answer-close callback (grep: `clearReady\|onAnswerClose\|answerScrollView.isHidden = true` near the answer teardown) and add `closeAskAnnotationOverlay()` via the appropriate existing hook on the app-delegate side — do not add new callbacks to `PetController` unless nothing reaches the app delegate. Document what you found in your report.

- [ ] **Step 5: Build + full test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Wire model annotations into Ask answer lifecycle with replace semantics"
```

---

### Task 6: Manual QA (performed by the maintainer — do not launch the app yourself)

**Files:** none.

- [ ] **Step 1: Build for the maintainer**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 2: Hand the maintainer this checklist**

Ask the maintainer to run the packaged app themselves (`bash Scripts/build-app-bundle.sh`, then `dist/Nugumi.app`) with a capable cloud vision model selected, and verify:

1. Ask "обведи кнопку сохранения и покажи стрелкой, куда нажать" → ellipse + arrow render over the right elements, accent-colored with white halo.
2. Click straight through a drawn shape onto the UI element under it — the click lands on the app below (overlay is click-through).
3. Follow-up that asks to point at something else → shapes are replaced, not stacked.
4. Follow-up with a plain text question (model returns no annotations) → old shapes disappear.
5. Esc / closing the answer panel / new ⌃⌥A → shapes disappear; no orphaned graphics.
6. Pet mode: shapes render with the pet's answer bubble and clear when the bubble closes.
7. Toggle invisibility mode while shapes are visible, take an area screenshot → shapes do not appear in the capture.
8. Switch to a weak local Ollama vision model and ask the same → possibly no/fewer shapes, but never a crash or broken answer text.

- [ ] **Step 3: Fix anything the checklist surfaces, then commit fixes**

```bash
git add -A Sources Tests
git commit -m "Fix model annotation QA findings"
```

(Skip the commit if QA is clean.)
