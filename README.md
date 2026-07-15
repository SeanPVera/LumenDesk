# LumenDesk

LumenDesk is a native SwiftUI smart-lighting controller for **macOS** and **iOS**. It controls supported **LIFX** and **Govee** bulbs directly on your local network, without cloud accounts, vendor API keys, bridge hardware, or an internet round trip.

The app is designed for day-to-day lighting control as well as richer home-lighting workflows: discovery, rooms, favorites, scenes, color themes, animated effects, schedules, command recovery, diagnostics, import/export, and a macOS menu bar controller.

## What LumenDesk does

- Discovers supported LIFX and Govee lights on the same LAN.
- Controls individual bulbs, rooms, selected groups, or every light at once.
- Supports power, brightness, full-color RGB control, and white color temperature control.
- Paints individual segments on Govee RGBIC devices (COB strips, string lights, neon ropes) with per-segment color and brightness, gradient blending, and live preview — the same specificity as the Govee Home app, without the cloud.
- Groups lights into vendor-agnostic rooms, so LIFX and Govee bulbs can live in the same room.
- Saves and recalls scenes captured from your current lighting state.
- Applies curated static lighting themes and animated effects.
- Choreographs local music into beat, frequency, and spatial lighting through a configurable Music Mode.
- Runs room schedules, including fixed times and sunrise/sunset-style actions.
- Provides undo/redo for recent lighting changes.
- Tracks command progress, failures, confirmations, discovery changes, and activity history.
- Offers a safe demo mode for trying the interface without controlling physical lights.
- Runs as a full app and, on macOS, as a menu bar lighting controller.

## Supported platforms

| Platform | Support |
| --- | --- |
| macOS | macOS 13 Ventura or later |
| iOS | iOS 16 or later |
| UI framework | SwiftUI |
| Build system | Xcode project, optionally regenerated with XcodeGen |

The same `LumenDesk` target is multiplatform and can be built for Mac or iPhone from the same scheme.

## Supported lighting systems

### LIFX

LumenDesk speaks the LIFX LAN protocol directly:

- Discovery uses UDP broadcast on port `56700` with `GetService` packets.
- Control uses LIFX LAN packets such as power and color/HSBK commands.
- State refresh reads back bulb information after discovery and changes where supported.

### Govee

LumenDesk speaks the Govee LAN API directly:

- Discovery uses UDP multicast `239.255.255.250:4001` on platforms that allow multicast.
- Govee devices reply on UDP `4002`.
- Commands are sent on UDP `4003`.
- Each Govee bulb must have **LAN Control** enabled in the Govee Home app.

For segmented RGBIC devices, LumenDesk additionally speaks two community-documented LAN extensions:

- `razer` — the real-time streaming mode used by Razer Chroma sync ("DreamView"), for live per-segment preview while editing.
- `ptReal` — relays the same 20-byte Bluetooth-format commands the Govee Home app writes (segment color, per-segment brightness, gradient toggle), so applied layouts persist on the device.

Not every Govee device supports the LAN API. If a device does not expose LAN Control in the Govee Home app, LumenDesk cannot control it locally.

## Privacy and networking model

LumenDesk is intentionally local-first:

- No LIFX cloud login.
- No Govee cloud login.
- No vendor API keys.
- No remote relay server.
- No analytics service in the app codebase.
- Lighting commands are sent directly to devices on your LAN.

The app needs local network permission because it sends and receives UDP packets on your network. On iOS, the first scan triggers Apple's Local Network privacy prompt; you must allow it for discovery and control to work.

Music Mode analyzes **system audio on macOS** through ScreenCaptureKit and **microphone input on iOS**. Analysis is local, audio is never recorded or retained, and the feature does not receive an Apple Music-only feed.

## Feature guide

### First-run onboarding

On a fresh install, LumenDesk shows a guided setup flow that helps you:

1. Understand the local-network requirements.
2. Prepare LIFX and Govee bulbs.
3. Run discovery.
4. Create rooms.
5. Assign discovered lights to rooms.
6. Enter the main workspace.

