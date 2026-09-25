// Draws a Nanoleaf Shapes wall from the outlines the bridge sends. The
// geometry itself (outlines, pivot) comes from web/bridge/src/nanoleaf.js,
// which is tested in lockstep with the native app; this file only turns it
// the way the wall hangs and fits it on screen. The rotation and numbering
// mirror NanoleafWallTransform and spatialPositions: keep them in lockstep,
// or the page will number and aim panels differently from the native app.

export type Point = [number, number]

export interface ShapesPanel {
  panelID: number
  kind: string
  name: string
  x: number
  y: number
  orientation: number
  outline: Point[]
}

export interface ShapesReference {
  panelID: number
  kind: string
  x: number
  y: number
  radius: number
}

export interface ShapesGeometry {
  pivot: Point
  panels: ShapesPanel[]
  references: ShapesReference[]
}

export type Direction = 'up' | 'down' | 'left' | 'right'

export function normalizeDegrees(degrees: number): number {
  if (!Number.isFinite(degrees)) return 0
  const remainder = degrees % 360
  return remainder < 0 ? remainder + 360 : remainder
}

/** Clockwise by the global orientation about the pivot, y up, exact at right angles. */
export function toWall(point: Point, pivot: Point, degrees: number): Point {
  const radians = (normalizeDegrees(degrees) * Math.PI) / 180
  const snap = (value: number) => (Math.abs(value) < 1e-12 ? 0 : value)
  const c = snap(Math.cos(radians))
  const s = snap(Math.sin(radians))
  const dx = point[0] - pivot[0]
  const dy = point[1] - pivot[1]
  return [dx * c + dy * s, -dx * s + dy * c]
}

export interface Fit {
  scale: number
  /** Screen position of the wall origin. */
  ox: number
  oy: number
}

export interface Bounds { minX: number; maxX: number; minY: number; maxY: number }

/** The drawing's extent on the wall as oriented, controller markers included. */
export function bounds(geometry: ShapesGeometry, degrees: number): Bounds | null {
  const points: Point[] = [
    ...geometry.panels.flatMap(p => p.outline.map(point => toWall(point, geometry.pivot, degrees))),
    ...geometry.references.flatMap(r => {
      const [x, y] = toWall([r.x, r.y], geometry.pivot, degrees)
      return [[x - r.radius, y - r.radius], [x + r.radius, y + r.radius]] as Point[]
    }),
  ]
  if (!points.length) return null
  const xs = points.map(p => p[0])
  const ys = points.map(p => p[1])
  return { minX: Math.min(...xs), maxX: Math.max(...xs), minY: Math.min(...ys), maxY: Math.max(...ys) }
}

/** Uniform scale, centred, y flipped for the screen. */
export function fit(geometry: ShapesGeometry, degrees: number, width: number, height: number, inset = 24): Fit {
  const extent = bounds(geometry, degrees)
  if (!extent) return { scale: 1, ox: width / 2, oy: height / 2 }
  const { minX, maxX, minY, maxY } = extent
  const scale = Math.min((width - inset * 2) / Math.max(1, maxX - minX), (height - inset * 2) / Math.max(1, maxY - minY))
  return { scale, ox: width / 2 - ((minX + maxX) / 2) * scale, oy: height / 2 + ((minY + maxY) / 2) * scale }
}

export function toScreen(point: Point, pivot: Point, degrees: number, view: Fit): Point {
  const [x, y] = toWall(point, pivot, degrees)
  return [view.ox + x * view.scale, view.oy - y * view.scale]
}

/** 1 is the leftmost panel on the wall as oriented; ties go to the lower ID. */
export function panelNumbers(geometry: ShapesGeometry, degrees: number): Record<number, number> {
  const placed = geometry.panels.map(p => ({ id: p.panelID, x: toWall([p.x, p.y], geometry.pivot, degrees)[0] }))
  const xs = placed.map(p => p.x)
  const span = Math.max(...xs) - Math.min(...xs)
  const minX = Math.min(...xs)
  const quantised = (x: number) => (span < 0.5 ? 0.5 : Math.round(((x - minX) / span) * 1e9) / 1e9)
  placed.sort((a, b) => quantised(a.x) - quantised(b.x) || a.id - b.id)
  return Object.fromEntries(placed.map((p, index) => [p.id, index + 1]))
}

/** The nearest panel within 60° of a direction on the wall, for arrow keys. */
export function neighbor(geometry: ShapesGeometry, degrees: number, from: number, direction: Direction): number | null {
  const origin = geometry.panels.find(p => p.panelID === from)
  if (!origin) return geometry.panels[0]?.panelID ?? null
  const [sx, sy] = toWall([origin.x, origin.y], geometry.pivot, degrees)
  const axis: Point = { up: [0, 1], down: [0, -1], left: [-1, 0], right: [1, 0] }[direction] as Point
  let best: { id: number; score: number } | null = null
  for (const panel of geometry.panels) {
    if (panel.panelID === from) continue
    const [x, y] = toWall([panel.x, panel.y], geometry.pivot, degrees)
    const dx = x - sx, dy = y - sy
    const distance = Math.hypot(dx, dy)
    if (distance <= 0.5) continue
    const alignment = (dx * axis[0] + dy * axis[1]) / distance
    if (alignment < 0.5) continue
    const score = distance * (2 - alignment)
    if (!best || score < best.score || (score === best.score && panel.panelID < best.id)) best = { id: panel.panelID, score }
  }
  return best?.id ?? null
}
