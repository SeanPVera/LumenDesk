import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { type Device, type RGB, hexToRGB, rgbToHex } from './bridge'
import { type Direction, bounds, fit, neighbor, normalizeDegrees, panelNumbers, toScreen } from './shapes/geometry'
import { type Tone, toRGB, toTone } from './shapes/tone'

// The browser side of the Shapes panel studio. The bridge owns the controller
// and sends the wall's drawing geometry; this page draws it the way the wall
// hangs, lets the user select panels and paint a draft, and applies the draft
// as one static per-panel display. Nothing reaches the wall before Apply.

type Draft = Record<number, Tone>

export interface ShapesActions {
  orientation: (degrees: number) => Promise<unknown>
  paint: (colors: Record<number, RGB>) => Promise<unknown>
  play: (name: string) => Promise<unknown>
  identify: (panelID: number) => Promise<unknown>
}

const INSET = 30
const BLACK: RGB = { r: 0, g: 0, b: 0 }

/** Display only: an sRGB impression of a white point. */
function kelvinRGB(kelvin: number): RGB {
  const t = Math.min(400, Math.max(10, kelvin / 100))
  const clamp = (x: number) => Math.round(Math.min(255, Math.max(0, x)))
  return {
    r: t <= 66 ? 255 : clamp(329.698727446 * (t - 60) ** -0.1332047592),
    g: clamp(t <= 66 ? 99.4708025861 * Math.log(t) - 161.1195681661 : 288.1221695283 * (t - 60) ** -0.0755148492),
    b: t >= 66 ? 255 : t <= 19 ? 0 : clamp(138.5177312231 * Math.log(t - 10) - 305.0447927307),
  }
}

function spoken(rgb: RGB): string {
  const { h, s, v } = toTone(rgb)
  if (v === 0) return 'off'
  const level = `${Math.round(v * 100)} percent`
  if (s < 0.12) return `white, ${level}`
  const names: [number, string][] = [[15, 'red'], [45, 'orange'], [70, 'yellow'], [160, 'green'], [200, 'cyan'],
    [255, 'blue'], [290, 'purple'], [335, 'pink'], [361, 'red']]
  return `${names.find(([limit]) => h < limit)?.[1] ?? 'red'}, ${level}`
}

/** What the wall shows panel by panel, when that can be known without guessing. */
function shownColors(device: Device): Record<number, RGB> | null {
  const shapes = device.shapes!
  const ids = shapes.geometry!.panels.map(p => p.panelID)
  const every = (rgb: RGB) => Object.fromEntries(ids.map(id => [id, rgb]))
  switch (shapes.output) {
    case 'design': return shapes.design ? Object.fromEntries(ids.map(id => [id, shapes.design![id] ?? BLACK])) : null
    case 'solid': return every(device.color ?? { r: 255, g: 255, b: 255 })
    case 'white': return every(kelvinRGB(device.kelvin ?? 3500))
    case 'off': return every(BLACK)
    default: return null
  }
}

function describeOutput(device: Device): string {
  const shapes = device.shapes!
  switch (shapes.output) {
    case 'design': return 'Showing a LumenDesk design'
    case 'solid': return 'One colour across the wall'
    case 'white': return 'White across the wall'
    case 'off': return 'The wall is off'
    case 'effect': return `Playing the controller scene “${shapes.effect}”, so panel colours can’t be read`
    default: return 'Showing something LumenDesk can’t read panel by panel'
  }
}

const SHAPE_NAMES: Record<string, string> = { hexagon: 'hexagons', triangle: 'triangles', miniTriangle: 'mini triangles' }

