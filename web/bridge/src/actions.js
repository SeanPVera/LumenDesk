import { clampPercent, percentToU16 } from './color.js'

// One place where a vendor-neutral intent becomes real commands, shared by
// direct control, scene apply and the scheduler — so all three behave the same.

export function applyCommand({ device, command, registry, lifx, govee, nanoleaf = null }) {
  registry.claimControl?.(device.id)
  const client = { lifx, govee, nanoleaf }[device.brand]
  if (!client) return false

  switch (command.kind) {
    case 'power':
      return applyPower(device, Boolean(command.on), client, registry)
    case 'brightness': {
      const value = clampPercent(command.value)
      const ok = device.brand === 'lifx'
        ? lifx.setColor(device, { brightnessPercent: value })
        : client.setBrightness(device, value)
      if (!ok) return false
      registry.patch(device.id, { brightness: value })
      return true
    }
    case 'state':
      return restoreState({ device, command, registry, client, lifx, govee, nanoleaf })
    case 'color': {
      const kelvin = Number(command.kelvin) || 0
      if (!client.setColor(device, { rgb: command.rgb, kelvin })) return false
      registry.patch(device.id, { color: command.rgb ?? device.color, kelvin: kelvin || null })
      return true
    }
    default:
      return false
  }
}

function applyPower(device, on, client, registry) {
  if (!client.setPower(device, on)) return false
  registry.patch(device.id, { power: on })
  return true
}

// State restoration deliberately keeps its existing acceptance semantics:
// power failure returns false; subsequent channel writes are best-effort.
function restoreState({ device, command, registry, client, lifx, govee, nanoleaf }) {
  const { isOn, brightness, color, kelvin } = command
  if (!applyPower(device, isOn, client, registry)) return false
  if (!isOn) return true

  if (device.brand === 'lifx') {
    restoreLIFXColor(lifx, device, command.hsbk, brightness, color, kelvin)
  } else if (device.brand === 'nanoleaf') {
    restoreSeparateChannels(nanoleaf, device, brightness, color, kelvin, command.design)
  } else {
    restoreSeparateChannels(govee, device, brightness, color, kelvin)
  }
  registry.patch(device.id, {
    brightness: clampPercent(brightness),
    color: color ?? device.color,
    kelvin: kelvin || null,
  })
  return true
}

function restoreLIFXColor(client, device, hsbk, brightness, color, kelvin) {
  // One SetColor packet must carry every channel. Separate colour and
  // brightness commands would rebuild HSBK from the previous device state.
  if (hsbk) {
    client.setColor(device, {
      hsbk: { ...hsbk, brightness: percentToU16(brightness) },
    })
  } else {
    // Legacy scenes lack HSBK; a stored kelvin does not imply white mode.
    client.setColor(device, {
      rgb: color ?? undefined,
      brightnessPercent: brightness,
      kelvin: color ? 0 : kelvin || 0,
    })
  }
}

function restoreSeparateChannels(client, device, brightness, color, kelvin, design = null) {
  // Shapes restores its panel design before master brightness. Without a
  // design, both Shapes and Govee use the same white/colour precedence.
  if (design) client.displayPanels(device, design)
  else if (kelvin) client.setColor(device, { kelvin })
  else if (color) client.setColor(device, { rgb: color })
  client.setBrightness(device, brightness)
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
      // A Shapes wall showing LumenDesk's design keeps every panel.
      design: device.brand === 'nanoleaf' && device.shapes?.output === 'design' ? device.shapes.design : null,
    }
  }
  return snapshots
}

/**
 * Apply a scene. Devices that have since disappeared are skipped rather than
 * failing the whole scene, and the result reports what actually happened.
 */
export function applyScene({ scene, registry, lifx, govee, nanoleaf = null, onlyDeviceIDs = null }) {
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
      nanoleaf,
      command: {
        kind: 'state',
        isOn: snap.isOn,
        brightness: snap.brightness,
        color: snap.color,
        kelvin: snap.kelvin,
        hsbk: snap.hsbk ?? null,
        design: snap.design ?? null,
      },
    })
    applied.push(deviceID)
  }

  return { applied, skipped }
}

/** Run a schedule's action against the lights of its room. */
export function runSchedule({ room, schedule, store, registry, lifx, govee, nanoleaf = null, commandsFor }) {
  const devices = room.lightIDs.map(x => registry.get(x)).filter(Boolean)

  if (schedule.action === 'applyScene') {
    const scene = store.listScenes().find(s => s.id === schedule.sceneID)
    if (!scene) return { ran: false, reason: 'scene missing' }
    // Scenes capture every light, so scope the apply to this room — a room's
    // schedule must not change lights elsewhere.
    const result = applyScene({ scene, registry, lifx, govee, nanoleaf, onlyDeviceIDs: room.lightIDs })
    return { ran: true, devices: result.applied.length }
  }

  const commands = commandsFor(schedule.action)
  if (!commands.length) return { ran: false, reason: 'unknown action' }
  for (const device of devices) {
    for (const command of commands) {
      applyCommand({ device, command, registry, lifx, govee, nanoleaf })
    }
  }
  return { ran: true, devices: devices.length }
}
