# SwiftUI implementation handoff

## Implementation status — Spectral Bench applied

The visual system was replaced wholesale. `Theme.swift` holds the tokens, geometry, backdrop, panel treatment, button styles, and the mark; `DesignControls.swift` holds the instrument layer that replaces the platform's stock controls.

- The palette moved from warm graphite and signal amber to cool obsidian neutrals plus one sampled dispersion ramp. Interface chrome is achromatic; colour means light.
- Typography dropped the serif voice. `LumenType.display` is SF Pro Condensed, `LumenType.readout` is SF Mono for every measured value, and `LumenType.instrumentLabel` engraves uppercase labels.
- Panels are `LumenPanelShape`: 5 pt radii with a 14 pt chamfer on the top-trailing corner, a lit top edge, a hairline, and a spectrum rail when active. `lumenCard(...)` keeps its old signature and now applies this treatment, so existing call sites did not need to change shape.
- Every `Slider`, `.toggleStyle(.switch)`, `.pickerStyle(.segmented)`, and `.toggleStyle(.button)` in the app target was replaced by `LumenFader`, `LumenPowerKeyStyle`, `LumenRockerStyle`, `LumenSelector`, and `LumenChipStyle`. `.bordered` and `.borderedProminent` became the console key styles.
- Coloured `Circle()` device swatches became `LumenLens` plates; capsule status badges became squared badges with indicator squares.
- The mark was redrawn: the beam now leaves the aperture white and lands on the desk rail as the full spectrum. `scripts/generate_brand_assets.py` was rewritten to match and the icon family regenerated.

LAN protocols, discovery, command transport, persistence, scheduling semantics, and segment application behaviour were not changed.

### Working on this system

- Reach for `DesignControls.swift` before reaching for a stock control. If a screen needs something the library does not have, add it there rather than styling one call site.
- A `ButtonStyle` or `ToggleStyle` is not part of the view hierarchy, so `@Environment` inside one is never populated. Both key styles extract an inner `View` (`LumenKeyFace`, `LumenPowerKeyFace`) to read `isEnabled` correctly — follow that pattern.
- A custom style cannot read `.tint()` or `.controlSize()`. If a call site used either to express state, express it in the style instead: that is why the schedule day picker is a chip toggle rather than tinted buttons.
- A `ToggleStyle` cannot read the text out of its own configuration label, which is why `LumenPowerKeyStyle` takes `spokenLabel` for VoiceOver.

## Recommended navigation change

Replace the sheet-heavy top-level composition in `ContentView` with a route model shared across platforms:

- macOS: `NavigationSplitView` with Home, Library, Automation, Devices, and Settings. Use a contextual toolbar and optional inspector.
- iPhone: `TabView` for Home, Library, Automation, and Devices, with `NavigationStack` detail routes. Keep Settings in a Home menu/profile destination.
- Continue using sheets for focused creation/editing: Save Scene, schedule editor, confirmation, and compact recovery. Segment Studio can be a macOS sheet/window and an iPhone full-screen cover.

## Existing views to restyle or reuse

- `FavoritesStripView`: keep persistence and ordering; restyle into low-profile horizontal tiles.
- `LightRowView`: preserve bindings, accessibility actions, recovery, and Segment Studio entry. Split compact identity/status from expanded editing.
- `RoomSectionView`: retain aggregate state and room operations; move schedules/effects/activity into summary rows or menu disclosure.
- `ScenesView`: retain scene/theme/effect data and actions; promote it from a temporary sheet into the Library destination.
- `GoveeSegmentEditorView`: preserve draft/opening state, selection, preview, presets, and application behavior; reorganize into canvas + inspector + fixed action footer.
- `OnboardingView`: retain setup state and discovery logic; separate permission preparation, device preparation, discovery outcomes, review, and room assignment.
- `ScheduleEditorView`: preserve scheduling model; introduce an explicit fixed/sunrise/sunset mode selector and stronger disabled-vs-paused copy.
- `MenuBarPopoverView`: keep its independent compact composition; update visuals and command states without mirroring Home.
- `UXCenterViews`: keep Diagnostics, Device Inspector, Activity, Discovery Inbox, and Missed Automations as progressive Devices/Automation destinations. Move novelty Labs out of core navigation.

## Views to decompose

`ContentView` currently owns too much destination state and presentation logic. Decompose it into:

- `AppRoute` and `AppNavigationModel`.
- `HomeWorkspaceView`.
- `HomeStatusHeader`.
- `GlobalLightingControl`.
- `RoomSummaryGrid` and `RoomSummaryCard`.
- `DeviceGrid` and `DeviceCompactRow`.
- `WorkspaceSearchAndFilters`.
- `ActiveLightingSummary`.
- `BulkLightingActionBar`.

