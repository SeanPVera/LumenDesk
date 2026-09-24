import { MusicFeatureAnalyzer } from './analyzer'
import { MusicChoreographyEngine } from './choreography'
import { configurationFor, normalizeConfiguration } from './config'
import { hsvToRgb } from './fixtures'
import { GROOVES, syntheticSnapshot, type Groove } from './grooves'
import {
  type AudioSourceKind,
  type FixtureRole,
  type FixtureTopology,
  type MusicFixtureDescriptor,
  type MusicLightingFrame,
  type MusicModeConfiguration,
  type MusicTransportKind,
  emptySnapshot,
  freshSnapshot,
} from './types'

const RENDER_HZ = 20
const WORKLET = `
class LumenTap extends AudioWorkletProcessor {
  constructor() {
    super(); this.left = new Float32Array(1024); this.right = new Float32Array(1024);
    this.used = 0; this.pending = 0; this.sequence = 0; this.dropped = 0;
    this.port.onmessage = () => { this.pending = Math.max(0, this.pending - 1); };
  }
  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;
    for (let i = 0; i < input[0].length; i++) {
      this.left[this.used] = input[0][i]; this.right[this.used] = (input[1] || input[0])[i];
      if (++this.used === 1024) {
        this.sequence++;
        if (this.pending < 2) {
          this.pending++;
          this.port.postMessage({left:this.left,right:this.right,sampleRate,
            endTime:(currentFrame+i+1)/sampleRate,sequence:this.sequence,dropped:this.dropped},
            [this.left.buffer,this.right.buffer]);
          this.left = new Float32Array(1024); this.right = new Float32Array(1024);
        } else { this.dropped++; }
        this.used = 0;
      }
    }
    return true;
  }
}
registerProcessor('lumen-tap', LumenTap)
`

export interface BridgeDevice {
  id: string
  name: string
  brand: 'lifx' | 'govee'
  reachable: boolean
}

export interface MusicSessionState {
  running: boolean
  source: AudioSourceKind
  grooveId: string
  fileName: string | null
  snapshot: ReturnType<typeof emptySnapshot>
  frame: MusicLightingFrame | null
  configuration: MusicModeConfiguration
  topology: FixtureTopology
  fixtures: MusicFixtureDescriptor[]
  error: string | null
  midiClock: boolean
}

type Listener = () => void

export class WebMusicSession {
  private listeners = new Set<Listener>()
  private analyzer = new MusicFeatureAnalyzer('Demo grid')
  private choreography = new MusicChoreographyEngine()
  private timer: number | null = null
  private startedAt = 0
  private sequence = 0
  private audio: AudioContext | null = null
  private mediaStream: MediaStream | null = null
  private workletNode: AudioWorkletNode | null = null
  private bufferSource: AudioBufferSourceNode | null = null
  private midiAccess: MIDIAccess | null = null
  private midiTicks = 0
  private midiBeats = 0
  private generation = 0
  private captureSequence = 0
  private midiLastBeat: number | null = null
  private midiLastTick: number | null = null
  private midiStopped = false
  private inputSnapshot = emptySnapshot()
  readonly diagnostics = { analyzedSamples: 0, droppedBuffers: 0, framesGenerated: 0, snapshotAge: 0 }
  version = 0
  private onFrame: ((frame: MusicLightingFrame) => void) | null = null

