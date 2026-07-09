# Ask Nugumi On-Screen Drawing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While the Ask Nugumi prompt is open, let the user draw freehand red strokes on the captured screen; at submit the strokes are burned into the already-captured screenshot so the vision model sees what the user is pointing at.

**Architecture:** A transparent, non-activating `NSPanel` overlay (`AskDrawingOverlayController`) covers the captured screen while the Ask prompt is open and collects mouse-drag strokes. At submit, a pure function `AskNugumiScreenCapture.annotated(with:)` composites the strokes into the existing screenshot data (no re-capture) and one sentence is appended to the outgoing question. Spec: `docs/superpowers/specs/2026-07-09-ask-nugumi-drawing-design.md`.

**Tech Stack:** Swift / AppKit / CoreGraphics only. No new dependencies.

## Global Constraints

- ALL app code goes into `Sources/Nugumi/App.swift` — the single-file layout is a project rule (see CLAUDE.md). Tests go into `Tests/NugumiTests/`.
- Deployment target macOS 14; no new SPM dependencies.
- Never use the words "translate/translation/translator" in user-facing strings.
- The word "Task N" line references in this plan use grep anchors (function/class names), not line numbers — the maintainer edits `App.swift` concurrently and line numbers drift. Always locate edit points by searching for the anchor text.
- If `swift build` crashes with swift-frontend signal 11 mentioning `_DarwinFoundation1 defined in both`, run `rm -rf .build/clang-module-cache*` and rebuild — it is a stale module cache, not a code bug.
- Never launch `Nugumi.app` or `swift run Nugumi` yourself — macOS TCC misattributes permissions when launched from an agent shell. Manual QA is performed by the maintainer.

---

### Task 1: Stroke compositing — `AskNugumiScreenCapture.annotated(with:)`

**Files:**

- Modify: `Sources/Nugumi/App.swift` — add an extension immediately after `struct AskNugumiScreenCapture { ... }` (anchor: `struct AskNugumiScreenCapture`)
- Test: `Tests/NugumiTests/AskNugumiDrawingTests.swift` (create)

**Interfaces:**

- Consumes: existing `struct AskNugumiScreenCapture` (`image: ImageInput`, `imagePixelSize: CGSize`, `screenFrame: CGRect`, `visibleFrame: CGRect`) and `struct ImageInput` (`data: Data`, `mediaType: String`).
- Produces: `func annotated(with strokes: [[NSPoint]]) -> AskNugumiScreenCapture` — strokes are arrays of points in **AppKit global screen coordinates** (y-up); returns a new capture whose `image` has the strokes drawn in red, or `self` unchanged when `strokes` is empty or anything fails. Task 4 calls exactly this signature.

- [ ] **Step 1: Write the failing tests**

Create `Tests/NugumiTests/AskNugumiDrawingTests.swift`:

