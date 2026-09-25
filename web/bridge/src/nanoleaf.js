// Nanoleaf Shapes LAN API, ported from LumenDesk/Services/Nanoleaf/.
//
// Layout parsing mirrors NanoleafTopologyParser, geometry mirrors
// NanoleafGeometry / NanoleafWallTransform / spatialPositions, and the
// encoders mirror NanoleafAnimData.staticString, NanoleafStreamPacket.encode
// and NanoleafCommand. Change them in lockstep with the Swift files and with
// test/nanoleaf.test.js, or the bridge and the native app will address
// different panels.
//
// Everything here is pure: no sockets, no HTTP, no clock.

export const API_PORT = 16021
export const STREAM_PORT = 60222
/** Nanoleaf asks external controllers never to stream faster than 10 Hz. */
export const MINIMUM_FRAME_INTERVAL_MS = 100
export const MAX_COORDINATE = 100_000

// MARK: Shape types (OpenAPI layout table, section 3.3)

const ACCESSORY_CODES = new Set([1, 5, 16, 19, 20])
const OTHER_FAMILY_CODES = new Set([0, 2, 3, 4, 14, 15, 17, 18, 29, 30, 31, 32])

export function shapeKind(code) {
  if (code === null || code === undefined) return 'unspecified'
  switch (code) {
    case 7: return 'hexagon'
    case 8: return 'triangle'
    case 9: return 'miniTriangle'
    case 12: return 'controller'
    default:
      if (ACCESSORY_CODES.has(code)) return 'accessory'
      if (OTHER_FAMILY_CODES.has(code)) return 'otherFamily'
      return 'unknown'
  }
}

/** Edge length in layout units. Never read from the deprecated sideLength. */
export const SIDE_LENGTH = { hexagon: 67, triangle: 134, miniTriangle: 67 }

export function isPaintable(panel) {
  return Object.hasOwn(SIDE_LENGTH, shapeKind(panel.shapeCode))
}

export function displayName(kind) {
  return {
    hexagon: 'Hexagon',
    triangle: 'Triangle',
    miniTriangle: 'Mini triangle',
    controller: 'Controller',
  }[kind] ?? 'Other part'
}

/** Light panels in ascending ID order, the order every encoder uses. */
export function paintablePanels(layout) {
  return layout.panels.filter(isPaintable).sort((a, b) => a.panelID - b.panelID)
}

// MARK: Topology parsing

export class TopologyProblem extends Error {
  /** `kind` is 'notReported' or 'malformed'; the message never echoes the request. */
  constructor(kind, detail = '') {
    super(kind === 'notReported' ? 'The controller did not report its panel layout.'
      : `The controller reported a panel layout LumenDesk could not read: ${detail}.`)
    this.kind = kind
    this.detail = detail
  }
}

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const isNumber = value => typeof value === 'number' && Number.isFinite(value)
/** Swift's `.rounded()`: halves away from zero. */
const roundHalfAway = value => Math.sign(value) * Math.round(Math.abs(value))

function orientationReport(panelLayout) {
  if (!('globalOrientation' in panelLayout)) return { kind: 'notReported' }
  const ranged = panelLayout.globalOrientation
  if (!isObject(ranged)) return { kind: 'unreadable' }
  const whole = key => {
    if (!(key in ranged)) return null
    const value = ranged[key]
    if (!isNumber(value) || Math.abs(value) >= 1_000_000) throw new Error('unreadable')
    return roundHalfAway(value)
  }
  try {
    const value = whole('value')
    if (value === null) return { kind: 'unreadable' }
    return { kind: 'reported', value, min: whole('min') ?? 0, max: whole('max') ?? 360 }
  } catch {
    return { kind: 'unreadable' }
  }
}

function entryNumber(entry, key, field, id) {
  const value = entry[key]
  if (!(key in entry) || !isNumber(value)) {
    throw new TopologyProblem('malformed', `${id === undefined ? 'an entry' : `panel ${id}`} has no readable ${field}`)
  }
  return value
}

