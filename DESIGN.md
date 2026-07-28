# Gizmate Design System

## 1. Atmosphere & Identity

Gizmate should feel like a quiet Mac-native command surface: compact, glassy, and direct. The signature is dark liquid glass around a restrained near-black settings shell, with a single Gizmate green accent used only for progress, success, and primary action.

## 2. Color

### Palette

| Role | Token | Light | Dark | Usage |
|------|-------|-------|------|-------|
| Surface/glass | `FlowTheme.glass` | transparent | transparent | Visual-effect-backed window background |
| Surface/card | `FlowTheme.card` | rgba(255,255,255,0.06) | rgba(255,255,255,0.06) | Settings panels and setup cards |
| Surface/subtle | `FlowTheme.subtleFill` | rgba(255,255,255,0.08) | rgba(255,255,255,0.08) | Secondary fills and inactive controls |
| Text/primary | `FlowTheme.ink` | #FFFFFF | #FFFFFF | Headings, body, active controls |
| Text/secondary | `FlowTheme.inkSecondary` | #BDBDBD | #BDBDBD | Supporting copy and secondary labels |
| Text/tertiary | `FlowTheme.inkTertiary` | #8C8C8C | #8C8C8C | Disabled, metadata, inactive icons |
| Border/hairline | `FlowTheme.hairline` | rgba(255,255,255,0.10) | rgba(255,255,255,0.10) | Dividers and quiet outlines |
| Accent/primary | `FlowTheme.accent` / `NSColor.nugumiAccent` | #11766E | #11766E | Success, selected state, primary setup progress |
| Accent/soft | `FlowTheme.accentSoft` | rgba(17,118,110,0.22) | rgba(17,118,110,0.22) | Soft selected backgrounds |
| Status/error | inline status error | #FF8C8C | #FF8C8C | Failed setup status only |

### Rules

- Keep Gizmate green functional, not decorative.
- Prefer white opacity tokens over extra gray constants for panels and dividers.
- New semantic colors must be added here before use.

## 3. Typography

### Scale

| Level | Size | Weight | Line Height | Tracking | Usage |
|-------|------|--------|-------------|----------|-------|
| Display | 30px | regular | system | 0 | Main section headings via `FlowTheme.serif(30)` |
| H2 | 29px | regular | system | 0 | Onboarding panel headings |
| Card title | 15px | semibold | system | 0 | Settings cards and provider groups |
| Row title | 14px | medium | system | 0 | Setup rows and model rows |
| Body | 13px | regular/medium | system | 0 | Controls, compact explanatory text |
| Caption | 12px | regular | system | 0 | Secondary copy and status detail |
| Micro | 11px | semibold | system | 0 | Monospaced section labels and progress markers |

### Font Stack

- Primary: Apple system sans via `.system`.
- Serif: Apple system serif through `FlowTheme.serif`.
- Display wordmark: bundled Pixelify through `Font.nugumiPixel`.

### Rules

- Main-window copy stays compact; do not use hero-scale type inside settings cards.
- Use medium and semibold for hierarchy instead of larger sizes.
- Letter spacing remains `0` unless an existing monospaced label already defines it.

## 4. Spacing & Layout

### Base Unit

All spacing maps to the 4px grid.

| Token | Value | Usage |
|-------|-------|-------|
| `space-1` | 4px | Tight label stacks |
| `space-2` | 8px | Icon-to-label, row gaps |
| `space-3` | 12px | Standard row spacing |
| `space-4` | 16px | Setup card internal stacks |
| `space-5` | 20px | Card padding variant |
| `space-6` | 24px | Provider group spacing |
| `space-8` | 32px | Major panel separation |

### Grid

- Main window uses a fixed sidebar plus flexible detail panel.
- Cards are un-nested `SubCard` panels with constrained text and stable row heights.
- Setup rows use glyph, text stack, spacer, then compact secondary buttons.

### Rules

- Do not add a card inside another card unless the existing component already owns the frame.
- Preserve arbitrary-window resizing; no text may clip at narrow widths.
- Setup and provider rows should not shift layout when status text changes.

## 5. Components

### `SubCard`

- **Structure**: One framed panel with vertical content.
- **Variants**: Default padding, compact padding, fill-height.
- **Spacing**: 16-24px internal rhythm.
- **States**: Static container only.
- **Accessibility**: Contains real buttons and labels; no fake interactive badges.
- **Motion**: None.

### `SecondaryButton`

- **Structure**: Compact SwiftUI button with rounded rectangle surface.
- **Variants**: Normal and destructive.
- **Spacing**: Minimum width only where repeated rows need alignment.
- **States**: Hover/press handled by platform button behavior and existing style.
- **Accessibility**: Visible text labels only.
- **Motion**: None.

### `SetupStepRow`

- **Structure**: Status glyph, title/status copy, flexible spacer, optional secondary and primary actions.
- **Variants**: Unknown, checking, ok, needs action, working, failed.
- **Spacing**: 12px horizontal gap, 2px text gap.
- **States**: Status copy appears only when meaningful; action buttons hide when terminal OK.
- **Accessibility**: Status is textual as well as visual.
- **Motion**: Progress spinner only for checking/working.

## 6. Motion & Interaction

### Timing

| Type | Duration | Easing | Usage |
|------|----------|--------|-------|
| Platform | system | system | Native buttons, menus, focus |
| Micro | 100-150ms | ease-out | Hover treatments already present in onboarding cards |
| Standard | 200-300ms | ease-in-out | Tab and panel transitions if added later |

### Rules

- Prefer native AppKit/SwiftUI interaction behavior.
- Do not animate layout properties.
- Progress should use `ProgressView` for long-running setup work.

## 7. Depth & Surface

### Strategy

Mixed, but constrained: real `NSVisualEffectView` glass at the window layer, translucent tonal card fills inside it, and one-pixel hairlines for structure.

| Level | Value | Usage |
|-------|-------|-------|
| Window glass | `NSVisualEffectView.Material.hudWindow` | Main shell/background |
| Card tonal fill | white opacity 0.06 | Settings panels |
| Hairline | white opacity 0.10 | Separators and outlines |

### Rules

- Do not introduce generic drop shadows.
- Use tonal fills and hairlines for hierarchy.
- Keep card radius aligned with existing component radius unless changing a whole component family.
