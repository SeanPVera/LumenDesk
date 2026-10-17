# Direction A implementation contract

Direction A is **Room Canvas**, the personal, foreground, Apple-native lighting
instrument specified in *LumenDesk — Three Futures. No Sacred Cows.*, version
1.0, 17 October 2026. The authoritative sources are the supplied
`LumenDesk_Reinvention_Brief.pdf` and `LumenDesk_Visual_Concepts.pdf`. The
reinvention brief is the requirements source; the visual-concepts publication
is a visual reference for A01–A06. Conceptual mockups are translated into
working native interactions rather than treated as implemented software.

## Baseline and repository assessment

- Starting revision: `100996d2cac9d222129dcb9e806c1ae375d2e8c2` on the
  environment-managed `work` branch; the working tree was clean.
- Native application: one SwiftUI macOS/iOS target. `LightManager` is the
  existing global coordinator; `PersistenceStore` writes versioned JSON;
  LIFX/Govee/Nanoleaf transports and Keychain-backed Nanoleaf credentials are
  native.
- Baseline verification: browser client 133/133 tests and production build
  passed; bridge 179/179 tests passed; the 48-theme catalog audit passed;
  `git diff --check` passed.
- Environment limit: this executor has no Xcode or Apple SDK, so native build,
  XCTest, VoiceOver, Full Keyboard Access, and physical-device checks require a
  macOS verification environment.

| Classification | Components | Direction A decision |
| --- | --- | --- |
| RETAIN | LIFX, Govee, Nanoleaf protocol clients; capability models; Keychain credentials; command-state semantics; preview/snapshot/undo/restore; hardware simulators | These are the earned device and recovery intelligence named by A07. |
| REFACTOR | `ThemePlanner`, room anchors, `PersistenceStore`, `LightManager`, menu-bar controller, import/export, onboarding/setup | Reframe as pure Look rendering, scoped room sessions, versioned Room/Look backup, quick room action, and one commissioning flow. |
| REPLACE | Spectrum Studio shell, room lanes, Scenes/Library taxonomy, advanced Music UI, global settings/navigation hierarchy | Replace with the Room Canvas, contextual inspector, Looks, Add or repair, and simplified Live. |
| REMOVE | Schedules/solar product UI and runtime, browser/bridge product, pro-console beat-map/MIDI authoring surfaces, parliament/certification/diary UI and persisted state | Direction A explicitly rejects these categories. Legacy data remains readable during migration where needed, but is not carried into the Direction A durable model. |
| INTRODUCE | Room session store, Room Canvas shell, Look Composer, unified Look shelf, transaction result presentation, observed-change badges, commissioning sequence, SQLite Room/Look store and migration | These are the missing A02–A06 product and architecture systems. |

## Requirement matrix

Status values are limited to: NOT STARTED, IN PROGRESS, IMPLEMENTED, VERIFIED,
BLOCKED, and INTENTIONALLY EXCLUDED. VERIFIED requires evidence in the final two
columns.