```swift
import AppKit
import XCTest

@testable import Nugumi

final class AskNugumiDrawingTests: XCTestCase {
    /// Solid-white square capture with a configurable screen mapping.
    private func makeWhiteCapture(
        pixelSide: Int,
        screenFrame: CGRect
    ) -> AskNugumiScreenCapture {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSide,
            pixelsHigh: pixelSide,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pixelSide, height: pixelSide).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        return AskNugumiScreenCapture(
            image: ImageInput(data: png, mediaType: "image/png"),
            imagePixelSize: CGSize(width: pixelSide, height: pixelSide),
            screenFrame: screenFrame,
            visibleFrame: screenFrame
        )
    }

    private func decode(_ image: ImageInput) -> NSBitmapImageRep {
        NSBitmapImageRep(data: image.data)!
    }

    func testAnnotatedBurnsRedStrokeIntoImage() {
        let capture = makeWhiteCapture(
            pixelSide: 80,
            screenFrame: CGRect(x: 0, y: 0, width: 80, height: 80)
        )
        // Horizontal stroke through the vertical center of the screen.
        let stroke = [NSPoint(x: 10, y: 40), NSPoint(x: 70, y: 40)]

        let annotated = capture.annotated(with: [stroke])

        let bitmap = decode(annotated.image)
        // The center pixel sits on the stroke regardless of y-flip.
        let center = bitmap.colorAt(x: 40, y: 40)!
        XCTAssertGreaterThan(center.redComponent, 0.7, "stroke should be red")
        XCTAssertLessThan(center.greenComponent, 0.5, "stroke should be red")
        // A corner pixel stays white (JPEG artifacts allowed for).
        let corner = bitmap.colorAt(x: 3, y: 3)!
        XCTAssertGreaterThan(corner.redComponent, 0.85)
        XCTAssertGreaterThan(corner.greenComponent, 0.85)
        XCTAssertGreaterThan(corner.blueComponent, 0.85)
    }

    func testAnnotatedWithNoStrokesReturnsImageUntouched() {
        let capture = makeWhiteCapture(
            pixelSide: 40,
            screenFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let annotated = capture.annotated(with: [])
        XCTAssertEqual(annotated.image.data, capture.image.data)
        XCTAssertEqual(annotated.image.mediaType, capture.image.mediaType)
    }

    func testAnnotatedMapsScreenPointsToImagePixels() {
        // Screen region is 160 pt at origin (100, 200); image is only
        // 80 px — 0.5× scale plus offset, like a Retina capture downscaled
        // for vision.
        let capture = makeWhiteCapture(
            pixelSide: 80,
            screenFrame: CGRect(x: 100, y: 200, width: 160, height: 160)
        )
        // Horizontal stroke through the screen-space center → must land on
        // the image center after scale + offset mapping.
        let stroke = [NSPoint(x: 120, y: 280), NSPoint(x: 240, y: 280)]

        let bitmap = decode(capture.annotated(with: [stroke]).image)

        let center = bitmap.colorAt(x: 40, y: 40)!
        XCTAssertGreaterThan(center.redComponent, 0.7)
        XCTAssertLessThan(center.greenComponent, 0.5)
    }

    func testAnnotatedIgnoresSinglePointStrokes() {
        // A click without a drag produces a 1-point stroke; it must not mark
        // the image (stray clicks stay harmless).
        let capture = makeWhiteCapture(
            pixelSide: 40,
            screenFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let bitmap = decode(capture.annotated(with: [[NSPoint(x: 20, y: 20)]]).image)
        let center = bitmap.colorAt(x: 20, y: 20)!
        XCTAssertGreaterThan(center.greenComponent, 0.85, "single point must not draw")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AskNugumiDrawingTests`
Expected: BUILD FAILURE — `value of type 'AskNugumiScreenCapture' has no member 'annotated'`

- [ ] **Step 3: Write the implementation**

In `Sources/Nugumi/App.swift`, directly after the closing brace of `struct AskNugumiScreenCapture` (anchor: `struct AskNugumiScreenCapture`), add:

```swift
extension AskNugumiScreenCapture {
    /// Burns user-drawn strokes (AppKit global screen points) into the
    /// screenshot as red marks so the vision model can see what the user is
    /// pointing at. Best-effort: any decode/encode failure returns `self`
    /// unannotated — the request is never blocked on annotation.
    func annotated(with strokes: [[NSPoint]]) -> AskNugumiScreenCapture {
        guard strokes.contains(where: { $0.count > 1 }),
              screenFrame.width > 0, screenFrame.height > 0,
              let cgImage = NSBitmapImageRep(data: image.data)?.cgImage
        else { return self }

        let width = cgImage.width
        let height = cgImage.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return self }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // AppKit global coordinates and CGContext both use a bottom-left
        // origin, so the mapping is pure scale + offset — no y flip.
        let scaleX = CGFloat(width) / screenFrame.width
        let scaleY = CGFloat(height) / screenFrame.height
        context.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1))
        // 4 pt on screen scaled to image pixels, floored so marks stay
        // visible on screenshots downscaled to the 2048 px vision edge.
        context.setLineWidth(max(3, 4 * scaleX))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes where stroke.count > 1 {
            let mapped = stroke.map { point in
                CGPoint(
                    x: (point.x - screenFrame.minX) * scaleX,
                    y: (point.y - screenFrame.minY) * scaleY
                )
            }
            let path = CGMutablePath()
            path.move(to: mapped[0])
            for point in mapped.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.strokePath()
        }

        guard let composited = context.makeImage() else { return self }
        let bitmap = NSBitmapImageRep(cgImage: composited)
        let jpegProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
        guard let jpeg = bitmap.representation(using: .jpeg, properties: jpegProps)
        else { return self }

        return AskNugumiScreenCapture(
            image: ImageInput(data: jpeg, mediaType: "image/jpeg"),
            imagePixelSize: imagePixelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AskNugumiDrawingTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/AskNugumiDrawingTests.swift
git commit -m "Add stroke compositing for Ask Nugumi screen captures"
```

---

