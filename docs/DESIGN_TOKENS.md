# Design Tokens

The single source of truth for these tokens is
`ios/BatteryHolder/DesignSystem/Theme.swift`. This document mirrors them so
designers and reviewers can reason about the system without reading Swift. Token
names map 1:1 to the Swift API (e.g. `Theme.color.brand`, `Theme.spacing.md`).

The system is **semantic** (roles, not raw values) and **adaptive** (every color
has a light and dark value resolved at runtime via a dynamic `UIColor`).

## Color

### Brand & accent

| Token | Role | Light | Dark |
|---|---|---|---|
| `brand` | Primary actions, active states | `#0A84FF` | `#0A84FF` |
| `brandPressed` | Pressed primary | `#0060DF` | `#409CFF` |
| `accent` | Energy / positive emphasis | `#30D158` | `#30D158` |

### Battery status (semantic scale)

| Token | Meaning | Light | Dark |
|---|---|---|---|
| `batteryGood` | ≥ 60% | `#30D158` | `#32D74B` |
| `batteryMedium` | 25–60% | `#FF9F0A` | `#FFB340` |
| `batteryLow` | 10–25% | `#FF9500` | `#FF9F0A` |
| `batteryCritical` | < 10% | `#FF453B` | `#FF6961` |

### Feedback

| Token | Light | Dark |
|---|---|---|
| `success` | `#248A3D` | `#30D158` |
| `warning` | `#B25000` | `#FF9F0A` |
| `danger`  | `#D70015` | `#FF453B` |

### Surfaces & text

| Token | Role | Light | Dark |
|---|---|---|---|
| `background` | App background | `#F2F2F7` | `#000000` |
| `surface` | Cards, sheets | `#FFFFFF` | `#1C1C1E` |
| `surfaceElevated` | Raised cards | `#FFFFFF` | `#2C2C2E` |
| `border` | Hairlines, dividers | `#E5E5EA` | `#38383A` |
| `textPrimary` | Titles, values | `#1C1C1E` | `#FFFFFF` |
| `textSecondary` | Labels, captions | `#6C6C70` | `#98989F` |
| `textOnBrand` | Text on brand fill | `#FFFFFF` | `#FFFFFF` |

## Typography

System font (SF Pro), Dynamic Type friendly. Tokens map to `Theme.font.*`.

| Token | Size / Weight | Usage |
|---|---|---|
| `largeTitle` | 34 / Bold | Screen hero (voltage readout) |
| `title` | 22 / Semibold | Section titles |
| `headline` | 17 / Semibold | Card titles, list rows |
| `body` | 17 / Regular | Body copy |
| `callout` | 16 / Regular | Secondary body |
| `subheadline` | 15 / Regular | Supporting text |
| `footnote` | 13 / Regular | Captions |
| `caption` | 12 / Regular | Pin labels, timestamps |
| `mono` | 17 / Regular, monospaced | ADC counts, voltages, GPIO ids |

## Spacing

4‑pt base grid. Tokens map to `Theme.spacing.*` (CGFloat).

| Token | Value |
|---|---|
| `xxs` | 2 |
| `xs` | 4 |
| `sm` | 8 |
| `md` | 12 |
| `lg` | 16 |
| `xl` | 24 |
| `xxl` | 32 |
| `xxxl` | 48 |

## Radius

| Token | Value | Usage |
|---|---|---|
| `sm` | 8 | Chips, small controls |
| `md` | 12 | Buttons, inputs |
| `lg` | 16 | Cards |
| `xl` | 24 | Sheets, hero panels |
| `pill` | 999 | Pills, toggles |

## Elevation

Soft, single‑layer shadows tuned for light mode; dark mode relies on surface
lightness instead of shadow.

| Token | Y offset | Blur | Opacity (light) |
|---|---|---|---|
| `none` | 0 | 0 | 0 |
| `card` | 2 | 8 | 0.08 |
| `raised` | 6 | 16 | 0.12 |
| `overlay` | 12 | 32 | 0.18 |

## Motion

| Token | Curve | Duration |
|---|---|---|
| `quick` | easeOut | 0.15s |
| `standard` | spring(response: 0.35, damping: 0.85) | ~0.35s |
| `emphasis` | spring(response: 0.5, damping: 0.7) | ~0.5s |

## Usage rules

1. **Never hard‑code hex in views.** Reference `Theme.color.*` only.
2. **Battery colors are computed** from percentage via
   `Theme.color.battery(forPercentage:)` so the whole app maps status → color
   identically.
3. **Spacing multiples only.** Layout uses `Theme.spacing.*`, not literal
   numbers, to keep the 4‑pt rhythm.
4. **Contrast.** Text/background pairs meet WCAG AA (≥ 4.5:1) in both themes.
