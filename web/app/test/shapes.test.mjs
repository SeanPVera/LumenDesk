// The page numbers, turns and navigates a Shapes wall exactly as the native
// app and the bridge do: the expected values below are the ones asserted in
// LumenDeskTests/NanoleafShapesTests.swift and web/bridge/test/nanoleaf.test.js,
// and the outlines come from the bridge's own lockstep-tested module.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { panelNumbers, toWall, neighbor, fit } from '../.test-build/shapes/geometry.js'
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

test('panels are numbered along the wall as oriented, as the native app numbers them', () => {
  assert.deepEqual(panelNumbers(mixedWall, 0), { 31000: 1, 9: 2, 5120: 3, 64001: 4, 1204: 5, 77: 6 })
  assert.deepEqual(panelNumbers(mixedWall, 180), { 77: 1, 1204: 2, 5120: 3, 64001: 4, 9: 5, 31000: 6 })
})

test('the wall turns clockwise like Nanoleaf’s SDK', () => {
  // rotateAuroraPanels(layout, 90) moves (100, 0) to (0, -100).
  const [x, y] = toWall([110, 20], [10, 20], 90)
  assert.ok(Math.abs(x) < 1e-9 && Math.abs(y + 100) < 1e-9)
})

test('arrow keys move to the panel on that side of the wall', () => {
  // 1204 and 77 both sit 30° off the axis; the nearer one wins, as natively.
  assert.equal(neighbor(mixedWall, 0, 5120, 'right'), 1204)
  assert.equal(neighbor(mixedWall, 0, 1204, 'up'), 77)
  assert.equal(neighbor(mixedWall, 0, 5120, 'down'), 64001)
  assert.equal(neighbor(mixedWall, 180, 5120, 'up'), 64001, 'a half turn puts the bottom triangle on top')
  assert.equal(neighbor(mixedWall, 0, 64001, 'down'), null)
})

test('the drawing fits the canvas at any orientation', () => {
  for (const degrees of [0, 30, 90, 239]) {
    const view = fit(mixedWall, degrees, 600, 400)
    assert.ok(view.scale > 0 && Number.isFinite(view.ox) && Number.isFinite(view.oy))
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
