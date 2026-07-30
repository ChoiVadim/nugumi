# Main Window Sections Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MainWindowSections.swift` with small, responsibility-focused files so settings code is easier and safer to locate and edit without changing runtime behavior.

**Architecture:** Keep every declaration in the existing `Gizmate` SwiftPM target and perform pure code motion by product surface. Shared view primitives move to one shared file; feature-specific private helpers stay beside their owning section; only declarations used across new files are promoted from `private` to internal.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, Swift Package Manager, XCTest

## Global Constraints

- Deployment target remains macOS 14.
- `Package.swift`, dependencies, bundle identity, persistence keys, model IDs, paths, notification names, UI copy, modifiers, dimensions, ordering, bindings, and callbacks must not change.
- No new SwiftPM targets or dependencies.
- No UI redesign, formatting sweep, feature work, or runtime-logic rewrite.
- Each new source file must own one coherent responsibility and remain below roughly 400 lines.
- Run `swift build` after every extraction task and stop immediately on a code-motion failure.
- The pre-refactor baseline is 405 passing tests with one skipped test.

---

## File Structure

Create these files under `Sources/Gizmate/MainWindow/Sections/`:

- `DetailRouter.swift`: section-to-view routing only.
- `SharedSectionControls.swift`: view primitives shared across settings and editor surfaces.
- `HomeSection.swift`: activity history and home usage summary.
- `InsightsSection.swift`: usage breakdowns and donut chart rendering.
- `VoiceSection.swift`: Voice tab composition and cleanup preview.
- `VoiceStyleCards.swift`: writing-style cards and text-editing bridges.
- `VoiceAppAssignments.swift`: app assignment icons and email voice sample.
- `LanguageSettings.swift`: reading/writing language controls.
- `AIEngineSection.swift`: AI Engine tab composition and model scope cards.
- `ModelPicker.swift`: model grouping, availability, and picker overlay.
- `ProviderSetup.swift`: provider authentication and Ollama setup cards.
- `SettingsSection.swift`: general settings, shortcuts, and About You.
- `LibrarySection.swift`: dictionary/snippet list and inline editing.
- `HelpSection.swift`: setup, support, reset, update, and quit actions.

Delete `Sources/Gizmate/MainWindow/MainWindowSections.swift` only after every
declaration has moved and the build succeeds.

---

### Task 1: Extract Routing and Shared Controls

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/DetailRouter.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/SharedSectionControls.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindowSections.swift:1-98`
- Modify: `Sources/Gizmate/MainWindow/MainWindowSections.swift:1254-1286`
- Modify: `Sources/Gizmate/MainWindow/MainWindowSections.swift:2412-2434`

**Interfaces:**

- Consumes: `MainWindowSection`, `RingSection`, `FlowTheme`
- Produces: `DetailRouter`, `MenuFieldLabel`, `ReadOnlyField`, `KeyCap`, `SecondaryButton`, `FlowTabBar`, and `RowIconButton`

- [ ] **Step 1: Capture the clean baseline**

Run:

```bash
git status --short --branch
swift test
```

Expected: the branch is clean; 405 tests pass and one test is skipped.

- [ ] **Step 2: Create `DetailRouter.swift`**

Use:

```swift
import SwiftUI

// Move `DetailRouter` from MainWindowSections.swift unchanged.
```

The moved declaration must retain the exact switch ordering:
`home`, `insights`, `ring`, `voice`, `library`, `aiEngine`, `settings`, `help`.

- [ ] **Step 3: Create `SharedSectionControls.swift`**

Use:

```swift
import SwiftUI

