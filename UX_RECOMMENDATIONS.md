# LumenDesk — UX Recommendations & Implementation Plan

**Audited:** 2026-05-17  
**Scope:** macOS SwiftUI desktop app for local smart-bulb control (LIFX + Govee)

---

## The 20 Recommendations

| # | Recommendation | Impact | Effort |
|---|---------------|--------|--------|
| 1 | Room-level master controls (toggle + brightness) | High | Low |
| 2 | Global "All Lights" controls in header | High | Low |
| 3 | Fix inline-rename UX (auto-focus, visible cancel) | High | Low |
| 4 | Text truncation for long names | Medium | Low |
| 5 | Per-light reachability indicator | High | Low |
| 6 | Color swatches for common colors | High | Medium |
| 7 | Drag-and-drop room & light reordering | High | Medium |
| 8 | Keyboard shortcuts for all major actions | Medium | Medium |
| 9 | Command-failure feedback (toast/banner) | High | Medium |
| 10 | Multi-select lights for bulk operations | High | Medium |
| 11 | Scenes — save & recall presets | High | High |
| 12 | Search / filter lights and rooms | Medium | Medium |
| 13 | Better empty state & first-run onboarding | Medium | Low |
| 14 | Undo / redo for power and color changes | Medium | High |
| 15 | Adaptive two-column layout for wider windows | Medium | Medium |
| 16 | Menu-bar item for quick access | Medium | High |
| 17 | Full VoiceOver / accessibility audit | High | High |
| 18 | Favorites strip for frequently used lights | Low | Medium |
| 19 | Export / import room configuration | Low | Low |
| 20 | Auto-dimming schedule per room | Medium | High |

---

## Detailed Recommendations

### 1. Room-Level Master Controls
**Problem:** Every bulb in a room must be toggled individually. Turning off a room means 5–10 context-menu interactions.  
**Fix:** Add a toggle and a brightness slider directly in the `RoomSectionView` header row. Tapping the toggle calls `manager.setPower(for: room, on: value)` across all bulbs in that room. The brightness slider sets a uniform brightness level. Both controls are disabled when the room is empty.  
**Impact:** Eliminates the single most common multi-step flow in the app.

---

### 2. Global "All Lights" Controls in Header
**Problem:** There is no single action to turn everything off (e.g., leaving home, going to bed).  
**Fix:** Add a master power toggle and a brightness slider in `ContentView`'s header next to the scan button. Slide-to-dim animates all discovered lights simultaneously. A long-press on the master toggle opens a confirmation popover when more than 3 rooms are present.  
**Impact:** Covers the most urgent "I need to kill all lights right now" use case.

---

### 3. Fix Inline-Rename UX
**Problem:** Room rename is triggered via context menu and swaps a `Text` for a `TextField`, but the field does not auto-focus. The only way to cancel is `Escape`, with no visible affordance.  
**Fix:**
- Call `.focused($isRenaming)` so the cursor lands in the field immediately.
- Render a small `×` button at the trailing edge of the text field for explicit cancel.
- Commit on `Return` or focus-loss; cancel on `Escape` or the `×` button.
- Restore the previous name on cancel instead of leaving an empty string.

---

### 4. Text Truncation for Long Names
**Problem:** Bulb names such as `"Govee H6054 Living Room Left Corner Floor Lamp"` will overflow the card layout. Room names with 30+ characters push controls off-screen.  
**Fix:** Add `.lineLimit(1).truncationMode(.tail)` to every name label. Show a tooltip (`.help()`) with the full name on hover so nothing is permanently hidden.

---

### 5. Per-Light Reachability Indicator
**Problem:** UDP commands are fire-and-forget. A bulb that is offline or unreachable looks identical to one that is on and responding. Users repeatedly retry controls on dead bulbs.  
**Fix:** Track `lastSeenAt: Date?` on `LightDevice`. After two consecutive failed refresh cycles (~60 s), mark the device `.stale`. Render a small amber warning icon (⚠) overlaid on the color circle and set the row to 50% opacity. Add a tooltip: *"Last seen 2 min ago — check bulb power."* Clear the stale state on the next successful response.

---

### 6. Color Swatches for Common Colors
**Problem:** Every color change opens the full macOS `ColorPicker`, which is a large modal wheel that requires precise manipulation for common choices like warm white, cool white, or red.  
**Fix:** Render a horizontal strip of 8 color swatches (warm white 2700 K, neutral 4000 K, daylight 6500 K, red, green, blue, purple, orange) above the `ColorPicker` button. Tapping a swatch applies immediately without opening the picker. The `ColorPicker` remains available for custom colors. Swatches respect the disabled state when the light is off.

---

