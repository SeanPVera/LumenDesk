// npm run bench:music [-- /absolute/path/to/baseline/analyzer.js]
// Compares the complete production analyzer on the same captured-style PCM.
// Results are processing time on this machine, not total browser/app CPU.
import { performance } from 'node:perf_hooks'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const current = await import('../.test-build/analyzer.js')
const variants = [{name:'current',Analyzer:current.MusicFeatureAnalyzer}]
if(process.argv[2]) {
  const baseline = await import(pathToFileURL(resolve(process.argv[2])).href)
  variants.unshift({name:'baseline',Analyzer:baseline.MusicFeatureAnalyzer})
}

const rate=48000,chunk=1024,seconds=20,buffers=[]
for(let offset=0;offset<rate*seconds;offset+=chunk) {
  const length=Math.min(chunk,rate*seconds-offset)
  const left=new Float32Array(length),right=new Float32Array(length)
  for(let i=0;i<length;i++) {
    const t=(offset+i)/rate,phase=t%.5
    left[i]=.7*Math.sin(2*Math.PI*65*t)*Math.exp(-phase/.045)*(1-Math.exp(-phase/.002))
      +.18*Math.sin(2*Math.PI*8000*t)*Math.exp(-(t%.125)/.012)
    right[i]=-.65*left[i]+.1*Math.sin(2*Math.PI*440*t)
  }
  buffers.push({left,right,end:100+(offset+length)/rate})
}

const silence=buffers.map(buffer=>({left:new Float32Array(buffer.left.length),right:new Float32Array(buffer.left.length),end:buffer.end}))
const scenarios=[
  {name:'stereo-drums',channels:2,buffers},
  {name:'mono-drums',channels:1,buffers},
  {name:'stereo-silence',channels:2,buffers:silence},
].map(scenario=>({...scenario,results:variants.map(variant=>({...variant,times:[],cpuTimes:[]}))}))

function analyzeScenario(Analyzer,scenario) {
  const analyzer=new Analyzer('Benchmark'),cpuStart=process.cpuUsage(),start=performance.now()
  for(const buffer of scenario.buffers) analyzer.analyze(buffer.left,buffer.end,scenario.channels===2?buffer:undefined,rate)
  const elapsed=performance.now()-start,cpu=process.cpuUsage(cpuStart)
  return {elapsed,cpuMs:(cpu.user+cpu.system)/1000,snapshot:analyzer.latest()}
}

// Warm every channel/silence path at the same callsite before collecting any
// timings. Interleave both scenarios and implementations so JIT transitions
// and changes in machine load cannot systematically favour the first case.
for(let run=0;run<10;run++) {
  const scenarioOrder=run%2?[...scenarios].reverse():scenarios
  for(const scenario of scenarioOrder) {
    const order=run%2?[...scenario.results].reverse():scenario.results
    for(const variant of order) {
      const {elapsed,cpuMs,snapshot}=analyzeScenario(variant.Analyzer,scenario)
      if(run>=3) { variant.times.push(elapsed); variant.cpuTimes.push(cpuMs) }
      variant.snapshot=snapshot
    }
  }
}

for(const scenario of scenarios) {
  const results=scenario.results
  for(const variant of results) {
    variant.times.sort((a,b)=>a-b)
    variant.cpuTimes.sort((a,b)=>a-b)
    variant.median=variant.times[Math.floor(variant.times.length/2)]
    variant.medianCpu=variant.cpuTimes[Math.floor(variant.cpuTimes.length/2)]
    console.log(JSON.stringify({metric:'music-analyzer-time',scenario:scenario.name,implementation:variant.name,
      audioSeconds:seconds,sampleRate:rate,channels:scenario.channels,chunkSamples:chunk,
      medianMs:variant.median,msPerAudioSecond:variant.median/seconds,
      medianCpuMs:variant.medianCpu,cpuMsPerAudioSecond:variant.medianCpu/seconds,
      tempo:variant.snapshot.tempo,analyzedSamples:variant.snapshot.analyzedSamples}))
  }
  if(results.length===2) {
    const [before,after]=results
    console.log(JSON.stringify({metric:'music-analyzer-time-change',scenario:scenario.name,
      percent:(after.median/before.median-1)*100,cpuPercent:(after.medianCpu/before.medianCpu-1)*100}))
  }
}
