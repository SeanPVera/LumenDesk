// Brand-agnostic device store. Mirrors the native app's LightDevice model:
// vendor-prefixed ids ("lifx:…", "govee:…") over a shared shape, so the web
// client never needs to know which protocol a light speaks.

const OFFLINE_AFTER_MS = 90_000

export class Registry {
  constructor({ now = () => Date.now() } = {}) {
    this.now = now
    this.devices = new Map()
  }

  upsert(id, patch) {
    const existing = this.devices.get(id)
    const device = {
      id,
      brand: id.split(':')[0],
      name: id,
      ip: null,
      power: false,
      brightness: 0,
      color: null,
      kelvin: null,
      ...existing,
      ...patch,
      lastSeen: this.now(),
    }
    this.devices.set(id, device)
    return device
  }

  get(id) {
    return this.devices.get(id) ?? null
  }

  /** Optimistic local update applied before the device confirms. */
  patch(id, patch) {
    const existing = this.devices.get(id)
    if (!existing) return null
    const device = { ...existing, ...patch }
    this.devices.set(id, device)
    return device
  }

  list() {
    const now = this.now()
    return [...this.devices.values()]
      .map(d => ({ ...d, reachable: now - d.lastSeen < OFFLINE_AFTER_MS }))
      .sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id))
  }
}
