# LumenDesk Bridge packages

The browser bridge packages include a pinned Node runtime, the built browser app,
the local lighting bridge, and a launcher. Users do not need Node, git, npm, or a
terminal. Packaged previews are available from the
[Package browser bridge workflow](https://github.com/SeanPVera/LumenDesk/actions/workflows/bridge-packages.yml?query=branch%3Amain).
Sign in to GitHub, open the latest successful **main** run, and scroll to
**Artifacts**. Choose `LumenDesk-Bridge-` followed by your computer's platform,
download it, and unpack the outer Actions zip before opening the package inside.
Artifacts expire after 14 days; use a newer successful run if a download has expired.

Tagged [Releases](https://github.com/SeanPVera/LumenDesk/releases) include the same
packages when their Assets section lists `LumenDesk-Bridge` files. Older releases
without those files do not include the browser bridge. If you cannot use GitHub
artifact downloads, follow [Run from source](../web/bridge/README.md#run-from-source).

## Install and open

| Computer | Package | First launch |
| --- | --- | --- |
| Apple silicon Mac | `LumenDesk-Bridge-<version>-macOS-arm64.dmg` | Open the disk image, drag **LumenDesk Bridge** into Applications, then open it. |
| Intel Mac | `LumenDesk-Bridge-<version>-macOS-x64.dmg` | Open the disk image, drag **LumenDesk Bridge** into Applications, then open it. |
| Windows x64 | `LumenDesk-Bridge-<version>-Windows-x64.zip` | Extract the entire archive and open **LumenDesk Bridge.exe**. Keep its folders beside the executable. |
| Linux x64 | `LumenDesk-Bridge-<version>-Linux-x64.tar.gz` | Extract the archive and open **Install LumenDesk.sh** with your file manager's Run as Program action. Then use **LumenDesk Bridge** in the applications menu. **Start LumenDesk.sh** also runs directly without installation. |

The launcher opens `http://127.0.0.1:8765` in your browser. On Mac, the **LD**
menu-bar item offers Open and Quit. On Windows, use the tray icon. On Linux, use
the **Stop LumenDesk Bridge** shortcut to stop the helper. Closing a browser tab
keeps the bridge and schedules running. Stop Music for immediate restoration.
If its page closes or stops responding, the current bridge restores its starting
output after five seconds without frames or heartbeats. Keep the bridge running
until restoration finishes; newer manual changes take priority.

Mac packages require macOS 13.5 or newer. Preview packages are ad-hoc signed and
not notarized: after a blocked first launch, use **System Settings → Privacy &
Security → Open Anyway**. Windows packages require Windows 10 or newer and are
unsigned; a first launch may show SmartScreen. Allow LAN access on your private
home network if the firewall asks. Linux packages require glibc 2.28 or newer and
a desktop with `xdg-open`; file managers may require marking the launcher trusted.
No administrator access is required for the Linux installation.

The bridge does not launch at login or install a background service. Open it
again after restarting the computer. Schedules need the bridge running and the
computer awake. Updates preserve rooms and schedules in
`~/.lumendesk/bridge-state.json` and Nanoleaf pairings in
`~/.lumendesk/nanoleaf-pairings.json`. Quit before replacing or removing the app.
Launcher errors are recorded in `~/.lumendesk/bridge-launcher.log`.

On the first connection, **Set up room** guides finding lights, creating or
choosing a room, assigning lights, and trying controls. Enable **LAN Control** in
Govee Home, keep LIFX bulbs on the same network, and pair Nanoleaf from the setup
guide or Devices. Allow local network access when the operating system asks.

## Build and verify

Build on the target operating system with Node and its standard compiler/tooling:

```sh
node scripts/package_bridge.mjs --version 1.1.0 --arch x64
node scripts/smoke_bridge_package.mjs dist/LumenDesk-Bridge-1.1.0-Linux-x64.tar.gz
```

Use `--arch arm64` for Apple silicon. macOS needs Xcode command-line tools;
Windows uses the .NET Framework C# compiler already on supported Windows systems.
The build runs the locked browser dependency installation, builds with a local
base path, verifies the official Node archive against the committed SHA256, and
includes runtime and browser dependency license notices. It writes a package,
an adjacent `.sha256`, and an internal `BUILD-MANIFEST.json` containing the
runtime source and file hashes. Build output is not committed.

The **Package browser bridge** workflow builds both Mac architectures, Windows
x64 and Linux x64. Smoke tests extract the actual archive, verify its manifest,
execute the shipped runtime and launcher, and check lifecycle cleanup with device
networking disabled. This validates packaging without contacting home lights.
The existing release workflow includes the four packages and their checksums in
the same release as the native app.

Package smoke tests complement browser regressions and bridge simulated-device
tests. Real LAN discovery, downloaded-file operating-system prompts, and physical
light output still need a hardware check before a public release.
