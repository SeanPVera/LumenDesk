# LumenDesk design system — Aurora Noir, refined

This document is the shared source of truth for the responsive prototype, the prepared Figma foundations, and the native SwiftUI implementation.

## Design principles

1. Control first; power, brightness, rooms, and favorites stay fastest.
2. Show command truth near the control that caused it.
3. Keep everyday surfaces calm and reserve expressive color for lighting previews and creative editing.
4. Put one primary decision in each region; secondary actions belong in menus or disclosure.
5. Reveal operational detail progressively.
6. Never confuse Preview with Apply.
7. Compose deliberately for macOS and iPhone.
8. Pair every semantic color with text, icon, shape, or accessible announcement.

## Token reference

### Semantic color

| Token | Value | Use |
| --- | --- | --- |
| `background/base` | `#090B12` | Window and application base |
| `background/subtle` | `#0D1019` | Sidebar and grouped background |
| `surface/default` | `#121722` | Standard cards and rows |
| `surface/raised` | `#181E2C` | Hover, sheet, and raised controls |
| `surface/emphasis` | `#20283A` | Selected or important surfaces |
| `surface/hover` | `#242D40` | Hover-only fill |
| `text/primary` | `#F5F7FB` | Headings and primary labels |
| `text/secondary` | `#AEB8C9` | Supporting text |
| `text/tertiary` | `#758096` | Metadata and quiet labels |
| `border/default` | `#2A3040` | Hairlines and cards |
| `border/strong` | `#3A4358` | Focused grouping and elevated dividers |
| `accent/primary` | `#8B7BFF` | Primary actions and selection |
| `accent/secondary` | `#45D8E8` | Local connection and links |
| `accent/expressive` | `#EE68CB` | Creative editing only |
| `accent/favorite` | `#F2B85B` | Favorites |
| `status/success` | `#45D5A4` | Online and confirmed |
| `status/warning` | `#F2B85B` | Stale, partial, and paused |
| `status/error` | `#FF657D` | Failed commands |
| `status/offline` | `#8992A6` | Offline/unreachable |
| `focus/ring` | `#65DDFF` | Keyboard focus ring |

Lighting colors are data, not semantic tokens. They belong in previews, swatches, segment cells, and restrained active-light indicators—not status labels.

### Typography

Primary family is SF Pro. `Display/Large` uses SF Pro Rounded Bold for the brand and a small number of creative headers. SF Mono is used only for compact metadata and values.

| Style | Size / line height | Use |
| --- | --- | --- |
| `Display/Large` | 48 / 54 | Cover and flagship creative title |
| `Title/Large` | 32 / 38 | Page title |
| `Title/Medium` | 24 / 30 | Major section |
| `Title/Small` | 18 / 23 | Card group and modal title |
| `Body/Large` | 17 / 25 | Introductory copy |
| `Body/Medium` | 15 / 22 | Standard copy |
| `Body/Small` | 13 / 18 | Supporting copy |
| `Label/Large` | 13 / 18 | Buttons and important labels |
| `Label/Medium` | 12 / 16 | Controls and badges |
| `Label/Small` | 10 / 14 | Metadata and eyebrows |

### Dimensions

- Spacing: 4, 8, 12, 16, 20, 24, 32, 40.
- Radius: 8, 12, 18, 24, full/pill.
- Controls: 32 pt desktop default; 44 pt mobile minimum.
- Icons: 16, 20, 24 pt.
- Responsive breakpoints: mobile composition at 650 px; compact desktop intent at approximately 1000 px.
- Elevation: `Elevation/Card` for restrained separation; `Elevation/Floating` for modal, toast, menu, and bulk-action overlays.

### Focus, transparency, and motion

- Focus: 2 px cyan ring plus a 2 px base-color offset.
- Reduced transparency: replace blur/translucency with opaque `background/subtle` or `surface/raised`.
- Quick transition: 160 ms; standard: 250 ms; expressive/slow: 600 ms.
- Reduced motion: remove drift, scale, parallax, and long crossfades; retain immediate opacity or state changes.

## Component inventory

### Chrome and navigation

- App Sidebar: default/hover/selected/attention; expanded and compact macOS variants.
- Top Toolbar: title, local connectivity, Scan, and menu-bar simulation.
- Mobile Tab Bar: Home, Library, Automation, Devices; selected/default states.
- Search Field, Filter Pill Group, Density Control, Scope Picker.

### Lighting control

- Global Control: aggregate power, average brightness, device reachability.
- Room Card: all-on, all-off, mixed, partial-offline, effect-running, automation-paused.
- Light Card/Row: comfortable/compact; selected; online/offline/stale; pending/applied/failed.
- Expanded Light Control: color/white mode, brightness, favorite, device truth, Segment Studio entry.
- Power Switch, Brightness Slider, Color Swatch, White Temperature Slider.
- Status Badge and Command State Indicator.