You can skip setup and use the main app immediately, but discovery and room organization are easier through the walkthrough.

### Discovery

Use **Scan** or press **⌘R** on macOS to search for lights. LumenDesk scans for both LIFX and Govee devices, updates its device list, and records discovery changes.

Discovery-related UI includes:

- Current scan status and phase.
- Last scan date.
- Number of scan responses.
- Newly discovered devices.
- Devices that came back online.
- Devices whose address changed.
- Devices that are still missing or offline.
- A Discovery Inbox for reviewing scan changes.

### Individual light controls

Each light row supports:

- Power toggle.
- Brightness slider.
- Color picker.
- Color/white mode switching.
- White color temperature adjustment.
- Custom display names.
- Favorite/unfavorite.
- Command status feedback.
- Offline/stale indicators.
- Recent colors and useful presets where available.
- A Segment Studio row on recognized Govee RGBIC devices, with a live mini-preview of the saved layout.

LumenDesk keeps a brand-agnostic device model while still sending the correct vendor-specific packets behind the scenes.

### Segment Studio (Govee COB strips, string lights, neon ropes)

Govee RGBIC devices are individually addressable in zones, and the Govee Home app lets you color each zone separately. LumenDesk's **Segment Studio** brings that same specificity to the LAN:

- A visual strip editor drawn to match the hardware: contiguous cells for COB strips and neon ropes, bulbs on a wire for string lights.
- Tap or drag across segments to select them; paint the selection with swatches, recent colors, or the system color picker. With nothing selected, painting fills the whole strip.
- Selection tools: All, None, Invert, Every Other, and shift-left/right to rotate the layout along the strip.
- **Per-segment brightness** — dim any selection independently of the rest of the strip.
- **Blend Across Selection** — fade from one color to another across the selected segments.
- **Gradient blending** toggle on COB hardware, matching the Govee app's gradient switch.
- **Live preview** streams edits to the light in real time (razer mode). The preview is volatile, so closing the studio without applying is a true cancel.
- **Apply to Light** makes the layout durable. COB strips and neon ropes store it in their own firmware (via the app-native Bluetooth-format commands relayed over the LAN), so it survives power cycles on its own. String, curtain, and permanent-outdoor lights have **no firmware-side segment storage at all** — Govee's own API exposes none for these families — so LumenDesk holds their layout through the live streaming channel and re-applies it automatically every 30 seconds, when a light reconnects, when it's powered back on, and at app launch. Held layouts persist as long as LumenDesk is running.
- 12 built-in segment presets (Rainbow Flow, Sunset Glow, Candy Cane, Fairy Dust, …) plus your own saved presets, automatically re-rendered to each device's segment count.
- A per-device segment-count stepper for models the catalog doesn't recognize — set it to whatever the Govee Home app shows.

Known SKU families (H619x/H61Cx COB strips, H61Ax/H61Dx neon ropes, H70Cx/H70Bx/H702x string and curtain lights, and more) are detected from discovery and get the right layout and defaults automatically. Any other Govee light can still open the studio from its context menu.

Segment layouts are captured into scenes, restored by undo/redo, re-applied after Identify flashes, and survive stopping an animated effect. The demo workspace includes a simulated COB strip and string lights so the studio can be explored without hardware.

Open the studio from the segment row on a light, or right-click → **Segment Studio…**.

### Rooms

Rooms are user-defined groups of lights. A room can contain lights from either vendor, and room actions fan out to all assigned lights.

Room features include:

- Create, rename, reorder, and delete rooms.
- Assign or unassign lights.
- Drag-and-drop assignment from the unassigned area into rooms.
- Collapse and expand room sections.
- Favorite rooms.
- View room power status, online/offline counts, pending command counts, and active schedules.
- Turn an entire room on or off.
- Set room brightness.
- Set room color.
- Set room white temperature.
- Apply themes and animated effects to a room.
- Pause and resume automation for a room.

Deleted rooms can be restored with the app's undo affordances when available.

### Favorites

