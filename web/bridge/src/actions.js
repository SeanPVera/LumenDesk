import { clampPercent } from './color.js'

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
    }
  }
  return snapshots
}

/**
 * Apply a scene. Devices that have since disappeared are skipped rather than
 * failing the whole scene, and the result reports what actually happened.
 */
export function applyScene({ scene, registry, lifx, govee }) {
  const applied = []
  const skipped = []

  for (const [deviceID, snap] of Object.entries(scene.snapshots ?? {})) {
    const device = registry.get(deviceID)
    if (!device) {
      skipped.push(deviceID)
      continue
    }
    const context = { device, registry, lifx, govee }
    applyCommand({ ...context, command: { kind: 'power', on: snap.isOn } })
    if (snap.isOn) {
      if (snap.kelvin) {
        applyCommand({ ...context, command: { kind: 'color', kelvin: snap.kelvin } })
      } else if (snap.color) {
        applyCommand({ ...context, command: { kind: 'color', rgb: snap.color } })
      }
      applyCommand({ ...context, command: { kind: 'brightness', value: snap.brightness } })
    }
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
    applyScene({ scene, registry, lifx, govee })
    return { ran: true, devices: Object.keys(scene.snapshots ?? {}).length }
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
