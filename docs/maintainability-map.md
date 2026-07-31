# Maintainability Map

This map explains the current source boundaries and which large files should
not be split mechanically. Use it before moving declarations or widening
access only to reduce line count.

## Current ownership seams

| Area | Edit here |
| --- | --- |
| Main window shell | `Sources/Gizmate/MainWindow/Core/` |
| Main window feature sections | `Sources/Gizmate/MainWindow/Sections/` |
| App entry and lifecycle | `Sources/Gizmate/App/GizmateApp.swift` |
| App preferences and updates | `Sources/Gizmate/App/GizmateApp+Preferences.swift`, `Sources/Gizmate/App/GizmateApp+Updates.swift` |
| Global shortcuts | `Sources/Gizmate/App/Shortcuts/` |
| Onboarding | `Sources/Gizmate/App/Onboarding/` |
| Live translation pipeline | `Sources/Gizmate/Live/` |
| Tool-agent coordinator | `Sources/Gizmate/App/ToolAgentLiveBuilder.swift` |
| Tool-agent runtime/validation support | `Sources/Gizmate/App/ToolAgentRuntimeLocation.swift`, `Sources/Gizmate/App/ToolAgentFixtureHistory.swift`, `Sources/Gizmate/App/ToolAgentHostCandidateValidator.swift`, `Sources/Gizmate/App/ToolAgentModelActionValidation.swift` |
| Tool-agent protocol foundations | `Sources/GizmateToolAgentCore/ToolAgentProtocolTypes.swift` |
| Tool-agent candidate models | `Sources/GizmateToolAgentCore/ToolAgentModels.swift` |
| Tool-agent request/fingerprint contracts | `Sources/GizmateToolAgentCore/ToolAgentContracts.swift` |
| Ring geometry | `Sources/Gizmate/Ring/RadialMenuLayoutPolicy.swift` |
| Ring interaction state | `Sources/Gizmate/Ring/RadialMenuController.swift` |
| Ask response parsing | `Sources/Gizmate/Ask/AskGizmateResponse.swift` |
| Ask conversation and prompts | `Sources/Gizmate/Ask/AskGizmateConversation.swift` |
| Ask layout geometry | `Sources/Gizmate/Ask/AskGizmateLayout.swift` |

## Intentionally stateful large owners

These files are large, but their current private-state boundaries are more
valuable than a cross-file extension split.

| File | Lines | Why it stays together | Requirement before a meaningful split |
| --- | ---: | --- | --- |
| `Sources/Gizmate/Pet/PetController.swift` | 1,537 | One controller owns panel, prompt, animation, and interaction state; private helper types are direct collaborators. | Introduce tested controller collaborators and verify the packaged pet/Ring UI. |
| `Sources/Gizmate/MainWindow/ToolEditor.swift` | 1,466 | The 1,289-line editor panel is one state-heavy SwiftUI view with private nested state and actions. | Define editor submodels/components with focused state-transition tests. |
| `Sources/Gizmate/Panels/TranslationContentView.swift` | 1,391 | Nearly the whole file is one stateful content view/controller surface. | Extract explicit rendering or interaction collaborators instead of widening private members. |
| `Sources/Gizmate/Live/LiveCaptionPanelController.swift` | 895 | Delegate callbacks depend on private follow-up controls and submission behavior. | Add controller interaction coverage, then extract a cohesive collaborator. |
| `Sources/Gizmate/Pet/PetMascotView.swift` | 741 | Drawing and animation state form one view implementation. | Separate a tested animation/render model before moving methods. |
| `Sources/Gizmate/App/Onboarding/OnboardingViews.swift` | 919 | This is already the coherent view cluster after model/support/controller extraction. | Split only when a view becomes an independently owned feature. |

Large `GizmateApp+*.swift` files are already domain extensions. Do not split
them solely by line count.

## Next safe declaration-level candidates

If another source-only refactor is needed, prefer these seams:

1. `Sources/Gizmate/App/UsageStats.swift`: models, store, and menu UI are
   separate top-level clusters. The snapshot/model cluster has focused tests;
   store and menu extraction also require manual menu verification.
2. `Sources/Gizmate/Panels/TranslationModes.swift`: composition styles, Gen Z
   style, and app classification can move as complete declarations.
3. `Sources/Gizmate/Selection/SelectionReading.swift`: clipboard
   reader/poster/snapshot/writer helpers can move together, but require manual
   selection, paste, and clipboard-restoration verification because direct
   coverage is limited.

## Refactor standard

For behavior-preserving source splits:

1. Move complete declarations byte-identically.
2. Do not widen `private` or `fileprivate` only to cross a file boundary.
3. Keep stored state with its owner.
4. Compare the moved block and the original-file residual mechanically.
5. Run focused tests, `swift build`, full `swift test`, and
   `git diff --check`.
6. Request an independent read-only review.

As of 2026-07-31, the verified full-suite baseline is 415 executed tests,
2 expected skips, and 0 failures.
