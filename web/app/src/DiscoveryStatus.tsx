import type { DiscoveryResponse } from './bridge'
import { summarizeDiscovery } from './discovery'

export interface DiscoveryStatusProps {
  scanning: boolean
  result: DiscoveryResponse | null
  answeredCount: number | null
  problem?: string | null
  onPair?: () => void
  onRetry?: () => void
}

export function DiscoveryStatus({ scanning, result, answeredCount, problem, onPair, onRetry }: DiscoveryStatusProps) {
  const summary = result ? summarizeDiscovery(result, answeredCount) : null
  const needsHelp = Boolean(problem || (summary && summary.outcome !== 'ready'))
  return <div className="discovery-status">
    <div role="status" aria-live="polite">
      {scanning ? <p>Searching your local network… Lights may appear while the search runs. A search can take up to a minute.</p>
        : problem ? <p className="error">Search failed: {problem}</p>
          : summary ? <>
            <p><strong>{summary.title}</strong></p>
            <p>{summary.detail}</p>
          </> : <p>Search for LIFX and Govee lights, or pair a Nanoleaf wall by its controller address.</p>}
    </div>
    {!scanning && summary && <details>
      <summary>Discovery details</summary>
      <ul className="steps">
        {(['lifx', 'govee'] as const).map(brand => {
          const probe = result?.probes?.[brand]
          return <li key={brand}><strong>{brand === 'lifx' ? 'LIFX' : 'Govee'}:</strong>{' '}
            {typeof probe?.sent === 'number'
              ? `${probe.sent} probes sent · ${probe.failed ?? 0} failed · ${probe.unoccupied ?? 0} empty addresses`
              : probe?.error ? 'Discovery failed' : 'Probe details unavailable'}
            {probe?.interfaces?.length ? <span> · {probe.interfaces.join(', ')}</span> : null}
          </li>
        })}
        {summary.errors.map(error => <li key={error} className="error">{error}</li>)}
      </ul>
      <p className="note">An empty address means no device lives there. Sending a probe does not confirm that a light received it.</p>
    </details>}
    <details open={needsHelp}>
      <summary>Prepare your lights and network</summary>
      <ol className="steps">
        <li>Keep the lights powered on and connect the computer running the bridge to the same local network. Guest Wi-Fi and client isolation can prevent devices from reaching each other.</li>
        <li><strong>Govee:</strong> open the light’s settings in Govee Home and enable <strong>LAN Control</strong>. Models without that setting may not support local control.</li>
        <li><strong>Nanoleaf Shapes or Aurora:</strong> pair the controller by its IP address. Hold its power button for 5–7 seconds until the LED flashes, then pair within 30 seconds.
          {onPair && <div><button type="button" className="ghost" onClick={onPair}>Pair a Nanoleaf wall</button></div>}
        </li>
        <li><strong>If probes cannot be sent:</strong> check local network permission for the bridge app or terminal in your computer’s settings. Check the firewall and any VPN that changes the local network route. If the browser reports blocked local access, open the page served by the bridge.</li>
      </ol>
    </details>
    {!scanning && needsHelp && onRetry && <button type="button" onClick={onRetry}>Search again</button>}
  </div>
}
