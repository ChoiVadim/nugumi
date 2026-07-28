# Ring Remove Hover Design

## Goal

Keep each Ring slot visually clean by showing its remove control only while
that slot is hovered.

## Behavior

- A populated slot hides its remove control at rest.
- Hovering anywhere over the slot reveals the remove control.
- Moving the pointer from the slot disc onto the remove control keeps it visible.
- An empty slot never shows a remove control.
- Clicking the revealed control keeps the existing `onClear` behavior.
- Populated slots retain a pointer-independent accessibility remove action.
- Empty slots expose neither a visual control nor an accessibility remove action.
- Slot count, ordering, labels, geometry, and Ring persistence do not change.

## Implementation

`RingSlotButton` continues to own the hover state. The hover modifier moves to
the complete slot container so both the disc and remove button belong to one
hover region. A small pure visibility policy makes the three states directly
testable: resting populated, hovered populated, and hovered empty.

The remove button is conditionally rendered only when the policy returns true,
with a short opacity transition. This avoids a hidden button intercepting clicks.
The always-present primary slot button exposes the same `clearAction` as a named
accessibility action for populated slots, preserving keyboard and VoiceOver use.

## Verification

- Unit test the visibility policy with literal expected values.
- Run the focused test once before implementation to observe RED.
- Run the focused test and full Swift test suite after implementation.
- Run `swift build`.
- Open the Ring settings UI and verify the control is hidden at rest, appears on
  hover, stays visible while moving onto it, and clears only the selected slot.
- Inspect the live accessibility tree: populated slots expose `Remove … from
  Ring`, while empty slots do not.
