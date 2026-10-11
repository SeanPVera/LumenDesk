// The page numbers, turns and navigates a Shapes wall exactly as the native
// app and the bridge do: the expected values below are the ones asserted in
// LumenDeskTests/NanoleafShapesTests.swift and web/bridge/test/nanoleaf.test.js,
// and the outlines come from the bridge's own lockstep-tested module.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { bounds, createScreenTransform, createWallTransform, panelNumbers, toScreen, toWall, neighbor, fit } from '../.test-build/shapes/geometry.js'
import { parseTopology, drawingGeometry } from '../../bridge/src/nanoleaf.js'
import { toRGB, toTone } from '../.test-build/shapes/tone.js'

const mixedWall = drawingGeometry(parseTopology({ panelLayout: { layout: { positionData: [
  { panelId: 5120, x: 0, y: 0, o: 0, shapeType: 7 },
  { panelId: 77, x: 100.5, y: 58.02, o: 0, shapeType: 7 },
  { panelId: 31000, x: -100.5, y: 58.02, o: 120, shapeType: 7 },
  { panelId: 1204, x: 67, y: -38.68, o: 0, shapeType: 9 },
  { panelId: 9, x: -67, y: -38.68, o: 0, shapeType: 9 },
  { panelId: 64001, x: 0, y: -96.7, o: 60, shapeType: 8 },
  { panelId: 0, x: -45, y: 105, o: 0, shapeType: 12 },
] } } }).layout)

const panel = (panelID, x, y, outline = []) => ({ panelID, x, y, outline, kind: 'triangle', name: 'Triangle', orientation: 0 })
const wall = (panels = [], references = [], pivot = [0, 0]) => ({ panels, references, pivot })

test('panels are numbered along the wall as oriented, as the native app numbers them', () => {
  assert.deepEqual(panelNumbers(mixedWall, 0), { 31000: 1, 9: 2, 5120: 3, 64001: 4, 1204: 5, 77: 6 })
  assert.deepEqual(panelNumbers(mixedWall, 180), { 77: 1, 1204: 2, 5120: 3, 64001: 4, 9: 5, 31000: 6 })
})

test('the wall turns clockwise like Nanoleaf’s SDK', () => {
  // rotateAuroraPanels(layout, 90) moves (100, 0) to (0, -100).
  const [x, y] = toWall([110, 20], [10, 20], 90)
  assert.ok(Math.abs(x) < 1e-9 && Math.abs(y + 100) < 1e-9)
})

test('reused wall and screen transforms retain angle normalization and a fixed pivot', () => {
  for (const [degrees, expected] of [
    [0, [100, 0]], [90, [0, -100]], [180, [-100, 0]], [270, [0, 100]],
    [-90, [0, 100]], [450, [0, -100]], [NaN, [100, 0]], [Infinity, [100, 0]],
    [30, [50 * Math.sqrt(3), -50]],
  ]) {
    const transform = createWallTransform([10, 20], degrees)
    for (const actual of [transform([110, 20]), toWall([110, 20], [10, 20], degrees)]) {
      assert.ok(Math.abs(actual[0] - expected[0]) < 1e-10 && Math.abs(actual[1] - expected[1]) < 1e-10)
    }
  }
  const pivot = [10, 20]
  const view = { scale: 2, ox: 30, oy: 40 }
  const screen = createScreenTransform(pivot, 90, view)
  assert.deepEqual(screen([110, 20]), [30, 240])
  assert.deepEqual(screen([10, 120]), [230, 40])
  assert.deepEqual(toScreen([110, 20], pivot, 90, view), [30, 240])
  pivot[0] = 50
  assert.deepEqual(screen([110, 20]), [30, 240], 'a reusable transform captures its fixed pivot')
})

test('bounds include oriented outlines and circular controller markers', () => {
  const geometry = wall([panel(10, 15, 25, [[10, 20], [20, 20], [10, 30]])],
    [{ panelID: 0, kind: 'controller', x: 5, y: 20, radius: 2 }], [10, 20])
  assert.deepEqual(bounds(geometry, 0), { minX: -7, maxX: 10, minY: -2, maxY: 10 })
  assert.deepEqual(bounds(geometry, 90), { minX: -2, maxX: 10, minY: -10, maxY: 7 })
  const markers = wall([], [{ panelID: 0, kind: 'controller', x: 10, y: 20, radius: 3 }], [10, 20])
  assert.deepEqual(bounds(markers, 37), { minX: -3, maxX: 3, minY: -3, maxY: 3 }, 'a marker radius does not rotate')
})

test('empty and degenerate layouts keep their fitting and navigation behavior', () => {
  for (const geometry of [wall(), wall([panel(8, 123, 456)])]) {
    assert.equal(bounds(geometry, 90), null, 'centers without outlines do not add a footprint')
    assert.deepEqual(fit(geometry, 90, 600, 400), { scale: 1, ox: 300, oy: 200 })
  }
  assert.deepEqual(panelNumbers(wall(), 90), {})
  assert.equal(neighbor(wall(), 90, 123, 'up'), null)
  const point = wall([panel(8, 5, 7, [[5, 7]])], [], [5, 7])
  assert.deepEqual(bounds(point, 0), { minX: 0, maxX: 0, minY: 0, maxY: 0 })
  assert.deepEqual(fit(point, 0, 600, 400), { scale: 352, ox: 300, oy: 200 })
  assert.deepEqual(panelNumbers(point, 239), { 8: 1 })
  assert.equal(neighbor(point, 239, 123, 'up'), 8, 'a missing origin selects the first panel')
  assert.equal(neighbor(point, 239, 8, 'up'), null)
})

