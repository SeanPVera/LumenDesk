import { clampPercent, percentToU16 } from './color.js'

// One place where a vendor-neutral intent becomes real commands, shared by
// direct control, scene apply and the scheduler — so all three behave the same.

export function applyCommand({ device, command, registry, lifx, govee }) {
  const client = device.brand === 'lifx' ? lifx : govee

  if (command.kind === 'power') {
    const on = Boolean(command.on)
    if (!client.setPower(device, on)) return false
    registry.patch(device.id, { power: on })
    return true
  }

  if (command.kind === 'brightness') {
    const value = clampPercent(command.value)
    const ok =
      device.brand === 'lifx'
        ? lifx.setColor(device, { brightnessPercent: value })
        : govee.setBrightness(device, value)
    if (!ok) return false
    registry.patch(device.id, { brightness: value })
    return true
  }

  // Restore an entire captured state at once. Necessary for LIFX, whose
  // SetColor packet carries hue, saturation, brightness and kelvin together:
  // sending colour then brightness rebuilds the second packet from the
  // device's *previous* HSBK and undoes the colour.
  if (command.kind === 'state') {
    const { isOn, brightness, color, kelvin } = command
    if (!client.setPower(device, isOn)) return false
    registry.patch(device.id, { power: isOn })
    if (!isOn) return true

    if (device.brand === 'lifx') {
      if (command.hsbk) {
        // Captured state, replayed exactly, with the scene's brightness.
        lifx.setColor(device, {
          hsbk: { ...command.hsbk, brightness: percentToU16(brightness) },
        })
      } else {
        // A scene saved before HSBK was captured: colour wins, because a
        // stored kelvin does not imply the light was white.
        lifx.setColor(device, {
          rgb: color ?? undefined,
          brightnessPercent: brightness,
          kelvin: color ? 0 : kelvin || 0,
        })
      }
    } else {
      // Govee needs separate messages; the client paces and coalesces them.
      if (kelvin) govee.setColor(device, { kelvin })
      else if (color) govee.setColor(device, { rgb: color })
      govee.setBrightness(device, brightness)
    }
    registry.patch(device.id, {
      brightness: clampPercent(brightness),
      color: color ?? device.color,
      kelvin: kelvin || null,
    })
    return true
  }

  if (command.kind === 'color') {
    const kelvin = Number(command.kelvin) || 0
    const ok =
      device.brand === 'lifx'
        ? lifx.setColor(device, { rgb: command.rgb, kelvin })
        : govee.setColor(device, { rgb: command.rgb, kelvin })
    if (!ok) return false
    registry.patch(device.id, { color: command.rgb ?? device.color, kelvin: kelvin || null })
    return true
  }

  return false
}

/** Capture the current state of the given devices as a scene snapshot. */
export function snapshot(devices) {
  const snapshots = {}
  for (const device of devices) {
    snapshots[device.id] = {
      isOn: device.power,
      brightness: device.brightness,
      color: device.color,
      kelvin: device.kelvin,
      // Exact vendor state where we have it, so a restore is not a round trip
      // through RGB. LIFX always reports a kelvin even for a saturated colour,
      // so kelvin alone cannot tell us whether the light was in white mode.
      hsbk: device.hsbk ?? null,
    }
  }
  return snapshots
}

/**
 * Apply a scene. Devices that have since disappeared are skipped rather than
 * failing the whole scene, and the result reports what actually happened.
 */
export function applyScene({ scene, registry, lifx, govee, onlyDeviceIDs = null }) {
  const applied = []
  const skipped = []

  for (const [deviceID, snap] of Object.entries(scene.snapshots ?? {})) {
    // A room-scoped apply must not touch lights in other rooms.
    if (onlyDeviceIDs && !onlyDeviceIDs.includes(deviceID)) continue

    const device = registry.get(deviceID)
    if (!device) {
      skipped.push(deviceID)
      continue
    }
    applyCommand({
      device,
      registry,
      lifx,
      govee,
      command: {
        kind: 'state',
        isOn: snap.isOn,
        brightness: snap.brightness,
        color: snap.color,
        kelvin: snap.kelvin,
        hsbk: snap.hsbk ?? null,
      },
    })
    applied.push(deviceID)
  }

  return { applied, skipped }
}

/** Run a schedule's action against the lights of its room. */
export function runSchedule({ room, schedule, store, registry, lifx, govee, commandsFor }) {
  const devices = room.lightIDs.map(x => registry.get(x)).filter(Boolean)

  if (schedule.action === 'applyScene') {
    const scene = store.listScenes().find(s => s.id === schedule.sceneID)
    if (!scene) return { ran: false, reason: 'scene missing' }
    // Scenes capture every light, so scope the apply to this room — a room's
    // schedule must not change lights elsewhere.
    const result = applyScene({ scene, registry, lifx, govee, onlyDeviceIDs: room.lightIDs })
    return { ran: true, devices: result.applied.length }
  }

  const commands = commandsFor(schedule.action)
  if (!commands.length) return { ran: false, reason: 'unknown action' }
  for (const device of devices) {
    for (const command of commands) {
      applyCommand({ device, command, registry, lifx, govee })
    }
  }
  return { ran: true, devices: devices.length }
}
