import { useEffect, useRef, useState } from 'react'
import type { Device } from './bridge'

/** Keep a rejected name visibly unsaved until the user retries or cancels. */
export function DeviceName({ device, onRename }: {
  device: Device
  onRename: (device: Device, name: string) => Promise<boolean>
}) {
  const [draft, setDraft] = useState(device.name)
  const [dirty, setDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const canonical = useRef(device.name)
  const pending = useRef(false)

  useEffect(() => {
    if (device.name === canonical.current) return
    canonical.current = device.name
    if (!dirty && !pending.current) {
      setDraft(device.name)
      if (device.name !== draft) setSaved(false)
    }
  }, [device.name, dirty, draft])

  const cancel = () => {
    if (pending.current) return
    setDraft(device.name)
    setDirty(false)
    setProblem(null)
    setSaved(false)
  }

  return <form className="device-name" aria-label={`Name for ${device.name}`} aria-busy={saving}
    onSubmit={async event => {
      event.preventDefault()
      if (pending.current || !draft.trim() || !dirty) return
      const name = draft.trim()
      if (name === device.name) {
        setDraft(name)
        setDirty(false)
        setProblem(null)
        return
      }
      pending.current = true
      setSaving(true)
      setProblem(null)
      try {
        if (await onRename(device, name)) {
          setDraft(name)
          setDirty(false)
          setSaved(true)
        } else {
          setProblem('Name was not saved. Retry or cancel your changes.')
        }
      } catch (error) {
        setProblem(error instanceof Error ? error.message : 'Name was not saved. Try again.')
      } finally {
        pending.current = false
        setSaving(false)
      }
    }}>
    <input className="rename" aria-label={`Rename ${device.name}`} value={draft} maxLength={60}
      disabled={saving} required onChange={event => {
        setDraft(event.target.value)
        setDirty(event.target.value !== device.name)
        setProblem(null)
        setSaved(false)
      }} />
    {dirty && <div className="name-actions">
      <button type="submit" disabled={saving || !draft.trim()}>{saving ? 'Saving…' : 'Save'}</button>
      <button type="button" className="ghost" disabled={saving} onClick={cancel}>Cancel</button>
      {!saving && !problem && <span className="note">Unsaved changes</span>}
    </div>}
    {saved && <span className="note" role="status">Name saved</span>}
    {problem && <p className="error" role="alert">{problem}</p>}
  </form>
}
