# LumenDesk user flow review

This record covers the everyday-user review and the subsequent complete UX audit.
Browser journeys run against
the production app with simulated bridge responses; bridge tests use simulated
controllers. Native and installer platform checks run in pull-request CI.

## Everyday journeys

The browser review covers connection, empty and offline states, choosing a room,
selecting individual lights, grouped power, brightness, color and white controls,
scene capture and recall, Music Mode,
Nanoleaf panel selection and painting, orientation, pairing errors, room creation
and deletion, schedule creation, and settings. The walkthrough includes narrow
screens, keyboard interaction, reduced motion and accessibility checks.

The native code review covers onboarding, scene editing and rehearsal, partial
scene retries, scheduling through daylight-saving changes, and the schedule
limit. It supplements the browser walkthrough; it does not establish physical
device behavior or native UI behavior.

## Fixes in this change

| User action | Corrected behavior |
| --- | --- |
| The bridge briefly disconnects | The workspace stays open, drafts survive, controls pause, and reconnection runs automatically. |
| A room or scene save fails | The entered name stays available for retry. Pending submissions block duplicates. |
| A panel design or orientation request fails | The draft and panel undo history stay available. |
| A grouped command or scene partly fails | Feedback reports sent and failed or skipped counts. Routine polling keeps the error visible. |
| A saved scene contains an off light | Its preview shows the saved off state. |
| A Nanoleaf controller scene is captured | Recalling the scene restores the controller scene by name. |
| Music cannot restore lights on Stop | Cleanup keeps its original ownership information, retries across section navigation, and finishes before another show starts. New manual edits retain priority. |
| Music capture is denied or a file cannot open | Setup remains editable, including room changes. A later Start captures newly included lights while preserving any previous show's original restoration snapshot. |
| A room is deleted | Confirmation explains light reassignment and schedule deletion. |
| Another client deletes the room being set up | Setup returns to Create or choose room and retains its name and light choices, including after Pause and reopen. |
| An older bridge lacks rooms and saved lighting | Basic light controls stay available; unsupported setup and saved-lighting actions are hidden, with a link to update the bridge. |
| A schedule is submitted repeatedly | Pending creation blocks duplicates. Native schedule creation also explains the 12-rule limit and retains rejected drafts. |
| The bridge resumes after sleep | Missed schedules run in time order using each rule's latest occurrence. |
| A native fixed-time schedule crosses daylight saving | Its local clock time stays correct; missing times move forward and repeated times run once. |
| A native scene retry is requested | Only failed lights receive the original scene version; off protection and successful lights are preserved. |
| A native scene rehearsal is saved or dismissed | Starting lighting is restored. Previous saved scene versions are reached through History. |
| Setup is read with accessibility tools | Skip setup remains a separate accessible control; browser scene and schedule controls have valid names and roles. |
| A slider changes faster than the bridge responds | Per-fixture commands stay ordered, continuous controls keep the latest pending value, and older responses cannot replace newer intent. Changing bridges cancels unsent work. |
| The bridge moves to another port | The published web client's Settings keeps port editing available during an outage. Initial health and lighting-data failures show their own diagnostics immediately. |
| Setup starts without any lights | A room can be created and completed before discovery. Back allows choosing another room, and Nanoleaf pairing works while discovery is running. |
| A Nanoleaf draft is left during navigation | Draft, selection and undo history stay with the wall. A delayed Apply clears only the submitted draft and preserves later edits. |
| Music's page closes, reloads or stops responding | The running bridge restores its exact starting output after a five-second lease. A duplicated tab cannot stop a live show; resumed timers detect expired ownership and show a stopped state. |
| A schedule is deleted | Confirmation names the action, time and room before deletion. |
| Mixed lights or saved scenes are inspected | Group controls label mixed brightness and white values; scene details expose saved power, brightness, color, temperature and panel-design information in text. |
| A phone controls fixtures or panels | Search sits above fixture selection, Music's sticky transport contains only controls/status, and small Nanoleaf panels have numbered touch buttons. |
| An empty native room is selected | Light, Scenes and Music remain available on iPhone and iPad. |
| Native appearance settings are changed | Quiet interface reduces decorative motion/glow, onboarding honors Reduce Motion, iOS text tokens scale with Dynamic Type, and platform-inapplicable or inert controls are hidden. Solar actions explicitly state on/off. |

