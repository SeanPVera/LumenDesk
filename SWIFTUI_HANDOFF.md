# SwiftUI implementation handoff

## Implementation status — applied July 14, 2026

The first native implementation pass is now active in the app target:

- `RootView` launches `LumenDeskShellView` after onboarding.
- macOS uses a `NavigationSplitView` with Home, Library, Automation, Devices, and Settings.
- iPhone uses native tabs for Home, Library, Automation, and Devices, with Settings presented from the toolbar.
- The refined Aurora Noir semantic palette and app accent are active globally.
- Home includes global control, favorites, rooms, search/filtering, selection/bulk actions, compact device truth, and room/light detail.
- Library, Automation, Devices, recovery, demo mode, scene preview/editing, schedules, and Segment Studio are wired to the existing `LightManager` behavior.
- LAN protocols, discovery, command transport, persistence, scheduling semantics, and segment application behavior were not changed.

Verification completed with a successful macOS Debug build and a clean direct type-check against the iOS 16 device SDK. A full iOS asset-catalog build remains environment-dependent because the attached Xcode installation currently reports no available simulator runtimes to `actool`.

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

Retain SF Pro through semantic SwiftUI fonts. Use `.rounded` only for `Display/Large` and a small set of brand headers; do not apply it to dense status and control text.

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
