# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

LumenDesk is a native SwiftUI smart-lighting controller for macOS 13+ and iOS 16+ that speaks the LIFX and Govee LAN protocols directly over UDP — local-first, with no cloud accounts, vendor SDKs, or third-party package dependencies (pure Apple frameworks, no SPM/CocoaPods). A single multiplatform `LumenDesk` target builds for both platforms from the same scheme.

## Build and test commands

Building and testing require macOS with Xcode 15+. In a Linux session there is no way to compile Swift here; CI (`.github/workflows/build.yml`) is the verification path — keep changes consistent with what it checks.

```sh
# Run unit tests (LumenDeskTests is a macOS-only test bundle)
xcodebuild -project LumenDesk.xcodeproj -scheme LumenDesk -configuration Debug \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

# Run a single test class or test method
#   append: -only-testing:LumenDeskTests/ScheduleEngineTests
#   or:     -only-testing:LumenDeskTests/DomainTests/testSceneSerialization

# Verify the iOS side still compiles
xcodebuild -project LumenDesk.xcodeproj -scheme LumenDesk -configuration Debug \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

CI additionally runs, before the build steps:

- `git diff --check` on the pushed range — trailing whitespace or whitespace errors fail the build.
- `python3 scripts/audit_lighting_themes.py`, which parses `LightingCatalog.swift` and fails on duplicate/near-duplicate palettes, a dropped original identifier, an unbalanced mood family, a wash theme that doesn't lead with its brightest colour, or a README mood count that has drifted. It then regenerates `THEME_CATALOG.md` and fails if the committed copy is stale.
- `plutil -lint LumenDesk/Info.plist LumenDesk/LumenDesk.entitlements`.
- `xcrun actool` validation of both asset catalogs.

Other tooling:

- **Release packaging**: `scripts/package_macos.sh` archives Release, signs, notarizes, and writes `dist/LumenDesk-<version>.dmg` using only Xcode/macOS tooling (macOS required). It picks a mode from whatever credentials are in the environment: ad-hoc (arm64 will not run a wholly unsigned binary), self-signed (any non-Developer-ID identity, signed during the archive so `exportArchive` and notarization are skipped, which keeps the Screen Recording and Local Network TCC grants stable across rebuilds), Developer ID, or notarized, and `.github/workflows/release.yml` runs it on `v*` tags. `Info.plist` takes its version from `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`, which are declared in `project.yml` — **drop them from `project.yml` and a regenerated project ships an empty version string**. `DISTRIBUTION.md` documents credentials and CI secrets.
- **Brand assets**: `python scripts/generate_brand_assets.py` (needs Pillow) regenerates the app icons **and** the SVGs in `BrandAssets/Logo/`, all from the script's `MASTER`/`MICRO`/`COLORS` constants — so a logo redesign means editing those constants, and hand-editing an SVG is pointless because the next run overwrites it. A separate workflow (triggered by changes to the logo files, the script, or the appiconset) reruns the script on PRs and fails if the committed outputs under `LumenDesk/Assets.xcassets/AppIcon.appiconset`, `BrandAssets/AppIcons`, `BrandAssets/Repository`, or `BrandAssets/Logo` don't match what it generates. The mark is the Plan drawing: an exterior envelope, one dominant room against two smaller ones, and a warm and a cool pool of light on the floors of the two that are lit. `MICRO` carries hand-tuned line weights for 16–64 px, where the master's proportional weights fall under a pixel; 16 and 24 px drop the second partition entirely.
- **Design prototype** (`design-prototype/`): standalone React/TypeScript/Vite UX mockup with no backend and no real lighting commands. `npm install && npm run dev` (port 4173); `npm run build` type-checks and builds. It is not part of the app build. Published to GitHub Pages under `/prototype/`.
- **Web app and bridge** (`web/`): a real browser client for LumenDesk, described in `web/README.md`. `web/bridge/` is a dependency-free Node service (Node 20+) that owns the UDP sockets and exposes a loopback HTTP API; `web/app/` is the Vite/React client, published at the Pages site root and also served by the bridge itself (`npm run app`) so the page and API share one origin — that same-origin route is the supported one, because browsers gate a remote site's access to the local network behind a user permission prompt. Browsers cannot send raw UDP, so the bridge is the only thing that talks to lights — keep protocol logic there, never in the client. `web/bridge/src/lifx.js` and `govee.js` are ports of the Swift encoders and are tested byte-for-byte against the same vectors as `LumenDeskTests/ProtocolTests.swift`; **change the two in lockstep or the bridge and the native app diverge on the wire**. `web/bridge/src/net.js` is the same lockstep pairing for discovery targets: it mirrors `LocalSubnet`/`probeSubnets`, and its tests mirror `NetworkUtilityTests.swift`. `web/bridge/src/nanoleaf.js` is the lockstep port of the Shapes layout parser, geometry, panel numbering and encoders (its tests mirror `NanoleafShapesTests.swift`), and `web/app/src/shapes/geometry.ts` mirrors the wall transform and numbering for the page, which draws from outlines the bridge sends. The Shapes token lives only in `~/.lumendesk/nanoleaf-pairings.json` (mode 0600) and must never reach a response, log line or error message. Client constructors take `sweep: false` so the test harness can point discovery at loopback without spraying the machine running the suite. `npm test` in `web/bridge` runs those plus fake-device integration tests over real UDP on loopback. Rooms, scenes, schedules, favourites and device names persist in `~/.lumendesk/bridge-state.json` via `store.js`; **schedules are evaluated in the bridge** (`schedules.js`, pure and clock-injected like the native `ScheduleEngine`) so they fire with no browser open, and `actions.js` is the single place a vendor-neutral intent becomes real commands for direct control, scene apply and the scheduler alike.
- **Pages deployment** (`.github/workflows/deploy-pages.yml`): builds `web/app` to the site root and `design-prototype` to `/prototype/`, and runs the bridge tests; pushes to `main` deploy, pull requests build without deploying. Because a project site is served from a subpath, both Vite configs take `base` from the `BASE_PATH` environment variable (supplied by `actions/configure-pages`) and default to `/` when unset — keep asset references relative or bundler-resolved so both layouts work.

## Adding, renaming, or deleting Swift files

`LumenDesk.xcodeproj/project.pbxproj` references every source file explicitly (no file-system-synchronized groups), using hand-maintained synthetic IDs: `A1…` file references, `B1…` build files, `C1…` groups for the app target; `A2…`/`B2…`/`C2…` for the test target. A new `.swift` file does not compile until it appears in the pbxproj. Either:

1. Edit `project.pbxproj` directly, adding a `PBXFileReference`, a `PBXBuildFile`, a group child entry, and a Sources-phase entry, following the existing sequential-ID pattern; or
2. On macOS, run `xcodegen generate` — `project.yml` is the declarative project definition and globs whole directories, so files on disk are picked up automatically.

If you change build settings, change them in `project.yml` as well so regeneration doesn't lose them.

## Architecture

### LightManager and extracted services

`Services/LightManager.swift` (~3,000 lines, `@MainActor ObservableObject`) is the single app-state hub, created once in `LumenDeskApp` and injected via `environmentObject`. All UI-facing state publishes through it, but domain logic is deliberately extracted into focused services that LightManager composes, taking injectable clocks/sleep functions so tests are deterministic. Most are UI-framework-free (`CommandCoordinator`, `ConfirmationCoordinator`, `ScheduleEngine`, `PersistenceStore` import no SwiftUI); the exceptions are `AudioReactiveSessionController`, itself an `ObservableObject` with `@Published` state that views observe directly, and `DemoWorkspaceController`, whose snapshots store SwiftUI `Color` values:

- `CommandCoordinator` — vendor-neutral command lifecycle (`queued → sending → applied → confirmed / failed / timedOut / cancelled`), pending-device tracking, expected-vs-confirmed device state, debounce/timeout timing via an injectable `Timing`/`sleep`. Vendor clients only encode packets and transport them.
- `ConfirmationCoordinator` — confirmation policy and the pending-request lifecycle; surfaced through the `managedActionConfirmations` modifier applied in `RootView`.
- `ScheduleEngine` — pure schedule evaluation returning `Decision` values (run/skipped/missed) for LightManager to apply; it never mutates devices or sends commands. Injectable `now` and `Calendar`.
- `DemoWorkspaceController` — owns the isolated demo workspace and the saved live workspace while Demo Mode is active, so demo devices never share mutable state with live ones.
- `PersistenceStore` (`ApplicationPersistence` protocol) — structured state persistence, injectable as a test spy.
- `AudioReactiveSessionController` (exposed as `manager.musicModeController`) — Music Mode session ownership (see below).

Effects are managed inside LightManager as `EffectRun`s: one animated effect per scope, several allowed concurrently as long as device sets don't overlap, each holding a snapshot for restore-on-stop.

### Vendor transport

`Services/UDPSocket.swift` wraps BSD sockets (broadcast, multicast, unicast). On top of it:

- `Services/LIFX/` — `LIFXProtocol` builds/parses binary LAN packets; `LIFXClient` discovers via UDP broadcast on 56700 (`GetService`) and sends power/HSBK/matrix commands. LIFX Luna matrix support (product IDs 219/220) lives in `Models/LIFXMatrix.swift`.
- `Services/Govee/` — `GoveeProtocol` builds LAN JSON messages; `GoveeClient` discovers via multicast `239.255.255.250:4001`, binds UDP 4002 for replies, commands on 4003. Two community-documented extensions handle RGBIC segments: `razer` (volatile real-time streaming, used for live preview and Music Mode frames) and `ptReal` (relays Govee Home's 20-byte BLE-format commands for durable segment layouts). `GoveeClient` paces commands ≥0.1 s apart per device and coalesces same-kind payloads to the newest, because Govee firmware drops back-to-back datagrams.

- `Services/Nanoleaf/` — Shapes over the documented local HTTP API (port 16021, Keychain pairing). `NanoleafClient` runs one ordered, coalescing lane per controller, the `GET /events` stream, and the external-control v2 UDP stream (port 60222, paced to 10 Hz, owner-scoped). `NanoleafLayout`/`NanoleafTopologyParser` parse layouts strictly by controller + panel ID; `NanoleafGeometry` draws from shape type (never the deprecated `sideLength`) and holds the one clockwise wall transform used for drawing, hit testing, numbering, themes, effects and Music Mode. `NanoleafShapesController` owns walls, output claims (design, preview, stream), editing sessions and the Demo Mode simulated wall. Rules easy to break: orientation and designs count only once a reading taken **after** the write confirms them (`awaitingWrite`); master brightness is a multiplier, so static designs carry each panel's level in RGB and streams hold master brightness at full and restore it; LumenDesk never deletes controller scenes and asks before replacing one; test vectors come from Nanoleaf's documentation or Hyperion, never from the encoder under test. Shapes files use the `A3…`/`B3…` pbxproj IDs.

LIFX and Govee clients report discovery and state through delegate protocols back to LightManager; `NanoleafClient` reports through closures (`onUpdate`, `onEvent`, `onStreamStatus` and others) that LightManager sets. The device model (`Models/LightDevice.swift`) is brand-agnostic; device IDs are vendor-prefixed strings (`lifx:…`, `govee:…`).

Discovery never relies on a single broadcast. `LocalSubnet` (in `UDPSocket.swift`) enumerates every usable IPv4 interface from `getifaddrs` — netmask included, tunnels and Apple's peer-to-peer radios excluded — and `UDPSocket.probeSubnets` aims one pass at each interface's subnet-directed broadcast, the limited broadcast, and every host on those subnets, on **both** platforms. Limited broadcast and unpinned multicast follow the default route, which on a machine holding a VPN route is the wrong interface; Govee multicast is therefore sent and joined per interface via `IP_MULTICAST_IF`/`ip_mreq`. The broadcast targets are sent over several spaced rounds because Wi-Fi carries broadcast unacknowledged at the lowest basic rate and a bulb in power save drops it; the unicast sweep is paced in bursts (a tight 253-packet burst returns `ENOBUFS` while ARP resolves) and runs twice with an ARP-warming gap. `LightManager.scanWindow` must stay longer than all of that combined. Each pass returns a `DiscoveryProbeReport`, which is what lets the diagnostics card separate "nothing answered" from "nothing left the machine" — don't reintroduce a `try?` on a discovery send. The report counts `datagramsSent`, `addressesUnoccupied` and `datagramsFailed` **separately**: `EHOSTUNREACH`/`EHOSTDOWN` on a directly-connected subnet is ARP giving up, so it means "no device at that address" and is most of any sweep — folding it into failures made a healthy scan accuse the user's VPN. `ENETUNREACH` stays a failure on purpose.

Address a Govee device by the source address of its reply (`GoveeClient.commandAddress`), never the `ip` field in the scan payload: that field is baked at join time and goes stale across a DHCP renewal, which sent every command to a dead address. `LIFXClient` has always used the source address.

The LIFX and Govee clients must notify their delegate on **every** discovery response, not only when the address changed. LightManager folds a repeat into the existing device; suppressing repeats meant a rescan never counted the light or re-marked it seen, and a single dropped callback (Demo Mode swallows live callbacks) hid the light until its address changed or the app restarted.

### Themes

`Models/LightingCatalog.swift` holds 48 static themes. Each is a palette plus a `ThemeDistribution` (`wash`, `anchored`, `gradient`, `alternating`, `scattered`) saying where those colours are meant to land. Identifiers are load-bearing — favourites, intent cards, and saved Music Mode palettes resolve by them — so never rename or repurpose one. The list is built with one `add(...)` call per row rather than as an array literal, for the same type-checker reason `GoveeSegmentProfile` is.

A palette entry is chroma plus level, not a colour. `Models/ThemePalette.swift` (`PaletteTone`) decomposes each hex with its own HSV maths, deliberately not through `NSColor`/`UIColor`, so it is identical on both platforms and in tests. `LightingTheme.normalizedTones` measures every level against the palette's brightest entry and floors it at 0.2. **The colour is sent at full value and the level rides the brightness channel** — LIFX takes hue/saturation/brightness as independent channels and ignores how dark the authored hex was, while Govee takes raw RGB and would dim by it twice. Sending the authored hex makes the same theme land differently on each brand; this is also the shape `applyScene` already restores in, so themes captured into scenes round-trip.

`Services/ThemePlanner.swift` is pure and Foundation-only: a theme plus ordered `ThemeFixture`s (`.solid`, `.segments`, `.matrix`) becomes one `ThemeFixturePlan` per light, carrying tone, brightness, kelvin, an optional `GoveeSegmentState`, an optional `LIFXMatrixState`, and a `ThemeAdaptation` recording what the fixture could not show. `LightManager.applyTheme` plans once, then routes each plan through the existing `applySegments` / `applyLIFXMatrix` / `sendColor` paths with `recordUndo: false, announce: false`, so undo is recorded once for the batch and one toast names any adaptation. Rules that are easy to break:

- A lone `.solid` fixture takes the key colour at the theme's **full** brightness; otherwise a dark-keyed theme would light a one-bulb room at a fraction of what the slider says.
- A `.wash` theme's first colour must be its brightest (within 15%), because that colour fills the whole room. Both the audit script and `LightingThemeTests` enforce it.
- Gradient ramps are quantised to `ThemePlanner.maximumGradientStops` (16), so a 200-bead string doesn't become 200 `ptReal` packets.
- Low-saturation entries carry a white point, since LIFX renders them from kelvin rather than hue. Saturated entries leave the device's kelvin alone.
- A fixture with a `simultaneousZoneLimit` keeps the zones the user already had lit (`preferredZones`), so a theme never moves the light around an H60B0.

Every catalog theme is also a Music Mode palette (`LightingTheme.musicPalette`, `MusicModeConfiguration.selectPalette(_:)`). Identity is recovered by comparing colour lists, not by storing a name, so the persisted schema is untouched and a hand-edited palette reports as custom. **Selecting a palette changes the colours and nothing else** — never `allowsFlashes`, `flashIntensity`, `maximumFlashFrequency`, or `photosensitivitySafeMode`.

### Persistence

`PersistedApplicationState` (in `Services/PersistenceStore.swift`) is the versioned structured archive — currently `schemaVersion` 2 — stored as a JSON file at `Application Support/LumenDesk/ApplicationState.json`, with a one-time migration from the individual `UserDefaults` values earlier releases used. Lightweight view preferences stay in `UserDefaults`/`@AppStorage` at their call sites with keys like `LumenDesk.workspaceLayout.v1`. Decoding is tolerant by convention: every field decodes with `(try? container.decode(...)) ?? default` so older archives and exports never fail. When adding persisted state, add the property, its `CodingKey`, and a tolerant decode line; bump the schema version when semantics change and supply safe defaults for older schemas (see the Music Mode schema-2 migration for the pattern).

Import/export (macOS app menu) does **not** reuse `PersistedApplicationState`: it goes through the separate `ConfigurationArchive` struct in the same file, whose fields are mapped by hand in `exportConfiguration(from:)` and `importingConfiguration(from:into:)`. A property added only to `PersistedApplicationState` persists locally but silently drops out of exported configurations — exportable values must also be added to `ConfigurationArchive` (as optionals, so configurations exported by older versions still import) and to both mappings.

### Music Mode

Documented in `MUSIC_MODE_ARCHITECTURE.md`; read it before touching the pipeline. Flow: `AudioCaptureService` (ScreenCaptureKit system audio on macOS, AVAudioEngine microphone on iOS) → `MusicFeatureAnalyzer` (FFT features) → `AudioReactiveSessionController` (one render clock, non-overlapping scope sessions) → `MusicChoreographyEngine` (features + `MusicModeConfiguration` + `FixtureTopology` → vendor-neutral `MusicLightingFrame`) → `MusicLightingRenderer` (latest-frame-per-fixture coalescing, independent per-transport rate ceilings) → LightManager (existing scope/conflict/undo/restore rules). Invariants:

- The catalog identifier remains `music-pulse` for saved-state compatibility.
- Live frames never emit persistent `ptReal` writes — RGBIC devices get the volatile razer stream only. The web client posts `/music/frame` as a single colour per fixture and must not invent a razer encoder without lockstep `ProtocolTests`.
- Photosensitivity-safe mode is on by default; `FlashSafetyLimiter` enforces a non-configurable hard ceiling of 3 flashes/second that no code path may bypass. Reduced Motion also disables flashes.
- `BeatTracker.beatsPerBar` stays 4. Metre detection is an overlay (`MetreTracker` in the same file) so existing downbeat tests keep passing. Do not add new Swift files without sequential pbxproj A1/B1 IDs.

### Views and navigation

`RootView` selects onboarding or `LumenDeskShellView`. The current shell uses
named Room / Schedules / Devices / Settings navigation on macOS and native tabs
plus Settings access on iOS. `PlanWorkspaceView` is now the selected-room workspace:
Light, Compositions and Music share one `LightScope` binding. `RoomConfigurationView`
and `RoomArrangementSheet` hold advanced organization. The file name Plan remains
for source compatibility; the primary workspace is not the old whole-home drawing.
`ContentView` remains legacy, with shared toast/diagnostic components still used.

The dark visual system is **Light in place**. `Theme.swift` holds neutral tokens;
fixture colors appear as output content. `DesignControls.swift` retains accessible
faders and buttons with native menus, fields, sheets and color pickers. Do not
reintroduce decorative console hardware or an icon-only navigation rail. Read
`DESIGN_SYSTEM.md` and `REDESIGN_REPORT.md` for the current hierarchy and validation.


## Conventions and invariants

- **Scope guard for UI work** (from `SWIFTUI_HANDOFF.md`): visual refactors must not change LAN protocols, discovery, scheduling semantics, scene persistence, held-segment-layout behavior, or command transport. Keep behavioral changes separately testable from presentation changes.
- **Volatile vs. durable segment state**: live preview (razer) is intentionally volatile — closing Segment Studio without applying is a true cancel. Only Apply writes durable state. Devices whose firmware has no segment storage (H60B0 lamps, string/curtain/outdoor lights) get their layouts *held* by LumenDesk and re-applied every 30 s, on reconnect, on power-on, and at launch — don't "fix" that re-apply loop away.
- **Tests** (XCTest, `@testable import LumenDesk`): mirror the existing style — inject `now`/`sleep`/`calendar` instead of sleeping, generate PCM buffers or deterministic feature snapshots for audio paths, and test protocol encoders byte-for-byte (`ProtocolTests`). Coordinator-level behavior (command lifecycle, confirmation, schedules, persistence migration, demo isolation) is where coverage lives; there is no XCUITest target. Opt-in AppKit-hosted production view captures live in RoomPlanningTests; browser interaction/axe review lives in web/app/scripts/visual-review.mjs.
- Debug builds set `REGISTER_WITH_LAUNCH_SERVICES=NO` on macOS so temporary DerivedData builds don't become candidates for the Screen Recording permission relaunch; Music Mode re-registers the running bundle before requesting access. Keep this when touching `project.yml`.
- `README.md` is the detailed user-facing feature reference — update it when behavior, shortcuts, or supported devices change.
