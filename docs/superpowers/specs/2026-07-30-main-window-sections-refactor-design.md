# Main Window Sections Refactor Design

## Goal

Make Gizmate easier and safer to edit by replacing the 2,585-line
`Sources/Gizmate/MainWindow/MainWindowSections.swift` catch-all with small,
responsibility-focused files while preserving the app's behavior exactly.

This is the first tranche of a broader maintainability refactor. It establishes
the extraction pattern and verification standard that later tranches can apply
to `LiveTranslation.swift`, `Onboarding.swift`, `PetController.swift`, and
`ToolEditor.swift`.

## Current Problem

`MainWindowSections.swift` contains unrelated settings surfaces and shared
components in one compilation unit:

- detail routing and shared field/button components;
- home history and usage summaries;
- insights charts;
- writing voice, language, and style editors;
- AI provider/model setup and model selection;
- shortcuts, general settings, and user profile settings;
- dictionary and snippet editing;
- help and support actions.

The file is difficult to navigate, expensive to hold in context, and easy to
edit incorrectly because a small change exposes an agent or maintainer to
thousands of unrelated lines. It also violates the repository rule that files
should own one subsystem and normally remain under roughly 400 lines.

## Chosen Approach

Perform pure code-motion extraction inside the existing `Gizmate` SwiftPM
target. Split the file by product surface, keeping related private helpers next
to the section that owns them. Preserve existing type names and access levels
unless a private symbol must become internal because its only consumer moves to
another file.

This approach is preferred over package modularization or dependency injection
changes because it gives an immediate navigation and context-size improvement
without mixing architecture changes with behavior changes.

## Target File Layout

Create `Sources/Gizmate/MainWindow/Sections/` with these files:

| File | Responsibility |
| --- | --- |
| `DetailRouter.swift` | `DetailRouter` and top-level section routing |
| `SharedSectionControls.swift` | controls reused by multiple sections, including `MenuFieldLabel`, `ReadOnlyField`, `KeyCap`, `SecondaryButton`, `FlowTabBar`, and `RowIconButton` |
| `HomeSection.swift` | home activity, history grouping, and history rows |
| `InsightsSection.swift` | usage breakdowns, palette logic, and donut charts |
| `VoiceSection.swift` | voice section routing plus built-in and custom writing-style cards |
| `VoiceEditors.swift` | custom instructions, text-editor bridge, chat samples, app icons, and wrapping layout |
| `LanguageSettings.swift` | reading and writing language controls |
| `AIEngineSection.swift` | AI engine section routing, provider groups, and model scope cards |
| `ModelPicker.swift` | model availability/grouping logic and the model picker overlay |
| `ProviderSetup.swift` | provider rows, Ollama setup, setup status, and AI engine status copy |
| `SettingsSection.swift` | shortcuts, general preferences, and About You settings |
| `LibrarySection.swift` | dictionary/snippet list, display rows, and inline editor |
| `HelpSection.swift` | help, support, reset, update, and quit rows |

After extraction, delete `MainWindowSections.swift`. SwiftPM discovers the new
files recursively, so `Package.swift` must not change.

The boundaries intentionally keep each new file below roughly 400 lines. If
formatting or required imports push a file beyond that guideline, split the
largest self-contained helper group again instead of recreating a smaller
catch-all.

## Boundary Rules

1. Keep UI copy, modifiers, dimensions, ordering, bindings, callbacks, and
   environment-object access unchanged.
2. Keep all persistence keys, model IDs, application identity, bundle
   identifiers, paths, and notification names unchanged.
3. Do not rename product types or redesign APIs during code motion.
4. Keep helpers private when all of their consumers remain in one new file.
5. Promote a helper from private to internal only when it is genuinely shared
   across extracted files. Do not make symbols public.
6. Do not create a new SwiftPM target or add dependencies.
7. Do not combine this refactor with UI cleanup, formatting churn, or feature
   work.

## Extraction Sequence

Extract one independently compilable section group at a time:

1. router and shared controls;
2. Home and Insights;
3. Voice, voice editors, and language settings;
4. AI Engine, model picker, and provider setup;
5. Settings, Library, and Help;
6. remove the empty original file.

Run `swift build` after every group. This makes the first failing extraction
small enough to diagnose directly and prevents a large code-motion batch from
hiding access-control mistakes.

## Verification

The baseline before refactoring is 405 passing tests with one skipped test.

Verification must include:

1. `swift build` after every extraction group;
2. `swift test --filter ModelGroupingTests`;
3. `swift test --filter OllamaSetupTests`;
4. `swift test --filter PaletteRuleTests`;
5. full `swift test`;
6. `git diff --check`;
7. a final diff audit confirming that the old file's code was moved, not
   behaviorally rewritten;
8. a source-size audit showing that the catch-all file is gone and each new
   file has one coherent responsibility.

Because this tranche is pure source organization, it does not alter TCC,
screen-capture, global-input, or animation behavior. A packaged-app TCC pass is
therefore not required for this tranche. A quick `swift run Gizmate` smoke
launch is useful if the resulting environment permits it, but it is not a
substitute for the build and test gates.

## Failure Handling

If a build fails after extraction:

- stop the sequence at that group;
- fix only missing imports, access levels, or ownership boundaries caused by
  the move;
- rerun the build before extracting another group.

If resolving a failure requires changing runtime logic, revert that extraction
design and choose a different file boundary. Behavior changes are outside this
tranche.

## Non-Goals

- redesigning the settings UI;
- changing model/provider behavior;
- changing persistence or app identity;
- moving code into new SwiftPM modules;
- refactoring Live Translation, onboarding, the pet, or tool building in the
  same code-motion batch;
- increasing test coverage for unrelated behavior.

## Completion Criteria

This tranche is complete only when:

- `MainWindowSections.swift` no longer exists;
- all settings surfaces compile from focused files under
  `MainWindow/Sections/`;
- the full existing test suite passes with no new failures;
- the working diff contains only the design/plan artifacts and
  behavior-preserving source organization;
- the resulting layout is documented clearly enough that a future editor can
  locate a settings feature without searching a multi-thousand-line file.

After completion, inspect the next large files and choose the next tranche by
maintainability value and behavioral risk rather than automatically splitting
every large file.
