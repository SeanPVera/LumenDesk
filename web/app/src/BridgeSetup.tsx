import { DEFAULT_PORT, healthURL } from './bridge'

export type BridgeState = 'checking' | 'connected' | 'unavailable'

/** A blocked local-network request and a bridge that is not running both
 *  surface as an opaque TypeError, so the message stays honest about that. */
export function describeFailure(err: unknown): string {
  if (err instanceof DOMException && err.name === 'TimeoutError') {
    return 'The bridge did not answer in time.'
  }
  return 'Could not reach the bridge.'
}

export function BridgeSetup({
  state,
  port,
  error,
  attempts,
  servedByBridge,
  onPort,
  onRetry,
}: {
  state: BridgeState
  port: number
  error: string | null
  attempts: number
  servedByBridge: boolean
  onPort: (value: number) => void
  onRetry: () => void
}) {
  const checking = state === 'checking'
  return (
    <div className="shell centered">
      <div className="panel wide">
        <span className="eyebrow">Local control only</span>
        <h1>Start the LumenDesk bridge</h1>
        <p>
          Browsers cannot open the raw UDP sockets that LIFX and Govee lights speak, so a small
          helper runs on your machine and does it for you — no account, no cloud, nothing leaves
          your network.
        </p>
        <p>
          The helper can also <strong>serve this app itself</strong>, which is the route that
          always works: the page and the lights are then the same local service, so no browser
          permission is involved.
        </p>

        <ol className="steps">
          <li>
            Install <a href="https://nodejs.org/">Node.js 20 or newer</a>, if you do not have it.
            Check with <code>node --version</code>.
          </li>
          <li>
            Open a terminal and run these three commands:
            <pre>
              <code>{`git clone --depth 1 https://github.com/SeanPVera/LumenDesk.git
cd LumenDesk/web/bridge
npm run app`}</code>
            </pre>
            <span className="note">
              It prints <code>LumenDesk is running. Open http://127.0.0.1:8765</code> when ready.
            </span>
          </li>
          <li>
            <strong>Open <code>http://127.0.0.1:8765</code></strong> — that address is this same
            app, served by the bridge, and it can always reach your lights. Keep the terminal open;
            the bridge only runs while it does.
          </li>
        </ol>

        <p className="hint">
          Prefer to keep using this published page instead? Run <code>npm start</code> rather than{' '}
          <code>npm run app</code> to expose only the API, then press Connect below — that route
          needs your browser to allow local network access.
        </p>

        <details className="alt">
          <summary>No git installed?</summary>
          <p>Download and unpack the repository instead:</p>
          <pre>
            <code>{`curl -L https://github.com/SeanPVera/LumenDesk/archive/refs/heads/main.tar.gz | tar xz
cd LumenDesk-main/web/bridge
npm start`}</code>
          </pre>
        </details>

        <div className="setup-actions">
          <label className="port">
            Bridge port
            <input
              type="number"
              value={port}
              min={1}
              max={65535}
              disabled={checking}
              onChange={event => onPort(Number(event.target.value) || DEFAULT_PORT)}
            />
          </label>
          <button className="primary" onClick={onRetry} disabled={checking}>
            {checking ? 'Connecting…' : 'Connect'}
          </button>
        </div>

        {attempts > 0 && !checking && (
          <div className="diagnostic" role="alert">
            <p className="diagnostic-head">
              {error ?? 'Could not reach the bridge.'} Tried{' '}
              <code>{healthURL(port)}</code>
              {attempts > 1 && ` · ${attempts} attempts`}
            </p>

            <p>
              <strong>1. Check whether the bridge is running.</strong> Open{' '}
              <a href={healthURL(port)} target="_blank" rel="noreferrer">
                {healthURL(port)}
              </a>{' '}
              in a new tab.
            </p>
            <ul>
              <li>
                If that tab shows <code>{'{"ok":true,…}'}</code>, the bridge is fine and your
                browser is blocking this page from reaching it — see step 2.
              </li>
              <li>
                If the tab fails to load, the bridge is not running. Start it with the commands
                above, and check the port here matches the one it printed.
              </li>
            </ul>

            {!servedByBridge && (
              <>
                <p>
                  <strong>2. Allow local network access.</strong> Chrome 142 and later ask
                  permission before a website may reach your local network. Look for that prompt,
                  or click the icon to the left of the address bar → <em>Site settings</em> → allow{' '}
                  <em>Local network access</em>, then press Connect again.
                </p>

                <p>
                  <strong>Still stuck?</strong> Skip the permission entirely by letting the bridge
                  serve the app, then use the address it prints:
                </p>
                <pre>
                  <code>{`cd LumenDesk/web/bridge
npm run app`}</code>
                </pre>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
