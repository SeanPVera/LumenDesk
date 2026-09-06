import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { Device } from './bridge'
import { MUSIC_HELP, PRESET_COPY, ROLE_COPY, SOURCE_COPY, configurationFor } from './music/config'
import { GROOVES } from './music/grooves'
import { hsvToRgb } from './music/fixtures'
import { WebMusicSession, frameToCommands, setFixtureRole } from './music/session'
import type { FixtureRole, MusicModePreset } from './music/types'

const PRESETS: Exclude<MusicModePreset, 'custom'>[] = [
  'ambient',
  'balanced',
  'concert',
  'cinematic',
  'soundcheck',
  'club',
  'halftime',
  'waltz',
]

const ROLES: FixtureRole[] = ['auto', 'wash', 'hit', 'accent', 'motion', 'off']

export function MusicModeView({
  devices,
  port,
  postFrame,
}: {
  devices: Device[]
  port: number
  postFrame: (
    port: number,
    states: { fixtureID: string; rgb: { r: number; g: number; b: number } }[],
  ) => Promise<unknown>
}) {
  const sessionRef = useRef<WebMusicSession | null>(null)
  if (!sessionRef.current) sessionRef.current = new WebMusicSession()
  const session = sessionRef.current
  const version = useSyncExternalStore(
    listener => session.subscribe(listener),
    () => session.version,
    () => session.version,
  )
  const state = session.state
  void version
  const [file, setFile] = useState<File | null>(null)
  const reachable = devices.filter(d => d.reachable)

  useEffect(() => {
    session.setDevices(reachable.map(d => ({ id: d.id, name: d.name, brand: d.brand, reachable: d.reachable })))
  }, [session, reachable.map(d => d.id).join('|')])

  useEffect(() => {
    session.setOnFrame(frame => {
      const commands = frameToCommands(frame)
      if (commands.length) postFrame(port, commands).catch(() => undefined)
    })
    return () => session.setOnFrame(null)
  }, [session, port, postFrame])

  const snapshot = state.snapshot
  const presetCopyKey = state.configuration.preset === 'custom' ? 'balanced' : state.configuration.preset
  const tempo =
    snapshot.isTempoLocked && snapshot.tempo > 0
      ? `${Math.round(snapshot.feltTempo || snapshot.tempo)} · ${snapshot.metre}/${snapshot.metre === 6 ? 8 : 4}`
      : 'Beat'

  return (
    <section className="music-desk">
      <div className="panel">
        <p className="eyebrow">Music Mode</p>
        <h2>Your lights follow the music.</h2>
        <p>
          Pick where the sound comes from, pick a preset, press Start. The music is analysed in
          this browser tab and never uploaded anywhere; only the resulting colours go to the
          bridge running on your own machine.
        </p>
        <ol className="steps">
          {MUSIC_HELP.steps.map(step => (
            <li key={step}>{step}</li>
          ))}
        </ol>
        <p className="note">{MUSIC_HELP.safety}</p>
        <div className="music-toolbar">
          <button
            className="primary"
            disabled={!reachable.length && state.source !== 'demo'}
            onClick={() => session.start(state.source === 'file' && file ? 'file' : state.source === 'midi' ? 'midi' : state.source === 'microphone' ? 'microphone' : 'demo', file ?? undefined)}
          >
            {state.running ? 'Restart' : 'Start'}
          </button>
          <button onClick={() => session.stop()} disabled={!state.running}>
            Stop
          </button>
          <button
            onClick={() => session.start('demo')}
            className={state.source === 'demo' ? 'nav active' : undefined}
            title={SOURCE_COPY.demo.plain}
          >
            Demo groove
          </button>
          <button
            onClick={() => session.start('microphone')}
            className={state.source === 'microphone' ? 'nav active' : undefined}
            title={SOURCE_COPY.microphone.plain}
          >
            Microphone
          </button>
          <label className="file-key" title={SOURCE_COPY.file.plain}>
            Open audio file
            <input
              type="file"
              accept="audio/*"
              onChange={event => {
                const next = event.target.files?.[0]
                if (!next) return
                setFile(next)
                session.start('file', next)
              }}
            />
          </label>
          <button onClick={() => session.start('midi')} title={SOURCE_COPY.midi.plain}>
            MIDI clock
          </button>
        </div>
        <p className="note">{SOURCE_COPY[state.source]?.plain ?? SOURCE_COPY.demo.plain}</p>
        {state.error && (
          <p className="error" role="alert">
            {state.error}
          </p>
        )}
        <p className="meta">
          {state.running ? 'Running' : 'Idle'} · {sourceLabel(state.source, state.fileName)} · {reachable.length} lights
          {state.midiClock ? ' · MIDI' : ''}
        </p>
      </div>

      <div className="panel">
        <p className="eyebrow">Preset</p>
        <div className="chip-row">
          {PRESETS.map(id => (
            <button
              key={id}
              className={state.configuration.preset === id ? 'chip on' : 'chip'}
              onClick={() => session.patch({ configuration: configurationFor(id) })}
            >
              {PRESET_COPY[id].name}
            </button>
          ))}
        </div>
        <p>{PRESET_COPY[presetCopyKey].plain}</p>
        <p className="meta">
          Good for: {PRESET_COPY[presetCopyKey].bestFor} · {PRESET_COPY[presetCopyKey].summary}
        </p>
        {state.source === 'demo' && (
          <label className="field">
            Demo groove
            <select
              value={state.grooveId}
              onChange={event => session.patch({ grooveId: event.target.value })}
            >
              {GROOVES.map(groove => (
                <option key={groove.id} value={groove.id}>
                  {groove.name} — {groove.summary}
                </option>
              ))}
            </select>
          </label>
        )}
      </div>

      <div className="panel meters">
        <Meter label="Input" value={snapshot.level} />
        <Meter label="Bass" value={snapshot.bass} />
        <Meter label="Mids" value={snapshot.mids} />
        <Meter label="Highs" value={snapshot.highs} />
        <div className="beat-readout">
          <span className={`beat-dot${snapshot.beat > 0.25 ? ' lit' : ''}`} />
          <span>{tempo}</span>
        </div>
        <p className="note">{MUSIC_HELP.readout}</p>
      </div>

      <div className="panel">
        <p className="eyebrow">Which light does what</p>
        <p>{MUSIC_HELP.roles}</p>
        {state.fixtures.length === 0 ? (
          <p>No lights yet. Scan from Home, or run a demo groove to watch the lights move without any hardware.</p>
        ) : (
          <ul className="fixture-list">
            {state.fixtures.map(fixture => {
              const stateFor = state.frame?.states.find(s => s.fixtureID === fixture.id)
              const rgb = stateFor ? hsvToRgb(stateFor.hue, stateFor.saturation, stateFor.brightness) : null
              return (
                <li key={fixture.id}>
                  <span
                    className="fixture-swatch"
                    style={rgb ? { background: `rgb(${rgb.r} ${rgb.g} ${rgb.b})` } : undefined}
                  />
                  <strong>{fixture.label}</strong>
                  <select
                    value={fixture.role}
                    title={ROLE_COPY[fixture.role].plain}
                    onChange={event => {
                      setFixtureRole(session, fixture.id, event.target.value as FixtureRole)
                      session.patch({})
                    }}
                  >
                    {ROLES.map(role => (
                      <option key={role} value={role}>
                        {ROLE_COPY[role].name}
                      </option>
                    ))}
                  </select>
                </li>
              )
            })}
          </ul>
        )}
        <dl className="role-legend">
          {ROLES.map(role => (
            <div key={role}>
              <dt>{ROLE_COPY[role].name}</dt>
              <dd>{ROLE_COPY[role].plain}</dd>
            </div>
          ))}
        </dl>
      </div>
      <p className="meta">
        {MUSIC_HELP.strips} Colours go to the bridge on port {port}.
      </p>
    </section>
  )
}

function Meter({ label, value }: { label: string; value: number }) {
  return (
    <label className="field">
      {label}
      <meter min={0} max={1} value={Math.max(0, Math.min(1, value))} />
    </label>
  )
}

function sourceLabel(source: string, fileName: string | null): string {
  if (source === 'file') return fileName ?? 'Audio file'
  if (source === 'microphone') return 'Microphone'
  if (source === 'midi') return 'MIDI clock'
  return 'Demo groove'
}
