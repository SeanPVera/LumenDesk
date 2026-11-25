# Polar Instrument — source-to-code map

The approved LumenDesk redesign (macOS only). Design references are the
Superdesign artboards; screenshots of the key ones live in
`docs/redesign/polar/`.

## Tokens

| Design token | Code |
|---|---|
| stage `#070B14` | `Polar.stage`, `Color.polarStage`, `Lumen.canvas` |
| desk `#0F1624` | `Polar.desk`, `Lumen.floor` |
| raised `#182234` | `Polar.raised` |
| chalk `#EEF3FB` | `Polar.chalk`, `Lumen.graphite` |
| meter `#A3B6CE` | `Polar.meter`, `Lumen.meter` |
| accent `#4F8CFF` | `Polar.accent`, `Lumen.ember`, AccentColor asset |
| mint `#2EE6A6` | `Polar.mint`, `Lumen.verdigris` (Confirmed) |
| pending / changed / attention | `Polar.pending` / `.changed` / `.attention` |
| SF Pro Rounded display | `Font.polarDisplay`, `LumenType.display` |
| SF Pro Text UI | `Font.polarUI`, `LumenType.body` |
| SF Mono numerics | `Font.polarMono`, `LumenType.readout` |
| 4-pt spacing | `PolarSpacing` |

`Theme.swift` keeps the existing `Lumen`/`LumenType` names (≈400 call
sites) and rebinds them onto Polar values, so every older screen re-skins
without being rewritten. New code should use `Polar`/`Font.polar*`.

## Components (`LumenDesk/Design/PolarComponents.swift`)

`GlowingOrb` (fixture silhouette + level-driven glow), `InstrumentSlider`,
`InstrumentDial`, `SegmentStrip`, `polarPanel()`, `PolarSectionLabel`,
`PolarStatusPill`, `PolarButtonStyle`, `PolarHexagon`.

## Light pages

`LightPageModel.resolve` picks a page by exact model code / LIFX product ID:

| Owned fixture | Match | Page controls | Transport |
|---|---|---|---|
| LIFX Luna | pid 219 | 26-zone matrix paint | wired (LIFX matrix) |
| LIFX Color 800 / 800 lm / A19 / Mini | pid 129 / 91 / 93 / 181 | orb, white-point dial, swatches, colour well | wired |
| Nanoleaf Shapes Hexagons | model NL42 | Shapes studio (paint, scenes, effects) | wired |
| Govee Curtain | H70B1 | 20-column hero + column painter | wired (stream hold) |
| Govee String Light | H70BC | same, curtain family | wired; model flagged as matched by elimination |
| Govee COB strip | H61E6 | blended bar + 15-zone painter | wired |
| Govee Light Bars | H6062 | 28-zone chain + painter | wired; painting writes segments, but the chain arrangement is set by hand because Govee doesn't report it |
| Govee Uplighter | H60B0 | 3 named lamps, 2-lit limit | wired (stream hold) |
| Govee String pods | H608B | 15 pods on a wire + painter | wired; per-pod white (RGB-mixed stream, Kelvin segment packet on durable apply) |
| Govee Strip Light S | H612B | 75 segments in rows of 15, labels every 5th | wired (stream hold) |

Anything else falls back to the pre-redesign editor routing.

`LightPageFeatureFlags` has been retired. Where a control the LAN protocol
genuinely can't drive would otherwise appear, the page instead carries a
factual note explaining the hardware limit rather than a dashed "Coming later"
placeholder — e.g. the curtain paints by column because single beads are
reachable only over Bluetooth, which LumenDesk doesn't use. Glide chain
geometry and per-pod Kelvin, once gated behind those flags, are now wired.

## Commands

From the "App menus" artboard: File ▸ New Look ⇧⌘N, Add Lights ⌘N;
View ▸ rooms ⌘1–⌘9, Looks ⌘L, Live ⇧⌘L; Lights ▸ All Off ⇧⌘O, All On,
Identify Selected ⌘I, Open Light Page ⌘↩, Refresh Network ⌘R, Cancel Queued
⌘.; Edit ▸ Undo/Redo ⌘Z/⇧⌘Z. Window-scoped commands travel on
`LumenCommandBus` to `RoomCanvasShellView`.