function parseEntry(entry, index) {
  if (!isObject(entry)) throw new TopologyProblem('malformed', `entry ${index + 1} is not a panel description`)
  const rawID = entryNumber(entry, 'panelId', 'panel ID')
  // Stream packets carry the ID in two bytes; anything else can't be addressed.
  if (rawID !== Math.round(rawID) || rawID < 0 || rawID > 0xffff) {
    throw new TopologyProblem('malformed', 'a panel ID cannot be addressed')
  }
  const id = rawID
  const x = entryNumber(entry, 'x', 'x position', id)
  const y = entryNumber(entry, 'y', 'y position', id)
  const o = entryNumber(entry, 'o', 'orientation', id)
  if (Math.abs(x) > MAX_COORDINATE || Math.abs(y) > MAX_COORDINATE) {
    throw new TopologyProblem('malformed', `panel ${id} is positioned outside any plausible wall`)
  }
  let shapeCode = null
  if ('shapeType' in entry) {
    const code = entry.shapeType
    if (!isNumber(code) || code !== Math.round(code) || Math.abs(code) >= 10_000) {
      throw new TopologyProblem('malformed', `panel ${id} has an unreadable shape type`)
    }
    shapeCode = code
  }
  return { panelID: id, x, y, orientation: o, shapeCode }
}

const informational = value => (isNumber(value) && Math.abs(value) < 100_000 ? Math.trunc(value) : null)

/**
 * Reads `panelLayout` out of a controller response object, strictly: an entry
 * without an ID or position, a duplicated ID, or an unaddressable ID rejects
 * the whole layout, so a caller keeps the last layout it trusted instead of
 * aiming colours at a wall that is not the user's. Throws TopologyProblem.
 */
export function parseTopology(response) {
  if (!isObject(response)) throw new TopologyProblem('malformed', 'the response was not a JSON object')
  if (!('panelLayout' in response)) throw new TopologyProblem('notReported')
  const panelLayout = response.panelLayout
  if (!isObject(panelLayout)) throw new TopologyProblem('malformed', 'panelLayout was not an object')
  const orientation = orientationReport(panelLayout)
  if (!('layout' in panelLayout)) throw new TopologyProblem('notReported')
  const layout = panelLayout.layout
  if (!isObject(layout)) throw new TopologyProblem('malformed', 'layout was not an object')
  if (!('positionData' in layout)) throw new TopologyProblem('malformed', 'positionData is missing')
  if (!Array.isArray(layout.positionData)) throw new TopologyProblem('malformed', 'positionData is not a list')
  const panels = []
  const seen = new Set()
  layout.positionData.forEach((entry, index) => {
    const panel = parseEntry(entry, index)
    if (seen.has(panel.panelID)) {
      throw new TopologyProblem('malformed', `panel ID ${panel.panelID} appears more than once`)
    }
    seen.add(panel.panelID)
    panels.push(panel)
  })
  return {
    layout: {
      panels,
      reportedPanelCount: informational(layout.numPanels),
      legacySideLength: informational(layout.sideLength),
    },
    orientation,
  }
}

/** Degrees in 0..<360, or null when the controller did not say. */
export function orientationDegrees(report) {
  return report?.kind === 'reported' ? normalizeDegrees(report.value) : null
}

export function normalizeDegrees(degrees) {
  if (!Number.isFinite(degrees)) return 0
  const remainder = degrees % 360
  return remainder < 0 ? remainder + 360 : remainder
}

/** The value to write, clamped into what the controller advertised. */
export function writableOrientation(degrees, report) {
  const min = report?.kind === 'reported' && report.min <= report.max ? report.min : 0
  const max = report?.kind === 'reported' && report.min <= report.max ? report.max : 360
  return Math.min(max, Math.max(min, normalizeDegrees(Math.round(degrees))))
}

// MARK: Geometry

export function polygon(cx, cy, circumradius, firstVertexDegrees, count) {
  return Array.from({ length: count }, (_, index) => {
    const radians = ((firstVertexDegrees + (index * 360) / count) * Math.PI) / 180
    return [cx + circumradius * Math.cos(radians), cy + circumradius * Math.sin(radians)]
  })
}