LumenDesk has a favorites strip for fast access to important items. Favorites can include:

- Individual lights.
- Rooms.
- Scenes.

Favorites are persisted and ordered, so the shortcuts you pin remain available across app launches.

### Search, filters, and layout

The main workspace includes tools for finding and narrowing what you see:

- Search text persisted across launches.
- Search scopes for all content, lights, rooms, or scenes.
- Filter to only powered-on lights.
- Filter to offline devices.
- Filter by vendor.
- Automatic, list, and grid workspace layouts.
- Comfortable and compact density modes.

Press **⌘F** to focus search in the main workspace.

### Bulk selection and group actions

Selection mode lets you pick multiple visible lights and apply actions in one step. Bulk actions include:

- Turn selected lights on.
- Turn selected lights off.
- Adjust selected brightness.
- Assign selected lights to a room.
- Clear or exit selection.

The app warns when selected devices are hidden by active filters, so you know if a bulk action includes lights you cannot currently see.

### Scenes

A scene is a saved lighting snapshot. Scenes include named per-device states such as:

- Power state.
- Brightness.
- Hue and saturation.
- White color temperature.
- Govee segment layouts (per-segment colors, per-segment brightness, gradient), when one is showing.

Scene features include:

- Save the current lighting state as a named scene.
- Search saved scenes.
- Rename scenes.
- Delete scenes.
- Favorite scenes.
- Preview/rehearse scenes before committing them.
- Apply scenes with options around whether devices may be turned off.
- Track scene revisions and drafts.
- Undo recent scene-related changes where supported.

Open the Lighting Library with **⇧⌘S**.

### Lighting themes

The Lighting Library includes 18 curated static themes across four categories:

- Nature.
- Atmosphere.
- Celebration.
- Focus.

Themes include palettes such as Aurora Veil, Afterglow, Tidepool, Forest Bath, Wildflowers, Moon Garden, Ember & Ash, Candy Cloud, Synthwave, Arcade Tokens, Festival Lanterns, Ice Cream Social, Deep Work, Reading Nook, Creative Spark, Quiet Mind, Desert Modern, and Pocket Galaxy.

Themes can be applied to all lights or to a specific room.

### Music Mode

Music Mode is a first-class section of the Lighting Library. It turns the existing `music-pulse` effect into a configurable choreography session while preserving that identifier for saved-state compatibility.

- Built-in presets: Ambient, Balanced, Concert, Cinematic, and Soundcheck, plus a persisted Custom configuration.
- Beat, bass, percussion, color-change, brightness, movement, silence, palette, and restoration controls.
- Explicit left-to-right, front-to-back, circular, or custom fixture topology. Rooms with no saved topology use deterministic label-and-ID ordering rather than discovery order.
- Vendor-neutral lighting frames translated to combined LIFX HSBK, efficient ordinary Govee LAN color, or volatile Govee RGBIC segment streaming.
- Independent transport ceilings and latest-frame coalescing so a slower bulb does not hold back an RGBIC stream.
- Photosensitivity-safe mode is enabled by default. Flash requests are disabled in safe mode and are always subject to an absolute 3-per-second ceiling plus the user's lower configured limit.
- Reduced Motion limits spatial movement and disables flashes.
- Demo Mode includes LIFX-style bulbs, Govee bulbs, segmented Govee fixtures, and a deterministic synthetic rhythm with no copyrighted audio.

On macOS the source is system audio and requires Screen Recording permission. On iPhone and iPad the source is the microphone and is labeled accordingly. See [Music Mode architecture](MUSIC_MODE_ARCHITECTURE.md) for the data flow and safety boundaries.

### Animated effects

The Lighting Library includes the following non-music animated effects:

- Color Flow.
- Ocean Wave.
- Breathe.
- Candlelight.
- Firefly Field.
- Prism Shuffle.
- Summer Storm.
- Golden Sunrise.
- Slow Sunset.

Effects can run against all lights or a specific room. Multiple effects may run at the same time as long as their device scopes do not overlap. Effects can be stopped individually or all at once, and LumenDesk can restore previous light states when stopping effects.

