import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MusicChoreographyEngine, FlashSafetyLimiter } from '../.test-build/choreography.js'
import { configurationFor } from '../.test-build/config.js'
import { emptySnapshot } from '../.test-build/types.js'

const snapshot = {...emptySnapshot(), level:.7, bass:.5, energy:.7, confidence:1,
  tempo:120, beatInterval:.5, feltInterval:.5, beatConfidence:1,
  beatReferenceTime:100, isTempoLocked:true}
function config() {
  return {...configurationFor('soundcheck'), palette:[{hex:0xff0000},{hex:0x0000ff}],
    movementAmount:0, movementSpeed:0, stereoImage:0, beatSensitivity:0,
    colorChangeIntensity:1, phraseAware:false}
}
function fixture(id, overrides={}) {
  return {id,label:id,transport:'lifxLAN',segmentCount:0,role:'auto',...overrides}
}
function topology() { return {layout:'leftToRight',fixtureOrder:[],excludedFixtureIDs:[]} }

test('each bar or panel fixture keeps its full gradient beside a much longer strip', () => {
  const room = [fixture('a-wall', {segmentCount: 4}), fixture('b-strip', {segmentCount: 200}),
    fixture('c-bar', {segmentCount: 4})]
  for (const intensity of [0, .1, 1]) {
    const settings = {...config(), colorChangeIntensity: intensity}
    const frame = new MusicChoreographyEngine().makeFrame(snapshot, settings, topology(), room, 100, 1)
    for (const id of ['a-wall', 'c-bar']) {
      const states = frame.states.filter(state => state.fixtureID === id)
      assert.equal(new Set(states.map(state => state.hue)).size, 4)
      assert.equal(states[0].hue, 0, `${id} starts at the first palette color`)
      assert.ok(Math.abs(states.at(-1).hue - 2/3) < 1e-12, `${id} reaches the last palette color`)
    }
  }
})

test('locked beat transitions finish within one render tick while unmetered audio eases', () => {
  const room = [fixture('a')], settings = config()
  for (const interval of [.3, .4, .5, 1]) {
    const frame = new MusicChoreographyEngine().makeFrame({...snapshot, beatInterval: interval, feltInterval: interval},
      settings, topology(), room, 100, 1)
    assert.ok(frame.states[0].transitionDuration <= .05)
    assert.ok(frame.states[0].transitionDuration <= interval * .12)
  }
  const live = new MusicChoreographyEngine().makeFrame({...snapshot, isTempoLocked: false}, settings, topology(), room, 100, 1)
  assert.equal(live.states[0].transitionDuration, .09)
})

test('live topology edits reorder, exclude, and restore cached targets',()=>{
  const engine=new MusicChoreographyEngine(), room=[fixture('a'),fixture('b'),fixture('c')], layout=topology(), settings=config()
  const frame=t=>engine.makeFrame(snapshot,settings,layout,room,t,Math.round((t-100)*20)+1)
  assert.deepEqual(frame(100).states.map(state=>state.fixtureID),['a','b','c'])
  layout.fixtureOrder.push('c','a','b')
  layout.excludedFixtureIDs.push('a')
  assert.deepEqual(frame(100.05).states.map(state=>state.fixtureID),['c','b'])
  layout.excludedFixtureIDs.push('b','c')
  assert.deepEqual(frame(100.1).states,[])
  layout.excludedFixtureIDs.length=0
  assert.deepEqual(frame(100.15).states.map(state=>state.fixtureID),['c','a','b'])
})

test('mutating descriptors updates segment counts, automatic roles, and off roles',()=>{
  const engine=new MusicChoreographyEngine(), settings=config(), layout=topology(), room=[fixture('strip',{segmentCount:4})]
  const first=engine.makeFrame(snapshot,settings,layout,room,100,1)
  assert.deepEqual(first.states.map(state=>state.segmentID),[0,1,2,3])
  room[0].segmentCount=2
  assert.deepEqual(engine.makeFrame(snapshot,settings,layout,room,100.05,2).states.map(state=>state.segmentID),[0,1])
  room[0].role='off'
  assert.deepEqual(engine.makeFrame(snapshot,settings,layout,room,100.1,3).states,[])

  const changed=new MusicChoreographyEngine(), unchanged=new MusicChoreographyEngine(), bulb=[fixture('bulb',{label:'Front'})]
  for(const value of [changed,unchanged]) value.makeFrame(snapshot,settings,layout,bulb,100,1)
  bulb[0].label='Rear'
  const renamed=changed.makeFrame(snapshot,settings,layout,bulb,100.05,2).states[0]
  const original=unchanged.makeFrame(snapshot,settings,layout,[fixture('bulb',{label:'Front'})],100.05,2).states[0]
  assert.ok(renamed.brightness<original.brightness)
})

test('live palette edits and layout changes reach the next frame without mutating earlier frames',()=>{
  const engine=new MusicChoreographyEngine(), settings=config(), layout=topology(), room=[fixture('strip',{segmentCount:4})]
  const first=engine.makeFrame(snapshot,settings,layout,room,100,1)
  const saved=structuredClone(first)
  layout.layout='circular'
  const circular=engine.makeFrame(snapshot,settings,layout,room,100.05,2)
  assert.notDeepEqual(circular.states.map(state=>state.hue),first.states.map(state=>state.hue))
  settings.palette.length=1
  settings.palette[0].hex=0x0000ff
  const blue=engine.makeFrame(snapshot,settings,layout,room,100.1,3)
  assert.ok(blue.states.every(state=>Math.abs(state.hue-2/3)<1e-12))
  settings.palette.length=0
  const fallback=engine.makeFrame(snapshot,settings,layout,room,100.15,4)
  const reference=new MusicChoreographyEngine().makeFrame(snapshot,settings,layout,room,100.15,4)
  assert.deepEqual(fallback.states.map(state=>[state.hue,state.saturation]),reference.states.map(state=>[state.hue,state.saturation]))
  assert.deepEqual(first,saved)
})

test('reset clears musical envelopes and cached inputs',()=>{
  const engine=new MusicChoreographyEngine(),settings=config(),layout=topology(),room=[fixture('strip',{segmentCount:20})]
  for(let i=0;i<20;i++) engine.makeFrame(snapshot,settings,layout,room,100+i*.05,i)
  engine.reset()
  assert.deepEqual(engine.makeFrame(snapshot,settings,layout,room,100,1),new MusicChoreographyEngine().makeFrame(snapshot,settings,layout,room,100,1))
})

test('flash limiter clamps unnormalized intensity and frequency independently of palette',()=>{
  const limiter=new FlashSafetyLimiter(),settings={...config(),photosensitivitySafeMode:false,allowsFlashes:true,flashIntensity:4,maximumFlashFrequency:100,palette:[]}
  assert.equal(limiter.admit(100,2,settings),1)
  assert.equal(limiter.admit(100.1,2,settings),0)
  assert.equal(limiter.admit(100+1/3,2,settings),1)
  settings.photosensitivitySafeMode=true
  assert.equal(limiter.admit(101,2,settings),0)
})
