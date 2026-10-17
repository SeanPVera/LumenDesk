import { useEffect, useState } from 'react'
import { healthURL } from './bridge'

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
  failedEndpoint = 'health',
  attempts,
  servedByBridge,
  onPort,
  onRetry,
}: {
  state: BridgeState
  port: number
  error: string | null
  failedEndpoint?: 'health' | 'state'
  attempts: number
  servedByBridge: boolean
  onPort: (value: number) => void
  onRetry: () => void
}) {
  const checking = state === 'checking'
  const [portText, setPortText] = useState(String(port))
  useEffect(() => setPortText(String(port)), [port])
  const requestedPort = Number(portText)
  const validPort = Number.isInteger(requestedPort) && requestedPort >= 1 && requestedPort <= 65535
  const diagnosticURL = failedEndpoint === 'state'
    ? healthURL(port).replace(/\/health$/, '/state') : healthURL(port)
  return (
    <main className="shell centered">
      <div className="panel wide">
        <span className="eyebrow">Local control only</span>
        <h1>{checking ? 'Connecting to your lights' : 'Connect your local lights'}</h1>
        <p>LumenDesk needs a local bridge to reach your LIFX, Govee and Nanoleaf lights.
          Start it on this computer, then open its local address. No LumenDesk account is required.</p>
        <p className="note">Connecting checks the bridge without changing your lights. You can safely retry.</p>


        <div className="bridge-install">
          <h2>Launch the browser bridge</h2>
          <p>Packaged previews for Mac, Windows and Linux include the runtime and this app.
            Sign in to GitHub, open the latest successful <strong>main</strong> build,
            and choose your computer under <strong>Artifacts</strong>. Unpack the downloaded
            zip, then open the launcher inside. Keep it running while you use your lights.</p>
          <a className="download-link" href="https://github.com/SeanPVera/LumenDesk/actions/workflows/bridge-packages.yml?query=branch%3Amain">Get a packaged preview</a>
          <p className="note">Preview downloads need a GitHub account and expire after 14 days.
            Use a newer successful build if needed, or set up from source below.
            {' '}<a href="https://github.com/SeanPVera/LumenDesk/releases">Release downloads</a>
            {' '}include the bridge only when Assets lists LumenDesk-Bridge files.</p>
        </div>

        <details className="alt">
          <summary>Set up from source</summary>
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
            app, served by the bridge, and it can send commands on your network. Keep the terminal open;
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
npm run app`}</code>
          </pre>
        </details>
        </details>

        <form className="setup-actions" onSubmit={event => {
          event.preventDefault()
          if (!validPort || checking) return
          if (requestedPort !== port) onPort(requestedPort)
          else onRetry()
        }}>
          <label className="port">
            Bridge port
            <input
              type="number"
              value={portText}
              min={1}
              max={65535}
              required
              onChange={event => setPortText(event.target.value)}
            />
          </label>
          <button className="primary" type="submit" disabled={checking || !validPort}>
            {checking ? 'Connecting…' : 'Connect'}
          </button>
        </form>

        {(attempts > 0 || error) && !checking && (
          <div className="diagnostic" role="alert">
            <p className="diagnostic-head">
              {error ?? 'Could not reach the bridge.'} Tried{' '}
              <code>{diagnosticURL}</code>
              {attempts > 1 && ` · ${attempts} attempts`}
            </p>

            <p>
              <strong>1. Check the bridge response.</strong> Open{' '}
              <a href={diagnosticURL} target="_blank" rel="noreferrer">
                {diagnosticURL}
              </a>{' '}
              in a new tab.
            </p>
            {failedEndpoint === 'state' ? <p>
              The bridge answered its health check, but the app could not load its lighting data.
              If this address also fails, restart the bridge and check its terminal for an error.
              If it shows device data, press Connect again.
            </p> : <ul>
              <li>
                If that tab shows <code>{'{"ok":true,…}'}</code>, the bridge is fine and your
                browser is blocking this page from reaching it — see step 2.
              </li>
              <li>
                If the tab fails to load, the bridge is not running. Start it with the commands
                above, and check the port here matches the one it printed.
              </li>
            </ul>}

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
    </main>
  )
}