### 7. Drag-and-Drop Room & Light Reordering
**Problem:** Reordering rooms or lights within a room requires repeated "Move Up / Move Down" context-menu taps, which is error-prone for lists longer than 3 items.  
**Fix:** Adopt SwiftUI's `.onMove` on the room list and `.draggable` / `.dropDestination` on light rows. Add a subtle drag handle (three horizontal lines) on the leading edge of each room header and each light row. Persist the new order to `UserDefaults` on drop completion. The context-menu "Move Up/Down" items can remain as a keyboard-friendly fallback.

---

### 8. Keyboard Shortcuts for All Major Actions
**Problem:** Only `Cmd+R` (scan) exists. Power users cannot control their lights without touching the mouse.  
**Fix:** Register the following shortcuts via `KeyboardShortcut`:

| Action | Shortcut |
|--------|----------|
| Scan for lights | `Cmd+R` (existing) |
| Toggle all lights | `Cmd+Shift+P` |
| New room | `Cmd+N` |
| Focus search | `Cmd+F` |
| Rename selected room | `F2` / `Enter` |
| Delete selected room | `Backspace` (with confirmation) |

Surface shortcuts in context menus and tooltips so they are discoverable.

---

### 9. Command-Failure Feedback (Toast / Banner)
**Problem:** UDP send failures are silent. `LightManager` prints errors to console but nothing surfaces in the UI. Users don't know whether their tap had any effect.  
**Fix:** In `LightManager`, collect send errors into an `@Published var lastError: String?`. In `ContentView`, attach a `.overlay` at the bottom of the window that shows a non-blocking banner ("Could not reach Bedside Lamp — check network") for 4 seconds. Auto-dismiss with a fade animation. Add a manual dismiss `×`.  Avoid showing banners for expected offline events (e.g., during active scan).

---

### 10. Multi-Select Lights for Bulk Operations
**Problem:** Operations like "move all bedroom lights to a new room" require moving each one individually via context menu.  
**Fix:** Add a selection mode toggled by a toolbar button (checkbox icon). In selection mode, each light row shows a leading checkbox. A floating action bar at the bottom of the window shows "X selected — Move to Room… | Turn On | Turn Off | Set Brightness…". Confirm-then-exit selection mode. This replaces roughly 80% of repetitive context-menu use.

---

### 11. Scenes — Save & Recall Lighting Presets
**Problem:** Users who configure the perfect warm evening setup must manually recreate it every session.  
**Fix:** Add a "Scenes" panel accessible from the header (wand icon). A scene captures the current state of every discovered light (power, brightness, color). Scenes are named, stored in `UserDefaults`, and recalled with a single tap. Recall sends commands in parallel across all vendor clients. Provide 3 starter scenes: "Evening", "Work", "Off". Scenes that include lights not currently reachable skip those lights gracefully and display a warning badge on the scene card.

---

### 12. Search / Filter Lights and Rooms
**Problem:** Users with 10+ bulbs across 4+ rooms spend time scrolling to locate a specific light.  
**Fix:** Add a `SearchField` (`.searchable` modifier) at the top of the scroll area. Typing filters rooms and light rows in real time (case-insensitive substring match on name, brand, or IP). Rooms with no matching lights collapse automatically. Clearing the search restores all sections. Trigger with `Cmd+F`.

---

### 13. Better Empty State & First-Run Onboarding
**Problem:** The empty state shows a lightbulb-slash icon with generic text. New users often don't know they must enable Govee LAN Control in the Govee Home app first.  
**Fix:** Replace the generic empty state with a two-step checklist:
1. ✓ Mac and bulbs on the same Wi-Fi — *check your router if unsure*
2. ✓ Govee bulbs: enable LAN Control in Govee Home app → Devices → [bulb] → Settings → LAN Control
3. ✓ LIFX bulbs: ensure bulbs are powered and paired

Render each step as a collapsible row with a checkmark that the user can tick manually. Add a "Scan Now" CTA button at the bottom. On first launch (no prior `UserDefaults` key), auto-open this checklist.

---

### 14. Undo / Redo for Power and Color Changes
**Problem:** Accidentally turning off all the lights in a room, or snapping a bulb to a wrong color, has no recovery path short of manually reconfiguring.  
**Fix:** Wrap state-mutating `LightManager` methods in an `UndoManager`-compatible pattern. Register each change with `undoManager.registerUndo(withTarget:)`. Expose Undo (`Cmd+Z`) and Redo (`Cmd+Shift+Z`) via the Edit menu. Limit the undo stack to the last 20 operations to avoid memory growth.

---