### Library and automation

- Favorite Tile; Scene Card; Theme Card; Effect Card.
- Running Effect Banner with Stop and Stop & Restore.
- Save Scene Sheet and Preview/Apply Dialog.
- Schedule Row, Day Selector, Solar Offset Control, Automation Pause Card, Missed Action Banner.

### Discovery, recovery, and settings

- Discovery Result, Scan Progress, Device Inspector, Desired-vs-Confirmed Table.
- Recovery Card, Toast, Undo Notification, Empty State.
- Setting Row, Demo Banner, Import/Export warning.
- Menu-bar Row and compact menu-bar scene tile.

### Segment Studio

- Segment Cell: default, hover, focused, selected, painted, dimmed.
- Segment Tool Group: All, None, Invert, Every Other, Shift Left/Right.
- Paint Control, Recent Swatch, Per-Segment Brightness, Gradient Control.
- Preset Card, Live Preview Indicator, Draft/Applied Footer, Apply Confirmation.

## State matrix

| State | Visual and semantic treatment | Accessible behavior |
| --- | --- | --- |
| Default | Base surface and label | Normal name/role/value |
| Hover | Raised surface or stronger border | No state announced |
| Focused | Cyan ring with dark offset | Keyboard focus remains visible |
| Pressed | Small darkening or scale on non-reduced motion | Native pressed state |
| Selected | Strong border, checkmark, and “Selected” text | `aria-pressed`/selected trait |
| Expanded | Disclosure arrow and visible detail region | Expanded/collapsed state |
| Disabled | Reduced contrast plus explanatory label/help | Disabled state and reason |
| Loading/Scanning | Progress icon and phase text | Polite live announcement |
| Empty | Icon, reason, and recovery action | Heading summarizes state |
| Online | Green dot + “Online” | Text always present |
| Offline | Slashed icon + “Offline” + recovery | Retry and Rescan available |
| Stale | Clock icon + “Stale” + last seen | Warn that control may still work |
| Pending/Queued | Clock and “Queued” | Announces command queued |
| Sending | Up-arrow/progress and “Sending” | Announces target device |
| Applied | Check icon + “Applied locally” | Clarifies device has not confirmed |
| Confirmed | Check icon + “Confirmed by device” | Announces final success |
| Failed | Error icon + “Failed” | Retry is adjacent and labeled |
| Retrying | Progress icon + “Retrying” | Announces retry attempt |
| Partially successful | Warning + count, e.g. “3 of 4 applied” | Names unresolved devices on disclosure |
| Favorite | Gold star plus “Favorite” | Selected/favorite trait |
| Effect running | Motion icon + effect name + scope | Stop action always available |
| Automation paused | Pause icon + pause-until description | Distinct from disabled schedule |
| Demo Mode | Persistent “No devices controlled” banner | Controls remain enabled and useful |

## Principal frame inventory

The implemented prototype represents these 16 principal high-fidelity states:

1. First-run Welcome/Privacy.
2. Preparation/Discovery progress.
3. Discovery results/Naming/Room assignment.
4. macOS Home, comfortable/populated.
5. macOS Home, compact/partial-offline.
6. macOS Home, bulk selection.
7. iPhone Home.
8. Room detail with partial power/offline.
9. Expanded light control.
10. Library overview and type differentiation.
11. Save Scene and detail/Preview/Apply.
12. Effect running.
13. Automation list/editor/pause/missed state.
14. Devices diagnostics/recovery.
15. Segment Studio initial/painted/gradient/live-preview/applied.
16. Menu-bar controller and Settings/Demo Mode.

## Connected prototype flows

### Setup

Welcome → Privacy → Prepare → Discovery → Review/Naming → Organize → Ready → Home.

### Everyday control and scene creation

Home → Room or Light → power/brightness/color → Sending → Applied locally → Confirmed → Library → Save Current Lighting → name/favorite → Favorites.

### Segment Studio

Home → Govee light → Segment Studio → select/paint/brightness/gradient → Live Preview (volatile) → Cancel or Apply confirmation → durable layout → Light detail.

## Accessibility notes

- Body text targets 4.5:1 contrast; large text and meaningful non-text UI target 3:1.
- Native ranges, buttons, switches, checkboxes, selects, and text fields are used in the prototype.
- Status never relies on hue alone.
- Mobile targets are at least 44 × 44 CSS pixels where controls are primary.
- Command and discovery transitions use polite live regions.
- Segment cells expose numbered labels and selected state.
- No real network, lighting, microphone, account, or vendor action is performed.
