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
- `plutil -lint LumenDesk/Info.plist LumenDesk/LumenDesk.entitlements`.
- `xcrun actool` validation of both asset catalogs.

Other tooling:

- **Brand assets**: `python scripts/generate_brand_assets.py` (needs Pillow) regenerates app icons from `BrandAssets/Logo/`. A separate workflow fails PRs if generated assets under `LumenDesk/Assets.xcassets/AppIcon.appiconset`, `BrandAssets/AppIcons`, or `BrandAssets/Repository` are stale relative to the logo sources.
- **Design prototype** (`design-prototype/`): standalone React/TypeScript/Vite UX mockup with no backend and no real lighting commands. `npm install && npm run dev` (port 4173); `npm run build` type-checks and builds. It is not part of the app build.

## Adding, renaming, or deleting Swift files

`LumenDesk.xcodeproj/project.pbxproj` references every source file explicitly (no file-system-synchronized groups), using hand-maintained synthetic IDs: `A1…` file references, `B1…` build files, `C1…` groups for the app target; `A2…`/`B2…`/`C2…` for the test target. A new `.swift` file does not compile until it appears in the pbxproj. Either:

1. Edit `project.pbxproj` directly, adding a `PBXFileReference`, a `PBXBuildFile`, a group child entry, and a Sources-phase entry, following the existing sequential-ID pattern; or
2. On macOS, run `xcodegen generate` — `project.yml` is the declarative project definition and globs whole directories, so files on disk are picked up automatically.

If you change build settings, change them in `project.yml` as well so regeneration doesn't lose them.

## Architecture

### LightManager and extracted services

`Services/LightManager.swift` (~3,000 lines, `@MainActor ObservableObject`) is the single app-state hub, created once in `LumenDeskApp` and injected via `environmentObject`. All UI-facing state publishes through it, but domain logic is deliberately extracted into focused services that LightManager composes. The services stay SwiftUI-free and take injectable clocks/sleep functions so tests are deterministic:

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

Both clients report discovery and state through delegate protocols back to LightManager. The device model (`Models/LightDevice.swift`) is brand-agnostic; device IDs are vendor-prefixed strings (`lifx:…`, `govee:…`). On iOS, where the multicast entitlement is absent, discovery falls back to a unicast sweep of the local /24.

### Persistence

`PersistedApplicationState` (in `Services/PersistenceStore.swift`) is the versioned structured archive — currently `schemaVersion` 2 — stored as JSON via UserDefaults; lightweight view preferences stay in `UserDefaults`/`@AppStorage` at their call sites with keys like `LumenDesk.workspaceLayout.v1`. Decoding is tolerant by convention: every field decodes with `(try? container.decode(...)) ?? default` so older archives and exports never fail. When adding persisted state, add the property, its `CodingKey`, and a tolerant decode line; bump the schema version when semantics change and supply safe defaults for older schemas (see the Music Mode schema-2 migration for the pattern). Import/export (macOS app menu) round-trips this same configuration.

### Music Mode

Documented in `MUSIC_MODE_ARCHITECTURE.md`; read it before touching the pipeline. Flow: `AudioCaptureService` (ScreenCaptureKit system audio on macOS, AVAudioEngine microphone on iOS) → `MusicFeatureAnalyzer` (FFT features) → `AudioReactiveSessionController` (one render clock, non-overlapping scope sessions) → `MusicChoreographyEngine` (features + `MusicModeConfiguration` + `FixtureTopology` → vendor-neutral `MusicLightingFrame`) → `MusicLightingRenderer` (latest-frame-per-fixture coalescing, independent per-transport rate ceilings) → LightManager (existing scope/conflict/undo/restore rules). Invariants:

- The catalog identifier remains `music-pulse` for saved-state compatibility.
- Live frames never emit persistent `ptReal` writes — RGBIC devices get the volatile razer stream only.
- Photosensitivity-safe mode is on by default; `FlashSafetyLimiter` enforces a non-configurable hard ceiling of 3 flashes/second that no code path may bypass. Reduced Motion also disables flashes.

### Views and navigation

`RootView` (in `LumenDeskApp.swift`) chooses `OnboardingView` on first run, then `LumenDeskShellView` (`Views/ProductShellView.swift`): a macOS `NavigationSplitView` / iOS `TabView` shell with Home, Library, Automation, Devices, and Settings destinations. `ContentView.swift` holds the main workspace (search, filters, bulk selection). macOS-only surfaces — command menus with keyboard shortcuts, the Settings scene, configuration import/export, and the `MenuBarExtra` controller — live behind `#if os(macOS)`, a pattern used throughout.

The app is locked to dark mode. Visual styling comes from the "Aurora Noir" design system: the `Lumen` token namespace in `Theme.swift` is the source of truth in code, `DESIGN_SYSTEM.md` documents the palette/typography/state matrix, and `SWIFTUI_HANDOFF.md` maps the redesign onto existing views.

## Conventions and invariants

- **Scope guard for UI work** (from `SWIFTUI_HANDOFF.md`): visual refactors must not change LAN protocols, discovery, scheduling semantics, scene persistence, held-segment-layout behavior, or command transport. Keep behavioral changes separately testable from presentation changes.
- **Volatile vs. durable segment state**: live preview (razer) is intentionally volatile — closing Segment Studio without applying is a true cancel. Only Apply writes durable state. Devices whose firmware has no segment storage (H60B0 lamps, string/curtain/outdoor lights) get their layouts *held* by LumenDesk and re-applied every 30 s, on reconnect, on power-on, and at launch — don't "fix" that re-apply loop away.
- **Tests** (XCTest, `@testable import LumenDesk`): mirror the existing style — inject `now`/`sleep`/`calendar` instead of sleeping, generate PCM buffers or deterministic feature snapshots for audio paths, and test protocol encoders byte-for-byte (`ProtocolTests`). Coordinator-level behavior (command lifecycle, confirmation, schedules, persistence migration, demo isolation) is where coverage lives; there are no UI tests.
- Debug builds set `REGISTER_WITH_LAUNCH_SERVICES=NO` on macOS so temporary DerivedData builds don't become candidates for the Screen Recording permission relaunch; Music Mode re-registers the running bundle before requesting access. Keep this when touching `project.yml`.
- `README.md` is the detailed user-facing feature reference — update it when behavior, shortcuts, or supported devices change.
