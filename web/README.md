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

1. Pick where the sound comes from. **Open audio file** is the most reliable —
   the page plays the track and lights to it. **Microphone** listens to the room
   and needs the browser's microphone permission. **MIDI clock** follows a beat
   from DJ or recording software. **Demo groove** is a built-in rhythm with no
   audio at all, which is how you see the lights move before committing to a
   track.
2. Pick a preset. **Balanced** is the safe first choice, and presets can be
   changed while the music is playing.
3. Press **Start**. The meters show what the page is hearing, and the label
   under the beat dot changes from "Beat" to the tempo and bar count once it
   locks, which normally takes about four seconds of steady rhythm.

Each light gets a job — **Auto** picks one for you, and the list on the page
explains what wash, hit, accent and motion each do. Flashing is blocked by
default and can never exceed three flashes a second.

Strip lights follow as one colour in the browser. Per-segment chases stay in the
Mac and iPhone apps until the segment encoder is ported with matching tests.

The earlier UX mockup still ships alongside the real app at
<https://seanpvera.github.io/LumenDesk/prototype/>; it simulates everything and
sends no commands.
