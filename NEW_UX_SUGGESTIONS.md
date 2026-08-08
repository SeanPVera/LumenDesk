# LumenDesk — Fourth-Pass UX Backlog: 10 New Practical Improvements

**Scope:** macOS & iOS SwiftUI local smart-bulb controller
**Context:** These 10 suggestions build upon the existing features (rooms, scenes, schedules, diagnostics, undo/redo, bulk selection) without duplicating the previous 60 recommendations.

---

## 10 New Practical UX Recommendations

| # | Recommendation | Usability problem | Proposed improvement | Impact | Effort |
|---|---|---|---|---|---|
| 1 | **Copy and Paste Lighting States** | To make one bulb exactly match another, users must memorize HSB/Kelvin values, create a temporary scene, or use a custom color picker, all of which are slow for one-off tasks. | Add "Copy State" and "Paste State" to device context menus and keyboard shortcuts (`Cmd+Shift+C` / `Cmd+Shift+V`), instantly transferring color, temperature, and brightness between bulbs. | High | Low |
| 2 | **Logical Fixture Grouping** | A three-bulb chandelier or four-bulb ceiling fan clutters the room view with individual rows, and users rarely want to control them separately. | Allow grouping multiple physical bulbs into a single logical "Fixture" that collapses into one row in the UI. Changes applied to the fixture fan out to all constituent bulbs, but they can be expanded if individual control is needed. | High | Medium |
| 3 | **Screen Color Sampler (macOS)** | Users want to match their room lighting to their desktop wallpaper, a paused movie, or digital artwork, but manually matching screen colors by eye is tedious and inaccurate. | Add a native eyedropper tool (using `NSColorSampler`) in the color picker, allowing users to sample any pixel on their screen and immediately push that color to the selected light. | Medium | Low |
| 4 | **Smart Brightness Caps (Nighttime Protection)** | Accidentally dragging a slider to 100% or triggering a bright scene at 2 AM is painful, and standard schedules don't prevent manual slider errors. | Add a user-defined "Nighttime Max Brightness" limit (e.g., max 30% between 11 PM and 6 AM). Sliders visually lock at this limit during the window, requiring an explicit override to exceed it. | High | Medium |
| 5 | **Relative Bulk Adjustments** | When multiple lights with different brightness levels (e.g., 80% and 40%) are selected, dragging a bulk slider snaps them all to the exact same absolute value, destroying the carefully tuned lighting ratio. | Make bulk slider adjustments relative by default (e.g., sliding down dims all by 10% relative to their starting point) and require a modifier key (`Option`) to snap them to a uniform absolute value. | High | Medium |
| 6 | **Semantic Iconography for Devices** | Text names are the only way to distinguish devices. In a dense UI or on a small screen, quickly parsing "Desk Lamp", "Floor Lamp", and "Ceiling" takes cognitive effort. | Provide a curated set of SF Symbols for fixtures (strip, desk lamp, pendant, TV). Render these icons beside the name to improve glanceability and make the UI feel personalized. | Medium | Low |
| 7 | **Location Profiles (Multi-Network Support)** | Users with lights at home and at the office, or who use a travel router, have all discovered devices pooled together, leading to a huge list of offline devices depending on where they are. | Introduce "Location Profiles" (e.g., Home, Office) that sandbox rooms, lights, and schedules to a specific network environment, auto-switching based on the connected Wi-Fi SSID. | High | High |
| 8 | **Stability Tracking & Disconnect Guidance** | The app identifies "stale" devices but doesn't track long-term health. A bulb that falls offline 10 times a week looks the same as one that was just unplugged. | Track connection stability over time. If a device frequently drops off the LAN, show a specific diagnostic warning suggesting a physical power-cycle, static IP assignment, or Wi-Fi signal check. | Medium | Medium |
| 9 | **Temporary Automation "Hold" (Snooze state)** | If a user manually overrides a light (e.g., turning on full white to find dropped keys) while an animated effect or schedule is running, the app might immediately overwrite their change on the next tick. | Add a "Hold State" lock icon. When toggled, the specific light ignores all incoming automated commands (effects/schedules) for a set time (e.g., 5 mins) before rejoining the group behavior. | High | Medium |
| 10 | **Natural Language Schedule Entry** | Creating a schedule using traditional pickers (Hour, Minute, AM/PM, Days) takes multiple clicks and can feel tedious compared to modern reminder apps. | Add a natural language text field at the top of the Schedule Editor. Typing "Turn on at sunset on weekdays" or "Dim to 20% at 11pm everyday" parses into the structured schedule UI instantly. | Medium | High |

---

## Implementation Priority

1. **Phase 1 (Quick Wins):** Copy/Paste States, Screen Color Sampler, Semantic Iconography.
2. **Phase 2 (Interaction Refinement):** Relative Bulk Adjustments, Smart Brightness Caps, Temporary Automation Hold.
3. **Phase 3 (Organization & Health):** Logical Fixture Grouping, Stability Tracking.
4. **Phase 4 (Advanced Features):** Location Profiles, Natural Language Schedule Entry.