| Requirement ID | Direction A requirement | Source reference | User-facing workflow/component | Planned implementation and primary source files | Dependencies | Status | Verification method | Verification evidence | Known deviation / limitation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DA-001 | Make LumenDesk a foreground Apple-native personal instrument organized by the physical room. | Direction A thesis, p.11; comparison p.35 | App launch and primary workspace | Replace `LumenDeskShellView` with a room-only native shell in `RoomCanvasView.swift`; remove hidden-service assumptions. | Existing native target | IMPLEMENTED | Native build and launch; source review | `RoomCanvasShellView` is the only app root; Xcode CI pending. | Apple runtime unavailable here. |
| DA-002 | Use Graphite `#20272B`, Canvas `#F4EADF`, Ember `#EF5F4F`, and Verdigris `#35A982`; fixture output colors remain literal. | A01, p.12 | Whole design system | Replace semantic tokens and accent asset in `Theme.swift` / `Assets.xcassets`. | SwiftUI color system | VERIFIED | Token audit; rendered capture | Exact four hex anchors confirmed in `Theme.swift`; catalog audit passed. | None. |
| DA-003 | Use DejaVu Sans Condensed for architectural display rhythm and Open Sans for labels/controls. | A01, p.12 | Titles, labels, controls | Bundle licensed font resources and map `LumenType` through Dynamic-Type-aware custom fonts. | Font resources; Info.plist | IMPLEMENTED | Bundle/font-name check; rendered capture | Four exact font binaries, licenses, PostScript names, plist entries, and Xcode resource are present; runtime render pending. | Runtime registration and visual fidelity still await the macOS CI render. |
| DA-004 | Status must combine wording, geometry, and color for Confirmed, Pending, Changed elsewhere, and Needs attention. | A01, p.12 | Canvas, inspector, transactions | Add reusable `RoomCanvasStatus` and badges with icons/shapes and accessible labels. | Command and observed state | IMPLEMENTED | Unit/source audit; VoiceOver manual check | Status enum/badge and external-change test added; XCTest pending. | Manual assistive-tech check blocked here. |
| DA-005 | The selected room is a live, direct-manipulation canvas with fixtures placed spatially. | A02, p.13; comparison pp.36–38 | Live Canvas | Build `RoomCanvasView` over persisted room anchors; select and reposition fixtures directly. | Room anchors; device projections | IMPLEMENTED | Selection/placement tests; rendered interaction | Canvas selection, drag, persisted anchors, and accessible move actions implemented; render/test pending. | None. |
| DA-006 | Primary navigation is rooms, with Add or repair attached to the room list—not six global destinations. | A02, p.13 | Room navigation | Room sidebar on macOS; native room navigation on iOS; contextual sheets only. | Rooms | IMPLEMENTED | Navigation source/interaction review | Source audit finds only room navigation plus contextual sheets. | None. |
| DA-007 | Selection exposes fixture names plus shared brightness and white point, with honest mixed and partial state. | A02, p.13 | Selection inspector | Scoped selection in `RoomSessionStore`; capability-safe aggregate controls; per-fixture result list. | Existing command APIs | IMPLEMENTED | Multi-selection tests; manual UI review | Shared scoped controls observe child devices; aggregate test updated; XCTest pending. | None. |
| DA-008 | Device-specific segment, matrix, panel, and Live controls appear only when the selected capability needs them. | A02/A06/A07, pp.13,17–18 | Contextual inspector | Reuse proven advanced editors as contextual inspectors and remove them from top-level navigation. | Capability detection and editors | IMPLEMENTED | Capability routing tests | Capability routing reaches Govee, Luna, and Nanoleaf editors only from one selected fixture. | None. |
| DA-009 | The live canvas offers a room Look shelf and Save current. | A02, p.13 | Look recall/capture | Present saved Looks/templates at the canvas foot; capture applied output only. | Existing snapshots | IMPLEMENTED | Capture/apply persistence test | Templates, migrated/saved Looks, recall, delete, and Save current are wired to `LightManager`. | None. |
| DA-010 | Compose one Look across unequal fixtures with Spatial wash, Gradient, and Exact fixture brushes. | A03, p.14 | Look Composer | Add `LookComposerView`, brush model, palette selection, spatial preview, and exact-fixture mode. | Pure renderer; room anchors | IMPLEMENTED | Renderer and composer state tests | Composer implements all three brushes, room/selection scope, palette, preview, and save. | None. |
| DA-011 | Adapt a Look honestly: solid bulbs hold one palette color while strips/walls carry spatial detail. | A03, p.14 | Composer adaptation summary | Promote `ThemePlanner` as `LookRenderer`; show `ThemePlan.adaptationSummary` and per-fixture results. | Existing capability planner | IMPLEMENTED | Existing/new planner tests | Existing pure planner drives preview/output and composer adaptation disclosure. | None. |
| DA-012 | Preview is volatile and visibly unsaved; Apply/Save is durable; Restore before preview returns the snapshot. | A03/A05/A07, pp.14,16,18 | Look Composer | Session snapshot and explicit preview/apply/save/restore lifecycle. | Recovery APIs | IMPLEMENTED | Lifecycle tests; hardware/manual verification | Rehearsal snapshot/restore and keep-on-save paths implemented; lifecycle XCTest pending. | Physical output/restore remains unverified without hardware. |
| DA-013 | Commission through Prepare → Find/identify → Place on canvas → Verify, including manual endpoint or repair in context. | A04/A05, pp.15–16 | Add or repair | Replace fragmented setup with `RoomCommissioningView`; reuse discovery/pairing/identify, then placement and verification. | Discovery and pairing | IMPLEMENTED | Flow tests; partial/error-state review | Prepare/Find/Place/Verify flow uses real scan, identify, assignment, anchors, pairing, and status. | Multicast discovery and pairing require real-network follow-up. |
| DA-014 | A room is usable immediately after verification; setup, naming, assignment, and placement are one sequence. | A04/A05, pp.15–16 | Commission completion | Commit membership/name/anchor together and return to the live room. | Room mutations | IMPLEMENTED | State-transition test | Placement anchors are committed with membership before returning to the selected room. | None. |
| DA-015 | Repair and diagnostics live beside the failing fixture. | A05/A07, pp.16,18 | Inline repair | Contextual repair disclosure in inspector; no top-level diagnostics destination. | Existing diagnostics data | IMPLEMENTED | Offline/failure-state review | Per-fixture status, retry, identify, and advanced editor are contextual; top-level diagnostics removed. | Physical recovery behavior remains unverified without hardware. |
| DA-016 | Music becomes Live: select room/input, choose Calm, Pulse, or Spatial, then Stop + restore. | A05/A07, pp.16,18; comparison p.38 | Live mode | Build `RoomLiveView` over existing capture/analyzer/session/render engine with only three safe response presets. | Existing Music engine | IMPLEMENTED | Lifecycle and preset mapping tests | Live maps Calm/Pulse/Spatial to the retained engine with local-audio consent and restore-on-stop. | None. |
| DA-017 | Remove authored cue stacks, MIDI mapping, advanced beat-map workflow, and pro-console framing from the product. | A05/A07, pp.16,18; matrix p.39 | Live mode/product boundary | Remove those UI paths and persistence from Direction A; retain internal analysis required for reliable response. | Music engine boundaries | IMPLEMENTED | Source search; native build | Advanced Music UI and MIDI entitlement removed; only internal DSP/legacy decode types remain. | Internal MIDI and beat-map implementation types remain compiled for engine/backward-config compatibility but are unreachable and unentitled. |
| DA-018 | Room Session Store owns view/session state only and keeps desired and observed state distinct. | A06, p.17 | Room session | Introduce `RoomSessionStore`; domain/device truth stays in services. | Observable SwiftUI state | IMPLEMENTED | Store transition tests | `RoomCanvasSessionStore` owns navigation/selection only; transition test added. | None. |
| DA-019 | Use a pure, capability-aware Look renderer. | A06, p.17 | Look planning | Reuse/refactor `ThemePlanner` behind `LookRenderer`, with no transport side effects. | Capability models | IMPLEMENTED | Deterministic renderer tests | `ThemePlanner` remains deterministic and transport-free; native unit suite pending. | None. |
| DA-020 | Commands run as bounded transactions and expose partial results per fixture. | A06, p.17; universal requirements p.10 | Apply Look and shared controls | Add room transaction presentation over existing per-device command queue/confirmation data. | `CommandCoordinator` | IMPLEMENTED | Partial-failure tests | Bounded coordinator state drives per-fixture badges and partial Look result feedback. | The existing coordinator records per-fixture lifecycle rather than keeping a separate durable batch history. |
| DA-021 | Reconcile observed state so external changes stay visible rather than being silently overwritten. | A06, p.17 | Canvas/status | Derive Changed elsewhere from desired/confirmed/revision state and require explicit reapply. | Device command state | IMPLEMENTED | External-change state tests | Observed-state comparison and acknowledge flow implemented; callback test added. | External-control behavior is simulated through protocol callbacks; physical app-to-app control is unverified. |
| DA-022 | Retain vendor-specific native actors/transports and best-effort confirmation semantics. | A06/A07, pp.17–18 | Hardware control | Keep verified protocol implementations; clarify actor/service ownership where safe. | Existing clients | IMPLEMENTED | Existing protocol/unit tests; native tests | Vendor transports are unchanged except transition plumbing; existing protocol tests await CI. | Full Swift tests blocked here. |
| DA-023 | Persist Rooms and Looks in versioned SQLite; keep credentials in Keychain; support migrations and backup. | A06, p.17; comparison pp.37,39–40 | Relaunch, migration, backup | Introduce SQLite-backed state with JSON migration/backup compatibility; keep Nanoleaf secrets out of exports. | SQLite3; Keychain | IMPLEMENTED | Migration/round-trip/corruption tests | SQLite rooms/looks tables, schema version, transaction backup, JSON migration, and recovery tests added. | Supporting capability state is one versioned metadata blob; Rooms and Looks are the first-class ordered tables. |
| DA-024 | Consolidate scenes, themes, designs, presets, and favorites into one Look recall model; migrate rooms/scenes to rooms/Looks. | A07, p.18; matrix pp.39–40 | Looks | Add unified Look item/source and migration; remove category-driven Library UI. | Existing scene/theme/design data | IMPLEMENTED | Migration and recall tests | Scenes migrate/appear as Looks; themes compose through the same renderer; device-only presets remain contextual. | Unscoped device presets cannot be migrated honestly; they stay contextual until captured as a room Look. |
| DA-025 | Remove built-in schedules and solar automation; make no unattended guarantee. | A06/A07, pp.17–18; matrix p.39 | Product/runtime | Remove schedule UI/timer/runtime from Direction A and exclude schedules from migrated durable state/backups. | Persistence migration | IMPLEMENTED | Source search; idle/runtime audit | Schedule UI removed, no scheduler is started, and active persistence/import strips schedule/solar state. | Legacy Codable types and dormant mutation/test helpers remain compiled to preserve old data; no UI, timer startup, or active persisted schedule survives. |
| DA-026 | Remove the browser client and local bridge product. | A07, p.18; matrix p.39 | Distribution/product surface | Delete `web/` and bridge packaging/docs/workflows after native replacement is established. | Repository cleanup | VERIFIED | File/workflow search | `web/`, bridge package/workflows/scripts, and browser release path are absent; baseline results retained below. | Baseline tests recorded before removal. |
| DA-027 | Remove parliament, certification, and persistent diary novelty state. | A07, p.18; matrix p.39 | Product/persistence | Remove UI, model, persistence, migration carry-forward, and docs. | Persistence migration | IMPLEMENTED | Source search; migration tests | Novelty UI removed and active store normalization clears novelty state; decoder-only model fields remain for migration. | Decoder-only novelty model fields remain for non-destructive legacy migration. |
| DA-028 | Retain the menu-bar controller as quick room action only. | Feature matrix p.39 | Menu bar | Rebuild popover around room choice, power/level, and Look recall. | Existing `MenuBarExtra` | IMPLEMENTED | Source review; macOS interaction | Popover exposes one room, power, level, Looks, scan, and open-app only. | macOS interaction blocked here. |
| DA-029 | Demo becomes a Sample Room, not a separate feature universe. | Feature matrix p.39 | Empty state/onboarding | Keep isolated simulation but present one sample room using normal Room Canvas flows. | Demo controller | IMPLEMENTED | Demo isolation tests; rendered review | Demo controller produces one isolated Sample Room and one Sample Evening Look; tests updated. | None. |
| DA-030 | Import/export becomes a versioned Room/Look backup and never exports credentials. | Feature matrix p.39; A06 p.17 | Backup/restore | Replace configuration wording/schema with Room Canvas backup and migration. | Persistence store | IMPLEMENTED | Round-trip/security tests | Menu and README use Room/Look backup language; version checks and Keychain boundary remain enforced. | None. |
| DA-031 | Empty, loading, unavailable, partial-failure, and changed-elsewhere states remain truthful and actionable. | Universal requirements p.10; A01/A05 | All primary workflows | Reusable native state views and inline recovery; no fake operational state. | Command/discovery/session state | IMPLEMENTED | State matrix review | Primary surfaces include scan progress, empty, stale, pending, changed, failure, retry, and restore states. | Some network states require physical devices. |
| DA-032 | Preserve native keyboard, focus, menus, accessibility, resizable layout, reduced motion, and responsive iPhone behavior. | Direct implementation brief §11; A06 p.17 | Whole product | Native containers, accessible canvas alternatives, named actions, adaptive inspector stacking. | SwiftUI/AppKit/UIKit | IMPLEMENTED | Source audit; Apple manual QA | Native containers, adaptive layout, accessible drag alternatives, reduced motion, and platform settings are implemented; manual QA pending. | VoiceOver, Full Keyboard Access, and real iPhone interaction require Apple-device QA. |
| DA-033 | Optimize for input-to-preview latency and energy use without moving DSP work into SwiftUI updates. | Tradeoffs p.40 | Composer/Live | Keep analysis/render loops isolated; throttle preview state and newest-frame transport. | Existing session controller | IMPLEMENTED | Performance tests/instruments | DSP/render loops remain outside SwiftUI; preview reuses bounded transport paths; performance suite awaits CI. | Instruments and physical input-to-photon measurement are not available in this executor. |
| DA-034 | Do not expose a listening service or claim unattended scheduling. | A06 p.17; comparison p.37 | Architecture/copy | Native-only process; no server; explicit foreground copy. | Removal work | VERIFIED | Process/listener/source audit | No browser/server product remains and foreground-only copy/runtime boundaries are explicit. | None. |