  readonly state: MusicSessionState = {
    running: false,
    source: 'demo',
    grooveId: 'four',
    fileName: null,
    snapshot: emptySnapshot(),
    frame: null,
    configuration: configurationFor('soundcheck'),
    topology: { layout: 'leftToRight', fixtureOrder: [], excludedFixtureIDs: [] },
    fixtures: [],
    error: null,
    midiClock: false,
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  setDevices(devices: BridgeDevice[]): void {
    const previous = new Map(this.state.fixtures.map(f=>[f.id,f]))
    this.state.fixtures = devices.filter(d=>!this.state.running || previous.has(d.id)).map(d=>previous.get(d.id) ?? deviceToFixture(d))
    const ids = this.state.fixtures.map(f => f.id)
    if (this.state.topology.fixtureOrder.length === 0) {
      this.state.topology.fixtureOrder = ids
    }
    this.emit()
  }

  setOnFrame(handler: ((frame: MusicLightingFrame) => void) | null): void {
    this.onFrame = handler
  }

  patch(partial: Partial<MusicSessionState>): void {
    Object.assign(this.state, partial)
    if (partial.configuration) {
      this.state.configuration = normalizeConfiguration(partial.configuration)
      this.analyzer.setPolicy(this.state.configuration.metreOverride, this.state.configuration.timeFeel)
    }
    this.emit()
  }

  async start(source: AudioSourceKind, file?: File): Promise<void> {
    await this.stop()
    const generation = ++this.generation
    this.captureSequence = 0
    this.inputSnapshot = emptySnapshot()
    this.state.snapshot = emptySnapshot()
    this.state.error = null
    this.state.source = source
    this.state.running = true
    this.startedAt = performance.now() / 1000
    this.sequence = 0
    this.choreography.reset()
    this.analyzer.reset(sourceLabel(source, file))
    this.analyzer.setPolicy(this.state.configuration.metreOverride, this.state.configuration.timeFeel)
    this.emit()
    try {
      if (source === 'microphone') await this.startMicrophone(generation)
      else if (source === 'file' && file) await this.startFile(file, generation)
      else if (source === 'midi') await this.startMidi(generation)
      if (generation !== this.generation) return
      this.timer = window.setInterval(() => this.tick(), 1000 / RENDER_HZ)
    } catch (err) {
      if (generation !== this.generation) return
      await this.stop()
      this.state.running = false
      this.state.error = err instanceof Error ? err.message : String(err)
      this.emit()
    }
  }

  async stop(): Promise<void> {
    this.generation++
    this.state.running = false
    this.inputSnapshot = emptySnapshot()
    this.state.snapshot = emptySnapshot()
    if (this.timer != null) {
      window.clearInterval(this.timer)
      this.timer = null
    }
    this.bufferSource?.stop()
    this.bufferSource = null
    this.workletNode?.disconnect()
    this.workletNode = null
    this.mediaStream?.getTracks().forEach(track => track.stop())
    this.mediaStream = null
    const audio = this.audio
    this.audio = null
    if (this.midiAccess) for (const input of this.midiAccess.inputs.values()) input.onmidimessage = null
    this.midiAccess = null
    this.midiTicks = 0; this.midiBeats = 0; this.midiLastBeat = null; this.midiLastTick = null
    if (audio) await audio.close().catch(() => undefined)
    this.state.running = false
    this.state.midiClock = false
    this.emit()
  }

  private emit(): void {
    this.version += 1
    for (const listener of this.listeners) listener()
  }

  private tick(): void {
    if (!this.state.running) return
    const timestamp = performance.now() / 1000
    this.sequence += 1
    if (this.state.source === 'demo') {
      const groove = GROOVES.find(g => g.id === this.state.grooveId) ?? GROOVES[0]
      this.state.snapshot = syntheticSnapshot(groove as Groove, this.startedAt, timestamp)
    } else {
      this.state.snapshot = freshSnapshot(this.inputSnapshot, timestamp)
    }
    const snapshot = this.state.snapshot
    const config = this.state.configuration
    if (config.metreOverride !== 'auto') {
      snapshot.metre = config.metreOverride
      snapshot.beatInBar = (snapshot.gridBeatPosition ?? snapshot.beatCount) % snapshot.metre
    }
    if (config.timeFeel !== 'auto') snapshot.timeFeel = config.timeFeel
    const multiplier = snapshot.timeFeel === 'half' ? 2 : snapshot.timeFeel === 'double' ? .5 : 1
    snapshot.feltInterval = snapshot.beatInterval * multiplier
    snapshot.feltTempo = snapshot.tempo / multiplier
    this.diagnostics.framesGenerated++
    this.diagnostics.snapshotAge = snapshot.analysisTimestamp == null ? 0 : Math.max(0,timestamp-snapshot.analysisTimestamp)
    const frame = this.choreography.makeFrame(
      this.state.snapshot,
      this.state.configuration,
      this.state.topology,
      this.state.fixtures,
      timestamp,
      this.sequence,
    )
    this.state.frame = frame
    this.onFrame?.(frame)
    this.emit()
  }

  private async ensureAudio(generation: number): Promise<AudioContext> {
    if (this.audio) return this.audio
    const audio = new AudioContext()
    const blob = new Blob([WORKLET], { type: 'text/javascript' })
    const url = URL.createObjectURL(blob)
    try { await audio.audioWorklet.addModule(url) } finally { URL.revokeObjectURL(url) }
    if (generation !== this.generation) { await audio.close(); throw new Error('Capture start cancelled') }
    this.audio = audio
    return audio
  }

  private connectTap(source: AudioNode, audio: AudioContext, monitor: boolean, generation: number): void {
    const node = new AudioWorkletNode(audio, 'lumen-tap')
    node.port.onmessage = event => {
      if (generation !== this.generation || !this.state.running) return
      const pcm = event.data
      const end = performance.now()/1000 - (audio.currentTime-pcm.endTime)
      this.consumePCM(pcm, end)
      node.port.postMessage('consumed')
    }
    const mute = audio.createGain()
    mute.gain.value = 0
    source.connect(node)
    node.connect(mute)
    mute.connect(audio.destination)
    if (monitor) source.connect(audio.destination)
    this.workletNode = node
  }

  private async startMicrophone(generation: number): Promise<void> {
    const audio = await this.ensureAudio(generation)
    const stream = await navigator.mediaDevices.getUserMedia({ audio: {echoCancellation:false,noiseSuppression:false,autoGainControl:false}, video: false })
    if (generation !== this.generation) { stream.getTracks().forEach(t=>t.stop()); return }
    this.mediaStream = stream
    const source = audio.createMediaStreamSource(this.mediaStream)
    this.connectTap(source, audio, false, generation)
  }

  private async startFile(file: File, generation: number): Promise<void> {
    const audio = await this.ensureAudio(generation)
    const buffer = await audio.decodeAudioData(await file.arrayBuffer())
    if (generation !== this.generation) return
    const source = audio.createBufferSource()
    source.buffer = buffer
    source.loop = true
    this.connectTap(source, audio, true, generation)
    source.start()
    this.bufferSource = source
    this.state.fileName = file.name
  }

  private async startMidi(generation: number): Promise<void> {
    if (!navigator.requestMIDIAccess) throw new Error('This browser does not expose MIDI.')
    const access = await navigator.requestMIDIAccess()
    if (generation !== this.generation) return
    this.midiAccess = access
    this.midiStopped = false
    this.state.midiClock = true
    for (const input of this.midiAccess.inputs.values()) {
      input.onmidimessage = event => this.handleMidi(event)
    }
  }

  /** Capture consumes every accepted buffer once, independently of rendering. */
  private consumePCM(pcm: {left:Float32Array;right:Float32Array;sampleRate:number;sequence:number;dropped:number}, end: number): void {
    if (pcm.sequence <= this.captureSequence) return
    if (this.captureSequence && pcm.sequence !== this.captureSequence+1) this.analyzer.reset()
    this.captureSequence = pcm.sequence
    const analyzed = this.analyzer.analyze(pcm.left,end,pcm,pcm.sampleRate)
    this.diagnostics.analyzedSamples += pcm.left.length
    this.diagnostics.droppedBuffers = pcm.dropped
    if (analyzed) {
      analyzed.analysisCompletedAt = performance.now()/1000
      analyzed.droppedBuffers = pcm.dropped
      this.inputSnapshot = analyzed
    }
  }

  private handleMidi(event: MIDIMessageEvent): void {
    const now = event.timeStamp/1000
    for (const byte of event.data ?? []) {
      if (byte === 0xfc) { this.midiStopped = true; this.inputSnapshot = emptySnapshot(); continue }
      if (byte === 0xfa) { this.midiTicks=0;this.midiBeats=0;this.midiLastBeat=null;this.midiLastTick=null;this.midiStopped=false;continue }
      if (byte === 0xfb) { this.midiStopped=false;this.midiLastTick=null;continue }
      if (byte !== 0xf8 || this.midiStopped) continue
      const tickInterval = this.midiLastTick == null ? 0 : now-this.midiLastTick
      this.midiLastTick = now
      if (this.midiTicks++ % 24 === 0) { this.midiBeats++; this.midiLastBeat=now }
      const interval = tickInterval>0 && tickInterval<.25 ? tickInterval*24 : this.inputSnapshot.beatInterval
      this.inputSnapshot = {...emptySnapshot(),level:.55,energy:.6,confidence:1,
        beat:this.midiTicks%24===1?1:0,pulse:.6,kick:.8,beatCount:this.midiBeats-1,
        gridBeatPosition:this.midiBeats-1,beatInBar:(this.midiBeats-1)%4,
        beatReferenceTime:this.midiLastBeat ?? now,beatInterval:interval,tempo:interval>0?60/interval:0,
        beatConfidence:interval>0?1:0,isTempoLocked:interval>0,analysisTimestamp:now,sourceDescription:'MIDI clock'}
    }
  }

}

export function deviceToFixture(device: BridgeDevice): MusicFixtureDescriptor {
  const transport: MusicTransportKind = device.brand === 'lifx' ? 'lifxLAN' : 'goveeLAN'
  return {
    id: device.id,
    label: device.name,
    transport,
    segmentCount: 0,
    role: 'auto',
  }
}

export function setFixtureRole(session: WebMusicSession, id: string, role: FixtureRole): void {
  session.state.fixtures = session.state.fixtures.map(fixture => {
    if (fixture.id !== id || (session.state.running && ((fixture.role === 'off') !== (role === 'off')))) return fixture
    return {...fixture,role}
  })
}

export interface MusicFrameCommand { fixtureID: string; rgb: { r: number; g: number; b: number }; brightness?: number; transitionDuration?: number; restoring?: boolean; owner?: string; controlRevision?: number; release?: boolean }

export function frameToCommands(frame: MusicLightingFrame): MusicFrameCommand[] {
  const byFixture = new Map<string, MusicFrameCommand>()
  for (const state of frame.states) {
    if (byFixture.has(state.fixtureID)) continue
    byFixture.set(state.fixtureID, {fixtureID:state.fixtureID,rgb:hsvToRgb(state.hue,state.saturation,1),
      brightness:state.brightness,transitionDuration:state.transitionDuration})
  }
  return [...byFixture.values()]
}

function sourceLabel(source: AudioSourceKind, file?: File): string {
  if (source === 'file') return file?.name ?? 'Audio file'
  if (source === 'microphone') return 'Microphone'
  if (source === 'midi') return 'MIDI clock'
  return 'Demo grid'
}

/** One HTTP operation in flight, one newest pending frame, 10 Hz ceiling.
 * A completed HTTP request is acceptance by the bridge, not device receipt. */
export class LatestMusicFrameSender {
  private pending: MusicLightingFrame | null = null
  private flight: Promise<void> | null = null
  private stopped = true
  private lastStart = -Infinity
  private timer: ReturnType<typeof setTimeout> | null = null
  readonly diagnostics = { coalesced:0, expired:0, submitted:0, accepted:0, failures:0 }
  constructor(private send: (states: MusicFrameCommand[]) => Promise<unknown>, private now = () => performance.now()/1000) {}
  start(): void { this.stopped=false }
  enqueue(frame: MusicLightingFrame): void {
    if (this.stopped) return
    if (this.pending) this.diagnostics.coalesced++
    this.pending=frame; this.pump()
  }
  private pump(): void {
    if (this.stopped || this.flight || this.timer || !this.pending) return
    const delay = Math.max(0,.1-(this.now()-this.lastStart))
    if (delay>0) { this.timer=setTimeout(()=>{this.timer=null;this.pump()},delay*1000);return }
    const frame=this.pending;this.pending=null
    if (this.now()-frame.timestamp>.25) { this.diagnostics.expired++;return }
    this.lastStart=this.now();this.diagnostics.submitted++
    this.flight=this.send(frameToCommands(frame)).then(()=>{this.diagnostics.accepted++},()=>{this.diagnostics.failures++})
      .finally(()=>{this.flight=null;this.pump()})
  }
  async stop(): Promise<void> {
    this.stopped=true;this.pending=null
    if(this.timer) clearTimeout(this.timer)
    this.timer=null
    await this.flight
  }
}