Soundcheck now lives inside Music Mode as a built-in compatibility preset.

### Schedules and automation

Each room can have schedules. Schedule entries support:

- Enable/disable per entry.
- Weekday selection.
- Fixed hour and minute.
- Offset minutes for solar-style entries.
- Actions such as turning on, turning off, or dimming to common brightness levels.
- Sunrise and sunset style actions using configurable sunrise/sunset times.

Automation controls include:

- Pause until the next schedule.
- Pause for one hour.
- Pause until manually resumed.
- Resume room automation.
- Review missed automations.

LumenDesk checks schedules periodically while the app is running.

### Nap Mode

Nap Mode is a one-click lighting routine intended for rest:

1. Gradually dims active lights.
2. Holds them low.
3. Brightens them gently again.

The header button shows the current nap countdown and can cancel an active nap routine.

### Undo, redo, and recovery

LumenDesk tracks recent lighting changes and supports:

- **⌘Z** to undo a light change.
- **⇧⌘Z** to redo a light change.
- Undo prompts for some destructive actions such as deleted rooms or scenes.
- Toasts for command failures with recovery actions when possible.
- Command cancellation for queued light commands with **⌘.** on macOS.

### Diagnostics and activity history

LumenDesk includes operational tools for understanding what the app is doing:

- Diagnostics Center.
- Activity Log.
- Discovery Inbox.
- Missed Automations view.
- Command state tracking: queued, sending, applied, failed, confirmed.
- Confirmed device state tracking.
- Exportable activity history.

These tools are useful when diagnosing Wi-Fi isolation, offline bulbs, unsupported Govee devices, or command failures.

### macOS menu bar controller

On macOS, LumenDesk also installs a menu bar extra. The menu bar controller can show different scopes depending on settings:

- Favorites.
- Active rooms.
- All rooms.

It gives quick access to common lighting controls without opening the full window. The menu bar icon reflects the current aggregate mood color of powered-on lights.

### Import and export

On macOS, use the app menu commands to export or import a JSON configuration.

Export includes app-managed configuration such as:

- Rooms.
- Favorites.
- Favorite ordering.
- Scenes.
- Custom light names.
- Brightness presets.
- Sunrise and sunset preferences.
- White-mode preferences.

Import replaces the current local configuration and shows a warning before overwriting rooms, scenes, favorites, and custom names.

### Demo Mode

Demo Mode lets you explore LumenDesk without controlling physical lights. In demo mode, the interface uses sample lights and rooms, shows a clear **SAFE DEMO** banner, and provides a **Return to Live** action.

Demo Mode is useful for screenshots, testing UI flows, or learning the app before scanning your real network.

### Accessibility and interface preferences

The UI honors system accessibility settings where applicable, including reduced motion and reduced transparency. Interface preferences include:

