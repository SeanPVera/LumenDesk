import { test } from 'node:test'
import assert from 'node:assert/strict'
import vm from 'node:vm'
import { WebMusicSession } from '../.test-build/session.js'
import { emptySnapshot } from '../.test-build/types.js'

// Load the actual module supplied to AudioWorklet, including its transfer
// protocol, rather than maintaining a second copy of the capture processor.
const workletSource = await (async () => {
  const original = globalThis.AudioContext
  let source
  globalThis.AudioContext = class {
    audioWorklet = { addModule: async url => { source = await (await fetch(url)).text() } }
    close() { return Promise.resolve() }
  }
  try {
    const session = new WebMusicSession()
    await session.ensureAudio(0)
    await session.stop()
    return source
  } finally { globalThis.AudioContext = original }
})()

function capture() {
  let Processor, allocations = 0, frame = 0
  const messages = [], transfers = []
  class CountedFloat32Array extends Float32Array {
    constructor(...args) {
      super(...args)
      if (args.length === 1 && args[0] === 1024) allocations++
    }
  }
  const port = {
    onmessage: null,
    postMessage(message, transfer) {
      transfers.push(transfer.length)
      messages.push(structuredClone(message, { transfer }))
    },
  }
  const context = vm.createContext({
    Float32Array: CountedFloat32Array, sampleRate: 48000, currentFrame: 0,
    AudioWorkletProcessor: class { port = port },
    registerProcessor: (name, constructor) => { assert.equal(name, 'lumen-tap'); Processor = constructor },
  })
  vm.runInContext(workletSource, context)
  const processor = new Processor()
  return {
    messages, transfers, processor,
    get allocations() { return allocations },
    process(channels, length = channels[0]?.length ?? 128) {
      context.currentFrame = frame
      assert.equal(processor.process([channels]), true)
      frame += length
    },
    acknowledge(message) {
      const transfer = message.right ? [message.left.buffer, message.right.buffer] : [message.left.buffer]
      const returned = structuredClone({ sequence: message.sequence, left: message.left, right: message.right }, { transfer })
      port.onmessage({ data: returned })
    },
  }
}

test('metre overrides preserve learned downbeats and use grid position when changing metre', () => {
  const session = new WebMusicSession(), rendered = []
  session.state.running = true
  session.state.source = 'microphone'
  session.choreography.makeFrame = (snapshot, config, topology, fixtures, timestamp, sequenceNumber) => {
    rendered.push(snapshot)
    return { states: [], timestamp, sequenceNumber, sustainedEnergyEvent: false, flashApplied: false }
  }
  for (const metre of [3, 4]) {
    session.state.configuration.metreOverride = metre
    session.inputSnapshot = { ...emptySnapshot(), metre, beatInBar: 0,
      gridBeatPosition: metre * 2 + 1, beatCount: 19 }
    session.tick()
    assert.equal(rendered.at(-1).beatInBar, 0, 'matching metre retains the detected bar offset')
    session.inputSnapshot = { ...emptySnapshot(), metre: 7, beatInBar: 2,
      gridBeatPosition: metre * 2, beatCount: 19 }
    session.tick()
    assert.equal(rendered.at(-1).beatInBar, 0, 'changed metre follows the locked grid, not earlier fallback onsets')
    assert.equal(rendered.at(-1).beatCount, 19)
    assert.equal(rendered.at(-1).gridBeatPosition, metre * 2)
  }
})

test('actual worklet preserves mono samples and reuses transferred buffers after warmup', () => {
  const tap = capture(), input = Float32Array.from({ length: 128 }, (_, i) => i / 128)
  for (let buffer = 0; buffer < 100; buffer++) {
    for (let quantum = 0; quantum < 8; quantum++) tap.process([input])
    const message = tap.messages.at(-1)
    assert.equal(message.channels, 1)
    assert.equal(message.right, null)
    assert.equal(message.left.length, 1024)
    assert.deepEqual(message.left.subarray(128, 256), input)
    assert.equal(message.endTime, (buffer + 1) * 1024 / 48000)
    tap.acknowledge(message)
  }
  assert.ok(tap.transfers.every(count => count === 1), 'mono transfers one channel')
  assert.equal(tap.allocations, 2, 'returned buffers replace per-capture allocation')
})

