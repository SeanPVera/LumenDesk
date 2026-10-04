# LumenDesk design system — Spectrum Studio

Source of truth: `LumenDesk/Theme.swift` (`Lumen`, `LumenType`,
`LumenToken`), `LumenDesk/DesignControls.swift`, and `web/app/src/styles.css`.
Dark appearance is intentional; there is no separate supported light theme.

## Tokens

| Role | Native token | sRGB hex |
| --- | --- | --- |
| Canvas | stage | #17191C |
| Secondary surface | deck | #202328 |
| Control surface | floor | #24272C |
| Raised/selected surface | floorRaised | #30343B |
| Emphasis surface | stripLoud | #32373A |
| Quiet separator | ruleSoft | #303539 |
| Control boundary | rule | #50585D |
| Primary text | chalk | #EDF0F1 |
| Secondary text | meter | #BCC3C7 |
| Tertiary text | muted | #A0A9AE |
| Nonessential/inactive marks | faint | #778187 |
| Focus/illumination | lit | #F8FAFA |
| Selection | mark | #EDF0F1 |
| Studio actions / faders | studioAccent | #FFBC72 |
| Connection/success | link | #B8C8C5 |
| Warning | warn | #F0B03C |
| Error | fail | #E38A7C |

The browser retains its earlier palette. Browser equivalents are semantic CSS variables at `:root`; its canvas is #101112,
surface #17191B, raised #272B2E, rule #50585D, text #EDF0F1, secondary #BCC3C7,
muted #A0A9AE, warning #F0B03C and error #E38A7C. The browser uses 4 px corners for native HTML controls. Success, offline, warning and error also carry text/icons.
Old semantic aliases remain to avoid needlessly rewriting every secondary view.

## Type, dimensions and hierarchy

System fonts name rooms and fixtures. `LumenType` floors token-based text at 12 pt;
readouts use tabular digits rather than an all-monospace interface. Page headings
are 24 pt; primary workspace controls use standard body/callout/headline styles.
The browser body is 15 px, with rem-based secondary text and responsive headings.
Some legacy direct SwiftUI font calls remain outside the token floor; these are
not a claim of complete Dynamic Type coverage.

Spacing tokens: 4, 8, 12, 16, 20, 24, 32, 40 pt. Room margins are 24 pt, 16 in
compact space. Major two-column groups use 28–40 pt. Controls share a 6 pt radius;
legacy tiles use 8; output marks use small 2–4 pt corners. Native menus/fields
retain platform geometry. Use a separator to express a list or editing boundary,
not an ornamental frame around every group. Elevation comes from surface value.

Faders provide 44 pt interaction height, visible focus, numeric value, keyboard
nudging and accessibility adjustable actions. Disabled paths reject both pointer
and accessibility changes. Segment cells and paint targets are at least 44 pt
where newly implemented. Essential reordering has named Earlier/Later buttons;
room placement also has row/column/size steppers. No drag-only essential action.

## Product content

- Fixture marks derive hue and relative intensity from existing state. Text stays
  on opaque neutral ground. Offline retains identity and uses explicit words.
- Scenes use scores of saved snapshots, ordered consistently; Apply recalls saved
  fixture IDs, including IDs outside the current room. The UI states this.
- Palettes show contiguous relationships, with names and pressed state.
- Segments show boundaries, order numbers and selection checkmarks. Luna preserves
  its actual 26-zone geometry. Limited/held hardware keeps its existing warnings.
- Music previews show generated frames. Diagnostics distinguish submission,
  masking and queue state. No fake moving spectrum or ornamental beat animation.

## Focus, state and motion

Primary controls use native Button/Picker/TextField semantics. Web focus-visible
uses an explicit outline and offset. Native faders use a focus boundary. Selection
has text/checkmark/border in addition to color. Invalid room placements explain
that no layout changed; offline controls remain readable but unavailable.

Short state transitions only: root/fixture/setup changes use about 0.18 s and are
removed when accessibilityReduceMotion is enabled. No ambient canvas animation.
Music live rendering remains driven by the existing session; native reduced-motion
safety is forwarded to the controller. Browser CSS disables transitions and
animations under prefers-reduced-motion; Music blocks flashes and caps movement
at 20%, including preference changes during a session. This is not a medical
safety guarantee and brightness modulation still occurs.

## Adaptation and validation boundaries

macOS minimum window: 620 × 540 pt. The native sidebar can collapse; room lanes
and the room inspector stack below 850 pt of detail width. The Mac overview
uses device lanes; iOS keeps its adaptive fixture field. Segment Studio
splits canvas/tools at 820 pt, Luna at 800. Scroll preserves access at shorter
heights. Web reflows at 900/540 px, with captures down to 390 px.

Native screenshots are production SwiftUI hosted in AppKit on CI, not iOS
simulator screenshots. Browser axe checks supplement rendered review; VoiceOver,
Full Keyboard Access, larger accessibility text and physical touch remain manual
release checks. See REDESIGN_REPORT.md for exact inspected states and results.

## Spectrum workspace

Mac navigation uses a native split view with rooms, lights, Scenes, Music,
Schedules, Devices and Settings. Overview lanes expose actual Nanoleaf topology,
applied segment layouts and Luna's 26-zone face. Unknown applied layouts say so.
Device detail keeps the canvas, selection tools, exact-value rows and paint tools
together. Per-region HEX fields validate six digits; numeric intensity is clamped
to 0–100%. The table scrolls horizontally at narrow widths. None is an empty edit
target; room-level bulk controls retain their explicit whole-room default.

Secondary orientation, presets and gradients use disclosure controls. A running
show blocks entry to painting until it is stopped. Preview cleanup and Apply use
the existing manager/controller paths. Presentation drafts live in the shell,
separately from device output and saved scenes. See SPECTRUM_STUDIO.md.