Decompose `LightRowView` into `LightIdentity`, `ConnectivityBadge`, `CommandStateView`, `PowerControl`, `BrightnessControl`, `ColorModeControl`, `LightRecoveryActions`, and `SegmentStudioEntry`.

Decompose `RoomSectionView` into `RoomSummaryHeader`, `RoomAggregateControls`, `RoomAutomationSummary`, and `RoomDeviceList`.

## Suggested reusable components

- `LumenSurface(role:)`
- `LumenStatusBadge(status:)`
- `LumenCommandIndicator(state:)`
- `LumenPowerToggle(state:onChange:)`
- `LumenBrightnessSlider(value:pending:)`
- `LumenColorSwatch(color:name:isSelected:)`
- `LumenEmptyState(icon:title:message:action:)`
- `LumenRecoveryCard(problem:actions:)`
- `LumenToast(style:message:action:)`
- `LumenSegmentCell(index:state:selection:)`
- `LumenActionFooter(draftState:previewState:cancel:apply:)`

## Token mapping

Create a Swift token namespace that mirrors Figma/CSS names:

```swift
enum LumenToken {
    enum Background {
        static let base = Color(hex: 0x090B12)
        static let subtle = Color(hex: 0x0D1019)
    }
    enum Surface {
        static let `default` = Color(hex: 0x121722)
        static let raised = Color(hex: 0x181E2C)
        static let emphasis = Color(hex: 0x20283A)
    }
    enum Status {
        static let success = Color(hex: 0x45D5A4)
        static let warning = Color(hex: 0xF2B85B)
        static let error = Color(hex: 0xFF657D)
        static let offline = Color(hex: 0x8992A6)
    }
    enum Spacing {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
    }
}
```

Use New York through SwiftUI's `.serif` system design for the wordmark, page titles, and section orientation. Retain SF Pro for controls and body copy. Use SF Mono for short instrument labels and values; do not apply it to paragraph copy.

## Command-state model

Keep `DeviceCommandState` as the source. Clarify terms in the view layer:

- `.queued` → “Queued”.
- `.sending` → “Sending”.
- optimistic desired state before a network response → “Applied locally”.
- `.applied` after response → “Confirmed by device”; return to quiet confirmed after a short delay.
- `.failed` → “Failed” with Retry and optional Rescan.

If changing the model naming is risky, add a presentation enum rather than changing transport semantics.

## Platform adaptation

### macOS

- Sidebar width approximately 220–240 pt; compact collapse near 1000 pt.
- Use hover, context menu, keyboard shortcuts, focus rings, inspector panels, and undo through commands.
- Comfortable and compact density remain user-selectable.
- Segment Studio uses a wide two-column canvas/inspector at comfortable window sizes.

### iPhone

- Keep primary tabs reachable at the bottom.
- Push Room and Light details in the navigation stack.
- Use full-width rows/cards rather than multi-column compression.
- Keep editing actions in a bottom-safe-area footer.
- Segment Studio stacks the canvas over tools; preserve a fixed Cancel/Apply region.

## Accessibility and motion

- Preserve existing `accessibilityLabel`, value, custom actions, reduced motion, and reduced transparency behavior.
- Add status phrases to room/light summaries so VoiceOver does not need to traverse decorative indicators.
- Announce command transitions without announcing every slider drag; debounce final values.
- Use `contentTransition(.numericText())` only when Reduce Motion is off.
- Replace spring/scale press animation with immediate highlight under Reduce Motion.
- Use opaque surfaces under Reduce Transparency.
- Confirm Dynamic Type layouts on iPhone; avoid fixed card heights around text.

## Suggested implementation order

1. Add semantic tokens and shared components without changing navigation.
2. Introduce command-status presentation and migrate Light/Room rows.
3. Add new macOS `NavigationSplitView` and iPhone `TabView` shell.
4. Move Library and Automation into stable destinations.
5. Rebuild Home from the new summary components.
6. Recompose Segment Studio with the existing behavior intact.
7. Move diagnostics/recovery into Devices and missed actions into Automation.
8. Polish onboarding and menu-bar controller.
9. Run VoiceOver, keyboard, Dynamic Type, reduced-motion, and reduced-transparency QA.

## Scope guard

Do not change LAN protocols, discovery, scheduling semantics, scene persistence, held segment-layout behavior, or command transport during the visual refactor. Keep behavioral migrations separately testable from presentation changes.
