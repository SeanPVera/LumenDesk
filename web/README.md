# LumenDesk on the web

Two pieces that together let a browser control real lights:

- **`bridge/`** — a dependency-free Node service that runs on your machine,
  speaks the LIFX and Govee LAN protocols over UDP and the Nanoleaf Shapes
  local HTTP API, and exposes them on a loopback HTTP API. See
  [bridge/README.md](bridge/README.md).
- **`app/`** — the React web client, published to GitHub Pages at
  <https://seanpvera.github.io/LumenDesk/>. It holds no protocol logic; it
  talks only to the bridge. **Room** owns a shared room picker and **Light**,
  **Scenes** and **Music** sections. **Schedules**, **Devices** and
  **Settings** contain secondary tasks.

The split exists because browsers cannot open raw UDP sockets, and GitHub Pages
has no server to relay through. Keeping the UDP in a local helper preserves
LumenDesk's local-only promise — no account, no cloud, nothing off your network.

Once connected, a brief bridge outage keeps the workspace and unfinished edits
open. Controls pause while the app reconnects automatically. Failed room, scene
and panel saves retain their drafts; pending room, scene and schedule submissions
block duplicates. Room deletion explains which lights lose their assignment and
which schedules are removed. Scene and bulk-power feedback reports commands sent
and skipped or failed lights, rather than promising physical confirmation.

## Connecting and organizing a room

Release **LumenDesk Bridge** packages include Node and the built browser app. Open the platform launcher to start both; use its Open and Quit or Start and Stop actions to manage it. [Bridge packaging](../docs/BRIDGE_DISTRIBUTION.md) covers installation and building. Until the next release publishes these assets, use `npm run app` in `web/bridge` with Node 20 or newer.

The first connection offers **Set up room**: Find lights → Create room → Assign lights → Try controls. You can pause and reopen it, choose an existing room, or pair Nanoleaf manually. Discovery distinguishes sent and failed probes and explains Govee LAN Control and network permissions. **Save current lighting** beside room controls captures every fixture in the selected room, including hidden or unselected fixtures. **Scenes** shows saved targets and their current rooms before applying. **Favorites** filters starred lights; hidden selections are excluded from grouped commands. **Schedules → Edit** preserves the existing rule, and device names use **Save / Cancel** with failed drafts kept for retry.

## Nanoleaf Shapes in the browser

Pair a Shapes wall once from **Devices → Pair a Nanoleaf Shapes wall**: enter the
controller's IP address, hold its power button for 5–7 seconds until the LED
flashes, then choose **Pair** within 30 seconds. The bridge keeps the access
token in `~/.lumendesk/nanoleaf-pairings.json`, readable only by your user
account, and never sends it to the page; **Forget** deletes it. The bridge has
no Bonjour discovery, so the address is entered by hand; the native app
discovers controllers.

Select the wall on its own in **Room → Light** and its panels open under the
room, drawn as the wall hangs:

- **Orientation**: turn the drawing with the 90° buttons or type degrees, then
  **Apply orientation**. It shows as requested until the controller reports it
  back.
- **Panels**: click to select, or tab to the wall once and use the arrow keys
  and Space. Select all, clear, invert, or pick every panel of one shape.
  **Identify on the wall** breathes one selected panel for four seconds.
- **Painting** starts from what the wall shows, or from a colour you choose
  when a controller scene is playing (its panel colours can't be read). Set a
  colour, an exact hex, each panel's level, or turn panels off; undo and redo
  work on the draft. Nothing reaches the wall until **Apply to wall**.
- **Scenes on the controller** can be played. Scenes saved in **Scenes**
  capture and restore a wall's panel design or its playing controller scene.

Browser Music Mode drives a Shapes wall as one colour, at most five updates a
second, and a restore brings back the design, scene or white the wall showed
before the show. Per-panel streaming, saved designs and groups, storing scenes
on the controller, scene editing and touch selection are in the Mac and iPhone
apps.

## Using Music Mode in the browser

The browser client analyses the music in the page itself and posts the resulting
colours to the bridge; nothing is uploaded anywhere. To run a show:

1. Choose a room in **Room**, open **Music**, and select a source. **Demo groove** is a built-in rhythm without audio. **Microphone** listens to the room, **MIDI clock** follows DJ or recording software, and **Audio file** uses a track chosen with **Choose audio file**. Selecting a source or file does not start capture or change lights.
2. Pick a preset and choose the included lights and their roles. **Soundcheck** is the default. Lights that are off must be turned on in Room first; Music does not change power.
3. Press **Start**. Microphone or MIDI access is requested here when needed. Input, Energy and tempo appear alongside fixture output. Presets and balance can change during the show; stop before changing membership. **Restart** starts the selected source after restoring the previous show.

**Stop** cancels capture, discards pending frames, drains the one in-flight frame
request, and restores the starting color and brightness while the show still owns
the fixture. A newer manual edit takes priority. Restart/source changes are
serialized with this restoration. Leaving the Music tab requests the same stop;
closing the whole browser cannot guarantee asynchronous network delivery. Use
explicit Stop before closing. Music does not change power, so turn lights on first.
If a restore or release request fails, it stays pending in this page and retries
after the bridge reconnects, including while another section is open. Another
show waits for that cleanup; a newer manual edit still takes priority. Reloading
or closing the page discards pending work, so wait for restoration before leaving.
Newly discovered lights wait until the next show rather than joining without a
restoration snapshot. Music Mode settings are session-only and reset on reload.

Each light gets a job. **Auto** reads the light's name, giving the punch to one
called "kick" or "downstage" and the second colour to one called "rear" or
"accent", with everything else filling the room. The bridge does not report
segments, so pick **Motion** by hand for a strip. Flashing is blocked by default
; ordinary brightness changes can still be uncomfortable, and no setting guarantees medical safety.

Strip lights follow as one colour in the browser. Per-segment chases stay in the
Mac and iPhone apps until the segment encoder is ported with matching tests.

The earlier UX mockup still ships alongside the real app at
<https://seanpvera.github.io/LumenDesk/prototype/>; it simulates everything and
sends no commands.

## Verification and diagnostics

`npm test` in `app/` compiles and exercises the shipped TypeScript music components
with continuous PCM, configuration changes and bounded sender tests. `npm test`
in `bridge/` sends real UDP to loopback device simulators, including independent
brightness and restoration ownership. These are not Swift or physical-device tests.
See [the evidence record](../MUSIC_MODE_EVIDENCE.md) for native CI and limitations.

The Music diagnostics disclosure shows capture, snapshot age, render interval,
onset/beat confidence and generated/HTTP counters. HTTP acceptance means queued
for local dispatch, not acknowledged or visibly rendered. The browser analyzes
continuous stereo batches at capture cadence, renders at 20 Hz and sends at most
10 HTTP frames/s, keeping one in flight and one latest pending frame.

## Interface review

`node scripts/visual-review.mjs` in `app/` runs production React in Chromium
against a mocked bridge. It checks room command scope, scene capture IDs, Music
controls/order/scope locking, the Shapes editor (keyboard selection, painting
exactly the selected panels, orientation pending, the unknown state while a
controller scene plays, pairing errors), failed draft saves, duplicate submission
guards, partial command results, reconnection, Music restoration retries across
navigation, deletion confirmation, schedules, settings, overflow and axe
accessibility, and saves screenshots. The mocked Shapes layout goes through the bridge's own parser
and geometry.
CI installs Playwright 1.56.1 and axe Playwright 4.10.2 for this task without adding
runtime dependencies. These checks do not establish physical light behavior.
