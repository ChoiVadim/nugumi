# Main Window Core Refactor Design

## Goal

Make the remaining main-window infrastructure easier and safer to edit by
replacing the 1,191-line `Sources/Gizmate/MainWindow/MainWindow.swift`
catch-all with responsibility-focused files while preserving runtime behavior.

This is the second tranche of the maintainability refactor. It follows the same
pure code-motion pattern already proven by the `MainWindowSections.swift`
split.

## Current Problem

`MainWindow.swift` currently mixes eight different concerns:

- the visual theme and AppKit-to-SwiftUI bridges;
- settings read models and mutation intents;
- the host protocol implemented by the app;
- the observable settings bridge used by the SwiftUI tree;
- main-window navigation metadata;
- `NSWindow` and `NSWindowController` lifecycle;
- root layout and the draggable title-bar strip;
- sidebar navigation and reusable page components.

These concerns change for different reasons and have very different consumers.
Keeping them in one file forces a maintainer or coding agent to load unrelated
window lifecycle, settings, and UI primitive code for small edits.

## Chosen Approach

Perform pure code-motion extraction inside the existing `Gizmate` SwiftPM
target. Preserve every declaration name, access level, property, callback,
modifier, string, dimension, and declaration order inside its responsibility
group. Add only the imports each new compilation unit requires.

No APIs need to be redesigned and no private declaration crosses a new file
boundary: `WindowDragStrip` remains beside `MainWindowRootView`, and its nested
`DragStripView` remains private.

## Target File Layout

Create these files under `Sources/Gizmate/MainWindow/Core/`:

| File | Responsibility |
| --- | --- |
| `MainWindowTheme.swift` | `FlowTheme`, the `Font` helper, and AppKit-backed visual/scroller bridges |
| `SettingsContracts.swift` | `SettingsSnapshot`, `AppRef`, `SettingsIntent`, and `SettingsHost` |
| `GizmateSettingsBridge.swift` | observable state, bindings, and host forwarding for the main-window tree |
| `MainWindowNavigation.swift` | `EngineSetupFocus` and `MainWindowSection` metadata |
| `MainWindowController.swift` | `MainWindow` and `MainWindowController` lifecycle |
| `MainWindowRootView.swift` | root split layout, overlays, and `WindowDragStrip` |
| `MainWindowSidebar.swift` | `SidebarView` and `NavItem` |
| `MainWindowComponents.swift` | reusable cards, banners, pickers, rows, stat tiles, and activity heatmap |

After every declaration moves and the build succeeds, delete
`Sources/Gizmate/MainWindow/MainWindow.swift`. SwiftPM discovers the new files
recursively, so `Package.swift` remains unchanged.

All target files remain below roughly 400 lines. The largest,
`MainWindowComponents.swift`, is expected to be about 375 lines.

## Boundary Rules

1. Keep behavior, UI copy, modifiers, dimensions, ordering, bindings,
   callbacks, notification names, and state ownership unchanged.
2. Preserve app identity, persistence keys, model IDs, paths, and side-effect
   routing.
3. Do not rename types or redesign the settings bridge/host API.
4. Preserve every existing access level; no symbol should become public.
5. Add only required imports. Do not add dependencies or SwiftPM targets.
6. Do not combine code motion with warning cleanup, UI redesign, formatting
   churn, or feature work.
7. Stop at the first compilation failure and fix only a missing import or a
   boundary mistake caused by extraction.

## Extraction Sequence

1. Move theme helpers and settings contracts.
2. Move the observable bridge and navigation metadata.
3. Move the window controller, root view, and sidebar.
4. Move reusable components and delete the empty original file.

Run `swift build` and `git diff --check` after every group.

## Verification

Verification must include:

1. incremental `swift build` after each extraction group;
2. `swift test --filter MainWindowInputControlTests`;
3. `swift test --filter PaletteRuleTests`;
4. full `swift test`;
5. `git diff --check`;
6. a scope audit proving `Package.swift`, resources, and code outside
   `MainWindow.swift`/`MainWindow/Core/` are unchanged by this tranche;
7. a declaration audit proving every old top-level declaration still exists
   exactly once;
8. a file-size audit proving the old catch-all is gone and each replacement
   remains below roughly 400 lines.

This tranche changes source organization only. It does not alter TCC,
screen-capture, global-input, or persistence behavior, so packaged-app TCC
verification is not required.

## Completion Criteria

- `MainWindow.swift` no longer exists.
- Its declarations compile from eight focused files under `MainWindow/Core/`.
- No access-level expansion or runtime-logic change was introduced.
- The complete existing test suite has no new failures.
- The final diff is limited to documentation and behavior-preserving code
  organization.
