# LumenDesk bridge

The bridge is the piece that makes the web app control real lights. It runs on
your machine, owns the UDP sockets that LIFX and Govee lights speak and the
local HTTP connection to Nanoleaf Shapes controllers, and exposes them to the
browser over a loopback HTTP API.

It exists because **browsers cannot send raw UDP**. LumenDesk's protocols are
UDP broadcast to `255.255.255.255:56700` (LIFX) and UDP multicast to
`239.255.255.250:4001` (Govee); no browser API can emit those datagrams, and
GitHub Pages is static hosting with no server to relay through. The bridge is
the smallest thing that closes that gap without giving up local-only control.

Nothing leaves your network: there is no account, no cloud call, and no
telemetry. The bridge binds loopback only (`127.0.0.1`) by default.

## Install the browser app

The **Package browser bridge** workflow builds self-contained previews for
macOS Apple silicon and Intel, Windows x64, and Linux x64. Download an artifact
from a successful [workflow run](https://github.com/SeanPVera/LumenDesk/actions/workflows/bridge-packages.yml)
and unpack the Actions artifact first. Tagged releases attach the resulting
`LumenDesk-Bridge-<version>-<platform>-<architecture>` packages alongside the
native macOS app. Existing releases made before this packaging change do not
contain bridge downloads.

- **macOS:** open the `.dmg`, drag **LumenDesk Bridge** into Applications and
  open it. Its **LD** menu-bar icon offers **Open LumenDesk** and **Quit LumenDesk
  Bridge**. Requires macOS 13.5 or newer; choose arm64 for Apple silicon or x64
  for Intel. Preview bundles are ad-hoc signed and not notarized. If a download
  is blocked, attempt to open it once, then use **System Settings → Privacy &
  Security → Open Anyway**.
- **Windows:** extract the whole `.zip` and double-click **LumenDesk Bridge.exe**.
  Its tray icon opens the page or quits the bridge. Keep the runtime, launcher
  and web folders next to the executable. Requires Windows 10 or newer, x64.
  Preview launchers are unsigned, so SmartScreen may ask about the download.
- **Linux:** extract the `.tar.gz` and run **Install LumenDesk.sh** with the file
  manager's **Run as Program** action. This copies the bundle into your home
  folder and adds **LumenDesk Bridge** and **Stop LumenDesk Bridge** to the
  applications menu. You can also run **Start LumenDesk.sh** directly. Requires
  x64, glibc 2.28 or newer, and a desktop with `xdg-open`.

The packages include the Node runtime and built web app. Opening the launcher
opens `http://127.0.0.1:8765` in your browser, without installing Node, cloning
the repository or setting up a terminal. There is no account or cloud service.
Closing the browser leaves the bridge running so schedules can run. **Quit**
or **Stop** shuts it down. Open it again after restarting your computer; the
installer does not create a startup service or launch at login. Quit before
updating or removing the bundle. Saved rooms and Nanoleaf pairings stay in
`~/.lumendesk`, so an update preserves them.

Allow network access on your private home network if the operating system asks.
Govee still needs LAN Control enabled; Nanoleaf still needs local pairing.

## Run from source

Requires [Node.js](https://nodejs.org/) 20 or newer — check with
`node --version`.

```sh
git clone --depth 1 https://github.com/SeanPVera/LumenDesk.git
cd LumenDesk/web/bridge
npm run app
```

Without git, download and unpack the repository instead:

```sh
curl -L https://github.com/SeanPVera/LumenDesk/archive/refs/heads/main.tar.gz | tar xz
cd LumenDesk-main/web/bridge
npm run app
```

Either way it prints:

```
  LumenDesk is running. Open http://127.0.0.1:8765
```

Open that address and control your lights. Leave the terminal open — the bridge
only runs while it does.

`npm run app` builds the web client and then serves it from the bridge, so the
page and the API share one origin. **This is the route that always works**: the
browser rules described below simply do not apply, because the page is not a
remote site reaching into your network — it *is* the local service.

### Using the published page instead

`npm start` runs the API alone, with no web client, for use with
<https://seanpvera.github.io/LumenDesk/>. That route is subject to the browser
rules in the next section and may be blocked. It needs no build step, since the
bridge itself has no dependencies.

```
--port <n>            listen port (default 8765)
--host <addr>         bind address (default 127.0.0.1, loopback only)
--allow-origin <url>  additional browser origin allowed to connect
--allow-any-origin    allow any origin (development only)
--quiet               suppress discovery logging
--no-network          serve without opening device sockets (development tests)
```

Govee lights only answer the LAN API when **LAN Control** is enabled for each
device in the Govee Home app. LIFX bulbs need no setup. Nanoleaf Shapes
controllers are paired once by address (see below).

## How the browser is allowed to reach it

A page served from `https://seanpvera.github.io` can call `http://127.0.0.1`
because loopback is a [potentially trustworthy origin][spec], so it is exempt
from mixed-content blocking.

Whether the request is *allowed* is then up to the browser, and this is the
part most likely to bite:

- **Chrome 142 and later** ship [Local Network Access][lna], which asks the
  user for permission before any site may reach the local network. LNA replaced
  the earlier Private Network Access design, so **no header the bridge sends
  can grant this** — only the person at the keyboard can, via the prompt or the
  site settings icon in the address bar. A denied or dismissed prompt fails as
  an ordinary network error, indistinguishable from the bridge being down.
- The bridge still answers `Access-Control-Allow-Private-Network: true` for
  older Chrome versions that run the PNA preflight. Harmless, but not the
  mechanism on current browsers.
- Other browsers differ and change over time.

If the hosted page cannot reach the bridge, stop fighting the permission and
let the bridge serve the client instead — the request is then same-origin and
none of the above applies:

```sh
cd web/bridge && npm run app
```

[spec]: https://w3c.github.io/webappsec-secure-contexts/#is-origin-trustworthy
[lna]: https://developer.chrome.com/blog/local-network-access

## API

All responses are JSON. Device ids are vendor-prefixed (`lifx:…`, `govee:…`)
and must be URL-encoded in paths.

| Method | Path | Body | Purpose |
| --- | --- | --- | --- |
| `GET` | `/health` | — | Identify the bridge |
| `GET` | `/devices` | — | All known devices and their state |
| `POST` | `/discover` | — | Broadcast a discovery sweep |
| `POST` | `/refresh` | — | Re-read state from known devices |
| `POST` | `/devices/{id}/power` | `{"on":true}` | Power on/off |
| `POST` | `/devices/{id}/brightness` | `{"value":0-100}` | Brightness percent |
| `POST` | `/devices/{id}/color` | `{"rgb":{"r":0,"g":0,"b":0}}` or `{"kelvin":2700}` | Colour or white |
| `GET` | `/state` | — | Devices, rooms, scenes and favourites in one call |
| `GET`/`POST` | `/rooms` | `{"name":"Studio"}` | List or create rooms |
| `POST` | `/rooms/{id}` | `{"name":…}` or `?delete=1` | Rename or delete a room |
| `POST` | `/rooms/{id}/schedules` | `{"hour":7,"minute":30,"action":"turnOn"}` | Add a schedule |
| `POST` | `/rooms/{id}/schedules/{sid}` | patch, or `?delete=1` | Update or delete a schedule |
| `GET`/`POST` | `/scenes` | `{"name":"Evening"}` | List, or capture current state as a scene |
| `POST` | `/scenes/{id}/apply` | — | Restore a scene |
| `POST` | `/devices/{id}/favorite` \| `/rename` \| `/room` | — / `{"name":…}` / `{"roomID":…}` | Organise a light |
| `POST` | `/nanoleaf/pair` | `{"host":"192.168.1.40","port":16021}` | Pair a Shapes controller whose pairing window is open |
| `POST` | `/devices/{id}/orientation` | `{"degrees":0-359}` | Write a Shapes wall's global orientation (`202`; confirmed by the next reading) |
| `POST` | `/devices/{id}/panels` | `{"colors":{"<panelID>":{"r":0,"g":0,"b":0}}}` | Show per-panel colours; panels left out go dark |
| `POST` | `/devices/{id}/effect` | `{"name":"Evening"}` | Play a scene stored on the controller |
| `POST` | `/devices/{id}/identify` | `{"panelID":1204}` | Breathe one panel for four seconds (temporary display) |
| `POST` | `/devices/{id}/forget` | — | Delete a Shapes credential; nothing is sent to the controller |

Commands apply optimistically and are corrected by the next poll, mirroring the
native app's command lifecycle.

### Nanoleaf Shapes

`src/nanoleaf.js` and `src/nanoleaf-client.js` port the native
`Services/Nanoleaf/` code. A Shapes device carries a `shapes` object: the
parsed layout, drawing geometry (panel outlines from shape type, the
controller as a marker), `orientation` as read back, `orientationPending`,
`output` (`off`, `solid`, `white`, `design`, `effect` or `external`), the
controller's scene list, the design LumenDesk last showed while it still owns
the wall, `problem` for a damaged layout reading and `lastFailure`.

- Pairing needs the controller's window (power button held 5–7 s). The token is
  kept in `~/.lumendesk/nanoleaf-pairings.json` with mode `0600` and never
  appears in a response, a log line or an error message.
- Each controller has one ordered lane that coalesces to the newest command,
  so a slow controller never replays stale colours. Walls are re-read every
  five seconds, which is how changes made in the Nanoleaf app show up.
- Music frames drive a wall as one colour, paced to one update every 200 ms,
  and a restore puts back the design, scene or white the wall showed first.

### Stored state and schedules

Rooms, scenes, schedules, favourites and custom device names are kept in
`~/.lumendesk/bridge-state.json`, written atomically. They live here rather than
in the browser so they survive a reload, are shared by every browser on the
machine, and — crucially for schedules — keep working with no page open.

**Schedules are evaluated by the bridge**, on a half-open time window, so a
missed tick (a laptop waking from sleep) still runs an entry once rather than
skipping or repeating it. Evaluation itself is pure and clock-injected, like the
native `ScheduleEngine`, so it is tested without waiting on real time.

## Tests

```sh
npm test
```

Two layers, both run in CI:

- **Protocol** — encoders asserted byte-for-byte against the same vectors as
  `LumenDeskTests/ProtocolTests.swift`, so the bridge and the native app put
  identical bytes on the wire.
- **Integration** — fake LIFX and Govee devices that speak the real protocols
  over UDP on loopback, exercising discovery, commands, state read-back, the
  Govee ≥100 ms pacing rule, and the CORS/Private Network Access headers.
- **Shapes** — layout parsing, geometry, numbering and encoders asserted against
  the same vectors as `LumenDeskTests/NanoleafShapesTests.swift` (Nanoleaf's
  documented animData and v2 stream bytes), and a fake controller over real
  HTTP on loopback for pairing, orientation readback, painting, scenes,
  identify, music pacing and restore, and forgetting.
- **Launcher** — startup from paths with spaces, graceful Quit, parent closure,
  reuse of an existing bridge, port conflicts, unexpected bridge exits and
  Linux desktop Open/Stop. These use a loopback-only fixture with no discovery.

To build and verify a self-contained package on its target OS:

```sh
node scripts/package_bridge.mjs --version 1.1.0
node scripts/smoke_bridge_package.mjs dist/LumenDesk-Bridge-1.1.0-Linux-x64.tar.gz
```

Run these commands from the repository root, choosing the produced `.dmg` or
`.zip` instead on macOS or Windows. The packager uses `npm ci` and a local-base
React production build, downloads an official Node LTS archive, checks its
committed SHA256 from `launcher/node-runtime.json`, and includes license notices
and a `BUILD-MANIFEST.json` with shipped file hashes. It never installs a system
Node runtime. To upgrade the bundled runtime, review the official Node release
and replace its version and all platform hashes together.

The smoke check extracts the actual archive into a path with spaces, validates
all hashes and runs the shipped launcher against the actual bridge. It checks
health, the bundled HTML/JS/CSS, state and shutdown using an isolated home folder
and `--no-network`; it does not send LAN discovery probes. The matrix workflow
runs this on both Mac architectures, Windows and Linux. A tagged release waits
for these artifacts and attaches them in the existing release job, without a
second competing release publication.

To drive the web app against fake lights with no hardware:

```sh
node test/harness.js          # bridge on 8765 with two fake lights
cd ../app && npm run dev
```

## Scope

The bridge covers discovery, power, brightness, colour and white for LIFX and
Govee lights, rooms, scenes, schedules and browser Music Mode frames, and for
Nanoleaf Shapes pairing, orientation, per-panel colour, controller scenes and
identify. LumenDesk's animated effects, RGBIC segment control, LIFX matrix
devices and Shapes per-panel streaming remain native-app features.
