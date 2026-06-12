# LumenDesk

A native macOS and iOS app for controlling **LIFX** and **Govee** smart bulbs
over your local network — no cloud, no API keys.

LumenDesk speaks each vendor's LAN protocol directly:

- **LIFX** — UDP broadcast on port `56700` for discovery (`GetService`), then
  per-bulb `LightSetColor` / `SetLightPower` packets.
- **Govee** — UDP multicast `239.255.255.250:4001` for discovery, replies on
  `:4002`, commands on `:4003`. Requires "LAN Control" enabled per bulb in the
  Govee Home app.

## Features

- Automatic discovery of all supported bulbs on your subnet
- Per-bulb on/off, brightness, and full-color picker
- Live state read back from each bulb after a change
- Single-window SwiftUI interface, sandboxed, hardened runtime

## Requirements

- macOS 13 Ventura or later, or iOS 16 or later
- Xcode 15 or later
- Bulbs and Mac/iPhone on the same Wi-Fi/LAN
- Govee bulbs must have **LAN Control** turned on in the Govee Home app
  (Device Settings → LAN Control). Only certain Govee SKUs support the LAN API.

## Building

Open `LumenDesk.xcodeproj` in Xcode and press ⌘R.

The first run will prompt for local-network access — accept it.

### Running on your iPhone

The single `LumenDesk` target is multiplatform — the same scheme builds for
Mac and iPhone.

1. Connect your iPhone over USB (or pair it wirelessly via
   Window → Devices and Simulators).
2. In the toolbar's destination picker, choose your iPhone instead of
   "My Mac".
3. In the target's **Signing & Capabilities** tab, pick your Apple ID team
   (a free personal team works).
4. Press ⌘R. On first launch the phone will block the unsigned developer
   app — approve it under Settings → General → VPN & Device Management.
5. Accept the **Local Network** permission prompt when the app first scans.

**How discovery works on iPhone:** iOS does not allow UDP broadcast or
multicast unless Apple grants the app the restricted
`com.apple.developer.networking.multicast` entitlement. LumenDesk therefore
falls back to a unicast sweep on iOS — it probes every address on your /24
subnet directly (LIFX `GetService` to `:56700`, Govee scan to `:4001`), and
the bulbs reply unicast. This works on typical home networks; if your subnet
is wider than /24, only the 253 addresses nearest your phone's IP are probed.
If you have the multicast entitlement on your account, add it in Signing &
Capabilities and discovery will also use real broadcast/multicast.

### Optional: regenerate the project with XcodeGen

If you prefer to regenerate the Xcode project from source:

```sh
brew install xcodegen
xcodegen generate
```

This reads `project.yml` and rewrites `LumenDesk.xcodeproj`.

## Project layout

```
LumenDesk/
├── LumenDeskApp.swift          # @main app entry
├── ContentView.swift           # Top-level SwiftUI view
├── Models/
│   └── LightDevice.swift       # Brand-agnostic bulb model
├── Services/
│   ├── LightManager.swift      # ObservableObject; fans out to vendor clients
│   ├── UDPSocket.swift         # BSD-socket UDP wrapper (broadcast + multicast)
│   ├── LIFX/
│   │   ├── LIFXProtocol.swift  # LIFX LAN packet builders / parsers
│   │   └── LIFXClient.swift    # Discovery + control over UDP 56700
│   └── Govee/
│       ├── GoveeProtocol.swift # Govee JSON messages
│       └── GoveeClient.swift   # Discovery + control over UDP 4001/4002/4003
├── Views/
│   └── LightRowView.swift      # Single-row controls (toggle, slider, picker)
├── Info.plist                  # NSLocalNetworkUsageDescription, etc.
└── LumenDesk.entitlements      # Sandbox + network client/server
```

## Troubleshooting

- **No bulbs found.** Confirm the Mac and bulbs are on the same VLAN. Many
  routers isolate "IoT" Wi-Fi networks from the main one — LumenDesk needs
  to broadcast (LIFX) and multicast (Govee) onto the bulbs' subnet.
- **Govee bulbs missing.** Open the Govee Home app, pick the device, and
  enable **LAN Control**. Older or budget Govee SKUs don't support it.
- **"Bind failed" on Govee.** Another app on this Mac is bound to UDP 4002.
  Quit that app or the other LAN-control client (e.g. govee2mqtt, Home
  Assistant Govee integration running on the same machine) and reopen
  LumenDesk.
- **LIFX bulbs show but don't change.** Some routers block UDP broadcast
  replies. Try moving the Mac to the same Wi-Fi band as the bulbs.

## Protocol references

- LIFX LAN protocol: <https://lan.developer.lifx.com/docs>
- Govee LAN API: <https://app-h5.govee.com/user-manual/wlan-guide>
