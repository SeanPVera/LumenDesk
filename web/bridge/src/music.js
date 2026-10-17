import { percentToU16 } from './color.js'

export const MUSIC_RECOVERY_LEASE_MS = 5000

const validRGB = rgb => rgb && ['r', 'g', 'b'].every(key => Number.isFinite(rgb[key]) && rgb[key] >= 0 && rgb[key] <= 255)

/** The bridge owns the starting output, so a vanished browser cannot lose it.
 * A heartbeat renews the lease without changing a light. Explicit controls,
 * scenes and schedules revoke ownership through Registry.claimControl. */
export function createMusicController({ registry, lifx, govee, nanoleaf = null, now = () => performance.now(), leaseMS = MUSIC_RECOVERY_LEASE_MS }) {
  const brightnessOpened = new Set()
  const beforeMusic = new Map()

  const forget = id => { brightnessOpened.delete(id); beforeMusic.delete(id) }
  const release = id => {
    // Fence delayed frames from a stopped, reloaded or expired page. A future
    // show reads this revision before capturing its own starting output.
    registry.claimControl(id)
    forget(id)
  }
  const restoreShapes = (device, before, level) => {
    if (level !== undefined && !nanoleaf.setBrightness(device, level * 100)) return false
    if (before.output === 'design' && before.design) return nanoleaf.displayPanels(device, before.design)
    if (before.output === 'effect' && before.effect) return nanoleaf.selectEffect(device, before.effect)
    if (before.output === 'white' && before.kelvin) return nanoleaf.setColor(device, { kelvin: before.kelvin })
    return null
  }

  const paint = (device, state, before, exact = false) => {
    const level = Number.isFinite(state.brightness) ? Math.max(0, Math.min(1, state.brightness)) : undefined
    const restoring = state.restoring === true
    let payload = state.rgb
    if (device.brand === 'govee' && level !== undefined) {
      if (restoring) {
        if (!govee.setBrightness(device, level * 100)) return false
        brightnessOpened.delete(device.id)
      } else {
        if (!brightnessOpened.has(device.id)) {
          if (!govee.setBrightness(device, 100)) return false
          brightnessOpened.add(device.id)
        }
        payload = Object.fromEntries(Object.entries(state.rgb).map(([key, value]) => [key, Math.round(value * level)]))
      }
    }
    const restoredShapes = device.brand === 'nanoleaf' && before && nanoleaf ? restoreShapes(device, before, level) : null
    const hsbk = before?.hsbk ? { ...before.hsbk,
      brightness: exact || level === undefined ? before.hsbk.brightness : percentToU16(level * 100) } : undefined
    const white = device.brand === 'govee' && before?.kelvin ? before.kelvin : null
    const ok = restoredShapes !== null
      ? restoredShapes
      : device.brand === 'lifx'
        ? lifx.setColor(device, { rgb: state.rgb, hsbk, brightnessPercent: level === undefined ? undefined : level * 100,
            durationMS: Number.isFinite(state.transitionDuration) ? Math.max(0, Math.min(500, state.transitionDuration * 1000)) : 90 })
        : device.brand === 'nanoleaf'
          ? Boolean(nanoleaf?.setColor(device, { rgb: state.rgb, brightnessPercent: level === undefined ? undefined : level * 100, transient: !restoring }))
          : govee.setColor(device, white ? { kelvin: white } : { rgb: payload })
    if (!ok) return false
    // This path never sends power, so only a device reading changes that field.
    registry.patch(device.id, { color: before?.color ?? payload, kelvin: before?.kelvin ?? null,
      ...(level !== undefined ? { brightness: device.brand === 'lifx' || restoring ? level * 100 : 100 } : {}) })
    return true
  }

  const expire = () => {
    for (const [id, before] of beforeMusic) {
      const device = registry.get(id)
      if (!device || device.musicOwner !== before.owner || device.controlRevision !== before.controlRevision) {
        forget(id)
        continue
      }
      if (now() - (device.musicFrameAt ?? 0) < leaseMS) continue
      // Once expired, late heartbeats/frames cannot revive a failed cleanup.
      // Keep its exact snapshot and retry until dispatch works or a newer
      // manual action takes the light away.
      before.expired = true
      try {
        if (!before.restoreOnDisconnect || paint(device, {
          rgb: before.color ?? { r: 255, g: 255, b: 255 },
          brightness: before.hsbk ? before.hsbk.brightness / 65535 : before.brightness / 100,
          restoring: true,
        }, before, true)) release(id)
      } catch {
        // A temporary client error must retain recovery and must not escape
        // the timer callback and terminate the local bridge.
      }
    }
  }

  const frame = states => {
    expire()
    let applied = 0
    const failed = [], rejectedOwnership = [], seen = new Set()
    for (const state of Array.isArray(states) ? states : []) {
      const id = state?.fixtureID
      if (!id || seen.has(id) || !validRGB(state.rgb)) continue
      seen.add(id)
      const device = registry.get(id)
      if (!device) continue
      if (state.owner) {
        if (state.controlRevision !== device.controlRevision
          || (device.musicOwner && device.musicOwner !== state.owner)
          || ((state.restoring || state.release) && device.musicOwner !== state.owner)
          || (beforeMusic.get(id)?.expired && !state.restoring)) {
          rejectedOwnership.push(id)
          continue
        }
        // The independent heartbeat can overtake a delayed first frame. It
        // cannot claim a light, and an unchanged revision is not a lost lease.
        // An expired/revoked show has a newer revision and is rejected above.
        if (state.heartbeat && !device.musicOwner) continue
        if (state.release) { release(id); continue }
        if (!device.musicOwner) {
          const shapes = device.shapes ?? {}
          brightnessOpened.delete(id)
          beforeMusic.set(id, { owner: state.owner, controlRevision: device.controlRevision,
            output: shapes.output, design: shapes.design ? structuredClone(shapes.design) : null,
            effect: shapes.effect, kelvin: device.kelvin, color: device.color ? { ...device.color } : null,
            brightness: device.brightness, hsbk: device.hsbk ? { ...device.hsbk } : null,
            restoreOnDisconnect: state.restoreOnDisconnect !== false, expired: false })
        }
        const before = beforeMusic.get(id)
        if (before && typeof state.restoreOnDisconnect === 'boolean') before.restoreOnDisconnect = state.restoreOnDisconnect
        registry.patch(id, { musicOwner: state.owner, musicFrameAt: now() })
        if (state.heartbeat) continue
      }
      const saved = state.restoring && state.owner ? beforeMusic.get(id) : undefined
      const before = saved?.owner === state.owner ? saved : undefined
      if (paint(device, state, before)) {
        if (state.restoring) {
          if (state.owner) release(id)
          else forget(id)
        }
        applied++
      } else failed.push(id)
    }
    return { ok: failed.length === 0, applied,
      ...(rejectedOwnership.length ? { rejectedOwnership } : {}),
      ...(failed.length ? { error: 'Music output could not be queued for every light. Retry when the lights reconnect.', failed } : {}),
      stage: 'accepted-for-local-dispatch' }
  }

  return { frame, expire, forget }
}