### Task 2: `AskDrawingOverlayController` — transparent draw-anywhere canvas

**Files:**

- Modify: `Sources/Nugumi/App.swift` — add the class directly above `final class AskPromptController` (anchor: `final class AskPromptController`)

**Interfaces:**

- Consumes: nothing from other tasks.
- Produces (used verbatim by Tasks 3 and 4):
  - `@MainActor final class AskDrawingOverlayController`
  - `init(screenFrame: NSRect)` — creates and orders front a transparent overlay covering that screen frame
  - `var window: NSWindow { get }` — the overlay panel, for the outside-click exemption
  - `var strokes: [[NSPoint]] { get }` — committed strokes in AppKit **global** screen coordinates (matches `annotated(with:)` input)
  - `func close()` — idempotent teardown (removes the ⌘Z monitor, closes the panel)

- [ ] **Step 1: Write the class**

Insert above `final class AskPromptController`:

```swift
/// Transparent, non-activating overlay that covers the captured screen while
/// the Ask Nugumi prompt is open. Mouse drags become freehand red strokes;
/// at submit they are composited into the pending screen capture. The panel
/// never becomes key, so typing stays in the prompt field the whole time.
@MainActor
final class AskDrawingOverlayController {
    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class StrokeCanvasView: NSView {
        var strokes: [[NSPoint]] = [] {
            didSet { needsDisplay = true }
        }
        private var activeStroke: [NSPoint] = []

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Cursor rects only apply to the key window and this panel is never
        // key, so the crosshair needs an always-active tracking area instead.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        override func mouseDown(with event: NSEvent) {
            activeStroke = [convert(event.locationInWindow, from: nil)]
        }

        override func mouseDragged(with event: NSEvent) {
            activeStroke.append(convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            // A plain click (no drag) draws nothing — stray clicks stay
            // harmless and never leave a dot on the screenshot.
            if activeStroke.count > 1 {
                strokes.append(activeStroke)
            }
            activeStroke = []
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.setStroke()
            for stroke in strokes + [activeStroke] where stroke.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = 4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: stroke[0])
                for point in stroke.dropFirst() {
                    path.line(to: point)
                }
                path.stroke()
            }
        }
    }

    private let panel: OverlayPanel
    private let canvas: StrokeCanvasView
    private let screenFrame: NSRect
    private var undoKeyMonitor: Any?
    private var didClose = false

    var window: NSWindow { panel }

    /// Committed strokes in AppKit global (screen) coordinates — the exact
    /// input `AskNugumiScreenCapture.annotated(with:)` expects.
    var strokes: [[NSPoint]] {
        canvas.strokes.map { stroke in
            stroke.map { NSPoint(x: $0.x + screenFrame.minX, y: $0.y + screenFrame.minY) }
        }
    }

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        canvas = StrokeCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        panel = OverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One notch below .floating so the Ask pill and pet panels (both
        // .floating) stay clickable above the canvas.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Strokes must never leak into a screen capture — they are
        // composited into the image at submit instead.
        panel.sharingType = .none
        // Explicit `false` opts out of AppKit's per-pixel transparency hit
        // test: a fully clear window must still receive drawing drags.
        panel.ignoresMouseEvents = false
        panel.contentView = canvas
        panel.orderFrontRegardless()
        installUndoKeyMonitor()
    }

    /// Idempotent: every Ask teardown path calls this, some more than once.
    func close() {
        guard !didClose else { return }
        didClose = true
        if let undoKeyMonitor {
            NSEvent.removeMonitor(undoKeyMonitor)
            self.undoKeyMonitor = nil
        }
        panel.close()
    }

    // ⌘Z anywhere while the Ask UI is open removes the last stroke. A local
    // monitor works for both the pill and the pet prompt (whichever is key)
    // without touching their text fields; when there are no strokes the
    // event passes through to the field's own undo.
    private func installUndoKeyMonitor() {
        undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "z",
                  !self.canvas.strokes.isEmpty
            else { return event }
            self.canvas.strokes.removeLast()
            return nil
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` (warnings about unrelated code are fine)

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add AskDrawingOverlayController transparent stroke canvas"
```

---

### Task 3: Overlay lifecycle wiring — appear with the prompt, die with it

**Files:**

- Modify: `Sources/Nugumi/App.swift` — five surgical edits, all anchored below.

**Interfaces:**

- Consumes: `AskDrawingOverlayController` from Task 2 (exact API listed there).
- Produces (used by Task 4):
  - `private var askDrawingOverlay: AskDrawingOverlayController?` app-state property
  - `@MainActor private func closeAskDrawingOverlay()` on the app delegate
- Modifies `AskPromptController`: adds `weak var drawingOverlayWindow: NSWindow?` and an exemption in `closeIfClickIsOutside` so clicks on the overlay draw instead of dismissing the pill.

- [ ] **Step 1: Add app state + present/close helpers**

Find the property `private var pendingAskNugumiCapture: AskNugumiScreenCapture?` (anchor: `pendingAskNugumiCapture: AskNugumiScreenCapture?`) and add below it:

```swift
    /// Draw-anywhere canvas over the captured screen; alive while the Ask
    /// prompt is open, consumed (strokes → image) at submit.
    private var askDrawingOverlay: AskDrawingOverlayController?
