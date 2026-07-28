# Ring Remove Hover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a populated Ring slot's remove control only while that slot is hovered.

**Architecture:** Keep hover ownership inside `RingSlotButton` and derive remove-control visibility from two inputs: whether the slot is empty and whether the complete slot container is hovered. Preserve the existing clear callback and all Ring geometry.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager

## Global Constraints

- Preserve exactly eight Ring slots and their current positions.
- Do not change `RingLayout`, persistence, slot labels, or `onClear` behavior.
- A populated slot shows removal only while its complete slot container is hovered.
- An empty slot never shows removal.
- A populated slot exposes a named accessibility remove action at rest; an empty slot does not.
- Do not add dependencies.
- Preserve unrelated uncommitted work in the repository.

---

### Task 1: Hover-only Ring remove control

**Files:**
- Modify: `Sources/Nugumi/MainWindow/RingSection.swift:141-253`
- Test: `Tests/NugumiTests/RadialMenuLayoutTests.swift`

**Interfaces:**
- Consumes: `RingSlotButton.isEmpty`, its SwiftUI hover state, and the existing `clearAction: () -> Void`.
- Produces: `RingSlotControlVisibility.showsClearControl(isEmpty:isHovering:) -> Bool` for visual visibility and `showsClearAccessibilityAction(isEmpty:) -> Bool` for the pointer-independent remove action.

- [ ] **Step 1: Write the failing test**

```swift
func testRingRemoveControlAppearsOnlyForHoveredPopulatedSlot() {
    XCTAssertFalse(
        RingSlotControlVisibility.showsClearControl(
            isEmpty: false,
            isHovering: false
        )
    )
    XCTAssertTrue(
        RingSlotControlVisibility.showsClearControl(
            isEmpty: false,
            isHovering: true
        )
    )
    XCTAssertFalse(
        RingSlotControlVisibility.showsClearControl(
            isEmpty: true,
            isHovering: true
        )
    )
}

func testRingRemoveAccessibilityActionAppearsOnlyForPopulatedSlot() {
    XCTAssertTrue(
        RingSlotControlVisibility.showsClearAccessibilityAction(isEmpty: false)
    )
    XCTAssertFalse(
        RingSlotControlVisibility.showsClearAccessibilityAction(isEmpty: true)
    )
}
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
swift test --filter RadialMenuLayoutTests
```

Expected: compilation fails because `RingSlotControlVisibility` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Add beside `RingSlotButton`:

```swift
enum RingSlotControlVisibility {
    static func showsClearControl(isEmpty: Bool, isHovering: Bool) -> Bool {
        !isEmpty && isHovering
    }

    static func showsClearAccessibilityAction(isEmpty: Bool) -> Bool {
        !isEmpty
    }
}
```

Move `.onHover { hovering = $0 }` from the primary slot button to the outer
`ZStack`, and replace `if !isEmpty` with:

```swift
if RingSlotControlVisibility.showsClearControl(
    isEmpty: isEmpty,
    isHovering: hovering
) {
    // Existing clear button, unchanged.
}
```

Apply `.transition(.opacity)` to the existing clear button and animate only the
hover visibility state with a 0.12-second ease-out animation.

Apply a named `Remove <label> from Ring` accessibility action to the primary
button only when `showsClearAccessibilityAction(isEmpty:)` is true. It invokes
the same existing `clearAction`.

- [ ] **Step 4: Run the focused test to verify GREEN**

Run:

```bash
swift test --filter RadialMenuLayoutTests
```

Expected: all eight `RadialMenuLayoutTests` pass with zero failures.

- [ ] **Step 5: Verify the complete change**

Run:

```bash
swift test
swift build
```

Expected: both commands exit 0 with zero test failures and zero compiler errors.

Open Settings → Ring and confirm:

1. No slot remove controls are visible at rest.
2. Hovering a populated slot reveals only its remove control.
3. Moving onto the remove control keeps it visible.
4. Empty slots never show removal.
5. Clicking removal clears only that slot without moving the other seven positions.
6. Populated slots expose `Remove … from Ring` in the macOS accessibility tree;
   empty slots do not.

- [ ] **Step 6: Review the final diff**

Run:

```bash
git diff -- Sources/Nugumi/MainWindow/RingSection.swift Tests/NugumiTests/RadialMenuLayoutTests.swift
```

Expected: only the visibility policies, focused tests, hover scope, opacity
transition, and named accessibility action are added to the existing
uncommitted Ring changes.
