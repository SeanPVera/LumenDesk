# LumenDesk design system — Spectral Bench

This document specifies the native product system. `BRAND_IDENTITY.md` explains the strategy, logo, voice, and the audit that led here.

## Design principles

1. Chrome is achromatic; colour means light. Everything else follows from this.
2. Control first; power, brightness, rooms, and favorites stay fastest.
3. Show command truth near the control that caused it.
4. Draw the instrument. Where the platform's control would make the product look like every other app, LumenDesk supplies its own.
5. Put one primary decision in each region; secondary actions belong in menus or disclosure.
6. Reveal operational detail progressively.
7. Never confuse Preview with Apply.
8. Compose deliberately for macOS and iPhone; keep window, toolbar, and menu chrome native.
9. Pair every semantic colour with text, icon, shape, or accessible announcement.

## Token reference

### Neutrals — the bench

| Token | Value | Use |
| --- | --- | --- |
| `background/void` | `#04060A` | Window well, wells, key legends |
| `background/base` | `#080B11` | Window and application base |
| `background/subtle` | `#0A0D14` | Sidebar and grouped background |
| `surface/default` | `#0E1219` | Standard panels and rows |
| `surface/raised` | `#151A23` | Hover, sheet, and raised controls |
| `surface/emphasis` | `#1E2530` | Selected or important surfaces |
| `surface/hover` | `#262E3B` | Hover-only fill |
| `text/primary` | `#E8EEF7` | Headings and primary labels |
| `text/secondary` | `#9AA6B5` | Supporting text |
| `text/tertiary` | `#64707F` | Metadata and quiet labels |
| `border/default` | `#1F2732` | Hairlines and panels |
| `border/strong` | `#333D4B` | Focused grouping and elevated dividers |
| `edge/highlight` | `#FFFFFF` @ 5% | The lit top edge of a raised panel |

### Beam — illumination

| Token | Value | Use |
| --- | --- | --- |
| `beam/default` | `#DCE7F6` | Direct control and selection |
| `beam/bright` | `#F6FAFF` | Illuminated keys, focus ring, live values |
| `beam/dim` | `#8C99AB` | Unlit legends and inactive labels |

### The dispersion ramp

Every semantic colour in the product is one of these eight samples; nothing else is coloured.

| Token | Value | Semantic role |
| --- | --- | --- |
| `wave/400` | `#6C4BF0` | LIFX fixtures, mid-band energy |
| `wave/460` | `#3D7BF5` | Ramp continuity |
| `wave/490` | `#21C4DE` | `accent/network` — local connection and discovery |
| `wave/530` | `#46D08A` | `status/success` — online and confirmed |
| `wave/570` | `#D9D45F` | Ramp continuity |
| `wave/590` | `#FFB13D` | `status/warning` — stale, partial, paused |
| `wave/620` | `#FF7A38` | `accent/creative` — music and motion only |
| `wave/660` | `#F1495C` | `status/error` — failed commands |

`status/offline` is `#64707F`; `focus/ring` is `beam/bright`. Drawn whole as `Lumen.spectrum`, the ramp is the product's one ornament.

Lighting colours are data, not semantic tokens. They belong in previews, swatches, segment cells, and the `LumenLens` plate — never in status labels.

### Typography

There is no serif in the system. SF Pro Condensed carries titles and names, SF Mono carries labels and every measured value, and standard SF Pro carries body copy and controls.

| Style | Face | Size / line height | Use |
| --- | --- | --- | --- |
| `Display/Large` | SF Pro Condensed Bold | 38 / 42 | Page title, uppercase, tracked +1.4 |
| `Display/Title` | SF Pro Condensed Bold | 22 / 26 | Major section and sheet title |
| `Display/Small` | SF Pro Condensed Semibold | 15 / 20 | Card group title, device name |
| `Readout/Hero` | SF Mono Semibold | 50 / 54 | The master value on Home |
| `Readout/Value` | SF Mono Semibold | 12–17 | Percentages, kelvin, counts, timings |
| `Label/Instrument` | SF Mono Semibold | 9–11 | Engraved uppercase labels, tracked +1.2 |
| `Body/Medium` | SF Pro | 15 / 22 | Standard copy |
| `Body/Small` | SF Pro | 13 / 18 | Supporting copy |