```

Find `private func captureScreenBeforeAskPromptTakesFocus()` (anchor: `captureScreenBeforeAskPromptTakesFocus`) and add these two methods directly after it:

```swift
    /// Shows the transparent drawing canvas over the screen that was just
    /// captured (falling back to the cursor's screen if capture failed).
    /// Clicks that land on it become strokes, so the prompt's outside-click
    /// dismissal is exempted for this window.
    @MainActor
    private func presentAskDrawingOverlay() {
        askDrawingOverlay?.close()
        askDrawingOverlay = nil
        let frame = pendingAskNugumiCapture?.screenFrame
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.frame
            ?? NSScreen.main?.frame
        guard let frame else { return }
        let overlay = AskDrawingOverlayController(screenFrame: frame)
        askDrawingOverlay = overlay
        askPromptController?.drawingOverlayWindow = overlay.window
    }

    @MainActor
    private func closeAskDrawingOverlay() {
        askDrawingOverlay?.close()
        askDrawingOverlay = nil
    }
```

- [ ] **Step 2: Present the overlay in all three entry points**

In `startAskNugumiPrompt()` (anchor: `func startAskNugumiPrompt`), pet branch — add one line after `self.presentPetAskPrompt()`:

```swift
        if selectionDisplayMode == .pet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
                self.presentPetAskPrompt()
                self.presentAskDrawingOverlay()
            }
            return
        }
```

Same function, pill branch — add one line after `controller.show()`:

```swift
        Task { @MainActor [weak self] in
            guard let self, self.askPromptController === controller else { return }
            self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            guard self.askPromptController === controller else { return }
            controller.show()
            self.presentAskDrawingOverlay()
        }
```

In `continueAskNugumiDialog()` (anchor: `func continueAskNugumiDialog`) — add one line after `self.presentPetAskPrompt()`:

```swift
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            self.presentPetAskPrompt()
            self.presentAskDrawingOverlay()
        }
