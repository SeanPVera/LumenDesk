import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MusicChoreographyEngine } from '../.test-build/choreography.js'
import { configurationFor } from '../.test-build/config.js'
import { emptySnapshot } from '../.test-build/types.js'
import { MusicFeatureAnalyzer } from '../.test-build/analyzer.js'
import { WebMusicSession, frameToCommands } from '../.test-build/session.js'
const fixtures = [{id:'a',label:'A',transport:'lifxLAN',segmentCount:0,role:'accent'}]
const topology = {layout:'leftToRight',fixtureOrder:['a'],excludedFixtureIDs:[]}
function snapshot(t) { return {...emptySnapshot(), level:.7,energy:.6,confidence:1,
  isTempoLocked:true,tempo:120,beatInterval:.5,feltInterval:.5,beatConfidence:1,
  beatReferenceTime:100+Math.floor((t-100)/.5)*.5,beatCount:Math.floor((t-100)/.5)} }
function frames(config) {
  const engine = new MusicChoreographyEngine()
  return Array.from({length:240},(_,i)=>engine.makeFrame(snapshot(100+i*.05), config, topology, fixtures,100+i*.05,i).states[0])
}
test('master zero is black even with floor and flashes',()=>{
  const config={...configurationFor('soundcheck'),masterBrightness:0,minimumBrightness:.4,photosensitivitySafeMode:false}
  assert.ok(frames(config).every(s=>s.brightness===0))
})
test('live ceiling takes effect immediately, including explicit flashes',()=>{
  const engine=new MusicChoreographyEngine(), config=configurationFor('concert')
  for(let i=0;i<30;i++) engine.makeFrame(snapshot(100+i*.05),config,topology,fixtures,100+i*.05,i)
  Object.assign(config,{masterBrightness:.5,maximumBrightness:.2,photosensitivitySafeMode:false})
  const s={...snapshot(102),snare:1,percussion:1}
  assert.ok(engine.makeFrame(s,config,topology,fixtures,102,31).states[0].brightness<=.1+1e-9)
})
test('one-color palette is preserved by every role',()=>{
  for(const role of ['wash','hit','accent','motion']){
    const engine=new MusicChoreographyEngine(), config={...configurationFor('soundcheck'),palette:[{hex:0xff0000}]}
    for(let i=0;i<40;i++){
      const s={...snapshot(100+i*.05),mood:1,chroma:[0,0,0,0,0,0,1,0,0,0,0,0]}
      const out=engine.makeFrame(s,config,topology,[{...fixtures[0],role}],100+i*.05,i).states[0]
      assert.ok(Math.min(out.hue,1-out.hue)<1e-9)
    }
  }
})
test('zero color change holds color across bars',()=>{
  const values=frames({...configurationFor('soundcheck'),colorChangeIntensity:0}).map(s=>s.hue)
  assert.ok(Math.max(...values)-Math.min(...values)<1e-9)
})
test('web frame commands carry independent brightness and transition',()=>{
  const command=frameToCommands({states:[{fixtureID:'a',hue:0,saturation:1,brightness:.2,transitionDuration:.09}],timestamp:0,sequenceNumber:1})[0]
  assert.equal(command.brightness,.2)
  assert.deepEqual(command.rgb,{r:255,g:0,b:0})
  assert.equal(command.transitionDuration,.09)
})
test('renderer ticks never analyze the same PCM again',()=>{
  const session=new WebMusicSession()
  session.state.running=true;session.state.source='microphone'
  let calls=0
  session.analyzer.analyze=()=>{calls++;return emptySnapshot()}
  session.latestPcm={left:new Float32Array(128),right:new Float32Array(128),sampleRate:48000}
  session.tick();session.tick()
  assert.equal(calls,0,'PCM must be consumed by capture, never by the render clock')
})

