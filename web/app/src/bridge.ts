// Client for the local LumenDesk bridge. The bridge runs on the user's own
// machine and owns the UDP sockets; this page only ever speaks HTTP to
// loopback, which browsers treat as a trustworthy origin even from HTTPS.

export type Brand = 'lifx' | 'govee'

export interface RGB {
  r: number
  g: number
  b: number
}

export interface Device {
  id: string
  brand: Brand
  name: string
  ip: string | null
  reachable: boolean
  power: boolean
  brightness: number
  color: RGB | null
  kelvin: number | null
}

export const DEFAULT_PORT = 8765

// When the bridge serves this page itself, the API is on the very same origin,
// so relative requests work and no cross-origin rules apply at all. That is
// resolved once at startup by probing same-origin /health; anything else (the
// published page, `npm run dev`) falls back to loopback on the chosen port.
let sameOrigin = false

export function useSameOrigin(value: boolean): void {
  sameOrigin = value
}

export function bridgeURL(port: number): string {
  return sameOrigin ? window.location.origin : `http://127.0.0.1:${port}`
}

/**
 * True when the page was served by the bridge. Checked before anything else so
 * the app never asks the browser for local-network access it does not need.
 */
export async function detectSameOrigin(): Promise<boolean> {
  try {
    const response = await fetch(`${window.location.origin}/health`, {
      signal: AbortSignal.timeout(2000),
    })
    if (!response.ok) return false
    const body = await response.json()
    return body?.service === 'lumendesk-bridge'
  } catch {
    return false
  }
}

/** The URL a user can open in a tab to check the bridge themselves. */
export function healthURL(port: number): string {
  return `${bridgeURL(port)}/health`
}

// A blocked local-network request can hang rather than fail fast, so every
// call is bounded instead of leaving the UI waiting forever.
const TIMEOUT_MS = 5000

async function request<T>(port: number, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${bridgeURL(port)}${path}`, {
    ...init,
    signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: init?.body ? { 'Content-Type': 'application/json' } : undefined,
  })
  if (!response.ok) {
    const detail = await response.json().catch(() => null)
    throw new Error(detail?.error ?? `bridge returned ${response.status}`)
  }
  return response.json() as Promise<T>
}

export function checkHealth(port: number) {
  return request<{ ok: boolean; service: string; version: string }>(port, '/health')
}

export function fetchDevices(port: number) {
  return request<{ devices: Device[] }>(port, '/devices').then(r => r.devices)
}

export function startDiscovery(port: number) {
  return request<{ ok: boolean }>(port, '/discover', { method: 'POST' })
}

const command = (port: number, id: string, action: string, body: unknown) =>
  request<{ device: Device }>(port, `/devices/${encodeURIComponent(id)}/${action}`, {
    method: 'POST',
    body: JSON.stringify(body),
  }).then(r => r.device)

export const setPower = (port: number, id: string, on: boolean) =>
  command(port, id, 'power', { on })

export const setBrightness = (port: number, id: string, value: number) =>
  command(port, id, 'brightness', { value })

export const setColor = (port: number, id: string, rgb: RGB) =>
  command(port, id, 'color', { rgb })

export const setKelvin = (port: number, id: string, kelvin: number) =>
  command(port, id, 'color', { kelvin })

export function hexToRGB(hex: string): RGB {
  const value = hex.replace('#', '')
  return {
    r: parseInt(value.slice(0, 2), 16),
    g: parseInt(value.slice(2, 4), 16),
    b: parseInt(value.slice(4, 6), 16),
  }
}

export function rgbToHex({ r, g, b }: RGB): string {
  const part = (v: number) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')
  return `#${part(r)}${part(g)}${part(b)}`
}