```

- [ ] **Step 3: Tear the overlay down on every close path**

In `startAskNugumiPrompt()`'s `AskPromptController` construction, `onClose:` closure — add `self.closeAskDrawingOverlay()`:

```swift
            onClose: { [weak self] in
                guard let self else { return }
                self.askPromptController = nil
                self.pendingAskNugumiCapture = nil
                self.closeAskDrawingOverlay()
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
```

In `presentPetAskPrompt()` (anchor: `func presentPetAskPrompt`), `onClose:` closure — add the same line:

```swift
            onClose: { [weak self] in
                guard let self else { return }
                self.pendingAskNugumiCapture = nil
                self.closeAskDrawingOverlay()
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
```

In `dismissAskNugumi()` (anchor: `func dismissAskNugumi`) — add one line after `pendingAskNugumiCapture = nil`:

```swift
        pendingAskNugumiCapture = nil
        closeAskDrawingOverlay()
```

- [ ] **Step 4: Exempt the overlay from the pill's outside-click dismissal**

In `AskPromptController` (anchor: `final class AskPromptController`), add a property next to the existing monitor properties:

```swift
    /// While the drawing overlay is up, clicks landing on it are strokes,
    /// not dismissals.
    weak var drawingOverlayWindow: NSWindow?
```

In `closeIfClickIsOutside(_:)` (anchor: `func closeIfClickIsOutside`), add the exemption right after the `panel.isVisible` guard:

```swift
    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        if let drawingOverlayWindow, event.window === drawingOverlayWindow {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        close()
    }
```

Note: `PetController` has no outside-click monitor for its prompt (only an Escape key monitor and pet-click close), so no pet-side exemption is needed. Verify with `grep -n "addGlobalMonitorForEvents" Sources/Nugumi/App.swift` — if a pet prompt click monitor has appeared since, apply the same window-exemption pattern there.

- [ ] **Step 5: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Wire drawing overlay into Ask Nugumi prompt lifecycle"
```

---

### Task 4: Submit path — composite strokes and tell the model about them

**Files:**

- Modify: `Sources/Nugumi/App.swift` — `submitAskNugumiPrompt(_:)` only (anchor: `func submitAskNugumiPrompt`)

**Interfaces:**

- Consumes: `askDrawingOverlay` / `closeAskDrawingOverlay()` (Task 3), `AskNugumiScreenCapture.annotated(with:)` (Task 1).
- Produces: no new API. Behavior contract: with zero strokes the request is byte-identical to today (same image data object, unmodified question).

- [ ] **Step 1: Collect strokes at submit and close the overlay**

In `submitAskNugumiPrompt(_:)`, find:

```swift
        let preparedCapture = pendingAskNugumiCapture
        pendingAskNugumiCapture = nil
```

and extend to:

```swift
        let preparedCapture = pendingAskNugumiCapture
        pendingAskNugumiCapture = nil
        // Strokes are consumed here: composited into the capture below, so
        // the on-screen canvas can come down before the request starts.
        let strokes = askDrawingOverlay?.strokes ?? []
        closeAskDrawingOverlay()
        let question = strokes.isEmpty
            ? cleanPrompt
            : cleanPrompt
                + "\n\n(The red marks on the screenshot are my annotations pointing at what I'm asking about.)"
```

Placement matters: this sits AFTER the vision-model and setup-error guards (which `return` early and must leave the overlay up so the user can fix the problem and resubmit) and BEFORE `askNugumiTask = Task { ... }`.

- [ ] **Step 2: Annotate the capture and send the augmented question**

Inside the same function's `askNugumiTask = Task { ... }` closure, after the `capture` variable is resolved (the `if let preparedCapture { ... } else { ... }` block) and after `try Task.checkCancellation()`, insert the compositing and switch the two usages:

```swift
                try Task.checkCancellation()

                // Compositing decodes + re-encodes a ≤2048 px JPEG; keep it
                // off the main actor like the capture encode itself.
                let annotatedCapture = strokes.isEmpty
                    ? capture
                    : await Task.detached(priority: .userInitiated) {
                        capture.annotated(with: strokes)
                    }.value
```

Then change the backend call from `question: cleanPrompt, image: capture.image` to:

```swift
                let response = try await backend.ask(
                    history: history,
                    question: question,
                    image: annotatedCapture.image,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
```

And the result presentation from `capture: capture` to:

```swift
                await MainActor.run {
                    self?.presentAskNugumiResult(
                        response,
                        capture: annotatedCapture,
                        prompt: cleanPrompt,
                        requestID: requestID
                    )
                }
```

`prompt: cleanPrompt` stays as-is on purpose — the annotation sentence is for the model only and must not pollute `askHistory` or the history store.

- [ ] **Step 3: Verify build and full test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests pass (including the 4 from Task 1).

- [ ] **Step 4: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Composite Ask Nugumi drawing strokes into the screen capture at submit"
```

---

### Task 5: Manual QA (performed by the maintainer — do not launch the app yourself)

**Files:** none.

- [ ] **Step 1: Build the debug binary for the maintainer**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 2: Hand the maintainer this checklist**

Ask the maintainer to run `swift run Nugumi` (or the built `dist/Nugumi.app` for the full-bundle path) themselves and verify:

1. ⌃⌥A → circle a UI element → type "what did I circle?" → answer references the circled element.
2. While the prompt is open the cursor is a crosshair over the screen, drags draw red lines, and typing in the pill still works.
3. ⌘Z removes only the last stroke; ⌘Z with no strokes leaves text-field undo working.
4. Esc and repeat ⌃⌥A both close pill + strokes together; no orphaned red lines remain.
5. Submit with zero strokes behaves exactly as before (no annotation sentence, image untouched).
6. Pet mode: prompt + drawing works; closing the pet prompt clears strokes.
7. Screenshot-area mode (⌃⌥ shortcut for area capture) is unaffected.
8. Clicking the pill itself still focuses the text field (click is not swallowed by the overlay).

- [ ] **Step 3: Fix anything the checklist surfaces, then commit fixes**

```bash
git add -A Sources Tests
git commit -m "Fix Ask Nugumi drawing QA findings"
```

(Skip the commit if QA is clean.)