function pcmRun({rate=48000,chunk=1024,seconds=14,amplitude=.7,hats=true,pad=false}={}) {
  const analyzer=new MusicFeatureAnalyzer('Synthetic PCM'), engine=new MusicChoreographyEngine()
  const config=configurationFor('soundcheck'), result=[]
  let renderAt=100
  for(let offset=0;offset<seconds*rate;offset+=chunk) {
    const count=Math.min(chunk,seconds*rate-offset)
    const pcm=Float32Array.from({length:count},(_,i)=>{
      const t=(offset+i)/rate, phase=t%.5, h=t%.125
      // Continuous phase / time, never restart a tone at a buffer boundary.
      return pad ? amplitude*(Math.sin(2*Math.PI*220*t)+.6*Math.sin(2*Math.PI*277.18*t)+.4*Math.sin(2*Math.PI*329.63*t))/2
        : amplitude*Math.sin(2*Math.PI*65*t)*Math.exp(-phase/.045)*(1-Math.exp(-phase/.002))
          +(hats?.18:0)*Math.sin(2*Math.PI*8000*t)*Math.exp(-h/.012)*(1-Math.exp(-h/.0005))
    })
    const end=100+(offset+count)/rate
    const s=analyzer.analyze(pcm,end,undefined,rate)
    if(s && end>=renderAt) {
      const frame=engine.makeFrame(s,config,topology,[{...fixtures[0],role:'wash'}],end,result.length)
      result.push({t:end-100,s,frame});renderAt+=.05
    }
  }
  return result
}
test('PCM kick with sixteenths follows 120 BPM across buffer sizes and rates',()=>{
  for(const [rate,chunk] of [[48000,128],[48000,1024],[44100,512],[44100,2048]]) {
    const rows=pcmRun({rate,chunk}), locked=rows.filter(r=>r.t>8&&r.s.isTempoLocked)
    assert.ok(locked.length>60,`${rate}/${chunk}: no useful lock`)
    const correct=locked.filter(r=>Math.abs(r.s.tempo-120)<6).length/locked.length
    assert.ok(correct>.9,`${rate}/${chunk}: ${(correct*100).toFixed(1)}% correct tempo`)
    assert.ok(rows.every(r=>!r.frame.flashApplied))
    console.log(JSON.stringify({metric:'web-production-pcm',rate,chunk,correct,lastTempo:rows.at(-1).s.tempo}))
  }
})
test('sustained PCM chord does not fabricate a grid',()=>{
  const rows=pcmRun({pad:true,seconds:20})
  assert.equal(rows.filter(r=>r.t>4&&r.s.isTempoLocked).length,0)
})
test('quiet and loud PCM retain useful distinct output levels',()=>{
  const quiet=pcmRun({amplitude:.04,hats:false,seconds:10}).filter(r=>r.t>5)
  const loud=pcmRun({amplitude:.8,hats:false,seconds:10}).filter(r=>r.t>5)
  const mean=rows=>rows.reduce((n,r)=>n+r.frame.states[0].brightness,0)/rows.length
  assert.ok(mean(quiet)>.04)
  assert.ok(mean(loud)-mean(quiet)>.08,`quiet ${mean(quiet)} loud ${mean(loud)}`)
  console.log(JSON.stringify({metric:'web-production-dynamics',quiet:mean(quiet),loud:mean(loud)}))
})
test('stale input decays and duplicate sample timestamps are rejected',()=>{
  const analyzer=new MusicFeatureAnalyzer('Test'), pcm=new Float32Array(1024).fill(.2)
  assert.ok(analyzer.analyze(pcm,100))
  assert.equal(analyzer.analyze(pcm,100),null)
  const engine=new MusicChoreographyEngine(),config={...configurationFor('soundcheck'),silenceBehavior:'fadeOut'}
  const stale={...snapshot(100),analysisTimestamp:100}
  let frame
  for(let i=0;i<160;i++) frame=engine.makeFrame(stale,config,topology,fixtures,100+i*.05,i)
  assert.ok(frame.states[0].brightness<.001)
})
test('capture consumes all samples, stereo and one buffer per callback',()=>{
  const session=new WebMusicSession()
  session.state.running=true;session.state.source='microphone'
  for(let i=0;i<48;i++) session.consumePCM({left:new Float32Array(1000),right:new Float32Array(1000),sampleRate:48000,sequence:i+1,dropped:0},100+(i+1)/48)
  assert.equal(session.diagnostics.analyzedSamples,48000)
  const count=session.diagnostics.analyzedSamples
  session.tick();session.tick()
  assert.equal(session.diagnostics.analyzedSamples,count)
})