### Dimensions

- Spacing: 4, 8, 12, 16, 20, 24, 32, 40.
- Radius: 5 (panel), 4 (tile), 3 (control), 2 (chip, swatch, badge). No pills.
- Chamfer: 14 pt on the top-trailing corner of every panel — the system's silhouette.
- Controls: 32 pt desktop default; 44 pt mobile minimum.
- Icons: 12, 14, 18 pt.
- Responsive breakpoints: mobile composition at 650 px; compact desktop intent at approximately 1000 px.
- Elevation: 1 px lit top edge plus a hairline for panels; short neutral shadow for modal, toast, menu, and bulk-action overlays.

### Focus, transparency, and motion

- Focus: 2 px beam-bright ring plus a 2 px base-colour offset.
- Reduced transparency: replace the bench rail and beam glow with opaque `background/void` or `surface/raised`.
- Quick transition: 160 ms; standard: 250 ms; expressive/slow: 600 ms.
- Reduced motion: remove drift, scale, parallax, and long crossfades; retain immediate opacity or state changes.
- Shadows: short neutral separation only. Device colour may create a restrained halo inside that device's control.

## Instrument controls

Defined in `LumenDesk/DesignControls.swift`. These are presentation only — every one is driven by a binding the existing views already own, and none of them talks to a device.

| Control | Replaces | Behaviour |
| --- | --- | --- |
| `LumenFader` | `Slider` | 20-division engraved scale (every fifth major), machined 5 × 20 cap, monospaced readout. Drag anywhere on the track to jump; arrow keys nudge on macOS; VoiceOver gets an adjustable action. `onEditingChanged` preserves commit-on-release. Tracks: `.beam`, `.spectrum`, `.kelvin`, `.tint(Color)` |
| `LumenPowerKeyStyle` | `.toggleStyle(.switch)` for light power | Illuminated key; `spokenLabel` supplies the VoiceOver label a `ToggleStyle` cannot read from its own configuration |
| `LumenRockerStyle` | `.toggleStyle(.switch)` elsewhere | Squared rocker; `showsLabel: false` for bare `Toggle("", isOn:)` rows |
| `LumenChipStyle` | `.toggleStyle(.button)` | Filter and day-of-week chips |
| `LumenSelector` | `.pickerStyle(.segmented)` | Recessed well, uppercase mono legends, spectrum underline on the live option |
| `LumenPrimary/SecondaryButtonStyle` | `.borderedProminent` / `.bordered` | Console keys; `compact: true` matches the old `.controlSize(.small)` footprint |
| `LumenDangerButtonStyle` | destructive buttons | Ramp red on a tinted face |
| `LumenIconButtonStyle` | bordered glyph buttons | Compact square key |
| `LumenLens` | coloured `Circle()` swatches | A fixture's lens plate, with catchlight, halo when lit, and a dashed edge when stale |
| `LumenMeter` | ad-hoc capsule bars | Segmented LED meter for watched values |
| `LumenReadout`, `LumenEyebrow`, `LumenStatusDot`, `LumenIconTile`, `SpectrumRule`, `LumenPanelShape` | — | The shared vocabulary the screens are built from |

Native toolbars, menus, alerts, confirmation dialogs, sheets, and `DatePicker` stay native.

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
- Power Key, Brightness Fader, Colour Swatch, White-Balance Fader (`.kelvin` track).
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
| Focused | Beam-bright ring with dark offset | Keyboard focus remains visible |
| Pressed | Small darkening or scale on non-reduced motion | Native pressed state |
| Selected | Strong border, checkmark, and “Selected” text | `aria-pressed`/selected trait |
| Expanded | Disclosure arrow and visible detail region | Expanded/collapsed state |
| Disabled | Reduced contrast plus explanatory label/help | Disabled state and reason |
| Loading/Scanning | Progress icon and phase text | Polite live announcement |
| Empty | Icon, reason, and recovery action | Heading summarizes state |
| Online | Green indicator square + “Online” | Text always present |
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
