// These assertions mirror LumenDeskTests/NanoleafShapesTests.swift so the
// bridge and the native app parse the same walls and put identical bytes on
// the wire. The expected values come from Nanoleaf's OpenAPI examples,
// Hyperion's driver and layouts real controllers reported, never from the
// encoders under test.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import * as nanoleaf from '../src/nanoleaf.js'

const firmware92Layout = {
  name: 'Shapes B77A', serialNo: 'S1', model: 'NL42', firmwareVersion: '9.2.0',
  panelLayout: {
    globalOrientation: { value: 240, max: 360, min: 0 },
    layout: { numPanels: 3, sideLength: 27, positionData: [
      { panelId: 22456, x: 73, y: 58, o: 0, shapeType: 9 },
      { panelId: 9927, x: 106, y: 77, o: 60, shapeType: 9 },
      { panelId: 0, x: 47, y: 73, o: 60, shapeType: 12 },
    ] },
  },
}

const hexagonAndTriangleLayout = {
  panelLayout: {
    globalOrientation: { value: 239, max: 360, min: 0 },
    layout: { numPanels: 3, sideLength: 0, positionData: [
      { panelId: 42956, x: 106, y: 38, o: 0, shapeType: 7 },
      { panelId: 9127, x: 173, y: 0, o: 0, shapeType: 9 },
      { panelId: 0, x: 47, y: 72, o: 60, shapeType: 12 },
    ] },
  },
}

function mixedWall(reversed = false) {
  const entries = [
    { panelId: 5120, x: 0, y: 0, o: 0, shapeType: 7 },
    { panelId: 77, x: 100.5, y: 58.02, o: 0, shapeType: 7 },
    { panelId: 31000, x: -100.5, y: 58.02, o: 120, shapeType: 7 },
    { panelId: 1204, x: 67, y: -38.68, o: 0, shapeType: 9 },
    { panelId: 9, x: -67, y: -38.68, o: 0, shapeType: 9 },
    { panelId: 64001, x: 0, y: -96.7, o: 60, shapeType: 8 },
    { panelId: 0, x: -45, y: 105, o: 0, shapeType: 12 },
  ]
  if (reversed) entries.reverse()
  return { panelLayout: { globalOrientation: { value: 30, max: 360, min: 0 },
    layout: { numPanels: 7, sideLength: 0, positionData: entries } } }
}

const layoutJSON = (entries, extra = {}) => ({ panelLayout: { ...extra, layout: { numPanels: 2, positionData: entries } } })

const problem = value => {
  try {
    nanoleaf.parseTopology(value)
    return null
  } catch (err) {
    assert.ok(err instanceof nanoleaf.TopologyProblem, String(err))
    return err.kind === 'notReported' ? 'notReported' : err.detail
  }
}

test('shape codes follow Nanoleaf’s table and only Shapes panels are paintable', () => {
  assert.equal(nanoleaf.shapeKind(7), 'hexagon')
  assert.equal(nanoleaf.shapeKind(8), 'triangle')
  assert.equal(nanoleaf.shapeKind(9), 'miniTriangle')
  assert.equal(nanoleaf.shapeKind(12), 'controller')
  assert.equal(nanoleaf.shapeKind(1), 'accessory')
  assert.equal(nanoleaf.shapeKind(2), 'otherFamily')
  assert.equal(nanoleaf.shapeKind(99), 'unknown')
  assert.equal(nanoleaf.shapeKind(null), 'unspecified')
  assert.equal(nanoleaf.isPaintable({ shapeCode: 12 }), false)
})

test('a firmware 9.2 layout parses by identity, controller included but never paintable', () => {
  const { layout, orientation } = nanoleaf.parseTopology(firmware92Layout)
  assert.equal(layout.panels.length, 3)
  assert.deepEqual(nanoleaf.paintablePanels(layout).map(p => p.panelID), [9927, 22456])
  assert.deepEqual(orientation, { kind: 'reported', value: 240, min: 0, max: 360 })
  assert.equal(layout.legacySideLength, 27)
  assert.equal(nanoleaf.orientationDegrees(orientation), 240)
})

test('reordered responses produce the same panels', () => {
  const forward = nanoleaf.parseTopology(mixedWall()).layout
  const backward = nanoleaf.parseTopology(mixedWall(true)).layout
  assert.deepEqual(nanoleaf.paintablePanels(forward), nanoleaf.paintablePanels(backward))
  assert.deepEqual(nanoleaf.paintablePanels(forward).map(p => p.panelID), [9, 77, 1204, 5120, 31000, 64001])
})