/**
 * A light panel's outline in layout space (y up), counter-clockwise, in the
 * vertex convention Nanoleaf's own plugin SDK draws with: triangles point up
 * at orientation 0, hexagons put vertices on the ±x axis.
 */
export function outline(panel) {
  const kind = shapeKind(panel.shapeCode)
  const side = SIDE_LENGTH[kind]
  if (!side) return null
  if (kind === 'hexagon') return polygon(panel.x, panel.y, side, panel.orientation, 6)
  return polygon(panel.x, panel.y, side / Math.sqrt(3), panel.orientation + 90, 3)
}

export function markerRadius(panel) {
  return shapeKind(panel.shapeCode) === 'controller' ? 12 : 16
}

export function footprint(layout) {
  return layout.panels.flatMap(entry => {
    const points = outline(entry)
    if (points) return points
    const r = markerRadius(entry)
    return [[entry.x - r, entry.y - r], [entry.x + r, entry.y + r], [entry.x - r, entry.y + r], [entry.x + r, entry.y - r]]
  })
}

export function pivot(layout) {
  const points = footprint(layout)
  if (!points.length) return [0, 0]
  const xs = points.map(p => p[0])
  const ys = points.map(p => p[1])
  return [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2]
}

/**
 * The layout turned into the wall view: rotated clockwise by the global
 * orientation about a fixed pivot, y still up. Clockwise is measured from
 * Nanoleaf's SDK, not assumed. Right-angle trig is exact, so panels in one
 * column never order themselves by rounding noise.
 */
export function wallTransform(rotationDegrees, center) {
  const radians = (normalizeDegrees(rotationDegrees) * Math.PI) / 180
  const snap = value => (Math.abs(value) < 1e-12 ? 0 : value)
  const c = snap(Math.cos(radians))
  const s = snap(Math.sin(radians))
  const [px, py] = center
  return {
    wall: ([x, y]) => {
      const dx = x - px
      const dy = y - py
      return [dx * c + dy * s, -dx * s + dy * c]
    },
    raw: ([x, y]) => [x * c - y * s + px, x * s + y * c + py],
  }
}

/**
 * Light panels placed along an axis of the wall as the user oriented it,
 * ordered by position then panel ID. Positions are quantised so panels in
 * one line tie exactly.
 */
export function spatialPositions(layout, rotationDegrees, axis = 'leftToRight') {
  const panels = paintablePanels(layout)
  if (!panels.length) return []
  const transform = wallTransform(rotationDegrees, pivot(layout))
  const centers = panels.map(p => ({ id: p.panelID, point: transform.wall([p.x, p.y]) }))
  const xs = centers.map(c => c.point[0])
  const ys = centers.map(c => c.point[1])
  const minX = Math.min(...xs), maxX = Math.max(...xs)
  const minY = Math.min(...ys), maxY = Math.max(...ys)
  const meanX = xs.reduce((a, b) => a + b, 0) / xs.length
  const meanY = ys.reduce((a, b) => a + b, 0) / ys.length
  const maxDistance = Math.max(...centers.map(c => Math.hypot(c.point[0] - meanX, c.point[1] - meanY)))
  const position = ([x, y]) => {
    switch (axis) {
      case 'leftToRight': return maxX - minX < 0.5 ? 0.5 : (x - minX) / (maxX - minX)
      case 'topToBottom': return maxY - minY < 0.5 ? 0.5 : (maxY - y) / (maxY - minY)
      case 'clockwise': {
        const dx = x - meanX, dy = y - meanY
        if (Math.hypot(dx, dy) <= 0.5) return 0
        const angle = Math.atan2(dx, dy)
        return (angle < 0 ? angle + 2 * Math.PI : angle) / (2 * Math.PI)
      }
      case 'outward': return maxDistance < 0.5 ? 0 : Math.hypot(x - meanX, y - meanY) / maxDistance
      default: throw new Error(`unknown axis ${axis}`)
    }
  }
  const quantised = value => Math.round(Math.min(1, Math.max(0, value)) * 1e9) / 1e9
  return centers
    .map(c => ({ panelID: c.id, position: quantised(position(c.point)) }))
    .sort((a, b) => (a.position === b.position ? a.panelID - b.panelID : a.position - b.position))
}