test('latest-frame sender bounds congestion and drains before restore',async()=>{
  const {LatestMusicFrameSender}=await import('../.test-build/session.js')
  let now=100,finish
  const sent=[]
  const sender=new LatestMusicFrameSender(states=>{sent.push(states);return new Promise(r=>{finish=r})},()=>now)
  const frame=n=>({states:[{fixtureID:'a',hue:0,saturation:1,brightness:n/10,transitionDuration:.09}],timestamp:now,sequenceNumber:n})
  sender.start();sender.enqueue(frame(1))
  sender.enqueue(frame(2));sender.enqueue(frame(3))
  assert.equal(sent.length,1)
  assert.equal(sender.diagnostics.coalesced,1)
  let stopped=false
  const stop=sender.stop().then(()=>{stopped=true})
  await Promise.resolve();assert.equal(stopped,false)
  finish();await stop
  now=101;sender.enqueue(frame(4));assert.equal(sent.length,1)
  sender.start();sender.enqueue({...frame(5),timestamp:99})
  assert.equal(sender.diagnostics.expired,1)
})
test('MIDI uses measured tempo, Stop suppresses ticks, Continue keeps position',()=>{
  const session=new WebMusicSession()
  const midi=(b,t)=>session.handleMidi({data:new Uint8Array([b]),timeStamp:t*1000})
  midi(0xfa,100)
  for(let i=0;i<97;i++)midi(0xf8,100+i*(60/90)/24)
  assert.ok(Math.abs(session.inputSnapshot.tempo-90)<.01)
  const position=session.inputSnapshot.beatCount
  midi(0xfc,103);midi(0xf8,103.1)
  assert.equal(session.inputSnapshot.isTempoLocked,false)
  midi(0xfb,103.2);midi(0xf8,103.3)
  assert.ok(session.inputSnapshot.beatCount>=position)
})
test('format change resets sample clock and stereo survives analysis',()=>{
  const analyzer=new MusicFeatureAnalyzer('Stereo')
  const left=Float32Array.from({length:2048},(_,i)=>.1*Math.sin(2*Math.PI*440*i/48000)),right=new Float32Array(2048)
  const first=analyzer.analyze(left,100,{left,right},48000)
  assert.equal(first.stereo,0)
  const next=analyzer.analyze(left,100+2048/44100,{left,right},44100)
  assert.equal(next.analyzedSamples,2048)
  assert.ok(Math.abs(next.analysisTimestamp-(100+2048/44100))<.001)
})

test('tempo reacquisition never teleports palette position',()=>{
  const engine=new MusicChoreographyEngine(),config=configurationFor('soundcheck')
  let previous
  for(let i=0;i<100;i++) previous=engine.makeFrame({...emptySnapshot(),level:.4,energy:.4,confidence:.8},config,topology,fixtures,100+i*.05,i).states[0]
  const locked={...snapshot(105),beatCount:99,gridBeatPosition:99,beatReferenceTime:105}
  const next=engine.makeFrame(locked,config,topology,fixtures,105,100).states[0]
  const delta=Math.abs(next.hue-previous.hue)
  assert.ok(Math.min(delta,1-delta)<.005)
})
test('accents retain headroom rather than clipping every strong beat',()=>{
  const values=frames({...configurationFor('concert'),minimumBrightness:0,maximumBrightness:1,masterBrightness:1,movementAmount:0})
  assert.ok(values.every(s=>s.brightness<1))
  assert.ok(Math.max(...values.map(s=>s.brightness))>.5)
})

test('immediate Stop wins over a pending Start', async()=>{
  globalThis.window=globalThis
  const session=new WebMusicSession()
  const start=session.start('demo')
  await session.stop();await start
  assert.equal(session.state.running,false)
  assert.equal(session.timer,null)
})
test('zero beat response removes rhythmic accents; two-bulb movement has distinct positions',()=>{
  const config={...configurationFor('soundcheck'),beatSensitivity:0,bassSensitivity:0,movementAmount:0,colorChangeIntensity:0,phraseAware:false}
  const steady=frames(config).slice(160).map(s=>s.brightness)
  assert.ok(Math.max(...steady)-Math.min(...steady)<.001)
  const moving={...config,movementAmount:1,movementSpeed:.5}
  const pair=[{...fixtures[0],role:'motion'},{...fixtures[0],id:'b',role:'motion'}]
  const layout={...topology,fixtureOrder:['a','b']}
  const engine=new MusicChoreographyEngine()
  const out=engine.makeFrame(snapshot(100),moving,layout,pair,100,1)
  assert.ok(Math.abs(out.states[0].brightness-out.states[1].brightness)>.01)
})

// Phase is integrated per sample; changing tempo never restarts the oscillator
// at a buffer seam. Windows straddle boundaries just as they do in capture.
test('PCM tracker follows gradual drift and reacquires a changed tempo',()=>{
  for(const mode of ['drift','step']) {
    const analyzer=new MusicFeatureAnalyzer(mode),rate=48000;let phase=0,locked=0,correct=0
    for(let offset=0;offset<rate*40;offset+=1024){
      const pcm=Float32Array.from({length:1024},(_,i)=>{
        const t=(offset+i)/rate,bpm=mode==='drift'?110+.5*t:t<18?108:132
        phase+=bpm/60/rate
        const b=phase%1,h=(phase*4)%1
        return .7*Math.sin(2*Math.PI*65*t)*Math.exp(-b/.09)*(1-Math.exp(-b/.004))
          +.12*Math.sin(2*Math.PI*8000*t)*Math.exp(-h/.096)*(1-Math.exp(-h/.004))
      })
      const t=(offset+1024)/rate,s=analyzer.analyze(pcm,100+t,undefined,rate)
      if(t>32&&s?.isTempoLocked){locked++;if(Math.abs(s.tempo-(mode==='drift'?110+.5*t:132))<6)correct++}
    }
    assert.ok(locked>250)
    assert.ok(correct/locked>.9,`${mode}: ${correct}/${locked}`)
  }
})
