# LumenDesk on the web

Two pieces that together let a browser control real lights:

- **`bridge/`** — a dependency-free Node service that runs on your machine,
  speaks the LIFX and Govee LAN protocols over UDP and the Nanoleaf Shapes
  local HTTP API, and exposes them on a loopback HTTP API. See
  [bridge/README.md](bridge/README.md).
- **`app/`** — the React web client, published to GitHub Pages at
  <https://seanpvera.github.io/LumenDesk/>. It holds no protocol logic; it
  talks only to the bridge. **Room** owns a shared room picker and **Light**,
  **Compositions** and **Music** sections. **Schedules**, **Devices** and
  **Settings** contain secondary tasks.

The split exists because browsers cannot open raw UDP sockets, and GitHub Pages
has no server to relay through. Keeping the UDP in a local helper preserves
LumenDesk's local-only promise — no account, no cloud, nothing off your network.

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
- **Scenes on the controller** can be played. Scenes saved in **Compositions**
  capture and restore a wall's panel design.

Browser Music Mode drives a Shapes wall as one colour, at most five updates a
second, and a restore brings back the design, scene or white the wall showed
before the show. Per-panel streaming, saved designs and groups, storing scenes
on the controller, scene editing and touch selection are in the Mac and iPhone
apps.

## Using Music Mode in the browser

The browser client analyses the music in the page itself and posts the resulting
colours to the bridge; nothing is uploaded anywhere. To run a show:

1. Choose a room in **Room**, open **Music**, and pick a preset. **Soundcheck** is the default first choice, and presets can be
   changed while the show is running.
2. Choose where the sound comes from. Each source button starts the show the
   moment you pick it, so choose the preset first if you want it applied from
   the first beat. **Open audio file** is the most reliable — the page plays the
   track and lights to it. **Microphone** listens to the room and needs the
   browser's microphone permission. **MIDI clock** follows a beat from DJ or
   recording software. **Demo groove** is a built-in rhythm with no audio at
   all, which is how you see the lights move before committing to a track.
   **Start** restarts whatever source you last chose.
3. Read Input, Energy and the confidence-qualified tempo alongside generated
   fixture output. Roles and Earlier/Later buttons describe choreography order.
   Show balance exposes the existing brightness, intensity, sensitivity, movement
   and palette controls. Detailed analyzer and transport values stay in diagnostics.

**Stop** cancels capture, discards pending frames, drains the one in-flight frame
request, and restores the starting color and brightness while the show still owns
the fixture. A newer manual edit takes priority. Restart/source changes are
serialized with this restoration. Leaving the Music tab requests the same stop;
closing the whole browser cannot guarantee asynchronous network delivery. Use
explicit Stop before closing. Music does not change power, so turn lights on first.
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
controller scene plays, pairing errors), overflow and axe accessibility, and
saves screenshots. The mocked Shapes layout goes through the bridge's own parser
and geometry.
CI installs Playwright 1.56.1 and axe Playwright 4.10.2 for this task without adding
runtime dependencies. These checks do not establish physical light behavior.