test('a missing layout is not reported, and damage rejects the whole layout', () => {
  assert.equal(problem({ name: 'Shapes' }), 'notReported')
  assert.equal(problem({ panelLayout: { globalOrientation: { value: 0 } } }), 'notReported')
  assert.equal(problem('not json'), 'the response was not a JSON object')
  assert.equal(problem({ panelLayout: 7 }), 'panelLayout was not an object')
  const cases = [
    [{ panelLayout: { layout: { numPanels: 1 } } }, 'positionData is missing'],
    [{ panelLayout: { layout: { positionData: { panelId: 1 } } } }, 'positionData is not a list'],
    [layoutJSON([{ panelId: 1, y: 0, o: 0, shapeType: 7 }]), 'panel 1 has no readable x position'],
    [layoutJSON([{ panelId: 1, x: '12', y: 0, o: 0, shapeType: 7 }]), 'panel 1 has no readable x position'],
    [layoutJSON([{ panelId: 1, x: true, y: 0, o: 0, shapeType: 7 }]), 'panel 1 has no readable x position'],
    [layoutJSON([{ panelId: 1, x: 0, y: 0, shapeType: 7 }]), 'panel 1 has no readable orientation'],
    [layoutJSON([{ x: 0, y: 0, o: 0, shapeType: 7 }]), 'an entry has no readable panel ID'],
    [layoutJSON([{ panelId: 70000, x: 0, y: 0, o: 0, shapeType: 7 }]), 'a panel ID cannot be addressed'],
    [layoutJSON([{ panelId: -3, x: 0, y: 0, o: 0, shapeType: 7 }]), 'a panel ID cannot be addressed'],
    [layoutJSON([{ panelId: 4, x: 0, y: 0, o: 0, shapeType: 7 }, { panelId: 4, x: 1, y: 0, o: 0, shapeType: 9 }]),
      'panel ID 4 appears more than once'],
    [layoutJSON([{ panelId: 4, x: 1e9, y: 0, o: 0, shapeType: 7 }]), 'panel 4 is positioned outside any plausible wall'],
    [layoutJSON([{ panelId: 4, x: 0, y: 0, o: 0, shapeType: 'hex' }]), 'panel 4 has an unreadable shape type'],
    [layoutJSON([7]), 'entry 1 is not a panel description'],
  ]
  for (const [json, detail] of cases) assert.equal(problem(json), detail, JSON.stringify(json))
})

test('an unreadable orientation is not reported as zero', () => {
  const value = nanoleaf.parseTopology(layoutJSON([{ panelId: 3, x: 0, y: 0, o: 0, shapeType: 7 }],
    { globalOrientation: { value: 'up' } }))
  assert.deepEqual(value.orientation, { kind: 'unreadable' })
  assert.equal(nanoleaf.orientationDegrees(value.orientation), null)
  const wrapped = nanoleaf.parseTopology(layoutJSON([{ panelId: 3, x: 0, y: 0, o: 0, shapeType: 7 }],
    { globalOrientation: { value: 360, max: 360, min: 0 } }))
  assert.equal(nanoleaf.orientationDegrees(wrapped.orientation), 0)
  assert.equal(nanoleaf.writableOrientation(-265, wrapped.orientation), 95)
})

// Two outlines share an edge when two of their vertices coincide.
function sharesEdge(a, b, tolerance = 1.5) {
  let matches = 0
  for (const p of a) if (b.some(q => Math.hypot(p[0] - q[0], p[1] - q[1]) < tolerance)) matches += 1
  return matches >= 2
}

test('outlines follow the SDK vertex convention that real walls tile with', () => {
  const triangles = nanoleaf.parseTopology(firmware92Layout).layout
  const a = nanoleaf.outline(triangles.panels.find(p => p.panelID === 22456))
  const b = nanoleaf.outline(triangles.panels.find(p => p.panelID === 9927))
  assert.ok(sharesEdge(a, b), 'mini triangles reported side by side share an edge')
  const mixed = nanoleaf.parseTopology(hexagonAndTriangleLayout).layout
  const hexagon = nanoleaf.outline(mixed.panels.find(p => p.panelID === 42956))
  const mini = nanoleaf.outline(mixed.panels.find(p => p.panelID === 9127))
  assert.ok(sharesEdge(hexagon, mini), 'a mini triangle on a hexagon edge shares it')
  assert.ok(!sharesEdge(nanoleaf.polygon(106, 38, 67, 30, 6), mini), 'a pointy-top hexagon would not')
  assert.equal(nanoleaf.outline({ panelID: 0, x: 0, y: 0, orientation: 0, shapeCode: 12 }), null)
})

test('the wall view turns clockwise like Nanoleaf’s SDK', () => {
  const transform = nanoleaf.wallTransform(90, [10, 20])
  // rotateAuroraPanels(layout, 90) moves (100, 0) to (0, -100).
  const [x, y] = transform.wall([110, 20])
  assert.ok(Math.abs(x) < 1e-9 && Math.abs(y + 100) < 1e-9)
  for (const degrees of [0, 37, 90, 239, 300, 359]) {
    const t = nanoleaf.wallTransform(degrees, [-3, 8])
    const [rx, ry] = t.raw(t.wall([123.5, -77.25]))
    assert.ok(Math.abs(rx - 123.5) < 1e-9 && Math.abs(ry + 77.25) < 1e-9)
  }
})

