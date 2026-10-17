# LumenDesk

LumenDesk is a native SwiftUI room-lighting instrument for macOS, iPhone, and
iPad. Direction A, **Room Canvas**, makes the physical room the primary
interface: select and place fixtures directly, shape one composition across
unequal hardware, see what each light confirmed, and restore the room when an
experiment ends.

There is no account, cloud authority, browser client, local web server, or
listening service. LumenDesk talks directly to supported fixtures while the app
is active.

## Room Canvas

- A room-only navigator replaces feature-level destinations.
- The live canvas shows literal fixture colour, output level, reachability, and
  relative placement.
- Selection exposes shared power, brightness, white point, and colour controls.
- Segment, matrix, and panel tools appear only for a fixture with that
  capability.
- Status is explicit: **Confirmed**, **Pending**, **Changed elsewhere**, or
  **Needs attention**. Every state uses wording, geometry, and colour.
- **Add or repair room** is one Prepare → Find/identify → Place → Verify flow.

## Looks

A Look is a saved room composition. The canvas includes immediate Evening,
Reading, Movie, and Bright templates, saved Looks, and **Save current**.
The built-in collection includes 48 curated static themes, all rendered through
the same capability-aware planner.

The Look Composer offers Spatial wash, Gradient, and Exact fixture brushes.
The pure capability renderer distributes one palette across normal bulbs,
Govee RGBIC segments, LIFX Luna zones, and Nanoleaf panels. It states every
adaptation instead of implying all fixtures can render the same detail.

Preview changes real output but remains recoverable: **Restore before preview**
returns the opening snapshot. **Save Look** keeps the preview and stores the
result. Apply and shared controls use the existing per-device command
coordinator, so partial results remain visible beside their fixtures.

Existing saved scenes migrate as Looks without losing device snapshots.

## Live

Live is a foreground room response, not a show-authoring console:

- choose system audio on macOS, microphone on iPhone/iPad, or an audio file;
- choose **Calm**, **Pulse**, or **Spatial**;
- stop and restore the exact opening room state.

Audio analysis is local and is not retained. The simplified surface does not
expose cue stacks, timelines, MIDI mapping, beat-map authoring, schedules, or
unattended automation.

## Supported local hardware

- LIFX LAN bulbs and the LIFX SuperColor Luna matrix
- Govee LAN lights, including recognized RGBIC segment and fixed-zone models
- Nanoleaf Shapes and Aurora, including pairing, controller layouts, per-panel
  designs, and live panel output

Unknown or partially reported hardware falls back to a safe single-colour
capability. Physical output is best-effort: the app distinguishes a sent
command from a state the fixture actually reported.

## Persistence and privacy

Rooms and Looks are ordered first-class rows in
`Application Support/LumenDesk/RoomCanvas.sqlite3`. Supporting capability state
is committed in the same SQLite transaction. The store is schema-versioned and
maintains `RoomCanvas.sqlite3.backup` after every successful save.

On first Direction A launch, the previous `ApplicationState.json` is decoded,
normalized, preserved as `RoomCanvas.sqlite3.legacy.json`, and migrated. Rooms
and scenes become Rooms and Looks. Removed schedule and novelty data remains in
that preserved legacy file but is neither executed nor copied into the active
store.

**Back Up Rooms & Looks** exports portable versioned JSON. Nanoleaf credentials
remain in Keychain and never enter SQLite backups or exported files.

## Build

Requirements:

- Xcode 16 or newer
- macOS 13+ target or iOS/iPadOS 16+ target

Open `LumenDesk.xcodeproj`, select the `LumenDesk` scheme, and build. The target
links the system SQLite library and bundles the licensed DejaVu Sans Condensed
and Open Sans font files in `LumenDesk/Resources/Fonts`.

Command-line verification on macOS:

```sh
xcodebuild \
  -project LumenDesk.xcodeproj \
  -scheme LumenDesk \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
```

The CI workflow also builds a generic iOS device target and runs static
analysis. LAN discovery, permissions, VoiceOver, and real fixture rendering
still require device-level verification.

## Architecture

- `RoomCanvasView.swift` — room session, live canvas, selection inspector,
  Looks, commissioning, and simplified Live UI
- `ThemePlanner.swift` — pure, deterministic capability-aware Look planning
- `LightManager.swift` — foreground command transactions, recovery snapshots,
  observation reconciliation, and vendor orchestration
- `CommandCoordinator.swift` — bounded/coalesced command lifecycle and
  best-effort confirmation
- `SQLiteStateDatabase.swift` — versioned SQLite Rooms/Looks store and backup
- `PersistenceStore.swift` — migration and portable Room/Look archive boundary
- `Services/LIFX`, `Services/Govee`, `Services/Nanoleaf` — native local protocol
  implementations

The source-to-implementation matrix and environment-limited verification log
are in [`docs/direction-a-implementation.md`](docs/direction-a-implementation.md).

## License

LumenDesk source is available under the repository [`LICENSE`](LICENSE).
Bundled font notices are retained beside their binaries in
`LumenDesk/Resources/Fonts`.
