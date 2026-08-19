# LumenDesk bridge

The bridge is the piece that makes the web app control real lights. It runs on
your machine, owns the UDP sockets that LIFX and Govee lights speak, and
exposes them to the browser over a loopback HTTP API.

It exists because **browsers cannot send raw UDP**. LumenDesk's protocols are
UDP broadcast to `255.255.255.255:56700` (LIFX) and UDP multicast to
`239.255.255.250:4001` (Govee); no browser API can emit those datagrams, and
GitHub Pages is static hosting with no server to relay through. The bridge is
the smallest thing that closes that gap without giving up local-only control.

Nothing leaves your network: there is no account, no cloud call, and no
telemetry. The bridge binds loopback only (`127.0.0.1`) by default.

## Run it

Requires [Node.js](https://nodejs.org/) 20 or newer — check with
`node --version`. There is nothing to install beyond that: the bridge has no
dependencies, so there is no `npm install` step.

```sh
git clone --depth 1 https://github.com/SeanPVera/LumenDesk.git
cd LumenDesk/web/bridge
npm start
```

Without git, download and unpack the repository instead:

```sh
curl -L https://github.com/SeanPVera/LumenDesk/archive/refs/heads/main.tar.gz | tar xz
cd LumenDesk-main/web/bridge
npm start
```

Either way it prints:

```
[bridge] listening on http://127.0.0.1:8765
```

Leave that terminal open — the bridge only runs while it does — and open the
web app at <https://seanpvera.github.io/LumenDesk/>, which will find it on port
8765. If you already have the repository checked out, just
`cd web/bridge && npm start`.

```
--port <n>            listen port (default 8765)
--host <addr>         bind address (default 127.0.0.1, loopback only)
--allow-origin <url>  additional browser origin allowed to connect
--allow-any-origin    allow any origin (development only)
--quiet               suppress discovery logging
```

Govee lights only answer the LAN API when **LAN Control** is enabled for each
device in the Govee Home app. LIFX bulbs need no setup.

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

If the hosted page cannot reach the bridge, run the app from your own machine
instead — same bridge, no cross-origin hop and no permission needed:

```sh
cd web/app && npm install && npm run dev
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

Commands apply optimistically and are corrected by the next poll, mirroring the
native app's command lifecycle.

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

To drive the web app against fake lights with no hardware:

```sh
node test/harness.js          # bridge on 8765 with two fake lights
cd ../app && npm run dev
```

## Scope

This first version covers discovery, power, brightness, colour and white for
LIFX and Govee lights. Scenes, schedules, effects, Music Mode, RGBIC segment
control and LIFX matrix devices remain native-app features; the bridge does not
implement them yet.