/** 1 is the leftmost panel on the wall as oriented. */
export function panelNumbers(layout, rotationDegrees) {
  return Object.fromEntries(spatialPositions(layout, rotationDegrees).map((entry, index) => [entry.panelID, index + 1]))
}

/**
 * What a browser needs to draw the wall without re-deriving geometry: each
 * light panel's outline in layout space, the reference entries (controller)
 * as markers, and the pivot the wall view turns about.
 */
export function drawingGeometry(layout) {
  return {
    pivot: pivot(layout),
    panels: paintablePanels(layout).map(panel => ({
      panelID: panel.panelID,
      kind: shapeKind(panel.shapeCode),
      name: displayName(shapeKind(panel.shapeCode)),
      x: panel.x,
      y: panel.y,
      orientation: panel.orientation,
      outline: outline(panel),
    })),
    references: layout.panels.filter(panel => !isPaintable(panel)).map(panel => ({
      panelID: panel.panelID,
      kind: shapeKind(panel.shapeCode),
      x: panel.x,
      y: panel.y,
      radius: markerRadius(panel),
    })),
  }
}

// MARK: Encoders

const byte = value => Math.max(0, Math.min(255, Math.round(Number(value) || 0)))

/**
 * One frame per panel: `numPanels panelId 1 R G B W T ...`. W is always 0;
 * the firmware ignores it. Frames go out in the order given.
 */
export function staticAnimData(frames) {
  const parts = [String(frames.length)]
  for (const frame of frames) {
    parts.push(String(frame.panelID), '1', String(byte(frame.r)), String(byte(frame.g)), String(byte(frame.b)), '0',
      String(Math.max(0, Math.round(frame.transition ?? 0))))
  }
  return parts.join(' ')
}

/** External control v2: big-endian UInt16 count, then id R G B W transition. */
export function streamPacket(frames) {
  const limited = frames.slice(0, 0xffff)
  const buffer = Buffer.alloc(2 + limited.length * 8)
  buffer.writeUInt16BE(limited.length, 0)
  limited.forEach((frame, index) => {
    const offset = 2 + index * 8
    buffer.writeUInt16BE(frame.panelID & 0xffff, offset)
    buffer.writeUInt8(byte(frame.r), offset + 2)
    buffer.writeUInt8(byte(frame.g), offset + 3)
    buffer.writeUInt8(byte(frame.b), offset + 4)
    buffer.writeUInt8(0, offset + 5)
    buffer.writeUInt16BE(Math.max(0, Math.min(0xffff, Math.round(frame.transition ?? 0))), offset + 6)
  })
  return buffer
}

export const orientationBody = degrees => ({ globalOrientation: { value: degrees } })
export const selectBody = name => ({ select: name })
export const displayStaticBody = frames => ({
  write: {
    command: 'display',
    version: '2.0',
    animType: 'static',
    animData: staticAnimData(frames),
    loop: false,
    palette: [],
    colorType: 'HSB',
  },
})
export const EXTERNAL_CONTROL_BODY = { write: { command: 'display', animType: 'extControl', extControlVersion: 'v2' } }

/**
 * Frames for every light panel: the design's colour where it has one, black
 * where it does not, in ascending ID order. Nothing that is not a Shapes
 * light panel is ever addressed.
 */
export function designFrames(layout, colors, transition = 3) {
  return paintablePanels(layout).map(panel => {
    const rgb = colors[panel.panelID] ?? colors[String(panel.panelID)] ?? { r: 0, g: 0, b: 0 }
    return { panelID: panel.panelID, r: byte(rgb.r), g: byte(rgb.g), b: byte(rgb.b), transition }
  })
}
