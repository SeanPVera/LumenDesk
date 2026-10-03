# Changelog

What changed in each LumenDesk release. The release workflow copies the
section whose heading matches the tag into that tag's GitHub release, above
the install steps, so write each entry for someone deciding whether to update.

## 1.1.0 - 2026-10-03

The first release with a Mac disk image to download. 1.0.0 shipped as source
only.

### New lights

- **Nanoleaf Shapes.** LumenDesk finds Shapes controllers on your network and
  pairs with one after you hold the controller's power button to open its
  pairing window. The credential stays in Keychain and never goes into an
  export. A wall is a set of panels now, not one big bulb: the panel studio
  draws it the way it hangs, sets its orientation, paints panels one at a time
  with swatches, exact hex, per-panel level, gradients, theme fills and groups,
  and saves designs in LumenDesk or on the controller. An orientation change
  counts only after the controller reads it back. LumenDesk never deletes a
  controller scene and asks before it replaces one.
- **Nanoleaf Aurora (Light Panels).** Works in the same studio. Aurora has no
  touch, so touch selection is Shapes only.
- **Live wall output.** Effects and Music Mode stream per-panel frames to a
  Nanoleaf wall at up to ten a second. The stream lets go as soon as anything
  else takes the wall, whether that's the Nanoleaf app, a button press,
  HomeKit or a scene.
- **Govee H6062 Glide Wall Light.** Segment Studio lays it out as 28 zones
  numbered from the controller along the chain and saves the layout to the
  light. Govee doesn't publish the zone map, so the count stays adjustable.
- Themes, scenes, schedules and undo all cover Nanoleaf walls, and Demo Mode
  gets a simulated wall that never touches the network.

### Themes

- 30 new themes, 48 in all across nine moods. Every original theme keeps its
  name and colours, so favourites and saved shortcuts still resolve.
- Each theme says where its colours belong: one wash, an anchor colour with
  accents, a gradient, alternating, or scattered. LumenDesk plans it light by
  light. A lone bulb gets the key colour at the theme's full brightness. A
  Govee strip or a LIFX Luna runs the spread along its own segments. A mixed
  room is planned as one, and a single message tells you what any light
  couldn't show.
- A theme now looks the same on LIFX and Govee. Govee lights used to get
  dimmed twice.
- Every theme doubles as a Music Mode palette. Picking one changes the colours
  and leaves your flash and photosensitivity settings alone.

### A new layout

- The app opens on a room. Light, Compositions and Music share one selection.
  Room, Schedules, Devices and Settings are named destinations on the Mac and
  tabs on iOS.
- Room setup proposes rooms from the names you already gave your lights, then
  pulses each unsorted light so you can point at it in the room instead of
  guessing which lamp "Shelf Strip" is. A light you can't spot waits in a tray
  until you can.
- A new app icon.
- The browser client gets the same room workspace.

### Music Mode

- Follows the beat instead of flashing at it. On a dense 124 BPM test groove
  the tempo stayed on the beat for every locked frame, up from 59%, and
  stopped jumping to the dotted-quarter rate. Click tracks from 140 to 190 BPM
  all lock.
- A held chord no longer invents a tempo.
- Brightness is a steady base that follows loudness, with a swell on each
  beat. Lights stop strobing at twice the beat rate, and quiet passages look
  quieter than loud ones.
- Colour holds for whole bars and changes on the downbeat instead of chasing
  noise.
- Plain-language help: a "How to get a show running" walkthrough, and an
  "Explain the controls" switch that puts a one-line explanation under every
  control.
- Audio capture, stop and restore got repaired on both clients. In the
  browser, Stop puts your lights back the way they were instead of freezing
  the last frame, LIFX lights get their brightness channel, and the analyzer
  runs about 1.4x faster.

### Discovery

- Finds lights a single broadcast misses. Each scan aims at every network
  interface's own subnet, repeats its broadcasts over several rounds for bulbs
  dozing in power save, and knocks on the addresses around yours one by one.
  Govee discovery goes out on each interface, so a VPN no longer swallows it.
- Diagnostics tells "nothing answered" apart from "nothing left this Mac", and
  stops blaming your VPN for empty addresses during a healthy scan.

### Fixes

- Govee lights no longer go dead after your router hands out new addresses.
  LumenDesk now talks to the address a light replied from.
- A rescan counts LIFX lights it already knew about.
- LIFX colour changes no longer report "did not confirm the change" after
  they landed.
- Scene rehearsal previews Govee segments the way Apply paints them, and sends
  Govee brightness too.
- Export tells you when it fails, and exports now remember which lights are in
  white mode.
- A light's own controls lock while an effect is driving it, with a Stop
  button right there, instead of taking changes the effect overwrites a frame
  later.
- Applying a theme to a Govee strip clears per-segment dimming left over from
  an earlier layout.
- Browser: a colour change no longer undoes a brightness change made a moment
  earlier, and a schedule saved with no days picked runs every day, the same
  as in the Mac app.

### Known limits

- The Nanoleaf support, the H6062 zone map and the new Music Mode timing were
  tested against simulated devices and synthesised audio, not real hardware.
  Reports from real walls and real rooms are welcome.
- The disk image is not notarized. The install steps below cover the one-time
  Gatekeeper step.

## 1.0.0 - 2026-09-05

First tagged release, source only. See the
[1.0.0 release](https://github.com/SeanPVera/LumenDesk/releases/tag/v1.0.0).
