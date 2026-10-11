import { useRef, useState } from 'react'
import type { Device } from './bridge'

/** Scene capture always uses the complete room scope, independent of output filters. */
export function SceneCapture({ devices, scopeName, onSave, showHeading = true }: {
  devices: Device[]
  scopeName: string
  onSave: (name: string) => Promise<boolean>
  showHeading?: boolean
}) {
  const [name, setName] = useState('')
  const [saving, setSaving] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const pending = useRef(false)
  const unavailable = devices.filter(device => !device.reachable || device.needsPairing).length

  return <div className="scene-capture-form">
    {showHeading && <h2>Save the current lighting</h2>}
    <p>Captures power, brightness and color for all {devices.length} fixture{devices.length === 1 ? '' : 's'} in <strong>{scopeName}</strong>,
      including fixtures hidden by a filter or outside your selection.</p>
    {unavailable > 0 && <p className="note">{unavailable} unavailable fixture{unavailable === 1 ? '' : 's'} will use the last known lighting.</p>}
    <form className="inline-form" aria-busy={saving} onSubmit={async event => {
      event.preventDefault()
      if (pending.current || !name.trim() || !devices.length) return
      pending.current = true
      setSaving(true)
      setProblem(null)
      try {
        if (await onSave(name.trim())) setName('')
        else setProblem('The scene was not saved. Your name is kept so you can try again.')
      } catch (error) {
        setProblem(error instanceof Error ? error.message : String(error))
      } finally {
        pending.current = false
        setSaving(false)
      }
    }}>
      <input type="text" aria-label="Scene name" placeholder="Scene name, e.g. Evening"
        value={name} onChange={event => { setName(event.target.value); setProblem(null) }}
        maxLength={60} disabled={saving} />
      <button className="primary" type="submit" disabled={saving || !name.trim() || !devices.length}>
        {saving ? 'Saving…' : 'Save scene'}
      </button>
    </form>
    {problem && <p className="error" role="status">{problem}</p>}
  </div>
}