## Implemented flow improvements

| Improvement | Result |
| --- | --- |
| Complete first-room setup | Find lights → Create or choose room → Assign lights → Try controls. Pause/reopen keeps the draft. Failed creation and partial assignment support retry. No lighting command is sent until a test control is used. Native onboarding also exposes room test controls and keeps live discovery behind setup. |
| Actionable discovery | Real probe diagnostics distinguish failures, fresh replies and silent searches. Vendor preparation covers Govee LAN Control, LIFX network access and manual Nanoleaf pairing. Older bridge results with missing timestamps remain unknown. |
| Bridge without development tools | Mac DMGs, Windows portable ZIP and Linux installable desktop packages bundle the pinned Node runtime, web app and a launcher. CI verifies the extracted distributions, and the release workflow includes them in one release. See [bridge packaging](BRIDGE_DISTRIBUTION.md). |
| Scenes and favorites | Scenes is consistent across platforms. Save current lighting sits beside room controls. Saved scene targets show fixture names, rooms, outside-room impact and unavailable or missing lights before recall. Favorites are visible in the modern native shell and filter browser fixtures. Hidden selections are excluded from grouped controls; scene capture still saves the complete room. |
| Explicit editing | Browser schedules offer Edit with existing values prefilled, Save/Cancel, missing-scene validation and retained failed drafts. Device names use explicit Save/Cancel, with pending, failure and success states. Canonical polls preserve dirty drafts and reconcile clean names. |
| Deliberate Music start | Select a source or file, preset and included lights before Start. Selection alone requests no audio access and sends no output. Stop stays available during the show and permission startup. Failed restoration remains visible and blocks a new show until cleanup succeeds. Native Music uses the same source-then-Start pattern. |

## Verification and release checks

The production browser build, all 130 component tests and all 179 bridge tests pass locally. The theme catalog audit and whitespace checks also pass; CI repeats these checks. The main Chromium walkthrough covers
29 rendered states, including 320 px phone widths, reduced motion, failures and recovery.
Focused production-app regressions cover guided setup/discovery, scenes/favorites,
schedule editing, explicit names, legacy bridges and Music capture recovery. Each script checks browser errors, narrow
screen overflow and axe accessibility. Music checks verify source selection sends
no frames and requests capture access only on Start.

The scripts are:

- [`visual-review.mjs`](../web/app/scripts/visual-review.mjs)
- [`room-setup-review.mjs`](../web/app/scripts/room-setup-review.mjs)
- [`scene-favorites-review.mjs`](../web/app/scripts/scene-favorites-review.mjs)
- [`schedule-name-review.mjs`](../web/app/scripts/schedule-name-review.mjs)
- [`legacy-bridge-review.mjs`](../web/app/scripts/legacy-bridge-review.mjs)
- [`music-setup-review.mjs`](../web/app/scripts/music-setup-review.mjs)
- [`music-recovery-review.mjs`](../web/app/scripts/music-recovery-review.mjs)

Screenshots and audit reports are written to `/tmp/LumenDesk-Web-QA` by default.
Existing native regressions cover scene retry, rehearsal cleanup, schedule capacity,
daylight saving, saved scene scope and favorites ordering. They supplement the
existing macOS test suite and iOS build; this Linux workspace cannot run Xcode.
Pull-request CI runs the complete native test suite, macOS analysis and the iOS build.
The bridge packaging matrix builds and smoke-tests both Mac architectures,
Windows x64 and Linux x64. Packages are preview artifacts until a release is
published; Mac previews are ad-hoc signed and Windows previews are unsigned.

Physical discovery, downloaded-app permission prompts, VoiceOver and actual
light output still require hardware verification before release. Sent or accepted
means local dispatch, rather than confirmed physical output. Native scene result
tracking still classifies availability before asynchronous transport completion;
it does not claim that a light visibly changed. The current bridge owns Music's
starting output and restores it after five seconds without frames or heartbeats;
this covers page closure, reload and browser suspension while the bridge remains
running. Explicit pending cleanup survives reload in the same tab. Older bridges
without this capability require Stop and completed restoration before closing.