### 15. Adaptive Two-Column Layout for Wider Windows
**Problem:** The single-column room list feels sparse and requires excessive scrolling when the window is expanded beyond ~800 px wide. The minimum window size is 520 px, but nothing adapts above that.  
**Fix:** Use `GeometryReader` to detect the available width. At ≥ 780 px, switch to a two-column `LazyVGrid` for room sections. At ≥ 1100 px, allow a three-column layout. The header and search bar remain full-width. This makes the app feel intentional at any window size rather than stretched.

---

### 16. Menu-Bar Item for Quick Access
**Problem:** Switching between the app and other work to adjust lights breaks focus. Users want to dim without leaving their current app.  
**Fix:** Add a persistent menu-bar icon (a filled lightbulb `🔆`). Clicking it opens a compact popover (280 × 380 px) showing the same room list with master toggles and brightness sliders. The popover auto-closes on outside click. Implement as a secondary `NSPopover` attached to an `NSStatusItem`. This is separate from the main window, which remains available.

---

### 17. Full VoiceOver / Accessibility Audit
**Problem:** The app has zero custom accessibility modifiers. Native controls (Toggle, Slider, ColorPicker) get basic VoiceOver by default, but custom elements (color circle, room header, brand badge) are invisible to assistive technology.  
**Fix:**
- `.accessibilityLabel("Bedroom, 3 lights, expanded")` on room headers.
- `.accessibilityLabel("\(device.name), \(device.brand), \(device.isOn ? "on" : "off"), brightness \(Int(device.brightness * 100))%")` on each light row.
- `.accessibilityAction(named: "Toggle power") { manager.togglePower(device) }` on color circles.
- `.accessibilityHint("Double-tap to rename")` on room name labels.
- Audit with Xcode Accessibility Inspector; target zero warnings.

---

### 18. Favorites Strip for Frequently Used Lights
**Problem:** Specific bulbs (bedside lamp, desk lamp) are adjusted far more often than others but are buried in room lists.  
**Fix:** Add a "Favorites" horizontal strip at the top of the scroll area (above rooms). Any light can be starred via its context menu. Favorites show as compact tiles (color circle + name + power toggle + brightness dial) in a horizontally scrollable strip. Stored in `UserDefaults`. Empty by default; hidden when no favorites are set.

---

### 19. Export / Import Room Configuration
**Problem:** Users with multiple Macs, or who reinstall the app, must recreate all rooms and assignments by hand.  
**Fix:** Add "Export Configuration…" and "Import Configuration…" to the File menu. Export serializes `rooms` from `UserDefaults` to a JSON file via `NSSavePanel`. Import reads a JSON file via `NSOpenPanel`, validates the schema, and merges (or replaces) the current room list. Show a diff preview before import ("3 rooms will be added, 1 updated").

---

### 20. Auto-Dimming Schedule Per Room
**Problem:** Users want their lights to automatically dim in the evening or turn off at bedtime but must remember to do it manually.  
**Fix:** Add a "Schedule" sheet accessible from each room's context menu. Each room supports up to 4 daily schedule entries: time + action (on/off/brightness/scene). Schedules fire via a `Timer` in `LightManager` that checks every 60 seconds against the current `Date`. Scheduling is local-only (no cloud). A status badge on the room header indicates when a schedule is active. Schedules survive app restarts via `UserDefaults`.

---

## Implementation Plan

Recommendations are grouped into four phases ordered by impact-to-effort ratio. Each phase can ship independently.

---

### Phase 1 — Quick Wins (1–2 weeks) — ✅ IMPLEMENTED
*Low effort, high payoff. All changes are isolated to existing files with no new architectural dependencies.*

| Priority | Rec | Files Affected | Status |
|----------|-----|----------------|--------|
| P1 | **#4** Text truncation for long names | `LightRowView.swift`, `RoomSectionView.swift` | ✅ Done |
| P2 | **#3** Fix inline-rename UX | `RoomSectionView.swift` | ✅ Done |
| P3 | **#13** Better empty state & first-run onboarding | `ContentView.swift` | ✅ Done |
| P4 | **#19** Export / import room configuration | `LumenDeskApp.swift`, `LightManager.swift`, `LumenDesk.entitlements` | ✅ Done |
| P5 | **#5** Per-light reachability indicator | `LightDevice.swift`, `LightManager.swift`, `LightRowView.swift` | ✅ Done |

**Deliverable:** Polished existing surfaces. No new concepts introduced. Shippable as a patch release.

