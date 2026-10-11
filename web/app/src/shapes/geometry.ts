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

export type WallTransform = (point: Point) => Point

/**
 * Creates a transformation function that rotates points clockwise by the given
 * orientation about a fixed pivot. Precomputing trigonometric functions (cos/sin)
 * once avoids repeated trig calculations and closures across panel vertices.
 */
export function createWallTransform(pivot: Point, degrees: number): WallTransform {
  const radians = (normalizeDegrees(degrees) * Math.PI) / 180
  const snap = (value: number) => (Math.abs(value) < 1e-12 ? 0 : value)
  const c = snap(Math.cos(radians))
  const s = snap(Math.sin(radians))
  const px = pivot[0]
  const py = pivot[1]
  return ([x, y]: Point): Point => {
    const dx = x - px
    const dy = y - py
    return [dx * c + dy * s, -dx * s + dy * c]
  }
}

/** Clockwise by the global orientation about the pivot, y up, exact at right angles. */
export function toWall(point: Point, pivot: Point, degrees: number): Point {
  return createWallTransform(pivot, degrees)(point)
}

export interface Fit {
  scale: number
  /** Screen position of the wall origin. */
  ox: number
  oy: number
}

export interface Bounds { minX: number; maxX: number; minY: number; maxY: number }

/**
 * The drawing's extent on the wall as oriented, controller markers included.
 * Single-pass min/max calculation avoids temporary array allocations (flatMap, map,
 * spread operators) and recomputing trigonometric factor lookups per point.
 */
export function bounds(geometry: ShapesGeometry, degrees: number): Bounds | null {
  const transform = createWallTransform(geometry.pivot, degrees)
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  let count = 0

  for (let i = 0; i < geometry.panels.length; i += 1) {
    const outline = geometry.panels[i].outline
    for (let j = 0; j < outline.length; j += 1) {
      const [x, y] = transform(outline[j])
      if (x < minX) minX = x
      if (x > maxX) maxX = x
      if (y < minY) minY = y
      if (y > maxY) maxY = y
      count += 1
    }
  }

  for (let i = 0; i < geometry.references.length; i += 1) {
    const r = geometry.references[i]
    const [x, y] = transform([r.x, r.y])
    const rMinX = x - r.radius, rMaxX = x + r.radius
    const rMinY = y - r.radius, rMaxY = y + r.radius
    if (rMinX < minX) minX = rMinX
    if (rMaxX > maxX) maxX = rMaxX
    if (rMinY < minY) minY = rMinY
    if (rMaxY > maxY) maxY = rMaxY
    count += 1
  }

  if (count === 0) return null
  return { minX, maxX, minY, maxY }
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

/**
 * 1 is the leftmost panel on the wall as oriented; ties go to the lower ID.
 * Precomputes transform once and avoids redundant min/max array spreads.
 */
export function panelNumbers(geometry: ShapesGeometry, degrees: number): Record<number, number> {
  const transform = createWallTransform(geometry.pivot, degrees)
  let minX = Infinity, maxX = -Infinity
  const placed = new Array<{ id: number; x: number }>(geometry.panels.length)
  for (let i = 0; i < geometry.panels.length; i += 1) {
    const p = geometry.panels[i]
    const x = transform([p.x, p.y])[0]
    placed[i] = { id: p.panelID, x }
    if (x < minX) minX = x
    if (x > maxX) maxX = x
  }
  const span = maxX - minX
  const quantised = (x: number) => (span < 0.5 ? 0.5 : Math.round(((x - minX) / span) * 1e9) / 1e9)
  placed.sort((a, b) => quantised(a.x) - quantised(b.x) || a.id - b.id)
  const result: Record<number, number> = {}
  for (let i = 0; i < placed.length; i += 1) {
    result[placed[i].id] = i + 1
  }
  return result
}

/** The nearest panel within 60° of a direction on the wall, for arrow keys. */
export function neighbor(geometry: ShapesGeometry, degrees: number, from: number, direction: Direction): number | null {
  const origin = geometry.panels.find(p => p.panelID === from)
  if (!origin) return geometry.panels[0]?.panelID ?? null
  const transform = createWallTransform(geometry.pivot, degrees)
  const [sx, sy] = transform([origin.x, origin.y])
  const axis: Point = { up: [0, 1], down: [0, -1], left: [-1, 0], right: [1, 0] }[direction] as Point
  let best: { id: number; score: number } | null = null
  for (let i = 0; i < geometry.panels.length; i += 1) {
    const panel = geometry.panels[i]
    if (panel.panelID === from) continue
    const [x, y] = transform([panel.x, panel.y])
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