export function ShapesEditor({ device, actions }: { device: Device; actions: ShapesActions }) {
  const shapes = device.shapes!
  const geometry = shapes.geometry!
  const key = useId().replace(/:/g, '')
  const [selected, setSelected] = useState<number[]>([])
  const [cursor, setCursor] = useState<number | null>(null)
  const [draftDegrees, setDraftDegrees] = useState<number | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [undo, setUndo] = useState<Draft[]>([])
  const [redo, setRedo] = useState<Draft[]>([])
  const [startHex, setStartHex] = useState('#ffffff')
  const [hexText, setHexText] = useState('')
  const [message, setMessage] = useState<string | null>(null)
  const refs = useRef(new Map<number, SVGGElement>())
  const stage = useRef<HTMLDivElement>(null)
  // Drawn one unit per CSS pixel, so labels and edges stay legible on a phone.
  const [width, setWidth] = useState(640)
  useEffect(() => {
    const element = stage.current
    if (!element || typeof ResizeObserver === 'undefined') return undefined
    const observer = new ResizeObserver(entries => {
      const next = Math.round(entries[0]?.contentRect.width ?? 0)
      if (next > 0) setWidth(next)
    })
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  const reported = shapes.orientationPending ?? shapes.orientation ?? 0
  const degrees = draftDegrees ?? reported
  // The height follows the wall as it hangs, not the draft, so turning the
  // drawing re-fits it instead of resizing the page under the pointer.
  const height = useMemo(() => {
    const extent = bounds(geometry, reported)
    const aspect = extent ? (extent.maxY - extent.minY) / Math.max(1, extent.maxX - extent.minX) : 0.6
    return Math.round(Math.min(560, Math.max(240, (width - INSET * 2) * aspect + INSET * 2)))
  }, [geometry, reported, width])
  const view = useMemo(() => fit(geometry, degrees, width, height, INSET), [geometry, degrees, width, height])
  const numbers = useMemo(() => panelNumbers(geometry, degrees), [geometry, degrees])
  const ordered = useMemo(() => [...geometry.panels].sort((a, b) => numbers[a.panelID] - numbers[b.panelID]),
    [geometry, numbers])
  const ids = ordered.map(p => p.panelID)
  // A refresh can drop panels; the selection keeps only the ones still there.
  const selection = selected.filter(id => ids.includes(id))
  const missing = selected.length - selection.length
  const targets = selection.length ? selection : ids
  const shown = shownColors(device)
  const colors: Record<number, RGB> | null = draft
    ? Object.fromEntries(ids.map(id => [id, draft[id] ? toRGB(draft[id]) : BLACK]))
    : shown
  const offline = !device.reachable
  const focusID = cursor !== null && ids.includes(cursor) ? cursor : ids[0]
  const kinds = [...new Set(geometry.panels.map(p => p.kind))]

  useEffect(() => { if (!draft) { setUndo([]); setRedo([]) } }, [draft])

  const toggle = (id: number) => setSelected(list => (list.includes(id) ? list.filter(x => x !== id) : [...list, id]))

  const change = (next: Draft) => {
    if (draft) setUndo(stack => [...stack.slice(-49), draft])
    setRedo([])
    setDraft(next)
  }
  const edit = (tone: (current: Tone) => Tone) => {
    if (!draft) return
    change(Object.fromEntries(ids.map(id => {
      const current = draft[id] ?? toTone(BLACK)
      return [id, targets.includes(id) ? tone(current) : current]
    })))
  }
  const undoStep = () => {
    if (!draft || !undo.length) return
    setRedo(stack => [...stack, draft])
    setDraft(undo[undo.length - 1])
    setUndo(stack => stack.slice(0, -1))
  }
  const redoStep = () => {
    if (!draft || !redo.length) return
    setUndo(stack => [...stack, draft])
    setDraft(redo[redo.length - 1])
    setRedo(stack => stack.slice(0, -1))
  }

  const onPanelKey = (event: KeyboardEvent<SVGGElement>, id: number) => {
    const directions: Record<string, Direction> = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' }
    let next: number | null = null
    if (event.key === ' ' || event.key === 'Enter') {
      event.preventDefault()
      toggle(id)
      return
    }
    if (directions[event.key]) next = neighbor(geometry, degrees, id, directions[event.key])
    else if (event.key === 'Home') next = ids[0]
    else if (event.key === 'End') next = ids[ids.length - 1]
    else return
    event.preventDefault()
    if (next !== null) {
      setCursor(next)
      refs.current.get(next)?.focus()
    }
  }

  const onEditorKey = (event: KeyboardEvent<HTMLElement>) => {
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== 'z' || !draft) return
    const target = event.target as HTMLElement
    if (target.tagName === 'INPUT' && (target as HTMLInputElement).type === 'text') return
    event.preventDefault()
    if (event.shiftKey) redoStep()
    else undoStep()
  }

  const start = (from: Record<number, RGB>) => setDraft(Object.fromEntries(ids.map(id => [id, toTone(from[id] ?? BLACK)])))

  const report = (promise: Promise<unknown>, done: string) =>
    promise.then(() => setMessage(done)).catch(err => setMessage(err instanceof Error ? err.message : String(err)))

  const levels = draft ? targets.map(id => Math.round((draft[id]?.v ?? 0) * 100)) : []
  const level = levels.length ? Math.round(levels.reduce((sum, v) => sum + v, 0) / levels.length) : 0
  const mixedLevel = new Set(levels).size > 1
  const single = selection.length === 1 ? geometry.panels.find(p => p.panelID === selection[0]) : undefined
  const singleColor = single && colors ? colors[single.panelID] : undefined
  const targetHexes = new Set(targets.map(id => (colors?.[id] ? rgbToHex(colors[id]) : 'unknown')))
  const sharedHex = targetHexes.size === 1 && !targetHexes.has('unknown') ? [...targetHexes][0] : null

  return (
    <section className="shapes-editor" aria-labelledby={`${key}-title`} onKeyDown={onEditorKey}>
      <div className="section-line">
        <h2 id={`${key}-title`}>Shapes panels · {device.name}</h2>
        <span className="meta">{geometry.panels.length} panels · {describeOutput(device)}</span>
      </div>
      {shapes.problem && <p className="note attention">The latest layout reading was damaged, so the last good layout is shown. {shapes.problem}</p>}
      {shapes.lastFailure && <p className="note attention">{shapes.lastFailure}</p>}
      {device.needsPairing && <p className="note attention">The controller no longer accepts this bridge. Pair it again in Devices.</p>}
      {missing > 0 && <p className="note attention">{missing} selected panel{missing === 1 ? ' is' : 's are'} no longer in the wall’s layout.</p>}
      <div className="shapes-layout">
        <div className="shapes-stage" ref={stage}>
          <svg className="shapes-canvas" viewBox={`0 0 ${width} ${height}`} role="group"
            aria-label={`${device.name}, ${ids.length} panels drawn as they hang. Arrow keys move between panels, Space selects.`}>
            <defs>
              <pattern id={`${key}-unknown`} patternUnits="userSpaceOnUse" width="7" height="7" patternTransform="rotate(45)">
                <rect width="7" height="7" fill="#1d2022" />
                <line x1="0" y1="0" x2="0" y2="7" stroke="#778187" strokeWidth="1.2" />
              </pattern>
            </defs>
            <text x={width / 2} y={17} textAnchor="middle" className="shapes-up" aria-hidden="true">↑ Up on the wall</text>
            {geometry.references.map(reference => {
              const [x, y] = toScreen([reference.x, reference.y], geometry.pivot, degrees, view)
              return <circle key={`r${reference.panelID}`} cx={x} cy={y} r={Math.max(3, reference.radius * view.scale)}
                className="shapes-reference" aria-hidden="true" />
            })}
            {ordered.map(panel => {
              const outline = panel.outline.map(point => toScreen(point, geometry.pivot, degrees, view))
              const [cx, cy] = toScreen([panel.x, panel.y], geometry.pivot, degrees, view)
              const color = colors?.[panel.panelID]
              const isSelected = selection.includes(panel.panelID)
              const off = Boolean(color) && color!.r + color!.g + color!.b === 0
              const tone = color ? toTone(color) : null
              const ink = !tone || off || tone.v * (1 - 0.5 * tone.s) < 0.55 ? 'light' : 'dark'
              return (
                <g key={panel.panelID} role="checkbox" aria-checked={isSelected}
                  tabIndex={panel.panelID === focusID ? 0 : -1}
                  ref={element => { if (element) refs.current.set(panel.panelID, element); else refs.current.delete(panel.panelID) }}
                  aria-label={`Panel ${numbers[panel.panelID]}, ${panel.name}, ${color ? spoken(color) : 'colour unknown'}`}
                  className={`shapes-panel${isSelected ? ' selected' : ''}${off ? ' off' : ''}`}
                  onFocus={() => setCursor(panel.panelID)}
                  onClick={() => { setCursor(panel.panelID); toggle(panel.panelID) }}
                  onKeyDown={event => onPanelKey(event, panel.panelID)}>
                  <polygon points={outline.map(([x, y]) => `${x.toFixed(2)},${y.toFixed(2)}`).join(' ')}
                    fill={color ? rgbToHex(color) : `url(#${key}-unknown)`} />
                  <text x={cx} y={cy} textAnchor="middle" dominantBaseline="central" className={ink} aria-hidden="true">
                    {`${isSelected ? '✓' : ''}${numbers[panel.panelID]}${color ? '' : '?'}`}
                  </text>
                </g>
              )
            })}
          </svg>
          <p className="note">
            {draft ? 'Draft: not on the wall until you apply it.' : 'What the wall shows now.'} A tick and a white
            edge mark a selected panel, a dashed edge an unlit one, hatching and a ? a colour that can’t be read.
            Colours are drawn before the wall’s brightness ({device.brightness}%).
          </p>
          <div className="toolbar">
            <span className="meta" aria-live="polite">
              {selection.length ? `${selection.length} of ${ids.length} selected` : `Nothing selected: tools change all ${ids.length}`}
            </span>
            <button onClick={() => setSelected(ids)}>Select all</button>
            <button onClick={() => setSelected([])} disabled={!selection.length}>Clear</button>
            <button onClick={() => setSelected(ids.filter(id => !selection.includes(id)))}>Invert</button>
            {kinds.length > 1 && kinds.map(kind => (
              <button key={kind} onClick={() => setSelected(geometry.panels.filter(p => p.kind === kind).map(p => p.panelID))}>
                All {SHAPE_NAMES[kind] ?? kind}
              </button>
            ))}
          </div>
          {single && (
            <div className="panel-info">
              <p className="note">
                Panel {numbers[single.panelID]} · {single.name} · ID {single.panelID} · turned {single.orientation}° in
                the layout · {singleColor ? rgbToHex(singleColor).toUpperCase() : 'colour unknown'}
              </p>
              <button className="ghost" disabled={offline}
                onClick={() => report(actions.identify(single.panelID), 'That panel breathes white on the wall for four seconds.')}>
                Identify on the wall
              </button>
            </div>
          )}
        </div>

        <div className="shapes-tools">
          <fieldset>
            <legend>Orientation</legend>
            <p className="note">
              {shapes.orientationPending !== null ? `${shapes.orientationPending}° requested, waiting for the controller to confirm`
                : shapes.orientation !== null ? `${shapes.orientation}°, read back from the controller` : 'Not reported by the controller'}
            </p>
            <div className="toolbar">
              <button onClick={() => setDraftDegrees(normalizeDegrees(degrees - 90))} aria-label="Turn 90 degrees counterclockwise">↺ 90°</button>
              <label className="inline">Degrees
                <input type="number" min={0} max={359} value={degrees}
                  onChange={e => setDraftDegrees(normalizeDegrees(Math.round(Number(e.target.value) || 0)))} />
              </label>
              <button onClick={() => setDraftDegrees(normalizeDegrees(degrees + 90))} aria-label="Turn 90 degrees clockwise">↻ 90°</button>
            </div>
            <div className="toolbar">
              <button className="primary" disabled={offline || draftDegrees === null || draftDegrees === reported}
                onClick={() => {
                  report(actions.orientation(degrees), 'Orientation sent. It counts once the controller reports it back.')
                  setDraftDegrees(null)
                }}>
                Apply orientation
              </button>
              <button className="ghost" disabled={draftDegrees === null} onClick={() => setDraftDegrees(null)}>Reset</button>
            </div>
            <p className="note">Turn the drawing until it matches the wall. Orientation aims spatial output and the controller’s own gestures; the panels never move.</p>
          </fieldset>

          <fieldset>
            <legend>Paint panels</legend>
            {!draft ? (
              shown ? (
                <button className="primary" disabled={offline} onClick={() => start(shown)}>Paint from what the wall shows</button>
              ) : (
                <>
                  <p className="note">Pick a starting colour. Applying replaces the scene that is playing.</p>
                  <div className="toolbar">
                    <label className="inline">Start colour
                      <input type="color" value={startHex} onChange={e => setStartHex(e.target.value)} />
                    </label>
                    <button disabled={offline} onClick={() => start(Object.fromEntries(ids.map(id => [id, hexToRGB(startHex)])))}>
                      Start painting
                    </button>
                  </div>
                </>
              )
            ) : (
              <>
                <div className="toolbar">
                  <label className="inline">Colour
                    <input type="color" value={sharedHex ?? '#ffffff'}
                      onChange={e => { const exact = toTone(hexToRGB(e.target.value)); edit(() => exact) }} />
                  </label>
                  {!sharedHex && <span className="meta">Mixed</span>}
                  <label className="inline">Hex
                    <input value={hexText} placeholder="#RRGGBB" size={9} onChange={e => setHexText(e.target.value)} />
                  </label>
                  <button onClick={() => {
                    const text = hexText.trim()
                    if (!/^#?[0-9a-f]{6}$/i.test(text)) { setMessage('Enter six hex digits, like #FF6A2B.'); return }
                    const exact = toTone(hexToRGB(text.replace(/^#?/, '#')))
                    edit(() => exact)
                  }}>Set</button>
                  <button onClick={() => edit(tone => ({ ...tone, v: 0 }))}>Turn off</button>
                </div>
                {/* An explicit for: a wrapping label would name the <output>, not the slider. */}
                <div className="field">
                  <span>
                    <label htmlFor={`${key}-level`}>Panel level</label>{' '}
                    <output htmlFor={`${key}-level`}>{mixedLevel ? 'Mixed' : `${level}%`}</output>
                  </span>
                  <input id={`${key}-level`} type="range" min={0} max={100} value={level}
                    aria-valuetext={mixedLevel ? `Mixed, averaging ${level} percent` : `${level} percent`}
                    onChange={e => { const v = Number(e.target.value) / 100; edit(tone => ({ ...tone, v })) }} />
                </div>
                <p className="note">Each panel keeps its own level; the wall’s brightness applies on top of it once.</p>
                <div className="toolbar">
                  <button onClick={undoStep} disabled={!undo.length}>Undo</button>
                  <button onClick={redoStep} disabled={!redo.length}>Redo</button>
                </div>
                <div className="toolbar">
                  <button className="primary" disabled={offline} onClick={() => {
                    report(actions.paint(Object.fromEntries(ids.map(id => [id, toRGB(draft[id] ?? toTone(BLACK))]))),
                      'Applied. The wall confirms it on its next reading.')
                    setDraft(null)
                  }}>Apply to wall</button>
                  <button className="ghost" onClick={() => setDraft(null)}>Discard draft</button>
                </div>
              </>
            )}
          </fieldset>

          <fieldset>
            <legend>Scenes on the controller</legend>
            {shapes.effects.length ? (
              <ul className="rows">
                {shapes.effects.map(name => (
                  <li className="row" key={name}>
                    <span className="row-action">{name}{shapes.effect === name && <strong> · playing</strong>}</span>
                    <button disabled={offline} onClick={() => report(actions.play(name), `Playing “${name}”.`)}>Play</button>
                  </li>
                ))}
              </ul>
            ) : <p className="note">The controller reports no stored scenes.</p>}
            <p className="note">In the browser, Music Mode drives a Shapes wall as one colour. The native app streams music panel by panel.</p>
          </fieldset>
          {message && <p className="note" role="status">{message}</p>}
        </div>
      </div>
    </section>
  )
}

/** The wall in a fixture tile: panel colours where they can be known, hatched where not. */
export function ShapesMiniWall({ device }: { device: Device }) {
  const geometry = device.shapes!.geometry!
  const degrees = device.shapes!.orientation ?? 0
  const key = useId().replace(/:/g, '')
  const view = fit(geometry, degrees, 120, 40, 2)
  const lit = device.power && device.reachable
  const colors = lit ? shownColors(device) : null
  return (
    <svg className="shapes-mini" viewBox="0 0 120 40" aria-hidden="true" focusable="false">
      <defs>
        <pattern id={`${key}-unknown`} patternUnits="userSpaceOnUse" width="5" height="5" patternTransform="rotate(45)">
          <rect width="5" height="5" fill="#1d2022" />
          <line x1="0" y1="0" x2="0" y2="5" stroke="#778187" strokeWidth="1" />
        </pattern>
      </defs>
      {geometry.panels.map(panel => {
        const color = colors?.[panel.panelID]
        const fill = !lit ? 'var(--surface)' : color ? rgbToHex(color) : `url(#${key}-unknown)`
        return <polygon key={panel.panelID} fill={fill}
          points={panel.outline.map(point => toScreen(point, geometry.pivot, degrees, view).map(n => n.toFixed(1)).join(',')).join(' ')} />
      })}
    </svg>
  )
}
