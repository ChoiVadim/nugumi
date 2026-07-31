# Radial Action Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking the floating bar or the pet opens a radial menu of 4 actions (Explain / Rewrite / Reply / Ask) instead of firing a default mode; the invisible right-click and Tab gestures are deleted.

**Architecture:** One new presentational component (`RadialActionMenuController` + pure `RadialMenuLayoutPolicy`) in `App.swift`. `FloatingTranslateButtonController` and `PetController` toggle it from their click handlers and map the picked action onto their existing `onTranslate`/`onRewrite`/`onSmartReply` callbacks plus a new `onAsk`. No transport, mode, or panel changes downstream.

**Tech Stack:** Swift / AppKit (SwiftPM), XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-10-radial-action-menu-design.md`

## Global Constraints

- Everything goes in `Sources/Nugumi/App.swift` — single-file layout is intentional (project CLAUDE.md). Tests go in `Tests/NugumiTests/`.
- **Never** use the words "translate/translation/translator" in NEW user-visible strings (labels, tooltips). Code identifiers are fine. The action label for the `.selection` mode is **"Explain"**.
- `FloatingButtonDefaultMode` ("Main mode"), the status-bar item, its defaults key, and `makeStatusBarIcon(for:)` are **out of scope — do not touch**. They drive the global shortcut and screenshot semantics.
- Line numbers drift (the file is being edited concurrently) — locate code by the exact symbol names and code snippets given below, not by line number.
- Build: `swift build`. Tests: `swift test`. Manual run: `swift run Nugumi` (needs Accessibility permission; Sparkle inert — that's fine).
- Comments follow house style: explain constraints/why, not what.

---

### Task 1: `RadialAction` + `RadialMenuLayoutPolicy` (pure logic, TDD)

**Files:**

- Modify: `Sources/Nugumi/App.swift` — insert the two types immediately **above** the line `final class FloatingTranslateButtonController {` (search for it; it is preceded by the closing of `PetMascotView`'s `tooltip(for:mode:)` helper).
- Test: `Tests/NugumiTests/RadialMenuLayoutTests.swift` (create)

**Interfaces:**

- Consumes: nothing.
- Produces (later tasks rely on these exact names):
  - `enum RadialAction: CaseIterable { case explain, rewrite, reply, ask }` with `var label: String`, `var symbolName: String`
  - `RadialMenuLayoutPolicy.ringRadius: CGFloat`
  - `RadialMenuLayoutPolicy.buttonDiameter: CGFloat`
  - `RadialMenuLayoutPolicy.buttonCenters() -> [CGPoint]` (offsets from panel center, same order as `RadialAction.allCases`)
  - `RadialMenuLayoutPolicy.panelFrame(anchor: NSPoint, screenVisibleFrame: NSRect) -> NSRect`

- [ ] **Step 1: Baseline — run the existing suite**

Run: `swift test 2>&1 | tail -5`
Expected: all existing tests pass. If not, STOP and report — don't build on a broken baseline.

- [ ] **Step 2: Write the failing test**

Create `Tests/NugumiTests/RadialMenuLayoutTests.swift`:

```swift
import AppKit
import XCTest

@testable import Nugumi

final class RadialMenuLayoutTests: XCTestCase {
    func testOneButtonCenterPerAction() {
        XCTAssertEqual(
            RadialMenuLayoutPolicy.buttonCenters().count,
            RadialAction.allCases.count
        )
    }

    func testButtonCentersSitOnTheRing() {
        for offset in RadialMenuLayoutPolicy.buttonCenters() {
            let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            XCTAssertEqual(distance, RadialMenuLayoutPolicy.ringRadius, accuracy: 0.001)
        }
    }

    func testPanelCentersOnAnchorAwayFromEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: NSPoint(x: 700, y: 450),
            screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.midX, 700, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 450, accuracy: 0.001)
    }

    func testPanelClampsInsideBottomLeftCorner() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: NSPoint(x: 10, y: 10),
            screenVisibleFrame: screen
        )
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
    }

    func testPanelClampsInsideTopRightCorner() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: NSPoint(x: 1430, y: 890),
            screenVisibleFrame: screen
        )
        XCTAssertLessThanOrEqual(frame.maxX, 1440)
        XCTAssertLessThanOrEqual(frame.maxY, 900)
    }

    func testEveryActionHasLabelAndSymbol() {
        for action in RadialAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil))
        }
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter RadialMenuLayoutTests 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'RadialMenuLayoutPolicy' in scope`.

- [ ] **Step 4: Implement the two types**

In `Sources/Nugumi/App.swift`, immediately above `final class FloatingTranslateButtonController {` (note: the class is annotated `@MainActor` on the preceding line — insert above that annotation), add:

```swift
/// Actions offered by the radial menu that opens around the floating bar /
/// pet. Labels avoid "translate" wording deliberately — house copy rule.
enum RadialAction: CaseIterable {
    case explain
    case rewrite
    case reply
    case ask

    var label: String {
        switch self {
        case .explain: return "Explain"
        case .rewrite: return "Rewrite"
        case .reply: return "Reply"
        case .ask: return "Ask"
        }
    }

    var symbolName: String {
        switch self {
        case .explain: return "sparkles"
        case .rewrite: return "pencil.line"
        case .reply: return "arrowshape.turn.up.left"
        case .ask: return "questionmark.bubble"
        }
    }
}

/// Pure geometry for the radial menu: where the four buttons sit around the
/// anchor and how the ring shifts to stay on screen. Kept free of AppKit
/// state so it is unit-testable.
enum RadialMenuLayoutPolicy {
    static let ringRadius: CGFloat = 64
    static let buttonDiameter: CGFloat = 44
    /// Room around the ring so hover labels under the buttons stay inside
    /// the panel.
    static let panelPadding: CGFloat = 28

    static var panelSide: CGFloat {
        (ringRadius + buttonDiameter / 2 + panelPadding) * 2
    }

    /// Offsets from the panel center, one per `RadialAction.allCases` entry:
    /// explain on top, rewrite left, reply right, ask at the bottom.
    static func buttonCenters() -> [CGPoint] {
        [
            CGPoint(x: 0, y: ringRadius),
            CGPoint(x: -ringRadius, y: 0),
            CGPoint(x: ringRadius, y: 0),
            CGPoint(x: 0, y: -ringRadius),
        ]
    }

    /// Panel frame centered on `anchor`, shifted (not shrunk) to stay inside
    /// the screen. The bar/pet itself does not move; near edges the ring is
    /// simply off-center around it.
    static func panelFrame(anchor: NSPoint, screenVisibleFrame: NSRect) -> NSRect {
        var frame = NSRect(
            x: anchor.x - panelSide / 2,
            y: anchor.y - panelSide / 2,
            width: panelSide,
            height: panelSide
        )
        if frame.minX < screenVisibleFrame.minX {
            frame.origin.x = screenVisibleFrame.minX
        }
        if frame.maxX > screenVisibleFrame.maxX {
            frame.origin.x = screenVisibleFrame.maxX - frame.width
        }
        if frame.minY < screenVisibleFrame.minY {
            frame.origin.y = screenVisibleFrame.minY
        }
        if frame.maxY > screenVisibleFrame.maxY {
            frame.origin.y = screenVisibleFrame.maxY - frame.height
        }
        return frame
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter RadialMenuLayoutTests 2>&1 | tail -5`
Expected: 6 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/RadialMenuLayoutTests.swift
git commit -m "Add RadialAction and RadialMenuLayoutPolicy with layout tests"
```

---

### Task 2: `RadialActionMenuController` (panel + buttons + dismissal)

**Files:**

- Modify: `Sources/Nugumi/App.swift` — insert directly **below** the `RadialMenuLayoutPolicy` enum added in Task 1.

**Interfaces:**

- Consumes: `RadialAction`, `RadialMenuLayoutPolicy` (Task 1); existing `InvisibilityState.apply(to:)`, `kVK_Escape` (already imported via Carbon.HIToolbox — used elsewhere in the file).
- Produces (Tasks 3–4 rely on):
  - `@MainActor final class RadialActionMenuController`
  - `init(centeredOn anchor: NSPoint, ignoring presenterWindow: NSWindow?, onSelect: @escaping (RadialAction) -> Void, onDismiss: @escaping () -> Void)` — `presenterWindow` is the bar/pet panel; clicks in it are left to the presenter's own toggle handler
  - `func show()`
  - `func close()` — silent teardown, does NOT call `onDismiss` (for presenter-initiated toggle/select paths)
  - `onDismiss` fires only for self-initiated closes: outside click, Escape, empty-backdrop click.

- [ ] **Step 1: Add the controller and its two private views**

Insert below `RadialMenuLayoutPolicy`:

```swift
/// The ring of action buttons that opens around the floating bar / pet.
/// Purely presentational: owns one transparent panel, reports the picked
/// action via `onSelect`, and calls `onDismiss` when it closed itself
/// (outside click, Escape, empty-area click). The presenter owns the
/// toggle state and calls `close()` for its own teardown paths.
@MainActor
final class RadialActionMenuController {
    private let panel: NSPanel
    /// The bar/pet panel that opened the menu. Its clicks are exempt from
    /// the local dismiss monitor — the presenter's click handler owns the
    /// toggle, and dismissing here first would make that handler reopen.
    private weak var presenterWindow: NSWindow?
    private let onSelect: (RadialAction) -> Void
    private let onDismiss: () -> Void
    private var buttons: [RadialMenuButtonView] = []
    private var dismissMonitors: [Any] = []
    private var didClose = false

    init(
        centeredOn anchor: NSPoint,
        ignoring presenterWindow: NSWindow?,
        onSelect: @escaping (RadialAction) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.presenterWindow = presenterWindow
        self.onSelect = onSelect
        self.onDismiss = onDismiss

        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: anchor,
            screenVisibleFrame: screen?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        )

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let container = RadialMenuBackdropView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        container.onEmptyClick = { [weak self] in self?.dismiss() }

        let panelCenter = NSPoint(x: frame.width / 2, y: frame.height / 2)
        for (action, offset) in zip(RadialAction.allCases, RadialMenuLayoutPolicy.buttonCenters()) {
            let button = RadialMenuButtonView(action: action) { [weak self] picked in
                self?.finish(with: picked)
            }
            button.setFrameOrigin(NSPoint(
                x: panelCenter.x + offset.x - button.frame.width / 2,
                y: panelCenter.y + offset.y - button.frame.height / 2
            ))
            container.addSubview(button)
            buttons.append(button)
        }
        panel.contentView = container
    }

    func show() {
        panel.orderFrontRegardless()
        animateButtonsIn()
        installDismissMonitors()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        removeDismissMonitors()
        panel.close()
    }

    private func dismiss() {
        guard !didClose else { return }
        close()
        onDismiss()
    }

    private func finish(with action: RadialAction) {
        guard !didClose else { return }
        close()
        onSelect(action)
    }

    private func animateButtonsIn() {
        guard let container = panel.contentView else { return }
        for button in buttons {
            let target = button.frame
            button.frame = NSRect(
                x: container.bounds.midX - target.width / 2,
                y: container.bounds.midY - target.height / 2,
                width: target.width,
                height: target.height
            )
            button.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                // Same springy overshoot as the bar's hover scale.
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.34, 1.45, 0.5, 1
                )
                button.animator().frame = target
                button.animator().alphaValue = 1
            }
        }
    }

    /// The panel is non-activating and never key, so Escape needs both a
    /// local monitor (Nugumi frontmost) and a global one (another app
    /// frontmost — observed, not consumed). Mouse clicks: the global monitor
    /// covers other apps, the local one covers Nugumi's own windows — except
    /// the menu itself and the presenting bar/pet, whose click handler owns
    /// the toggle.
    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        var monitors: [Any?] = []
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window !== self.panel,
                  event.window !== self.presenterWindow
            else { return event }
            Task { @MainActor [weak self] in self?.dismiss() }
            return event
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            Task { @MainActor [weak self] in self?.dismiss() }
            return nil
        })
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        dismissMonitors = monitors.compactMap { $0 }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
    }
}

/// Transparent backdrop behind the ring buttons. A click that lands on it —
/// rather than on a button — dismisses the menu.
private final class RadialMenuBackdropView: NSView {
    var onEmptyClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onEmptyClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEmptyClick?()
    }
}

/// One circular glass button on the ring: SF Symbol icon, hover tint, and a
/// small label that fades in under the circle on hover.
private final class RadialMenuButtonView: NSView {
    private let action: RadialAction
    private let onPick: (RadialAction) -> Void
    private let circleView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let labelField: NSTextField
    private var trackingArea: NSTrackingArea?

    init(action: RadialAction, onPick: @escaping (RadialAction) -> Void) {
        self.action = action
        self.onPick = onPick
        self.labelField = NSTextField(labelWithString: action.label)

        let diameter = RadialMenuLayoutPolicy.buttonDiameter
        let labelHeight: CGFloat = 16
        // Wider and taller than the circle so the hover label fits.
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: diameter + 28,
            height: diameter + labelHeight + 4
        ))
        wantsLayer = true

        circleView.material = .hudWindow
        circleView.state = .active
        circleView.blendingMode = .behindWindow
        circleView.wantsLayer = true
        circleView.layer?.cornerRadius = diameter / 2
        circleView.layer?.masksToBounds = true
        circleView.frame = NSRect(
            x: (bounds.width - diameter) / 2,
            y: labelHeight + 4,
            width: diameter,
            height: diameter
        )
        addSubview(circleView)

        iconView.image = NSImage(
            systemSymbolName: action.symbolName,
            accessibilityDescription: action.label
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        iconView.contentTintColor = .labelColor
        iconView.imageAlignment = .alignCenter
        iconView.frame = circleView.bounds
        iconView.autoresizingMask = [.width, .height]
        circleView.addSubview(iconView)

        labelField.font = .systemFont(ofSize: 11, weight: .medium)
        labelField.textColor = .labelColor
        labelField.alignment = .center
        labelField.sizeToFit()
        labelField.frame = NSRect(
            x: (bounds.width - labelField.frame.width) / 2,
            y: 0,
            width: labelField.frame.width,
            height: labelHeight
        )
        labelField.alphaValue = 0
        addSubview(labelField)

        toolTip = action.label
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    // Swallow mouseDown: unhandled it would bubble up the responder chain to
    // the backdrop, whose mouseDown dismisses the menu before mouseUp lands.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        onPick(action)
    }

    private func setHovered(_ hovered: Bool) {
        iconView.contentTintColor = hovered ? .nugumiAccent : .labelColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            labelField.animator().alphaValue = hovered ? 1 : 0
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`. The historical `.nugumiAccent` token is now
`.gizmateAccent`; its `NSColor` extension lives in
`Sources/Gizmate/App/Bootstrap.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add RadialActionMenuController ring UI with dismiss monitors"
```

---

### Task 3: Wire the floating bar to the menu, delete its gestures

**Files:**

- Modify: `Sources/Nugumi/App.swift` — `FloatingTranslateButtonController`, `FloatingTranslateButtonView.applyModeVisuals()`, and the three `FloatingTranslateButtonController(` callsites.

**Interfaces:**

- Consumes: `RadialActionMenuController` (Task 2).
- Produces: `FloatingTranslateButtonController.init` gains `onAsk: @escaping () -> Void` (after `onSmartReply`). Task 5 relies on all `TabKeyInterceptor` references in this class being gone.

- [ ] **Step 1: Rework `FloatingTranslateButtonController`**

Locate `final class FloatingTranslateButtonController {` (annotated `@MainActor`). Apply these changes:

1. Property changes — replace:

```swift
    private var currentMode: TranslationMode
    private var tabInterceptor: TabKeyInterceptor?
```

with:

```swift
    private let onAsk: () -> Void
    private var radialMenu: RadialActionMenuController?
```

2. Init — add the parameter after `onSmartReply` and store it; drop the `currentMode` assignment:

```swift
    init(
        screenPoint: NSPoint,
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void,
        onAsk: @escaping () -> Void
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.onAsk = onAsk
```

(`initialMode` stays a parameter — it still picks the button's glyph via `FloatingTranslateButtonView(initialMode:)`.)

3. Click wiring at the end of init — replace:

```swift
        buttonView.onClick = { [weak self] in
            guard let self else { return }
            self.invokeCurrentMode()
        }
        buttonView.onRightClick = { [weak self] in
            self?.invokeRewriteMode()
        }
```

with:

```swift
        buttonView.onClick = { [weak self] in
            self?.toggleRadialMenu()
        }
```

4. `show()` — delete the `TabKeyInterceptor` block, leaving:

```swift
    func show() {
        panel.orderFrontRegardless()
        buttonView.enableHoverScaling()
    }
```

5. `close()` — replace the tab lines with menu teardown:

```swift
    func close() {
        radialMenu?.close()
        radialMenu = nil
        panel.close()
    }
```

6. `setLoading()` — replace the tab lines with menu teardown:

```swift
    func setLoading() {
        panel.ignoresMouseEvents = true
        radialMenu?.close()
        radialMenu = nil
        buttonView.setLoading(true)
    }
```

7. Delete `toggleMode()`, `invokeCurrentMode()`, and `invokeRewriteMode()` entirely; add in their place:

```swift
    private func toggleRadialMenu() {
        if let radialMenu {
            radialMenu.close()
            self.radialMenu = nil
            return
        }
        let menu = RadialActionMenuController(
            centeredOn: buttonCenterInScreen(),
            ignoring: panel,
            onSelect: { [weak self] action in
                guard let self else { return }
                self.radialMenu = nil
                switch action {
                case .explain: self.onTranslate(self.selectedText)
                case .rewrite: self.onRewrite(self.selectedText)
                case .reply: self.onSmartReply(self.selectedText)
                case .ask: self.onAsk()
                }
            },
            onDismiss: { [weak self] in
                self?.radialMenu = nil
            }
        )
        radialMenu = menu
        menu.show()
    }

    private func buttonCenterInScreen() -> NSPoint {
        let frameInWindow = buttonView.convert(buttonView.bounds, to: nil)
        let screenRect = panel.convertToScreen(frameInWindow)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }
```

- [ ] **Step 2: Update the three callsites**

Search for `FloatingTranslateButtonController(` — exactly 3 construction sites:

1. In `showFloatingUI` (the one built from `let controller = FloatingTranslateButtonController(` with real handlers) — add after the `onSmartReply:` closure:

```swift
            onAsk: { [weak self] in
                self?.startAskNugumiPrompt()
            }
```

(`startAskNugumiPrompt()` already closes the floating bar itself and works in every display mode — no extra teardown here.)

2. In `showAskFloatingLoadingBar` (no-op handlers) — add `onAsk: {}` after `onSmartReply: { _ in }`.

3. In `showInstantTranslationLoading` (no-op handlers) — add `onAsk: {}` after `onSmartReply: { _ in }`.

- [ ] **Step 3: Replace the bar's gesture-teaching tooltips**

In `FloatingTranslateButtonView.applyModeVisuals()`, replace:

```swift
        switch currentMode {
        case .selection, .revise, .reviseMessage:
            actionButton.toolTip = "Translate selection - right-click to Rewrite, Tab to switch to Reply"
        case .draftMessage:
            actionButton.toolTip = "Rewrite my text - Tab to switch to Reply"
        case .smartReply:
            actionButton.toolTip = "Generate reply - Tab to switch back"
        }
```

with:

```swift
        actionButton.toolTip = "Choose an action"
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` — no unused-variable warnings for the removed members.

- [ ] **Step 5: Manual smoke test (floating bar)**

Run `swift run Nugumi` (background it). In the status-bar menu ensure display mode is "Floating bar". Select text in any app → bar appears → click it:

- Ring of 4 buttons (Explain top, Rewrite left, Reply right, Ask bottom) animates out around the bar.
- Click the bar again → ring closes.
- Reopen → click **Explain** → the normal result panel flow runs.
- Reopen on a new selection → **Ask** opens the Ask capsule.
- Reopen → press Escape → closes. Reopen → click far away in another app → closes.
  Kill the app when done. Report any deviation instead of "fixing" blind.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Open radial menu from floating bar click; drop right-click/Tab gestures"
```

---

### Task 4: Wire the pet to the menu, delete its gestures

**Files:**

- Modify: `Sources/Nugumi/App.swift` — `PetController` and the single `petController?.showReady(` callsite in `showFloatingUI`.

**Interfaces:**

- Consumes: `RadialActionMenuController` (Task 2).
- Produces: `PetController.showReady` gains `onAsk: @escaping () -> Void` (after `onSmartReply`). Task 5 relies on all `TabKeyInterceptor` references in this class being gone.

- [ ] **Step 1: Rework `PetController`**

1. Properties — replace `private var tabInterceptor: TabKeyInterceptor?` with:

```swift
    private var onAsk: (() -> Void)?
    private var radialMenu: RadialActionMenuController?
```

2. Click wiring (in init/setup, search `petView.onClick = `) — replace:

```swift
        petView.onClick = { [weak self] in
            guard let self else { return }
            if self.isPromptVisible || self.onPromptClose != nil {
                self.closePromptFromUser()
                return
            }
            self.invokeCurrentMode()
        }
        petView.onRightClick = { [weak self] in
            self?.invokeRewriteMode()
        }
```

with:

```swift
        petView.onClick = { [weak self] in
            guard let self else { return }
            if self.isPromptVisible || self.onPromptClose != nil {
                self.closePromptFromUser()
                return
            }
            self.toggleRadialMenu()
        }
```

3. `showReady` — new signature and body changes:

```swift
    func showReady(
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void,
        onAsk: @escaping () -> Void
    ) {
```

Inside, after `self.onSmartReply = onSmartReply` add `self.onAsk = onAsk`, and delete the `enableTabInterceptor()` line.

4. Everywhere the controller nils its ready callbacks (`onSmartReply = nil` — occurs in `showPrompt`, `holdReadyUntilPanelCloses`, `clearReady`, `showThinking`, and one more prompt-teardown path; find every occurrence), add `onAsk = nil` on the next line. (In `showPrompt` the existing lines use explicit `self.`; match the local style.)

5. Delete every `tabInterceptor?.disable()` / `tabInterceptor = nil` pair in the class, and delete the whole `enableTabInterceptor()` and `toggleMode()` methods.

6. In `clearReady()` and `showThinking()`, add menu teardown at the start of the mutation block (right after the guard in `clearReady`):

```swift
        radialMenu?.close()
        radialMenu = nil
```

Also add the same two lines to `close()` (the method that invalidates timers and closes both panels).

7. Replace `invokeCurrentMode()` and `invokeRewriteMode()` with:

```swift
    private func toggleRadialMenu() {
        if let radialMenu {
            radialMenu.close()
            self.radialMenu = nil
            return
        }
        // Same gate the old direct invocation had: the ring only makes sense
        // while a selection is armed.
        guard selectedText != nil, !isReadyLockedUntilPanelCloses else { return }
        let menu = RadialActionMenuController(
            centeredOn: petCenterInScreen(),
            ignoring: panel,
            onSelect: { [weak self] action in
                guard let self else { return }
                self.radialMenu = nil
                guard let selectedText = self.selectedText else { return }
                switch action {
                case .explain: self.onTranslate?(selectedText)
                case .rewrite: self.onRewrite?(selectedText)
                case .reply: self.onSmartReply?(selectedText)
                case .ask: self.onAsk?()
                }
            },
            onDismiss: { [weak self] in
                self?.radialMenu = nil
            }
        )
        radialMenu = menu
        menu.show()
    }

    private func petCenterInScreen() -> NSPoint {
        let frameInWindow = petView.convert(petView.bounds, to: nil)
        let screenRect = panel.convertToScreen(frameInWindow)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }
```

- [ ] **Step 2: Update the `showReady` callsite**

In `showFloatingUI`, the `petController?.showReady(` call — add after the `onSmartReply:` closure:

```swift
                onAsk: { [weak self] in
                    self?.startAskNugumiPrompt()
                }
```

- [ ] **Step 3: Replace the pet's gesture-teaching tooltip**

In `PetMascotView`'s `tooltip(for:mode:)`, the `.ready` case returns per-mode strings. Replace the inner mode switch:

```swift
            switch mode {
            case .selection, .revise, .reviseMessage:
                return "Translate selection - right-click to Rewrite, Tab to switch to Reply"
            case .draftMessage:
                return "Rewrite my text - Tab to switch to Reply"
            case .smartReply:
                return "Generate reply - Tab to switch back"
            }
```

with:

```swift
            return "Choose an action"
```

(If the compiler then flags the unused `mode` parameter in some paths, leave the signature alone — other cases may still use it; only the `.ready` body changes.)

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Manual smoke test (pet mode)**

Run `swift run Nugumi`, switch display mode to "Pet mode" in the status-bar menu. Select text → pet becomes ready → click it:

- Ring opens around the pet; each action fires its flow; Ask opens the pet prompt.
- Second click on the pet closes the ring.
- With the Ask prompt open, clicking the pet closes the prompt and does NOT open the ring.
- New selection while ring is open (`showReady` re-fires): ring state should stay sane — if the ring lingers stale, close it in `showReady` too (`radialMenu?.close(); radialMenu = nil` right after the guard) and note that in the commit.
  Kill the app when done.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Open radial menu from pet click; drop pet right-click/Tab gestures"
```

---

### Task 5: Delete the orphaned gesture machinery + full verification

**Files:**

- Modify: `Sources/Nugumi/App.swift`

**Interfaces:**

- Consumes: Tasks 3–4 having removed every wiring reference.
- Produces: no `TabKeyInterceptor`, no `onRightClick` anywhere in the codebase.

- [ ] **Step 1: Delete `TabKeyInterceptor`**

Run: `grep -n "TabKeyInterceptor" Sources/Nugumi/App.swift`
Expected: only the class definition (`final class TabKeyInterceptor {` … its closing brace, ~70 lines including `enable()`/`disable()`/CGEvent tap callback). If wiring references remain, Tasks 3–4 missed a spot — fix there first. Then delete the entire class.

- [ ] **Step 2: Delete the right-click plumbing**

Run: `grep -n "onRightClick\|RightClickableButton" Sources/Nugumi/App.swift`

Delete, in this order:

1. `PetMascotView`: the `var onRightClick: (() -> Void)?` property and the override that calls `onRightClick?()` (a `rightMouseUp`/`rightMouseDown` override — delete the whole override method).
2. `FloatingTranslateButtonView`: the `var onRightClick: (() -> Void)?` property and the `actionButton.onRightClick = { … }` wiring block in its setup.
3. `RightClickableButton`: the class subclasses `NSButton` only to surface right-clicks. Replace its single usage `private let actionButton = RightClickableButton()` with `private let actionButton = NSButton()`, then delete the class.

- [ ] **Step 3: Sweep for orphans**

Run: `grep -n "TabKeyInterceptor\|onRightClick\|RightClickableButton\|invokeCurrentMode\|invokeRewriteMode" Sources/Nugumi/App.swift`
Expected: no matches.

- [ ] **Step 4: Full build + test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build clean, all tests pass (including the Task 1 layout tests).

- [ ] **Step 5: Final manual pass (both surfaces)**

`swift run Nugumi`: repeat the Task 3 and Task 4 smoke checklists once each, plus:

- Drag-select near the right screen edge → ring stays fully on screen.
- Status-bar menu: "Main mode" item still present and still switches the shortcut behavior (out-of-scope machinery untouched).
  Kill the app when done.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Delete TabKeyInterceptor and right-click plumbing"
```