test('worklet emits complete stereo spans and exact clocks even across oversized quanta', () => {
  const tap = capture()
  const left = Float32Array.from({ length: 1536 }, (_, i) => i / 1536)
  const right = left.map(value => -value)
  tap.process([left, right])
  assert.equal(tap.messages.length, 1)
  assert.deepEqual(tap.messages[0].left, left.subarray(0, 1024))
  assert.deepEqual(tap.messages[0].right, right.subarray(0, 1024))
  assert.equal(tap.messages[0].channels, 2)
  assert.equal(tap.messages[0].endTime, 1024 / 48000)
  tap.acknowledge(tap.messages[0])
  const ending = new Float32Array(512).fill(.3)
  tap.process([ending, ending])
  assert.deepEqual(tap.messages[1].left.subarray(0, 512), left.subarray(1024))
  assert.deepEqual(tap.messages[1].right.subarray(0, 512), right.subarray(1024))
  assert.deepEqual(tap.messages[1].left.subarray(512), ending)
  assert.equal(tap.messages[1].endTime, 2048 / 48000)
  assert.ok(tap.transfers.every(count => count === 2))
})

test('route changes discard partial windows and input interruptions create sequence gaps', () => {
  const tap = capture(), old = new Float32Array(384).fill(.1), fresh = new Float32Array(1024).fill(.7)
  tap.process([old])
  tap.process([fresh, fresh])
  const stereo = tap.messages[0]
  assert.deepEqual(stereo.left, fresh)
  assert.equal(stereo.channels, 2)
  assert.equal(stereo.dropped, 1)
  assert.equal(stereo.sequence, 2)
  tap.acknowledge(stereo)
  tap.process([])
  tap.process([fresh])
  const mono = tap.messages[1]
  assert.equal(mono.channels, 1)
  assert.equal(mono.sequence, 4, 'lost route cannot lend its history to resumed PCM')
  assert.equal(mono.right, null)
  assert.equal(mono.endTime, (384 + 1024 + 128 + 1024) / 48000)
})

test('worklet bounds backpressure and rejects duplicate acknowledgements', () => {
  const tap = capture(), input = new Float32Array(1024).fill(.2)
  for (let i = 0; i < 4; i++) tap.process([input])
  assert.equal(tap.messages.length, 2)
  assert.equal(tap.processor.pending.size, 2)
  assert.equal(tap.allocations, 3, 'blocked captures reuse the current writable buffer')
  const firstSequence = tap.messages[0].sequence
  tap.acknowledge(tap.messages[0])
  tap.processor.port.onmessage({ data: { sequence: firstSequence } })
  assert.equal(tap.processor.pending.size, 1)
  tap.process([input])
  assert.equal(tap.messages[2].sequence, 5)
  assert.equal(tap.messages[2].dropped, 2)
  assert.equal(tap.processor.pending.size, 2)
})

test('capture passes real mono layout and retains the legacy stereo callback shape', () => {
  const session = new WebMusicSession(), calls = []
  session.analyzer.analyze = (samples, end, stereo) => { calls.push(stereo); return null }
  const left = new Float32Array(1024), right = new Float32Array(1024)
  session.consumePCM({ left, right, channels: 1, sampleRate: 48000, sequence: 1, dropped: 0 }, 100)
  session.consumePCM({ left, right, channels: 2, sampleRate: 48000, sequence: 2, dropped: 0 }, 100.02)
  session.consumePCM({ left, right, sampleRate: 48000, sequence: 3, dropped: 0 }, 100.04)
  session.consumePCM({ left, right, sequence: 3, sampleRate: 48000, dropped: 0 }, 100.04)
  assert.equal(calls.length, 3)
  assert.equal(calls[0], undefined)
  for (const stereo of calls.slice(1)) {
    assert.equal(stereo.left, left)
    assert.equal(stereo.right, right)
  }
  assert.equal(session.diagnostics.analyzedSamples, 3072)
})

function withClockAndTap(t) {
  const originalPerformance = globalThis.performance, originalNode = globalThis.AudioWorkletNode
  let now = 100
  const nodes = []
  globalThis.performance = { now: () => now * 1000 }
  globalThis.AudioWorkletNode = class {
    constructor(_audio, _name, options) {
      this.options = options
      this.returned = []
      this.port = { onmessage: null, postMessage: (message, transfer) => {
        this.returned.push(structuredClone(message, { transfer }))
      } }
      nodes.push(this)
    }
    connect() {}
    disconnect() {}
  }
  t.after(() => { globalThis.performance = originalPerformance; globalThis.AudioWorkletNode = originalNode })
  const audio = {
    currentTime: 10, destination: {},
    getOutputTimestamp: () => ({ contextTime: 9.8, performanceTime: now * 1000 }),
    createGain: () => ({ gain: { value: 1 }, connect() {} }),
  }
  const pcm = (sequence, endTime, sample = .7) => ({
    left: new Float32Array(1024).fill(sample), channels: 1,
    sampleRate: 48000, sequence, dropped: 0, endTime,
  })
  return { nodes, audio, pcm, setNow: time => { now = time } }
}

