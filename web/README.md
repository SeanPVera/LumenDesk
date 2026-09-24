# LumenDesk on the web

Two pieces that together let a browser control real lights:

- **`bridge/`** — a dependency-free Node service that runs on your machine,
  speaks the LIFX and Govee LAN protocols over UDP, and exposes them on a
  loopback HTTP API. See [bridge/README.md](bridge/README.md).
- **`app/`** — the React web client, published to GitHub Pages at
  <https://seanpvera.github.io/LumenDesk/>. It holds no protocol logic; it
  talks only to the bridge. Destinations mirroring the native shell: Home
  (favourites, rooms, search, filters, bulk actions), Library (scenes),
  Music Mode (DSP in the browser, frames posted to the bridge), Automation
  (schedules), Devices (rooms and naming) and Settings.

The split exists because browsers cannot open raw UDP sockets, and GitHub Pages
has no server to relay through. Keeping the UDP in a local helper preserves
LumenDesk's local-only promise — no account, no cloud, nothing off your network.

## Using Music Mode in the browser

The browser client analyses the music in the page itself and posts the resulting
colours to the bridge; nothing is uploaded anywhere. To run a show:

1. Pick a preset. **Soundcheck** is the default first choice, and presets can be
   changed while the show is running.
2. Choose where the sound comes from. Each source button starts the show the
   moment you pick it, so choose the preset first if you want it applied from
   the first beat. **Open audio file** is the most reliable — the page plays the
   track and lights to it. **Microphone** listens to the room and needs the
   browser's microphone permission. **MIDI clock** follows a beat from DJ or
   recording software. **Demo groove** is a built-in rhythm with no audio at
   all, which is how you see the lights move before committing to a track.
   **Start** restarts whatever source you last chose.
3. Watch the meters for what the page is hearing. The label under the beat dot
   changes from "Beat" to the tempo and bar count once it locks, which normally
   takes about four seconds of steady rhythm.

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
