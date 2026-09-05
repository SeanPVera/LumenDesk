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
} from './types'

const RENDER_HZ = 20
const WORKLET = `
class LumenTap extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0]
    if (input && input[0] && input[0].length) {
      const left = input[0]
      const right = input[1] || input[0]
      const copy = new Float32Array(left.length)
      copy.set(left)
      const copyR = new Float32Array(right.length)
      copyR.set(right)
      this.port.postMessage({ left: copy, right: copyR, sampleRate: sampleRate }, [copy.buffer, copyR.buffer])
    }
    return true
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
  private latestPcm: { left: Float32Array; right: Float32Array; sampleRate: number } | null = null
  version = 0
  private onFrame: ((frame: MusicLightingFrame) => void) | null = null

  readonly state: MusicSessionState = {
    running: false,
    source: 'demo',
    grooveId: 'four',
    fileName: null,
    snapshot: emptySnapshot(),
    frame: null,
    configuration: configurationFor('concert'),
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
    this.state.fixtures = devices.map(deviceToFixture)
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
      if (source === 'microphone') await this.startMicrophone()
      else if (source === 'file' && file) await this.startFile(file)
      else if (source === 'midi') await this.startMidi()
      this.timer = window.setInterval(() => this.tick(), 1000 / RENDER_HZ)
    } catch (err) {
      this.state.running = false
      this.state.error = err instanceof Error ? err.message : String(err)
      this.emit()
    }
  }

  async stop(): Promise<void> {
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
    if (this.audio) {
      await this.audio.close().catch(() => undefined)
      this.audio = null
    }
    this.midiAccess = null
    this.state.running = false
    this.state.midiClock = false
    this.emit()
  }

  private emit(): void {
    this.version += 1
    for (const listener of this.listeners) listener()
  }

  private tick(): void {
    const timestamp = performance.now() / 1000
    this.sequence += 1
    if (this.state.source === 'demo') {
      const groove = GROOVES.find(g => g.id === this.state.grooveId) ?? GROOVES[0]
      this.state.snapshot = syntheticSnapshot(groove as Groove, this.startedAt, timestamp)
    } else if (this.state.source === 'midi') {
      // MIDI clock publishes through handleMidi; keep last snapshot.
    } else if (this.latestPcm) {
      const pcm = this.latestPcm
      const analyzed = this.analyzer.analyze(pcm.left, timestamp, { left: pcm.left, right: pcm.right }, pcm.sampleRate)
      if (analyzed) this.state.snapshot = analyzed
    }
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

  private async ensureAudio(): Promise<AudioContext> {
    if (this.audio) return this.audio
    const audio = new AudioContext()
    const blob = new Blob([WORKLET], { type: 'text/javascript' })
    const url = URL.createObjectURL(blob)
    await audio.audioWorklet.addModule(url)
    URL.revokeObjectURL(url)
    this.audio = audio
    return audio
  }

  private connectTap(source: AudioNode, audio: AudioContext, monitor: boolean): void {
    const node = new AudioWorkletNode(audio, 'lumen-tap')
    node.port.onmessage = event => {
      this.latestPcm = event.data
    }
    const mute = audio.createGain()
    mute.gain.value = 0
    source.connect(node)
    node.connect(mute)
    mute.connect(audio.destination)
    if (monitor) source.connect(audio.destination)
    this.workletNode = node
  }

  private async startMicrophone(): Promise<void> {
    const audio = await this.ensureAudio()
    this.mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false })
    const source = audio.createMediaStreamSource(this.mediaStream)
    this.connectTap(source, audio, false)
  }

  private async startFile(file: File): Promise<void> {
    const audio = await this.ensureAudio()
    const buffer = await audio.decodeAudioData(await file.arrayBuffer())
    const source = audio.createBufferSource()
    source.buffer = buffer
    source.loop = true
    this.connectTap(source, audio, true)
    source.start()
    this.bufferSource = source
    this.state.fileName = file.name
  }

  private async startMidi(): Promise<void> {
    if (!navigator.requestMIDIAccess) throw new Error('This browser does not expose MIDI.')
    this.midiAccess = await navigator.requestMIDIAccess()
    this.state.midiClock = true
    for (const input of this.midiAccess.inputs.values()) {
      input.onmidimessage = event => this.handleMidi(event)
    }
  }

  private handleMidi(event: MIDIMessageEvent): void {
    const byte = event.data?.[0]
    if (byte === 0xf8) {
      this.midiTicks += 1
      if (this.midiTicks >= 24) {
        this.midiTicks = 0
        this.midiBeats += 1
        const now = performance.now() / 1000
        const snapshot = emptySnapshot()
        snapshot.isTempoLocked = true
        snapshot.confidence = 1
        snapshot.beat = 1
        snapshot.pulse = 1
        snapshot.kick = 0.8
        snapshot.level = 0.55
        snapshot.energy = 0.6
        snapshot.beatCount = this.midiBeats
        snapshot.beatInBar = this.midiBeats % 4
        snapshot.beatReferenceTime = now
        snapshot.beatInterval = 0.5
        snapshot.tempo = 120
        snapshot.feltInterval = 0.5
        snapshot.feltTempo = 120
        snapshot.metre = 4
        snapshot.sourceDescription = 'MIDI clock'
        this.state.snapshot = snapshot
      }
    } else if (byte === 0xfa || byte === 0xfb || byte === 0xfc) {
      this.midiTicks = 0
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
  session.state.fixtures = session.state.fixtures.map(fixture => (fixture.id === id ? { ...fixture, role } : fixture))
}

export function frameToCommands(frame: MusicLightingFrame): { fixtureID: string; rgb: { r: number; g: number; b: number } }[] {
  const byFixture = new Map<string, { r: number; g: number; b: number }>()
  for (const state of frame.states) {
    if (byFixture.has(state.fixtureID)) continue
    byFixture.set(state.fixtureID, hsvToRgb(state.hue, state.saturation, state.brightness))
  }
  return [...byFixture.entries()].map(([fixtureID, rgb]) => ({ fixtureID, rgb }))
}

function sourceLabel(source: AudioSourceKind, file?: File): string {
  if (source === 'file') return file?.name ?? 'Audio file'
  if (source === 'microphone') return 'Microphone'
  if (source === 'midi') return 'MIDI clock'
  return 'Demo grid'
}