test('monitored playback waits for audible samples across multiple queued captures', t => {
  const { nodes, audio, pcm, setNow } = withClockAndTap(t)
  const session = new WebMusicSession()
  session.state.running = true; session.state.source = 'file'
  session.analyzer.analyze = (samples, end) => ({
    ...emptySnapshot(), analysisTimestamp: end, beatReferenceTime: end,
    beat: samples[0], snare: samples[0], level: .4, energy: .4,
  })
  const rendered = []
  session.choreography.makeFrame = snapshot => { rendered.push(snapshot); return { states: [], timestamp: 100, sequenceNumber: 1 } }
  session.connectTap({ connect() {} }, audio, true, 0)
  const node = nodes[0]
  assert.deepEqual(node.options.outputChannelCount, [1])
  node.port.onmessage({ data: pcm(1, 10, .4) })
  node.port.onmessage({ data: pcm(2, 10.02, .7) })
  node.port.onmessage({ data: pcm(3, 10.04, 1) })
  assert.equal(node.returned.length, 3, 'future snapshots return PCM promptly')
  assert.equal(session.playbackCount, 3)
  session.tick()
  setNow(100.19); session.tick()
  assert.equal(rendered.at(-1).beat, 0, 'a future captured hit cannot flash early')
  setNow(100.201); session.tick()
  assert.ok(Math.abs(rendered.at(-1).beat - .4) < 1e-6)
  assert.ok(Math.abs(session.inputSnapshot.analysisTimestamp - 100.2) < 1e-12)
  setNow(100.225); session.tick()
  assert.ok(Math.abs(rendered.at(-1).beat - .7) < 1e-6)
  assert.equal(session.playbackCount, 1)
  setNow(100.245); session.tick()
  assert.equal(rendered.at(-1).beat, 1)
  assert.equal(session.playbackCount, 0)
  setNow(101); session.tick()
  assert.ok(session.state.snapshot.snare < .001, 'ready snapshots still age when capture stops')
})

test('microphones retain capture time, output-clock fallback works, and old generations are ignored', t => {
  const { nodes, audio, pcm } = withClockAndTap(t)
  const session = new WebMusicSession(), times = []
  session.state.running = true; session.state.source = 'microphone'
  session.analyzer.analyze = (_samples, end) => { times.push(end); return null }
  session.connectTap({ connect() {} }, audio, false, 0)
  nodes[0].port.onmessage({ data: pcm(1, 9.98) })
  assert.ok(Math.abs(times[0] - 99.98) < 1e-12)
  assert.equal(session.playbackCount, 0)
  session.state.source = 'file'
  audio.getOutputTimestamp = () => ({ contextTime: 0, performanceTime: 0 })
  session.connectTap({ connect() {} }, audio, true, 0)
  nodes[1].port.onmessage({ data: pcm(2, 10) })
  assert.equal(times[1], 100)
  session.generation++
  nodes[1].port.onmessage({ data: pcm(3, 10.02) })
  assert.equal(times.length, 2)
  assert.equal(nodes[1].returned.length, 1)
})

test('capture gaps and stop clear future playback history and the queue stays bounded', async t => {
  const { setNow } = withClockAndTap(t)
  globalThis.window = globalThis
  const session = new WebMusicSession(), left = new Float32Array(1024)
  session.state.running = true; session.state.source = 'file'
  let resets = 0
  session.analyzer.reset = () => { resets++ }
  session.analyzer.analyze = (_samples, end) => ({ ...emptySnapshot(), beat: 1, analysisTimestamp: end })
  for (let i = 1; i <= 200; i++) {
    session.consumePCM({ left, channels: 1, sampleRate: 48000, sequence: i, dropped: 0 }, 105 + i / 100)
  }
  assert.equal(session.playbackCount, 128)
  session.tick()
  assert.equal(session.state.snapshot.beat, 0)
  session.consumePCM({ left, channels: 1, sampleRate: 48000, sequence: 202, dropped: 1 }, 108)
  assert.equal(resets, 1)
  assert.equal(session.playbackCount, 1)
  setNow(107.9); session.tick()
  assert.equal(session.state.snapshot.beat, 0)
  await session.stop()
  assert.equal(session.playbackCount, 0)
})

