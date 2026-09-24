# LumenDesk redesign discovery — 2026-09-24

Baseline: main at 3ceeec29d88a9193be5c3402779a376a27b07e59. Repository tree has CLAUDE.md and no AGENTS.md.
The workspace exec-server failed to initialize; only connector reads/writes and GitHub Actions are available. No local shell, Xcode, simulator, or physical lighting devices are available.

## Actual product
- Native: one SwiftUI target, macOS 13+ and iOS 16+. Dark appearance. RootView selects onboarding or LumenDeskShellView. Native menus, settings scene, menu-bar controller.
- Browser: production React/TypeScript/Vite client and local Node bridge. Separate design-prototype is a mockup, not production and not evidence of native rendering.
- Actual shell is Plan / Looks / Cues / Rig / Settings, with a 58-point icon rail on Mac and tabs on iOS. CLAUDE/brand/design/handoff prose still describes older Home/Library and Spectral Bench versions. Source takes precedence.
- PlanWorkspaceView draws every room in a six-column faux architectural board, hard-codes Ground floor / 1:50, and supplies a narrow per-room inspector. Color/white/segments require a full-controls sheet. iOS opens that sheet when a room is tapped.
- Looks contains scenes/themes/effects/Music Mode with an independently owned scope. Scene snapshots target saved device IDs; a room picker must never silently retarget a scene.
- Room, LightScope, LightDevice, LightingScene/DeviceSnapshot, FixtureTopology and MusicModeConfiguration remain canonical. LightManager is the single MainActor ObservableObject. Views may hold selection, draft and navigation state, never shadow domain state.
- Room.lightIDs is ordered; fixtureAnchors and planFrame already persist/export within Room. Music topology is a separate ordering with roles/exclusions, not a floor plan. The two have different meanings.
- LIFX whole-color and Luna matrix output; Govee whole-color and SKU-specific RGBIC segments. Unknown hardware is not proof of segment support. H60B0 has two lit zones of three. Segment previews are volatile; Apply persists/holds layouts. Draft storage on close is distinct from emitted output.
- Power/brightness/color/kelvin routes through existing manager methods, undo, coordinator and transports. Effects own non-overlapping device sets and restoration snapshots. Manual controls must not fight an active show.
- Music uses existing source, analyzer, session controller, choreography and renderer. Roles/order, permission/no-audio, confidence, safe-mode, reduced-motion and restoration are essential. Do not fork DSP.
- Setup: onboarding, RoomSetupView, scans/inbox/diagnostics; no-device and unsorted-device states. DemoWorkspaceController isolates live state; import/export schema remains 2.
- Existing accessibility includes labels, adjustable faders, role text, segment selection buttons, native dialogs. Risks: tiny fixed typography/targets, unlabeled reorder glyphs, faders that do not guard disabled adjustable actions, non-adaptive horizontal groups, always-on animations.
- CI: macOS xcodebuild test and generic iOS build; git diff --check, theme audit, plist/asset checks; web npm ci/build and bridge npm test. No UI test target or screenshot gate. Physical validation absent.
- Open independent PRs: #104 Nanoleaf and #105 Music repairs. This branch starts on main and must not claim those repairs are included.

## Design thesis: light in place
LumenDesk looks like a field of named emitters because its content is physical light. The selected room is a continuous, neutral, dark surface; a fixture carries its own color and intensity within its output mark. Position means a saved relative placement, never invented architectural scale. Unknown placement is labeled as an ordered arrangement. Names, status and selected checkmarks remain on opaque ground.

One scope header and one editing surface connect the room, fixtures, compositions and music. Power and level remain immediate; color/white and segment access appear in place. Multi-selection names the target count and can always be cleared. Scenes are horizontal composition scores from stored snapshots with explicit saved scope; effects name their owner and offer Stop & Restore.

System text names things, tabular numbers measure, monospace is reserved for diagnostics. Color is contained output data. No floor-plan fiction, icon-only primary navigation, fake hardware, blanket glow, hero statistics, or nested card grids. Motion only acknowledges state; Reduced Motion removes UI transitions, and existing music safety handling remains intact.

## Implementation boundaries
Keep transports, effects, capture/DSP, persistence schema, identifiers, held layouts and restore semantics. A scoped scene-capture parameter is a focused extension of the existing capture path (default remains all), not another scene model. Selection reconciliation and scene scope need regression tests.

Affected: ProductShellView, PlanWorkspaceView, Theme/DesignControls, LightRow, MusicModeView/Visualizer, segment/Luna editors, setup surfaces, production web App/views/styles, scoped scene capture, existing tests and documentation. Reuse compiled files where possible; any added test must be registered in pbxproj.

## Integration and environment update

PR #105 landed on main as 2e46663 during implementation. It is incorporated in
this branch with its capture, control, transport, lifecycle and regression tests
preserved. Its engineering changes are upstream work, not a design rewrite.
Local Linux execution later became available. An isolated checkout now supports
web builds, tests and browser rendering; Apple compilation/rendering still uses
GitHub Actions. The earlier environment note records the original constraint.
