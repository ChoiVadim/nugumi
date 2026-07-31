# Main Window Core Refactor Implementation Plan

**Status:** Implemented and verified. Checkboxes below preserve the original
pre-implementation contract; they are not a live progress tracker.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task by task.

**Goal:** Replace `MainWindow.swift` with small, responsibility-focused files
so theme, settings, lifecycle, navigation, and reusable UI code can be edited
independently without changing behavior.

**Architecture:** Keep every declaration in the existing `Gizmate` SwiftPM
target and perform pure code motion along the file's existing `MARK` sections.
Preserve access levels because every private helper remains beside its sole
consumer.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, Combine, Swift Package
Manager, XCTest

## Global Constraints

- Deployment target remains macOS 14.
- `Package.swift`, dependencies, bundle identity, persistence keys, model IDs,
  paths, notification names, UI copy, modifiers, dimensions, ordering,
  bindings, and callbacks must not change.
- No new SwiftPM targets or dependencies.
- No UI redesign, formatting sweep, warning cleanup, feature work, or runtime
  rewrite.
- Each new file owns one coherent responsibility and remains below roughly 400
  lines.
- Run `swift build` and `git diff --check` after each extraction task.

---

### Task 1: Extract Theme and Settings Contracts

**Files:**

- Create: `Sources/Gizmate/MainWindow/Core/MainWindowTheme.swift`
- Create: `Sources/Gizmate/MainWindow/Core/SettingsContracts.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindow.swift:1-276`

**Interfaces:**

- Theme produces `FlowTheme`, `Font.gizmatePixel`,
  `ScrollerConfigurator`, and `VisualEffectBackground`.
- Contracts produce `SettingsSnapshot`, `AppRef`, `SettingsIntent`, and
  `SettingsHost`.

- [ ] Move the complete Theme block to `MainWindowTheme.swift` with
  `import AppKit` and `import SwiftUI`.
- [ ] Move the settings snapshot, intent, and host blocks to
  `SettingsContracts.swift` with `import GizmateToolAgentCore`.
- [ ] Preserve every declaration and access level unchanged.
- [ ] Remove only the moved blocks from the original file.
- [ ] Run:

```bash
swift build
git diff --check
```

- [ ] Commit with `Split main window theme and settings contracts`.

---

### Task 2: Extract the Bridge and Navigation

**Files:**

- Create: `Sources/Gizmate/MainWindow/Core/GizmateSettingsBridge.swift`
- Create: `Sources/Gizmate/MainWindow/Core/MainWindowNavigation.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindow.swift:277-522`

**Interfaces:**

- Bridge consumes `SettingsHost` and exposes the existing observable state,
  bindings, and forwarding methods.
- Navigation produces `EngineSetupFocus` and `MainWindowSection`.

- [ ] Move `GizmateSettingsBridge` unchanged with `Combine`, `Foundation`,
  `GizmateToolAgentCore`, and `SwiftUI` imports.
- [ ] Move the two navigation enums unchanged.
- [ ] Remove only the moved blocks from the original file.
- [ ] Run:

```bash
swift build
git diff --check
```

- [ ] Commit with `Split settings bridge and main window navigation`.

---

### Task 3: Extract Window Lifecycle and Composition

**Files:**

- Create: `Sources/Gizmate/MainWindow/Core/MainWindowController.swift`
- Create: `Sources/Gizmate/MainWindow/Core/MainWindowRootView.swift`
- Create: `Sources/Gizmate/MainWindow/Core/MainWindowSidebar.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindow.swift:523-818`

**Interfaces:**

- Controller owns `MainWindow` and `MainWindowController`.
- Root owns `MainWindowRootView` and private `WindowDragStrip`.
- Sidebar owns `SidebarView` and `NavItem`.

- [ ] Move the complete window block with `AppKit` and `SwiftUI` imports.
- [ ] Move the complete root block with `AppKit` and `SwiftUI` imports.
- [ ] Move the complete sidebar block with `AppKit` and `SwiftUI` imports.
- [ ] Keep `WindowDragStrip` and its nested `DragStripView` private.
- [ ] Remove only the moved blocks from the original file.
- [ ] Run:

```bash
swift build
git diff --check
```

- [ ] Commit with `Split main window lifecycle and composition`.

---

### Task 4: Extract Shared Components and Remove the Catch-All

**Files:**

- Create: `Sources/Gizmate/MainWindow/Core/MainWindowComponents.swift`
- Delete: `Sources/Gizmate/MainWindow/MainWindow.swift`

**Interfaces:**

- Produces `DetailCard`, `DetailContainer`, `SubCard`, `PageBanner`,
  `PillPicker`, `StatTile`, `SettingRow`, and `ActivityHeatmap`.

- [ ] Move the complete reusable-building-blocks section with
  `import SwiftUI`.
- [ ] Delete the now-empty original file.
- [ ] Run:

```bash
swift build
swift test --filter MainWindowInputControlTests
swift test --filter PaletteRuleTests
git diff --check
```

- [ ] Confirm every file under `MainWindow/Core/` remains below roughly 400
  lines.
- [ ] Commit with `Finish main window core split`.

---

### Task 5: Final Verification

- [ ] Run the full suite:

```bash
swift test
```

Expected: 405 tests execute with no failures; environment-dependent tests may
remain skipped as in the current baseline.

- [ ] Confirm the old file is gone:

```bash
test ! -e Sources/Gizmate/MainWindow/MainWindow.swift
```

- [ ] Audit source sizes and declarations:

```bash
wc -l Sources/Gizmate/MainWindow/Core/*.swift
rg -n '^(private )?(struct|enum|final class|class|protocol|extension) ' \
  Sources/Gizmate/MainWindow/Core/*.swift
```

- [ ] Confirm this tranche did not alter files outside its documented scope:

```bash
git diff --exit-code <tranche-base>..HEAD -- \
  Package.swift Resources Sources/Gizmate \
  ':!Sources/Gizmate/MainWindow/MainWindow.swift' \
  ':!Sources/Gizmate/MainWindow/Core'
```

- [ ] Run `git diff --check` and verify `git status --short`.
- [ ] Request an independent code review before presenting or merging.