## Significant decisions

1. The current Spectrum Studio and historical Plan redesigns are implementation
   material, not design authority. Room Canvas replaces their product hierarchy.
2. Proven transport, renderer, and advanced-fixture code is retained behind
   contextual Room Canvas inspectors; it does not dictate top-level navigation.
3. Existing JSON state is treated as a migration source and backup interchange,
   not the final A06 store. Schedules and novelty state are intentionally omitted
   from the Direction A durable model.
4. The existing Music analysis/render engine remains because A07 retains safe
   live capability. Direction A removes advanced authoring concepts from the
   product surface, not the low-level signal processing that makes Live reliable.
5. Legacy schedule and novelty Codable types remain readable so old state can
   be preserved in the migration sidecar. They have no Direction A route,
   scheduler startup, or active-store payload; removing the decoder types would
   turn a product retirement into silent user-data loss.
6. Device-only Govee and Nanoleaf presets remain available inside their
   contextual capability editors. An unscoped strip/panel preset cannot be
   converted honestly into a room Look until the user captures it in a room.

## Verification log

| Date | Revision | Check | Result |
| --- | --- | --- | --- |
| 2026-10-17 | `100996d` | `git diff --check` | Passed |
| 2026-10-17 | `100996d` | `web/app` tests | 133 passed |
| 2026-10-17 | `100996d` | `web/app` production build | Passed |
| 2026-10-17 | `100996d` | `web/bridge` tests | 179 passed |
| 2026-10-17 | `100996d` | `scripts/audit_lighting_themes.py` | Passed; 48 themes |
| 2026-10-17 | `100996d` | Native Xcode build/test | BLOCKED: Xcode and Apple SDK are unavailable on this Linux executor |
| 2026-10-17 | working tree | Direction A palette/token audit | Passed; exact Graphite, Canvas, Ember, and Verdigris anchors |
| 2026-10-17 | working tree | Bundled-font audit with `fc-scan` | Passed; `DejaVuSansCondensed`, `DejaVuSansCondensed-Bold`, `OpenSans`, and `OpenSans-Semibold` |
| 2026-10-17 | working tree | `scripts/audit_lighting_themes.py` | Passed; 48 themes and README contract |
| 2026-10-17 | working tree | Xcode project reference/bracket audit | Passed; new sources/resources present, retired UI references absent |
| 2026-10-17 | working tree | `git diff --check` | Passed |