for (const source of ['microphone', 'file']) {
  test(`${source} preserves a hit between render ticks without replaying it into the next capture`, t => {
    const { setNow } = withClockAndTap(t)
    const session = new WebMusicSession()
    session.state.running = true; session.state.source = source
    session.analyzer.analyze = (samples, end) => ({
      ...emptySnapshot(), snare: samples[0], onset: samples[0], analysisTimestamp: end,
      level: end === 100.01 ? .8 : .3, beatCount: end === 100.01 ? 3 : 4,
    })
    const pcm = (sequence, hit) => ({ left: new Float32Array(1024).fill(hit), channels: 1,
      sampleRate: 48000, sequence, dropped: 0 })
    session.consumePCM(pcm(1, .95), 100.01)
    session.consumePCM(pcm(2, 0), 100.03133333333333)
    setNow(100.04); session.tick()
    assert.ok(Math.abs(session.state.snapshot.snare - .95 * Math.exp(-.03 / .08)) < 1e-7)
    assert.equal(session.state.snapshot.level, .3, 'keep the newest loudness')
    assert.equal(session.state.snapshot.beatCount, 4, 'keep the newest beat grid')
    setNow(100.09); session.tick()
    assert.ok(Math.abs(session.state.snapshot.snare - .95 * Math.exp(-.08 / .08)) < 1e-7,
      'capture stalls continue the original envelope without refreshing its peak')
    session.consumePCM(pcm(3, 0), 100.10)
    setNow(100.11); session.tick()
    assert.equal(session.state.snapshot.snare, 0, 'a consumed hit is not merged into later captures')
  })
}

test('MIDI ticks retain one decaying beat snapshot and preserve slow-tempo loudness', t => {
  const { setNow } = withClockAndTap(t)
  const session = new WebMusicSession()
  session.state.running = true; session.state.source = 'midi'
  const midi = (byte, time) => session.handleMidi({ data: new Uint8Array([byte]), timeStamp: time * 1000 })
  midi(0xfa, 100); midi(0xf8, 100)
  const first = session.inputSnapshot
  for (let tick = 1; tick < 24; tick++) midi(0xf8, 100 + tick / 24)
  assert.equal(session.inputSnapshot, first, '23 timing ticks allocate no new musical snapshots')
  assert.equal(session.inputSnapshot.analysisTimestamp, 100, 'timing ticks cannot refresh the hit')
  setNow(100.2); session.tick()
  assert.ok(Math.abs(session.state.snapshot.pulse - Math.exp(-.2 / .16)) < 1e-12)
  assert.ok(Math.abs(session.state.snapshot.beat - Math.exp(-.2 / .08)) < 1e-12)
  midi(0xf8, 101)
  assert.notEqual(session.inputSnapshot, first)
  assert.equal(session.inputSnapshot.tempo, 60)
  assert.equal(session.inputSnapshot.snare, .9, 'MIDI backbeats match native quarter-note accents')
  for (let tick = 1; tick < 24; tick++) midi(0xf8, 101 + tick / 24)
  setNow(101.9); session.tick()
  assert.equal(session.state.snapshot.level, .55, 'slow MIDI beats keep their sustained loudness bed')
  assert.ok(session.state.snapshot.snare < .0001, 'backbeat transients release between ticks')
})

test('render frames notify live subscribers without invalidating Music Mode controls', t => {
  const { setNow } = withClockAndTap(t)
  const session = new WebMusicSession()
  let live = 0, controls = 0
  const unsubscribeLive = session.subscribe(() => { live++ })
  const unsubscribeControls = session.subscribeControls(() => { controls++ })
  session.state.running = true
  for (let i = 0; i < 20; i++) { setNow(100 + i * .05); session.tick() }
  assert.equal(live, 20)
  assert.equal(controls, 0)
  assert.equal(session.controlsVersion, 0)
  session.patch({ grooveId: 'breaks' })
  assert.equal(live, 21)
  assert.equal(controls, 1)
  assert.equal(session.controlsVersion, 1)
  unsubscribeLive(); unsubscribeControls()
  session.setDevices([])
  assert.equal(live, 21)
  assert.equal(controls, 1)
})

test('controls receive file and MIDI details after asynchronous source startup', async t => {
  withClockAndTap(t)
  const originalWindow = globalThis.window
  globalThis.window = { setInterval: () => 1, clearInterval() {} }
  t.after(() => { globalThis.window = originalWindow })
  for (const source of ['file', 'midi']) {
    const session = new WebMusicSession(), received = []
    session.subscribeControls(() => received.push({ fileName: session.state.fileName, midiClock: session.state.midiClock }))
    session.startFile = async () => { await Promise.resolve(); session.state.fileName = 'drums.wav' }
    session.startMidi = async () => { await Promise.resolve(); session.state.midiClock = true }
    await session.start(source, source === 'file' ? {} : undefined)
    assert.deepEqual(received.at(-1), {
      fileName: source === 'file' ? 'drums.wav' : null,
      midiClock: source === 'midi',
    }, 'completed source setup must publish controls without depending on render-frame notifications')
    await session.stop()
  }
})