test('bounds preserve numeric extrema semantics while streaming vertices', () => {
  const reference = { panelID: 0, kind: 'controller', x: 3, y: 4, radius: -2 }
  assert.deepEqual(bounds(wall([], [reference]), 0), { minX: 1, maxX: 5, minY: 2, maxY: 6 })
  const invalid = bounds(wall([panel(1, 0, 0, [[0, 0], [NaN, 1]])]), 0)
  assert.ok(Object.values(invalid).every(Number.isNaN), 'an invalid vertex propagates to the extent')
  const signedZero = bounds(wall([panel(1, 0, 0, [[-0, -1], [0, -1]])]), 0)
  assert.ok(Object.is(signedZero.minX, -0) && Object.is(signedZero.maxX, 0))
})

test('large outlines do not depend on the engine argument-count limit', () => {
  const outline = Array.from({ length: 150_000 }, (_, i) => [i, i % 2 ? 4 : -3])
  assert.deepEqual(bounds(wall([panel(1, 0, 0, outline)]), 0), { minX: 0, maxX: 149_999, minY: -3, maxY: 4 })
})

test('numbering preserves sub-unit and quantized ties by lower panel ID', () => {
  assert.deepEqual(panelNumbers(wall([panel(8, 0, 0), panel(2, 0.49, 0)]), 0), { 2: 1, 8: 2 })
  assert.deepEqual(panelNumbers(wall([panel(8, 0, 0), panel(2, 0.5, 0)]), 0), { 8: 1, 2: 2 })
  assert.deepEqual(panelNumbers(wall([panel(9, 0, 0), panel(1, 1e-7, 0), panel(4, 1000, 0)]), 0), { 1: 1, 9: 2, 4: 3 })
  assert.deepEqual(panelNumbers(wall([panel(8, 0, 0), panel(2, 100, 0)]), 90), { 2: 1, 8: 2 })
})

test('arrow keys move to the panel on that side of the wall', () => {
  // 1204 and 77 both sit 30° off the axis; the nearer one wins, as natively.
  assert.equal(neighbor(mixedWall, 0, 5120, 'right'), 1204)
  assert.equal(neighbor(mixedWall, 0, 1204, 'up'), 77)
  assert.equal(neighbor(mixedWall, 0, 5120, 'down'), 64001)
  assert.equal(neighbor(mixedWall, 180, 5120, 'up'), 64001, 'a half turn puts the bottom triangle on top')
  assert.equal(neighbor(mixedWall, 0, 64001, 'down'), null)
})

test('navigation retains score ties, the distance cutoff and the directional cone', () => {
  const tied = wall([panel(10, 0, 0), panel(8, 10, 10), panel(2, 10, -10), panel(1, 0.5, 0)])
  assert.equal(neighbor(tied, 0, 10, 'right'), 2, 'equal scores choose the lower ID and ignore coincident centers')
  assert.equal(neighbor(tied, 90, 10, 'down'), 2, 'the same tie survives a right-angle rotation')
  const boundary = wall([panel(10, 0, 0), panel(8, 1, Math.sqrt(3)), panel(2, 1, 2)])
  assert.equal(neighbor(boundary, 0, 10, 'right'), 8, '60 degrees is included while a wider angle is excluded')
})

test('the drawing fits the canvas at any orientation', () => {
  for (const degrees of [0, 30, 90, 239, -90, 450, NaN]) {
    const view = fit(mixedWall, degrees, 600, 400)
    assert.ok(view.scale > 0 && Number.isFinite(view.ox) && Number.isFinite(view.oy))
    const screen = createScreenTransform(mixedWall.pivot, degrees, view)
    const inside = ([x, y], radius = 0) => {
      assert.ok(x - radius >= 24 - 1e-9 && x + radius <= 576 + 1e-9)
      assert.ok(y - radius >= 24 - 1e-9 && y + radius <= 376 + 1e-9)
    }
    for (const panel of mixedWall.panels) panel.outline.map(screen).forEach(point => inside(point))
    for (const reference of mixedWall.references) inside(screen([reference.x, reference.y]), reference.radius * view.scale)
  }
})

test('a panel level scales the colour and keeps its hue, as a native design does', () => {
  // Independent expectations: primaries by definition, and a level change is a
  // plain per-channel scale, because HSV value is linear in every channel.
  assert.deepEqual(toTone({ r: 255, g: 0, b: 0 }), { h: 0, s: 1, v: 1 })
  assert.equal(toTone({ r: 0, g: 0, b: 255 }).h, 240)
  assert.equal(toTone({ r: 128, g: 128, b: 128 }).s, 0)
  const warm = { r: 255, g: 106, b: 43 }
  for (const level of [1, 0.5, 0.2]) {
    assert.deepEqual(toRGB({ ...toTone(warm), v: level }),
      { r: Math.round(255 * level), g: Math.round(106 * level), b: Math.round(43 * level) })
  }
  assert.deepEqual(toRGB({ ...toTone(warm), v: 0 }), { r: 0, g: 0, b: 0 }, 'level zero is a panel painted off')
})
