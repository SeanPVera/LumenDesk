import { MusicFeatureAnalyzer } from './analyzer'
import { TapCalibrator, analyzeAudioBuffer, applyBeatMap, type BeatMap } from './beat-map'
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
  retainUnrenderedTransients,
} from './types'

const RENDER_HZ = 20
const WORKLET = `
class LumenTap extends AudioWorkletProcessor {
  constructor() {
    super(); this.left = new Float32Array(1024); this.right = null;
    this.used = 0; this.channels = 0; this.sequence = 0; this.dropped = 0;
    this.pending = new Set(); this.free = [];
    this.port.onmessage = event => {
      const returned = event.data;
      if (!returned || !this.pending.delete(returned.sequence)) return;
      for (const channel of [returned.left, returned.right]) {
        if (channel && channel.length === 1024) this.free.push(channel);
      }
    };
  }
  take() { return this.free.pop() || new Float32Array(1024); }
  process(inputs) {
    const input = inputs[0];
    const channels = input && input[0] ? Math.min(input.length, 2) : 0;
    if (channels !== this.channels) {
      // Never join PCM from different routes into one analysis window. A
      // sequence gap also resets the analyzer when an input disappears.
      if (this.channels) this.sequence++;
      if (this.used) this.dropped++;
      this.used = 0; this.channels = channels;
      if (channels < 2 && this.right) { this.free.push(this.right); this.right = null; }
      if (channels === 2 && !this.right) this.right = this.take();
    }
    if (!channels) return true;
    let offset = 0;
    while (offset < input[0].length) {
      const count = Math.min(1024 - this.used, input[0].length - offset);
      const whole = offset === 0 && count === input[0].length;
      this.left.set(whole ? input[0] : input[0].subarray(offset, offset + count), this.used);
      if (channels === 2) this.right.set(whole ? input[1] : input[1].subarray(offset, offset + count), this.used);
      this.used += count; offset += count;
      if (this.used === 1024) {
        this.sequence++;
        if (this.pending.size < 2) {
          this.pending.add(this.sequence);
          const transfer = channels === 2 ? [this.left.buffer, this.right.buffer] : [this.left.buffer];
          this.port.postMessage({left:this.left,right:this.right,channels,sampleRate,
            endTime:(currentFrame+offset)/sampleRate,sequence:this.sequence,dropped:this.dropped}, transfer);
          this.left = this.take();
          if (channels === 2) this.right = this.take();
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
  brand: 'lifx' | 'govee' | 'nanoleaf'
  reachable: boolean
}

export type BeatMapStatus = 'none' | 'analyzing' | 'ready' | 'unavailable'

export interface BeatMapState {
  status: BeatMapStatus
  /** 0…1 while analysing. */
  progress: number
  tempo: number | null
}

export interface MusicSessionState {
  beatMap: BeatMapState
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

interface CapturedPCM {
  left: Float32Array
  right?: Float32Array | null
  channels?: 1 | 2
  sampleRate: number
  sequence: number
  dropped: number
  endTime: number
}

export class WebMusicSession {
  private listeners = new Set<Listener>()
  private controlsListeners = new Set<Listener>()
  private analyzer = new MusicFeatureAnalyzer('Demo grid')
  private choreography = new MusicChoreographyEngine()
  private timer: number | null = null
  private startedAt = 0
  private lastRenderAt: number | null = null
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
  private readonly midiTickTimes = new Float64Array(25)
  private midiTimingWrite = 0
  private midiTimingCount = 0
  private midiStopped = false
  private inputSnapshot = emptySnapshot()
  private hasUnrenderedCapture = false
  private readonly playbackSnapshots: Array<ReturnType<typeof emptySnapshot> | undefined> = new Array(128)
  private playbackRead = 0
  private playbackCount = 0
  /** Maps survive Stop and Restart for the life of the page, keyed by file identity. */
  private readonly beatMapCache = new Map<string, BeatMap | null>()
  private beatMap: BeatMap | null = null
  private fileStartContextTime = 0
  private fileDuration = 0
  private lastProgressEmit = 0
  /** The grid the last frame rendered against, which calibration taps are measured from. */
  private calibrationGrid: { reference: number; interval: number } | null = null
  private readonly tapCalibrator = new TapCalibrator()
  readonly diagnostics = { analyzedSamples: 0, droppedBuffers: 0, framesGenerated: 0, snapshotAge: 0, renderInterval: 0 }
  version = 0
  controlsVersion = 0
  private onFrame: ((frame: MusicLightingFrame) => void) | null = null

  readonly state: MusicSessionState = {
    beatMap: { status: 'none', progress: 0, tempo: null },
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

  subscribeControls(listener: Listener): () => void {
    this.controlsListeners.add(listener)
    return () => this.controlsListeners.delete(listener)
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
    const stopped = this.stop()
    const generation = this.generation
    await stopped
    if (generation !== this.generation) return
    this.captureSequence = 0
    this.inputSnapshot = emptySnapshot()
    this.clearPlaybackSnapshots()
    this.state.snapshot = emptySnapshot()
    this.state.error = null
    this.beatMap = null
    this.state.beatMap = { status: 'none', progress: 0, tempo: null }
    this.state.source = source
    this.state.running = true
    this.startedAt = performance.now() / 1000
    this.sequence = 0
    this.lastRenderAt = null
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
      this.emit()
    } catch (err) {
      if (generation !== this.generation) return
      await this.stop()
      this.state.running = false
      this.state.error = err instanceof Error ? err.message : String(err)
      this.emit()
    }
  }

  async stop(): Promise<void> {
    const generation = ++this.generation
    this.state.running = false
    this.inputSnapshot = emptySnapshot()
    this.clearPlaybackSnapshots()
    this.state.snapshot = emptySnapshot()
    this.beatMap = null
    this.state.beatMap = { status: 'none', progress: 0, tempo: null }
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
    this.midiTicks = 0; this.midiBeats = 0; this.midiLastBeat = null
    this.resetMidiTiming()
    if (audio) await audio.close().catch(() => undefined)
    if (generation !== this.generation) return
    this.state.running = false
    this.state.midiClock = false
    this.emit()
  }

  private emit(controlChange = true): void {
    this.version += 1
    for (const listener of this.listeners) listener()
    if (controlChange) {
      this.controlsVersion += 1
      for (const listener of this.controlsListeners) listener()
    }
  }

  private tick(): void {
    if (!this.state.running) return
    const timestamp = performance.now() / 1000
    this.promotePlaybackSnapshots(timestamp)
    this.diagnostics.renderInterval = this.lastRenderAt == null ? 0 : timestamp-this.lastRenderAt
    this.lastRenderAt = timestamp
    this.sequence += 1
    // A playing file with a finished map takes its grid from the map and the
    // playback clock; loudness and hits still come from live analysis.
    const position = this.state.source === 'file' && this.beatMap ? this.filePosition(timestamp) : null
    const live = position != null && this.beatMap
      ? applyBeatMap(this.inputSnapshot, this.beatMap, position, timestamp)
      : this.inputSnapshot
    if (this.state.source === 'demo') {
      const groove = GROOVES.find(g => g.id === this.state.grooveId) ?? GROOVES[0]
      this.state.snapshot = syntheticSnapshot(groove as Groove, this.startedAt, timestamp)
    } else {
      this.state.snapshot = freshSnapshot(live, timestamp)
    }
    // The display and engine each age the original snapshot once.
    const snapshot = this.state.source === 'demo' ? this.state.snapshot : {...live}
    const config = this.state.configuration
    if (config.metreOverride !== 'auto' && config.metreOverride !== snapshot.metre) {
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
      snapshot,
      this.state.configuration,
      this.state.topology,
      this.state.fixtures,
      timestamp,
      this.sequence,
    )
    this.calibrationGrid = snapshot.isTempoLocked && snapshot.beatInterval > 0 && snapshot.beatReferenceTime > 0
      ? { reference: snapshot.beatReferenceTime, interval: snapshot.beatInterval }
      : null
    this.state.frame = frame
    this.onFrame?.(frame)
    this.hasUnrenderedCapture = false
    this.emit(false)
  }

  private async ensureAudio(generation: number): Promise<AudioContext> {
    if (this.audio) return this.audio
    const audio = new AudioContext()
    const blob = new Blob([WORKLET], { type: 'text/javascript' })
    const url = URL.createObjectURL(blob)
    try { await audio.audioWorklet.addModule(url) }
    catch (error) { await audio.close().catch(()=>undefined); throw error }
    finally { URL.revokeObjectURL(url) }
    if (generation !== this.generation) { await audio.close(); throw new Error('Capture start cancelled') }
    this.audio = audio
    return audio
  }

  private connectTap(source: AudioNode, audio: AudioContext, monitor: boolean, generation: number): void {
    const node = new AudioWorkletNode(audio, 'lumen-tap', { outputChannelCount: [1] })
    node.port.onmessage = event => {
      if (generation !== this.generation || !this.state.running) return
      const pcm: CapturedPCM = event.data
      let end = performance.now()/1000 - (audio.currentTime-pcm.endTime)
      if (monitor && audio.getOutputTimestamp) {
        // Monitored files follow the samples at the speakers. This measured
        // clock pair includes output buffering; microphones retain capture time.
        const output = audio.getOutputTimestamp()
        if (output.contextTime != null && output.performanceTime != null &&
            Number.isFinite(output.contextTime) && Number.isFinite(output.performanceTime) &&
            output.contextTime >= 0 && output.performanceTime > 0) {
          end = output.performanceTime/1000 + pcm.endTime-output.contextTime
        }
      }
      try { this.consumePCM(pcm, end) }
      finally {
        const transfer = pcm.right ? [pcm.left.buffer, pcm.right.buffer] : [pcm.left.buffer]
        node.port.postMessage({ sequence: pcm.sequence, left: pcm.left, right: pcm.right }, transfer)
      }
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
    // A fixed start time is what the playback clock counts from.
    const when = audio.currentTime + 0.05
    source.start(when)
    this.fileStartContextTime = when
    this.fileDuration = buffer.duration
    this.bufferSource = source
    this.state.fileName = file.name
    this.prepareBeatMap(file, buffer, generation)
  }

  /** Taps recorded since the last reset. */
  get calibrationTapCount(): number { return this.tapCalibrator.count }

  /** Whether the show has a beat grid to time taps against. */
  get canCalibrate(): boolean { return this.state.running && this.calibrationGrid != null }

  /** Records one tap, made when the person saw the lights pulse, on the render clock. */
  recordCalibrationTap(): void {
    const grid = this.calibrationGrid
    if (!grid) return
    this.tapCalibrator.tap(performance.now() / 1000, grid.reference, grid.interval)
    this.emit()
  }

  resetCalibrationTaps(): void {
    this.tapCalibrator.reset()
    this.emit()
  }

  /** The light timing offset the taps call for, or null until there are enough consistent taps. */
  calibratedLatencyOffset(): number | null {
    return this.tapCalibrator.suggestedOffset(this.state.configuration.outputLatencyOffset ?? 0)
  }

  /** Builds (or reuses) the file's beat map while the live show is already playing. */
  private prepareBeatMap(file: File, buffer: AudioBuffer, generation: number): void {
    const key = `${file.name}:${file.size}:${file.lastModified}`
    if (this.beatMapCache.has(key)) {
      this.useBeatMap(this.beatMapCache.get(key) ?? null)
      return
    }
    this.state.beatMap = { status: 'analyzing', progress: 0, tempo: null }
    this.emit()
    void analyzeAudioBuffer(buffer, progress => {
      if (generation !== this.generation) return
      this.state.beatMap = { ...this.state.beatMap, progress }
      const now = performance.now()
      if (now - this.lastProgressEmit > 150) { this.lastProgressEmit = now; this.emit() }
    }, () => generation === this.generation).then(map => {
      if (generation !== this.generation) return
      this.beatMapCache.set(key, map)
      this.useBeatMap(map)
    }, () => {
      if (generation !== this.generation) return
      this.useBeatMap(null)
    })
  }

  private useBeatMap(map: BeatMap | null): void {
    this.beatMap = map && map.confidence >= 0.08 ? map : null
    this.state.beatMap = this.beatMap
      ? { status: 'ready', progress: 1, tempo: this.beatMap.tempo }
      : { status: 'unavailable', progress: 1, tempo: null }
    this.emit()
  }

  /** Track position audible at `timestamp` (performance seconds), from the output clock. */
  private filePosition(timestamp: number): number | null {
    const audio = this.audio
    if (!audio || !(this.fileDuration > 0)) return null
    let contextTime = audio.currentTime
    const output = audio.getOutputTimestamp?.()
    if (output && output.contextTime != null && output.performanceTime != null &&
        Number.isFinite(output.contextTime) && Number.isFinite(output.performanceTime) && output.performanceTime > 0) {
      contextTime = output.contextTime + (timestamp - output.performanceTime / 1000)
    }
    const elapsed = contextTime - this.fileStartContextTime
    if (elapsed < 0) return null
    return elapsed % this.fileDuration
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
  private consumePCM(pcm: Omit<CapturedPCM, 'endTime'>, end: number): void {
    if (pcm.sequence <= this.captureSequence) return
    if (this.captureSequence && pcm.sequence !== this.captureSequence+1) {
      this.analyzer.reset()
      this.clearPlaybackSnapshots()
      this.inputSnapshot = emptySnapshot()
    }
    this.captureSequence = pcm.sequence
    const stereo = pcm.channels !== 1 && pcm.right ? pcm as typeof pcm & {right:Float32Array} : undefined
    const analyzed = this.analyzer.analyze(pcm.left,end,stereo,pcm.sampleRate)
    this.diagnostics.analyzedSamples += pcm.left.length
    this.diagnostics.droppedBuffers = pcm.dropped
    if (analyzed) {
      analyzed.analysisCompletedAt = performance.now()/1000
      analyzed.droppedBuffers = pcm.dropped
      if (this.state.source === 'file') {
        // Output may be buffered ahead of the speakers. Keep bounded snapshots
        // until their samples are audible instead of firing future transients.
        if (this.playbackCount === this.playbackSnapshots.length) {
          this.playbackRead = (this.playbackRead+1)%this.playbackSnapshots.length
          this.playbackCount--
        }
        this.playbackSnapshots[(this.playbackRead+this.playbackCount)%this.playbackSnapshots.length] = analyzed
        this.playbackCount++
      } else this.acceptCaptureSnapshot(analyzed)
    }
  }

  private promotePlaybackSnapshots(timestamp: number): void {
    while (this.playbackCount) {
      const snapshot = this.playbackSnapshots[this.playbackRead]!
      if (snapshot.analysisTimestamp != null && snapshot.analysisTimestamp > timestamp) break
      this.acceptCaptureSnapshot(snapshot)
      this.playbackSnapshots[this.playbackRead] = undefined
      this.playbackRead = (this.playbackRead+1)%this.playbackSnapshots.length
      this.playbackCount--
    }
  }

  private clearPlaybackSnapshots(): void {
    this.playbackSnapshots.fill(undefined)
    this.playbackRead = 0
    this.playbackCount = 0
    this.hasUnrenderedCapture = false
  }

  private acceptCaptureSnapshot(snapshot: ReturnType<typeof emptySnapshot>): void {
    this.inputSnapshot = retainUnrenderedTransients(snapshot,
      this.hasUnrenderedCapture ? this.inputSnapshot : undefined)
    this.hasUnrenderedCapture = true
  }

  private handleMidi(event: MIDIMessageEvent): void {
    const now = event.timeStamp/1000
    if (!Number.isFinite(now)) return
    for (const byte of event.data ?? []) {
      if (byte === 0xfc) { this.midiStopped = true; this.resetMidiTiming(); this.inputSnapshot = emptySnapshot(); continue }
      if (byte === 0xfa) {
        this.midiTicks=0;this.midiBeats=0;this.midiLastBeat=null;this.resetMidiTiming();this.midiStopped=false
        this.inputSnapshot = emptySnapshot();continue
      }
      if (byte === 0xfb) { this.midiStopped=false;this.resetMidiTiming();continue }
      if (byte !== 0xf8 || this.midiStopped) continue
      if (this.midiLastTick != null && now < this.midiLastTick) continue
      // A stopped clock cannot lend its old tempo to a resumed stream.
      if (this.midiLastTick != null && now-this.midiLastTick > Math.max(.25,(this.inputSnapshot.beatInterval || 1.2)*1.5)) {
        this.resetMidiTiming()
        this.midiLastBeat = null
      }
      this.midiLastTick = now
      this.midiTickTimes[this.midiTimingWrite] = now
      this.midiTimingWrite = (this.midiTimingWrite+1)%this.midiTickTimes.length
      this.midiTimingCount = Math.min(this.midiTickTimes.length,this.midiTimingCount+1)
      const isBeat = this.midiTicks++ % 24 === 0
      if (isBeat) { this.midiBeats++; this.midiLastBeat=now }
      // Measure a quarter note (24 clocks), rather than amplifying one tick's
      // scheduling jitter by 24. Wait for a measured beat before claiming lock.
      const oldest = (this.midiTimingWrite-this.midiTimingCount+this.midiTickTimes.length)%this.midiTickTimes.length
      const span = now-this.midiTickTimes[oldest]
      const interval = this.midiTimingCount === this.midiTickTimes.length && span >= .15 && span <= 1.2 ? span : 0
      const reference = this.midiLastBeat ?? (interval > 0 ? now-((this.midiTicks-1)%24)*interval/24 : now)
      // A clock tick refines timing; only a quarter note is a musical hit.
      // Keeping the beat's capture timestamp lets every intervening render
      // see its real decay instead of refreshing the pulse 24 times per beat.
      if (isBeat) {
        const beatInBar = (this.midiBeats-1)%4
        this.inputSnapshot = {...this.inputSnapshot,level:.55,energy:.62,confidence:1,
          beat:1,pulse:1,kick:beatInBar===0?1:.35,
          snare:beatInBar===1||beatInBar===3?.9:.1,percussion:.4,
          bass:.6,mids:.45,highs:.35,beatCount:this.midiBeats-1,
          gridBeatPosition:this.midiBeats-1,beatInBar,metreConfidence:1,
          analysisTimestamp:now,sourceDescription:'MIDI clock'}
      }
      const snapshot = this.inputSnapshot
      snapshot.beatReferenceTime = reference
      snapshot.beatInterval = snapshot.feltInterval = interval
      snapshot.tempo = snapshot.feltTempo = interval > 0 ? 60/interval : 0
      snapshot.beatCount = snapshot.gridBeatPosition = this.midiBeats-1
      snapshot.beatInBar = (this.midiBeats-1)%4
      snapshot.beatConfidence = interval > 0 ? 1 : 0
      snapshot.isTempoLocked = interval > 0
      snapshot.freshnessGrace = Math.max(.25, interval*1.5)
    }
  }

  private resetMidiTiming(): void {
    this.midiLastTick = null
    this.midiTimingWrite = 0
    this.midiTimingCount = 0
  }

}

export function deviceToFixture(device: BridgeDevice): MusicFixtureDescriptor {
  const transport: MusicTransportKind = device.brand === 'lifx' ? 'lifxLAN' : device.brand === 'nanoleaf' ? 'nanoleafLAN' : 'goveeLAN'
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