**Implementation notes:**
- **#4** — `.lineLimit(1).truncationMode(.tail)` on bulb and room names, with `.help()` tooltips exposing the full text on hover.
- **#3** — `@FocusState` auto-focuses the rename field; a visible `×` button and `Esc` (`onExitCommand`) cancel and restore the prior name; empty names are rejected on commit.
- **#13** — Replaced the static empty state with an interactive 3-step setup checklist (tap to tick) plus a prominent "Scan Now" default-action button.
- **#19** — `Export/Import Configuration…` in the File menu via `NSSavePanel`/`NSOpenPanel`; pretty-printed JSON; malformed imports surface a status message instead of silently wiping rooms. Added `files.user-selected.read-write` sandbox entitlement.
- **#5** — Added `isStale` to `LightDevice`; the 30 s refresh timer flags devices unseen for >75 s. Stale rows dim to 60%, gain an amber border + ⚠ badge on the color dot, and a tooltip showing "last seen". A central `markSeen()` helper clears the flag on any successful response.

> ⚠️ This is a macOS-only SwiftUI app; no Swift/Xcode toolchain exists in the cloud Linux environment, so changes were hand-reviewed rather than compiled. Build & smoke-test on a Mac before release.

---

### Phase 2 — Core Interaction Improvements (3–4 weeks)
*Medium effort. Introduces new UI patterns (swatches, drag-drop, toasts) that pair well together.*

| Priority | Rec | Files Affected |
|----------|-----|----------------|
| P1 | **#1** Room-level master controls | `RoomSectionView.swift`, `LightManager.swift` |
| P2 | **#2** Global "All Lights" controls in header | `ContentView.swift`, `LightManager.swift` |
| P3 | **#9** Command-failure feedback (toast/banner) | `LightManager.swift`, `ContentView.swift` |
| P4 | **#6** Color swatches for common colors | `LightRowView.swift` |
| P5 | **#7** Drag-and-drop reordering | `ContentView.swift`, `RoomSectionView.swift`, `LightManager.swift` |
| P6 | **#8** Keyboard shortcuts | `LumenDeskApp.swift`, `ContentView.swift` |

**Deliverable:** The app becomes significantly faster for daily use. Room master controls alone justify a minor version bump.

---

### Phase 3 — Power-User Features (4–6 weeks)
*Medium-to-high effort. Introduces new data models (scenes, favorites, search state) and new views.*

| Priority | Rec | Files Affected |
|----------|-----|----------------|
| P1 | **#12** Search / filter | `ContentView.swift`, new `SearchBar` component |
| P2 | **#10** Multi-select + bulk operations | `ContentView.swift`, `LightRowView.swift`, `LightManager.swift`, new `BulkActionBar` |
| P3 | **#11** Scenes — save & recall presets | New `Scene.swift` model, new `ScenesView.swift`, `LightManager.swift` |
| P4 | **#15** Adaptive two-column layout | `ContentView.swift`, new `RoomGridView.swift` |
| P5 | **#18** Favorites strip | New `FavoritesStripView.swift`, `LightDevice.swift`, `LightManager.swift` |
| P6 | **#14** Undo / redo | `LightManager.swift`, `LumenDeskApp.swift` |

**Deliverable:** LumenDesk becomes a professional-grade tool for users with large smart-home setups.

---

### Phase 4 — Platform Integration & Accessibility (6–8 weeks)
*Highest effort. Requires platform-level work (NSStatusItem, UndoManager, VoiceOver audit) and careful testing.*

| Priority | Rec | Files Affected |
|----------|-----|----------------|
| P1 | **#17** Full VoiceOver / accessibility audit | All `Views/`, Xcode Accessibility Inspector review |
| P2 | **#16** Menu-bar item for quick access | New `MenuBarManager.swift`, new `MenuBarPopoverView.swift`, `LumenDeskApp.swift` |
| P3 | **#20** Auto-dimming schedule per room | New `Schedule.swift` model, new `ScheduleEditorView.swift`, `LightManager.swift`, `Room.swift` |

**Deliverable:** App is suitable for enterprise/accessibility-audited environments and deep macOS integration.

---

## Effort & Impact Summary

```
Impact
 High │  5  9  1  2  10  11  17  6  7
      │  3  13     8       12     16  20
  Med │  4  19    15   14  18
      │
  Low │
      └─────────────────────────────────── Effort →
           Low      Med      High
```

Start top-left (High impact, Low effort = Phase 1 & early Phase 2).  
Items in the top-right (High impact, High effort = #10, #11, #17) anchor Phase 3 & 4.

---

## Notes

- **No third-party dependencies** are required for any recommendation. All use native SwiftUI / AppKit APIs available on macOS 13+.
- Phases 1 and 2 can be developed in parallel across two engineers without merge conflicts (Phase 1 touches display-only code; Phase 2 touches interaction code).
- Phase 3's **Scenes** feature (#11) is a prerequisite for **Schedules** (#20) — build in that order.
- Accessibility (#17) should be a continuous practice from Phase 2 onward, not a one-time audit at the end.
