import type { Device, DiscoveryResponse } from './bridge'

export type DiscoveryOutcome = 'ready' | 'blocked' | 'partial' | 'silent' | 'unknown'

export interface DiscoverySummary {
  outcome: DiscoveryOutcome
  title: string
  detail: string
  sent: number | null
  failed: number
  unoccupied: number
  errors: string[]
}

/** A reachable reading can predate a scan by 90 seconds. Count fresh replies only. */
export function countDiscoveryReplies(devices: Device[], startedAt: number): number | null {
  if (devices.some(device => typeof device.lastSeen !== 'number')) return null
  return devices.filter(device => device.lastSeen! >= startedAt).length
}

export function summarizeDiscovery(result: DiscoveryResponse, answeredCount: number | null): DiscoverySummary {
  // Nanoleaf's `sent` is a count of paired controllers queued for refresh, not
  // network probes. It must not make a failed UDP discovery look healthy.
  const probes = (['lifx', 'govee'] as const).map(brand => ({ brand, probe: result.probes?.[brand] }))
  const known = probes.filter(({ probe }) => typeof probe?.sent === 'number')
  const sent = known.length ? known.reduce((sum, { probe }) => sum + (probe!.sent ?? 0), 0) : null
  const failed = probes.reduce((sum, { probe }) => sum + (probe?.failed ?? 0), 0)
  const unoccupied = probes.reduce((sum, { probe }) => sum + (probe?.unoccupied ?? 0), 0)
  const errors = probes.flatMap(({ brand, probe }) => {
    const error = probe?.error ?? probe?.lastError
    return error ? [`${brand === 'lifx' ? 'LIFX' : 'Govee'}: ${error}`] : []
  })
  const pairedError = result.probes?.nanoleaf?.error
  if (pairedError) errors.push(`Nanoleaf: ${pairedError}`)
  const answers = answeredCount === null
    ? 'This bridge does not provide fresh reply timestamps.'
    : answeredCount === 0
      ? 'No lights answered during this search.'
      : `${answeredCount} light${answeredCount === 1 ? '' : 's'} answered during this search.`
  const failedVendors = probes.some(({ probe }) => Boolean(probe?.error))
  const allVendorsFailed = probes.every(({ probe }) => Boolean(probe?.error))

  if (!result.ok || sent === 0 || allVendorsFailed) {
    return { outcome: 'blocked', title: 'Discovery could not send network probes',
      detail: `${sent === 0 ? 'No discovery probes were sent. ' : ''}${answers} Check the bridge computer’s network connection and local network permissions, then try again.`,
      sent, failed, unoccupied, errors }
  }
  if (failed || failedVendors || pairedError) {
    return { outcome: 'partial', title: 'Some discovery requests failed',
      detail: `${sent === null ? '' : `${sent} network probes were sent. `}${answers} Check the details below and try again if a light is missing.`,
      sent, failed, unoccupied, errors }
  }
  if (answeredCount !== null && answeredCount > 0) {
    return { outcome: 'ready', title: 'Lights are available', detail: answers, sent, failed, unoccupied, errors }
  }
  if (sent !== null && answeredCount === 0) {
    return { outcome: 'silent', title: 'Probes sent, no lights answered',
      detail: `${sent} network probes were sent. Check the light’s power, Wi-Fi connection and vendor setup below, then search again.`,
      sent, failed, unoccupied, errors }
  }
  return { outcome: 'unknown', title: 'Search finished',
    detail: `${answers} ${sent === null ? 'This bridge does not report network probe diagnostics.' : `${sent} network probes were sent.`} Check the list of lights below.`,
    sent, failed, unoccupied, errors }
}