// Move the complete declarations for MenuFieldLabel, ReadOnlyField, KeyCap,
// SecondaryButton, FlowTabBar, and RowIconButton into this file unchanged.
```

Apply only these access-control changes because consumers now live in different
files:

```diff
-private struct MenuFieldLabel: View {
+struct MenuFieldLabel: View {

-private struct ReadOnlyField: View {
+struct ReadOnlyField: View {

-private struct KeyCap: View {
+struct KeyCap: View {

-private struct FlowTabBar: View {
+struct FlowTabBar: View {
```

`SecondaryButton` and `RowIconButton` are already internal and remain
unchanged.

- [ ] **Step 4: Remove the moved declarations from the original file**

Use one `apply_patch` update that removes only the complete declaration blocks
listed above. Keep the imports and all feature sections in place.

- [ ] **Step 5: Verify the extraction**

Run:

```bash
swift build
git diff --check
```

Expected: build succeeds and the diff has no whitespace errors.

- [ ] **Step 6: Commit the independently compiling extraction**

```bash
git add Sources/Gizmate/MainWindow/MainWindowSections.swift \
  Sources/Gizmate/MainWindow/Sections/DetailRouter.swift \
  Sources/Gizmate/MainWindow/Sections/SharedSectionControls.swift
git commit -m "Split main window routing and shared controls"
```

---

### Task 2: Extract Home and Insights

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/HomeSection.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/InsightsSection.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindowSections.swift:99-498`

**Interfaces:**

- Consumes: `GizmateSettingsBridge`, `UsageStatsSnapshot`, `TranslationHistoryEntry`, `FlowTheme`
- Produces: `HomeSection`, `InsightsSection`

- [ ] **Step 1: Create `HomeSection.swift`**

Use:

```swift
import AppKit
import SwiftUI

// Move HomeSection, HomeContent, and HistoryRow unchanged.
```

Keep `HomeContent` and `HistoryRow` private. Include the existing history
grouping, day-title logic, clipboard copy action, and empty-state rendering in
the move.

- [ ] **Step 2: Create `InsightsSection.swift`**

Use:

```swift
import SwiftUI

// Move InsightsSection, InsightsContent, BreakdownPalette, and DonutChart
// unchanged.
```

Keep `InsightsContent`, `BreakdownPalette`, and `DonutChart` private.

- [ ] **Step 3: Remove the moved declarations from the original file**

Remove the complete Home and Insights blocks, including their section markers,
without reformatting the surrounding Voice code.

- [ ] **Step 4: Verify the extraction**

Run:

```bash
swift build
git diff --check
```

Expected: build succeeds and no source behavior has changed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Gizmate/MainWindow/MainWindowSections.swift \
  Sources/Gizmate/MainWindow/Sections/HomeSection.swift \
  Sources/Gizmate/MainWindow/Sections/InsightsSection.swift
git commit -m "Split home and insights settings sections"
```

---

### Task 3: Extract Voice and Language Settings

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/VoiceSection.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/VoiceStyleCards.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/VoiceAppAssignments.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/LanguageSettings.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindowSections.swift:499-1183`

**Interfaces:**

- Consumes: `GizmateSettingsBridge`, `CleanupLevel`, `AppCategory`, `WritingStyle`, `AppRef`, `TranslationLanguage`
- Produces: `VoiceSection`, `StyleCard`, `CustomStyleCard`, `AppIconStrip`, `EmailVoiceSampleEditor`, `LanguagesTab`

- [ ] **Step 1: Create `VoiceSection.swift`**

Use:

```swift
import SwiftUI

// Move VoiceSection, StyleTab, the CleanupLevel private extension, and
// CleanupExample unchanged.
```

Keep `StyleTab`, the `CleanupLevel` extension, and `CleanupExample` private.

- [ ] **Step 2: Create `VoiceStyleCards.swift`**

Use:

```swift
import AppKit
import SwiftUI

// Move StyleCard, CustomStyleCard, CustomInstructionEditor, PlainTextEditor,
// and ChatBubble unchanged.
```

Apply only these cross-file access changes:

```diff
-private struct StyleCard: View {
+struct StyleCard: View {

-private struct CustomStyleCard: View {
+struct CustomStyleCard: View {

-private struct PlainTextEditor: NSViewRepresentable {
+struct PlainTextEditor: NSViewRepresentable {
```

Keep `CustomInstructionEditor` and `ChatBubble` private. `PlainTextEditor` is
internal because `EmailVoiceSampleEditor` and `AboutYouTab` consume it from
other files.

- [ ] **Step 3: Create `VoiceAppAssignments.swift`**

Use:

```swift
import AppKit
import SwiftUI

// Move AppIconStrip, AppIconBubble, CircleDisc, AppIconProvider,
// EmailVoiceSampleEditor, and FlowWrap unchanged.
```

Apply only these cross-file access changes:

```diff
-private struct AppIconStrip: View {
+struct AppIconStrip: View {

-private struct EmailVoiceSampleEditor: View {
+struct EmailVoiceSampleEditor: View {
```

Keep `AppIconBubble`, `CircleDisc`, and `FlowWrap` private.
`AppIconProvider` remains internal exactly as it is today.

- [ ] **Step 4: Create `LanguageSettings.swift`**

Use:

```swift
import SwiftUI

// Move LanguagesTab and LanguageMenu unchanged.
```

Apply this cross-file access change:

```diff
-private struct LanguagesTab: View {
+struct LanguagesTab: View {
```

Keep `LanguageMenu` private.

- [ ] **Step 5: Remove the moved Voice and Languages declarations**

Remove the complete blocks from the original file. Do not alter any string,
binding, preview sample, language ordering, or persistence intent.

- [ ] **Step 6: Verify the extraction**

Run:

```bash
swift build
git diff --check
```

Expected: build succeeds. If a private-access error appears, promote only the
specific declaration named by the compiler and document why it crosses files.

- [ ] **Step 7: Commit**

```bash
git add Sources/Gizmate/MainWindow/MainWindowSections.swift \
  Sources/Gizmate/MainWindow/Sections/VoiceSection.swift \
  Sources/Gizmate/MainWindow/Sections/VoiceStyleCards.swift \
  Sources/Gizmate/MainWindow/Sections/VoiceAppAssignments.swift \
  Sources/Gizmate/MainWindow/Sections/LanguageSettings.swift
git commit -m "Split voice and language settings sections"
```

---

### Task 4: Extract AI Engine, Model Picker, and Provider Setup

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/AIEngineSection.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/ModelPicker.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/ProviderSetup.swift`
- Modify: `Sources/Gizmate/MainWindow/MainWindowSections.swift:1184-2023`
- Test: `Tests/GizmateTests/ModelGroupingTests.swift`
- Test: `Tests/GizmateTests/OllamaSetupTests.swift`

**Interfaces:**

- Consumes: `GizmateSettingsBridge`, `EngineSetupFocus`, `CloudProvider`, `ModelUseScope`, `LLMModel`, `BootstrapState`
- Produces: `AIEngineSection`, `ModelPickerOverlay`, `ModelAvailability`, `ModelGrouping`, `AIEngineStatusCopy`

- [ ] **Step 1: Create `AIEngineSection.swift`**

Use:

```swift
import SwiftUI

// Move AIEngineSection, ProviderGroupCard, and ModelScopeCard unchanged.
```

Keep `ProviderGroupCard` and `ModelScopeCard` private.

- [ ] **Step 2: Create `ModelPicker.swift`**

Use:

```swift
import SwiftUI

// Move ModelTriggerLabel, modelSourceLabel, modelIsUsable,
// ModelAvailability, ModelGrouping, ModelPickerOverlay, and ModelPickerPanel
// unchanged.
```

Keep `ModelTriggerLabel`, `modelSourceLabel`, `modelIsUsable`, and
`ModelPickerPanel` private. Preserve the internal access of
`ModelAvailability`, `ModelGrouping`, and `ModelPickerOverlay` because tests and
the main window consume them.

- [ ] **Step 3: Create `ProviderSetup.swift`**

Use:

```swift
import SwiftUI

// Move AIEngineStatusCopy, InlineInfoRow, ProviderRow, OllamaSetupCard,
// OllamaCloudSetupCard, StepButton, SetupStatusGlyph, setupStatusMessage, and
// SetupStepRow unchanged.
```

Apply only these cross-file access changes:

```diff
-private struct InlineInfoRow: View {
+struct InlineInfoRow: View {

-private struct ProviderRow: View {
+struct ProviderRow: View {

-private struct OllamaSetupCard: View {
+struct OllamaSetupCard: View {

-private struct OllamaCloudSetupCard: View {
+struct OllamaCloudSetupCard: View {
```

Keep `StepButton`, `SetupStatusGlyph`, `setupStatusMessage`, and `SetupStepRow`
private. `AIEngineStatusCopy` remains internal.

- [ ] **Step 4: Remove the moved AI Engine declarations**

Remove the complete AI Engine, model picker, and provider setup blocks from the
original file. `FlowTabBar` must already be absent because Task 1 owns it.

- [ ] **Step 5: Verify compilation and focused behavior**

Run:

```bash
swift build
swift test --filter ModelGroupingTests
swift test --filter OllamaSetupTests
git diff --check
```

Expected: build succeeds and both focused suites pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Gizmate/MainWindow/MainWindowSections.swift \
  Sources/Gizmate/MainWindow/Sections/AIEngineSection.swift \
  Sources/Gizmate/MainWindow/Sections/ModelPicker.swift \
  Sources/Gizmate/MainWindow/Sections/ProviderSetup.swift
git commit -m "Split AI engine settings sections"
```

---

### Task 5: Extract Settings, Library, and Help

**Files:**

- Create: `Sources/Gizmate/MainWindow/Sections/SettingsSection.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/LibrarySection.swift`
- Create: `Sources/Gizmate/MainWindow/Sections/HelpSection.swift`
- Delete: `Sources/Gizmate/MainWindow/MainWindowSections.swift`
- Test: `Tests/GizmateTests/PaletteRuleTests.swift`

**Interfaces:**

- Consumes: `GizmateSettingsBridge`, `GlobalShortcutAction`, `ShortcutGroup`, `SnippetKind`, `SnippetsStore`, `Snippet`
- Produces: `SettingsSection`, `AboutYouTab`, `LibrarySection`, `HelpSection`

- [ ] **Step 1: Create `SettingsSection.swift`**

Use:

```swift
import SwiftUI

// Move SettingsSection, ShortcutsTab, GeneralTab, AboutYouTab, and its local
// hint-row implementation unchanged.
```

Apply this cross-file access change because `VoiceSection` renders the tab:

```diff
-private struct AboutYouTab: View {
+struct AboutYouTab: View {
```

Keep `ShortcutsTab` and `GeneralTab` private.

- [ ] **Step 2: Create `LibrarySection.swift`**

Use:

```swift
import SwiftUI

// Move LibrarySection, SnippetsListContent, SnippetDisplayRow, and
// SnippetEditorRow unchanged.
```

`RowIconButton` must not be duplicated here; it comes from
`SharedSectionControls.swift`.

- [ ] **Step 3: Create `HelpSection.swift`**

Use:

```swift
import SwiftUI

// Move HelpSection and HelpRow unchanged.
```

Keep `HelpRow` private.

- [ ] **Step 4: Delete the exhausted original file**

Confirm it contains no remaining declarations, then delete:

```text
Sources/Gizmate/MainWindow/MainWindowSections.swift
```

- [ ] **Step 5: Verify compilation and the focused palette contract**

Run:

```bash
swift build
swift test --filter PaletteRuleTests
git diff --check
```

Expected: build and focused tests pass; SwiftPM discovers every new file without
a `Package.swift` change.

- [ ] **Step 6: Commit**

```bash
git add Sources/Gizmate/MainWindow/Sections \
  Sources/Gizmate/MainWindow/MainWindowSections.swift
git commit -m "Finish main window sections split"
```

---

### Task 6: Verify Behavior Preservation and Maintainability

**Files:**

- Modify only if verification exposes an extraction error:
  `Sources/Gizmate/MainWindow/Sections/*.swift`
- Inspect: `docs/superpowers/specs/2026-07-30-main-window-sections-refactor-design.md`

**Interfaces:**

- Consumes: all extracted section files
- Produces: a verified, behavior-preserving source layout with no catch-all file

- [ ] **Step 1: Run the complete suite**

Run:

```bash
swift test
```

Expected: 405 tests pass, one test is skipped, and there are no unexpected
failures.

- [ ] **Step 2: Audit source size and ownership**

Run:

```bash
test ! -e Sources/Gizmate/MainWindow/MainWindowSections.swift
wc -l Sources/Gizmate/MainWindow/Sections/*.swift
rg -n '^(struct|enum|final class|class|protocol) ' \
  Sources/Gizmate/MainWindow/Sections
```

Expected: the original file is absent, every new file is below roughly 400
lines, and every top-level declaration appears in the planned owner file.

- [ ] **Step 3: Audit for accidental scope expansion**

Run:

```bash
git diff 5a7d7ae..HEAD -- Package.swift Resources Sources/Gizmate \
  ':!Sources/Gizmate/MainWindow/MainWindowSections.swift' \
  ':!Sources/Gizmate/MainWindow/Sections'
git diff --check 5a7d7ae..HEAD
git status --short
```

Expected: no output for unrelated production paths, no whitespace errors, and
no uncommitted source changes.

- [ ] **Step 4: Review the code-motion diff**

Run:

```bash
git diff --stat 5a7d7ae..HEAD
git diff --find-renames=20% 5a7d7ae..HEAD -- \
  Sources/Gizmate/MainWindow/MainWindowSections.swift \
  Sources/Gizmate/MainWindow/Sections
```

Expected: additions in the new section files correspond to removal of the old
catch-all; intentional semantic differences are limited to imports and the
documented `private`-to-internal promotions.

- [ ] **Step 5: Run a non-blocking app smoke launch when practical**

Run:

```bash
swift run Gizmate
```

Expected: the app reaches its normal menu-bar runtime without an immediate
startup crash. Stop the foreground process after observing successful launch.
This is not a TCC verification gate.

- [ ] **Step 6: Record the verified tranche**

If verification required no source correction, no extra commit is needed. If
an extraction-only correction was necessary:

```bash
git add Sources/Gizmate/MainWindow/Sections
git commit -m "Fix main window section extraction"
```

The next maintainability tranche starts only after this plan's completion
criteria are proven.