- Quiet Interface.
- Aurora Firefly ambient overlay toggle.
- Workspace layout.
- Interface density.
- Menu bar content scope.
- Menu bar urgent-only mode.
- Confirmation policy.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘R` | Scan for lights |
| `⇧⌘P` | Toggle all lights |
| `⌘.` | Cancel queued light commands |
| `⌘Z` | Undo light change |
| `⇧⌘Z` | Redo light change |
| `⌘F` | Focus search |
| `⇧⌘S` | Open the Lighting Library |

The app also includes an in-app Keyboard Shortcuts view.

## Requirements

### Development requirements

- macOS 13 Ventura or later for Mac development.
- Xcode 15 or later.
- SwiftUI-compatible Apple platform SDKs.
- Optional: XcodeGen if you want to regenerate the Xcode project from `project.yml`.

### Runtime requirements

- Mac or iPhone on the same Wi-Fi/LAN as the bulbs.
- Local Network permission accepted on iOS.
- LIFX bulbs reachable by UDP on the local network.
- Govee bulbs with **LAN Control** enabled.
- A network that allows device-to-device UDP traffic.

## Building and running

### Run on macOS

1. Open `LumenDesk.xcodeproj` in Xcode.
2. Select the `LumenDesk` scheme.
3. Choose **My Mac** as the run destination.
4. Press **⌘R**.
5. If prompted by macOS firewall or privacy dialogs, allow local network communication.
6. Run a scan from the app or with **⌘R**.

### Run on iPhone

1. Connect your iPhone over USB, or pair it wirelessly from **Window → Devices and Simulators** in Xcode.
2. Open `LumenDesk.xcodeproj`.
3. Select the `LumenDesk` scheme.
4. Choose your iPhone in Xcode's destination picker.
5. In **Signing & Capabilities**, select your Apple ID team. A free personal team is enough for local development.
6. Press **⌘R**.
7. If iOS blocks the unsigned developer app, approve it in **Settings → General → VPN & Device Management**.
8. Launch LumenDesk and accept the **Local Network** permission prompt.
9. Run discovery.

### iOS discovery behavior

Apple restricts UDP broadcast and multicast on iOS unless the app has the restricted `com.apple.developer.networking.multicast` entitlement. To remain usable without that entitlement, LumenDesk falls back to a unicast sweep on iOS:

- It probes addresses on the local `/24` subnet.
- It sends LIFX discovery probes to UDP `56700`.
- It sends Govee scan messages to UDP `4001`.
- Bulbs reply unicast when they support the relevant LAN protocol.

This works on many home networks. If your network is larger than a `/24`, only the nearby `/24` address range is probed unless you add the multicast entitlement and update the project capabilities.

## Optional: regenerate the Xcode project

If you prefer to regenerate the project from `project.yml`, install XcodeGen and run:

```sh
brew install xcodegen
xcodegen generate
```

This rewrites `LumenDesk.xcodeproj` from the declarative project configuration.

## How to use LumenDesk

### 1. Prepare your network

- Put your Mac or iPhone and bulbs on the same Wi-Fi/LAN.
- Disable client isolation for the Wi-Fi network used by the bulbs.
- Avoid guest networks unless they explicitly allow local device communication.
- For Govee, enable **LAN Control** for each supported device in the Govee Home app.

### 2. Discover lights

- Open LumenDesk.
- Complete or skip onboarding.
- Click **Scan** or press **⌘R**.
- Wait for discovered lights to appear.
- Open the Discovery Inbox if you want to review new, changed, or missing devices.

### 3. Name and organize lights

- Rename lights so they match their physical location.
- Create rooms such as Living Room, Office, Bedroom, or Kitchen.
- Assign each light to a room.
- Pin frequently used lights, rooms, or scenes as favorites.

### 4. Control lights

- Use each light row for individual power, brightness, color, and white temperature.
- Use room controls to change every light in a room.
- Use the global controls to affect all lights.
- Use selection mode for temporary groups.

### 5. Save scenes

- Set your lights exactly how you want them.
- Open the Lighting Library with **⇧⌘S**.
- Go to **My Scenes**.
- Save the current lighting state with a meaningful name.
- Favorite the scene if you want it in the favorites strip or menu bar.

### 6. Apply themes and effects

- Open the Lighting Library.
- Choose **Themes** for curated static palettes.
- Choose **Effects** for animated lighting.
- Pick whether to apply to all lights or a room.
- Stop effects from the library header or room controls when finished.

### 7. Add schedules

- Open a room's menu.
- Choose **Edit Schedules**.
- Add a schedule entry.
- Pick weekdays, time or solar-style timing, and an action.
- Use automation pause controls when you want to temporarily stop scheduled changes.

### 8. Use the menu bar on macOS

- Open the LumenDesk menu bar extra.
- Control favorites or rooms quickly.
- Change what appears in the menu bar from Settings.

### 9. Back up configuration

- On macOS, choose **Export Configuration…** from the app commands.
- Save the JSON file somewhere safe.
- Use **Import Configuration…** to restore or move the setup to another Mac.

## Project layout

```text
LumenDesk/
├── LumenDeskApp.swift              # App entry point, macOS commands, settings scene, menu bar extra
├── ContentView.swift               # Main workspace, header, search, filters, bulk actions, shortcut sheet
├── Theme.swift                     # Shared colors, materials, shape helpers, and visual styling
├── Info.plist                      # Local network and platform privacy metadata
├── LumenDesk.entitlements          # Sandbox and network entitlements
├── Models/
│   ├── GoveeSegments.swift         # Segment capability catalog, layouts, and presets for Govee RGBIC devices
│   ├── LightDevice.swift           # Brand-agnostic light model
│   ├── LightingCatalog.swift       # Built-in themes and animated effects
│   ├── LightingScene.swift         # Saved scene model
│   ├── Room.swift                  # Room and light-scope models
│   ├── ScheduleEntry.swift         # Schedule actions and schedule entries
│   └── UXEnhancements.swift        # Diagnostics, preferences, activity, revisions, menu-bar models
├── Services/
│   ├── AudioLevelMonitor.swift     # Local audio-level measurement for music-reactive effects
│   ├── LightManager.swift          # App state, persistence, commands, schedules, scenes, effects, undo/redo
│   ├── UDPSocket.swift             # BSD socket UDP wrapper for broadcast, multicast, and unicast traffic
│   ├── LIFX/
│   │   ├── LIFXClient.swift        # LIFX discovery and command transport
│   │   └── LIFXProtocol.swift      # LIFX packet builders and parsers
│   └── Govee/
│       ├── GoveeClient.swift       # Govee discovery and command transport
│       └── GoveeProtocol.swift     # Govee LAN JSON messages
└── Views/
    ├── FavoritesStripView.swift    # Favorite lights, rooms, and scenes
    ├── GoveeSegmentEditorView.swift # Segment Studio: per-segment painting for Govee RGBIC devices
    ├── LightRowView.swift          # Per-light controls
    ├── MenuBarPopoverView.swift    # macOS menu bar UI
    ├── OnboardingView.swift        # First-run guided setup
    ├── RoomSectionView.swift       # Room controls, schedules, room menus, room effects
    ├── ScenesView.swift            # Lighting Library: scenes, themes, and effects
    ├── ScheduleEditorView.swift    # Room schedule editor
    └── UXCenterViews.swift         # Diagnostics, activity log, settings, discovery, missed automation views
