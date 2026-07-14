# LumenDesk UX audit and redesign direction

## Product summary and primary jobs

LumenDesk is a local-first controller for mixed LIFX and Govee lighting. Its strongest product promise is not merely privacy; it is fast, honest control with unusually capable local creative tools. The primary jobs are:

1. See what the home is doing and change power or brightness immediately.
2. Control a room or light without wondering whether the device accepted the command.
3. recall a favorite look, capture the current setup, or start and stop an effect.
4. Create detailed RGBIC layouts in Segment Studio without losing work or confusing a live preview with a durable application.
5. Configure schedules and temporarily pause automation without disabling it by accident.
6. Discover, organize, and recover devices when the local network is imperfect.

## Existing architecture

The current `ContentView` is a vertically stacked workspace with a large action-heavy header, global power and brightness, search/filtering, a timeline, intent dock, favorites, then room and device content. Most destinations—including Library, diagnostics, activity, discovery changes, identify mode, the Experience Center, and novelty Labs—open as sheets. Rooms expand inline and contain detailed controls. The same target adapts with conditional SwiftUI shims, but the composition is still primarily desktop-shaped and sheets carry much of the navigation burden on iPhone.

The state model is more mature than the visible hierarchy suggests. `LightManager` distinguishes queued, sending, applied, failed, and confirmed device state; maintains desired and confirmed snapshots; records discovery and activity; handles partial failures; supports undo, automation overrides, effects, demo data, and segment preview/application. These are valuable foundations to expose more coherently rather than replace.

## Findings

### What works

- Local-first value, mixed-vendor rooms, and the lack of account friction are distinctive and credible.
- Room and light controls already cover partial power, offline devices, color/white modes, recovery, accessibility labels, keyboard shortcuts, reduced motion, and reduced transparency.
- Segment Studio is a genuine flagship capability with device-aware layouts, per-segment brightness, gradient support, live streaming preview, durable application, presets, and cancel/revert behavior.
- Command, discovery, activity, and confirmed-state models provide the raw material for trustworthy feedback.
- Favorites, scenes, themes, effects, schedules, bulk selection, demo mode, and the menu-bar controller form a useful complete product rather than a thin device remote.

### Friction and hierarchy problems

- The main header gives too many actions similar prominence. Nap, Select, Experience, Library, New Room, Scan, and More compete with global control.
- The first viewport stacks timeline, intent dock, favorites, rooms, and device controls before the user has chosen a task. Cards are visually similar, so importance is unclear.
- Frequent control and operational utilities share a surface. Diagnostics, discovery changes, activity, and experiments are useful but do not deserve primary-navigation weight.
- Sheet-based navigation makes Library and other major destinations feel temporary. On iPhone, large desktop sheets do not become a deliberate mobile navigation model.
- Optimistic command state exists but is easy to miss. “Applied locally” and “confirmed by device” need stable terminology and proximity to the affected control.
- Rooms place status, schedules, effects, recent activity, automation overrides, power, and a large menu in one header. The summary is informative but dense.
- Scenes, curated themes, and animated effects share a Library but need stronger type labels and different primary verbs: Restore, Preview/Apply, and Start.
- The vivid Aurora Noir system applies glow and gradient emphasis broadly. Everyday control should be calmer; lighting color should live mostly in previews, active-light edges, and creative editors.
- Novelty features such as Lighting Parliament, Firefly Conservatory, and compliance concepts distract from the core instrument when surfaced near normal controls. They should remain in a secondary Labs area.

## Recommended information architecture

- **Home** — global status and power, favorites, room summaries, individual lights, active effect, next automation, search/filter/layout, and bulk selection.
- **Library** — My Scenes, Themes, and Effects with persistent target selection, clear Preview/Apply/Start verbs, running-effect controls, and Save Current Lighting.
- **Automation** — schedules, paused rooms, missed actions, and edit flows. Per-schedule disabled state remains visually and semantically separate from room-level pause.
- **Devices** — discovery, unassigned devices, device inspector, diagnostics, desired-versus-confirmed state, and activity.
- **Settings** — appearance, interaction, menu bar, privacy/permissions, import/export, demo mode, and secondary Labs.

On macOS this becomes a sidebar workspace with a contextual toolbar and optional inspector. On iPhone it becomes a four-item bottom tab bar (Home, Library, Automation, Devices), with Settings in the Home profile/menu and details pushed in a navigation stack. Major editing uses bottom sheets or full-screen covers; it does not shrink the desktop shell.

## Prioritized screen inventory

### Tier 1: frequent control

1. macOS Home — comfortable, populated.
2. macOS Home — compact and partial-offline.
3. macOS Home — bulk selection.
4. iPhone Home.
5. Room detail with partial power and one offline device.
6. Expanded light control with optimistic command state.
7. Library overview.
8. Theme/scene detail and Save Scene flow.
9. Effect running state.
10. Segment Studio — initial/painted/gradient/live preview/applied states.

### Tier 2: setup and continuity

11. First-run welcome/local network/device preparation.
12. Discovery progress/results/room assignment.
13. Automation list and schedule editor.
14. macOS menu-bar controller.
15. Devices diagnostics and recovery.
16. Settings and Demo Mode.

## Design principles

1. **Control first.** Power, brightness, room entry, and favorites stay within one action of Home.
2. **Truth near the action.** Every optimistic command can say Sending, Applied locally, Confirmed by device, Failed, or Partially applied next to the affected control.
3. **Calm by default, expressive on demand.** Normal surfaces are quiet; Library previews and Segment Studio carry the color.
4. **One primary decision per region.** Headers orient; cards control; menus hold secondary actions.
5. **Progressive disclosure for expertise.** Ordinary recovery is concise; addresses, protocol context, and desired-versus-confirmed details live in Devices.
6. **Preview is not Apply.** Volatile preview and durable application use different language, placement, and confirmation.
7. **Platform-native composition.** macOS uses sidebar, toolbar, hover, keyboard, and inspector patterns; iPhone uses tabs, navigation stacks, sheets, and reachable bottom actions.
8. **Status is redundant by design.** Icon, text, shape, and accessible announcements supplement semantic color.

## Accessibility direction

- Minimum 4.5:1 body-text contrast and 3:1 for large text and meaningful non-text UI.
- A two-pixel cyan focus ring with a dark offset border; never remove the browser or platform focus without replacement.
- Minimum 44 × 44 point mobile targets and 28–32 point compact macOS controls.
- Status always includes a label/icon; live regions announce command transitions and scanning results.
- Sliders use native controls with explicit labels and values. Selection tools use buttons with `aria-pressed`.
- Reduced motion removes transforms, glow drift, and long transitions. Reduced transparency replaces translucent surfaces with opaque hierarchy tokens.
- Lighting swatches retain names and selection marks so hue is never the only identifier.