test('panels are numbered along the wall as oriented, exactly as the native app numbers them', () => {
  const layout = nanoleaf.parseTopology(mixedWall()).layout
  assert.deepEqual(nanoleaf.panelNumbers(layout, 0), { 31000: 1, 9: 2, 5120: 3, 64001: 4, 1204: 5, 77: 6 })
  assert.deepEqual(nanoleaf.panelNumbers(layout, 180), { 77: 1, 1204: 2, 5120: 3, 64001: 4, 9: 5, 31000: 6 })
  const leftToRight = nanoleaf.spatialPositions(layout, 0)
  assert.equal(leftToRight[0].panelID, 31000)
  assert.equal(leftToRight.at(-1).position, 1)
  const topDown = nanoleaf.spatialPositions(layout, 0, 'topToBottom')
  assert.equal(topDown[0].panelID, 77)
  assert.equal(topDown.at(-1).panelID, 64001)
})

test('static animData matches Nanoleaf’s documented example', () => {
  // OpenAPI 3.2.6.1 "Temporary static display".
  const frames = [
    { panelID: 82, r: 255, g: 0, b: 255, transition: 20 },
    { panelID: 60, r: 0, g: 255, b: 255, transition: 20 },
    { panelID: 118, r: 0, g: 0, b: 0, transition: 20 },
  ]
  assert.equal(nanoleaf.staticAnimData(frames), '3 82 1 255 0 255 0 20 60 1 0 255 255 0 20 118 1 0 0 0 0 20')
})

test('stream packets match Nanoleaf’s documented v2 bytes', () => {
  // OpenAPI 3.2.6.2: panels 374, 651 and 235 as a v2 byte stream.
  const frames = [
    { panelID: 374, r: 255, g: 0, b: 255, transition: 12 },
    { panelID: 651, r: 255, g: 255, b: 0, transition: 128 },
    { panelID: 235, r: 0, g: 255, b: 255, transition: 451 },
  ]
  assert.deepEqual([...nanoleaf.streamPacket(frames)], [
    0x00, 0x03, 0x01, 0x76, 0xff, 0x00, 0xff, 0x00, 0x00, 0x0c,
    0x02, 0x8b, 0xff, 0xff, 0x00, 0x00, 0x00, 0x80,
    0x00, 0xeb, 0x00, 0xff, 0xff, 0x00, 0x01, 0xc3,
  ])
  assert.deepEqual([...nanoleaf.streamPacket([])], [0, 0])
  assert.equal(nanoleaf.STREAM_PORT, 60222)
  assert.equal(nanoleaf.MINIMUM_FRAME_INTERVAL_MS, 100)
})

test('request bodies match the documented contracts', () => {
  assert.deepEqual(nanoleaf.orientationBody(120), { globalOrientation: { value: 120 } })
  assert.deepEqual(nanoleaf.selectBody('Northern Lights'), { select: 'Northern Lights' })
  // Hyperion's driver sends exactly this to start v2 streaming.
  assert.deepEqual(nanoleaf.EXTERNAL_CONTROL_BODY,
    JSON.parse('{"write" : {"command" : "display", "animType" : "extControl", "extControlVersion" : "v2"}}'))
  const display = nanoleaf.displayStaticBody([{ panelID: 9, r: 1, g: 2, b: 3, transition: 1 }]).write
  assert.equal(display.command, 'display')
  assert.equal(display.animType, 'static')
  assert.equal(display.animData, '1 9 1 1 2 3 0 1')
  assert.equal(display.loop, false)
  assert.equal(display.animName, undefined, 'a preview is never stored under a name')
})

test('design frames cover every light panel, black where uncovered, never the controller', () => {
  const layout = nanoleaf.parseTopology(mixedWall()).layout
  const frames = nanoleaf.designFrames(layout, { 9: { r: 255, g: 128, b: 0 }, 5555: { r: 1, g: 1, b: 1 } }, 3)
  assert.deepEqual(frames.map(f => f.panelID), [9, 77, 1204, 5120, 31000, 64001])
  assert.deepEqual(frames[0], { panelID: 9, r: 255, g: 128, b: 0, transition: 3 })
  assert.deepEqual(frames[1], { panelID: 77, r: 0, g: 0, b: 0, transition: 3 })
  assert.ok(!frames.some(f => f.panelID === 0 || f.panelID === 5555))
})

test('drawing geometry carries every light panel\u2019s outline and the controller as a marker', () => {
  const layout = nanoleaf.parseTopology(mixedWall()).layout
  const geometry = nanoleaf.drawingGeometry(layout)
  assert.deepEqual(geometry.panels.map(p => p.panelID), [9, 77, 1204, 5120, 31000, 64001])
  assert.equal(geometry.panels.find(p => p.panelID === 5120).outline.length, 6)
  assert.equal(geometry.panels.find(p => p.panelID === 64001).outline.length, 3)
  assert.deepEqual(geometry.references.map(r => [r.panelID, r.kind]), [[0, 'controller']])
  assert.deepEqual(geometry.pivot, nanoleaf.pivot(layout))
})