```

## Troubleshooting

### No bulbs found

- Confirm the computer/phone and bulbs are on the same LAN or VLAN.
- Make sure the Wi-Fi network does not enable client isolation.
- Avoid guest Wi-Fi networks for either the controller or bulbs.
- Check that your firewall allows LumenDesk to send and receive local UDP traffic.
- Try running Scan again after power-cycling a bulb.

### Govee bulbs do not appear

- Open the Govee Home app.
- Select the device.
- Open device settings.
- Enable **LAN Control**.
- Confirm the model supports Govee's LAN API.
- Quit other LAN-control tools that might already be bound to UDP `4002` on the same machine.

### LIFX bulbs appear but do not respond

- Check that the bulbs and controller are on the same subnet.
- Some routers treat broadcast and UDP replies differently across bands or VLANs; try the same Wi-Fi band.
- Reboot the bulb and scan again.
- Confirm no firewall rule is blocking UDP `56700`.

### iPhone finds fewer lights than Mac

- iOS discovery may be using the unicast `/24` fallback if the app does not have Apple's multicast entitlement.
- Make sure the iPhone's IP address is in the same `/24` range as the bulbs.
- If your home network uses a larger or segmented subnet, test from the same Wi-Fi segment as the bulbs.

### Govee bind errors

If LumenDesk reports a bind failure for Govee, another app may already be listening on UDP `4002`. Quit other Govee LAN clients, Home Assistant integrations running locally, command-line experiments, or bridge tools, then reopen LumenDesk.

### Schedules do not fire

- LumenDesk must be running for schedules to be evaluated.
- Confirm the schedule entry is enabled.
- Confirm the selected weekdays include today.
- Check the room automation pause state.
- Review Missed Automations for skipped entries.
- Verify configured sunrise and sunset times if using solar-style actions.

### Segment colors do not change

- Confirm the device is a segmented RGBIC model (COB strip, string lights, neon rope, curtain). Single-zone bulbs and plain RGB strips ignore segment commands.
- Make sure **LAN Control** is enabled and normal color changes from LumenDesk already work.
- If the strip's zones don't line up with the editor, adjust the segment-count stepper in the Segment Studio to match what the Govee Home app shows for the device.
- Live preview and applied layouts are separate: preview uses a volatile streaming mode, while **Apply to Light** writes the durable state. If a layout disappears when the studio closes, it was previewed but never applied.
- On string, curtain, and permanent-outdoor lights (H70Cx, H70Bx, H702x, H705x), applied layouts are **held by LumenDesk**, not stored in the light — their firmware has no segment memory. The layout re-applies automatically while LumenDesk runs; if LumenDesk quits, the lights fall back to their built-in state until it next launches.
- A firmware update in the Govee Home app can help on devices that predate LAN segment support.

### Music Mode does not respond

- On **macOS**, Music Mode reacts to **system audio from any app**. Make sure something is actually playing; there is no musical input to analyze during silence.
- Grant **Screen Recording** to LumenDesk (macOS) or **microphone** access (iOS) when prompted.
- Open **Lighting Library → Music Mode**, choose a preset and scope, then select **Start**.
- Confirm the audio is loud enough for the input being monitored.
- Stop and restart Music Mode after changing permissions.

### Music Mode and system audio (Screen Recording, macOS)

On macOS, Music Mode analyzes the **system-audio mix** as its **only** source. It is not an Apple Music-specific feed and does not use the microphone, so room noise never mixes into the analysis. System audio is captured through ScreenCaptureKit, which macOS gates behind the **Screen Recording** permission:

- The first time you start Music Mode without the permission, macOS shows the Screen Recording prompt. Turn on **LumenDesk** in System Settings, return to LumenDesk, and start Music Mode again. LumenDesk re-checks the permission live on every start, so a relaunch is normally unnecessary.
- If the permission is still off, LumenDesk shows a message pointing you to **System Settings → Privacy & Security → Screen & System Audio Recording** (called **Screen Recording** before macOS 15). Enable LumenDesk there and start Music Mode again.
- macOS shows the permission prompt only the first time; after that LumenDesk points you to System Settings instead. LumenDesk **never** silently falls back to the microphone on macOS — if it can't read system audio, it tells you why instead of reacting to room noise.

> **Note (developer builds):** Debug builds disable Xcode's automatic Launch Services registration so test products in temporary DerivedData folders do not become permission-relaunch candidates. Music Mode refreshes the currently running bundle's registration immediately before asking for access. A Screen Recording grant is also tied to the app's code signature. An unsigned or ad-hoc-signed build (the default when no development team is set) can still be re-prompted after rebuilding; set `DEVELOPMENT_TEAM` in `project.yml` for a stable signing identity.

On **iOS**, Music Mode uses the **microphone** (there is no system-audio capture on iOS); grant microphone access when prompted.

## Protocol references

- LIFX LAN protocol: <https://lan.developer.lifx.com/docs>
- Govee LAN API: <https://app-h5.govee.com/user-manual/wlan-guide>
- Govee `razer` streaming packets (community-documented, used for live segment preview): OpenRGB's Govee controller, <https://gitlab.com/CalcProgrammer1/OpenRGB>
- Govee `ptReal` Bluetooth-format command relay (community-documented, used for durable segment layouts): govee2mqtt, <https://github.com/wez/govee2mqtt>

## Development notes

- LumenDesk uses SwiftUI and an `ObservableObject` manager for app state.
- Persistent app state is stored through user defaults and JSON-encoded values.
- Network transport is implemented with local UDP sockets rather than vendor SDKs.
- The app is sandboxed and uses network client/server entitlements for LAN communication.
- The macOS target includes a Settings scene, command menus, import/export panels, and a menu bar extra.
