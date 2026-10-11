// node --import ./test/register.mjs ./test/bench-choreography.mjs [baseline/choreography.js]
// Measures frame mapping, not whole-app CPU or physical light response.
import assert from 'node:assert/strict'
import { performance } from 'node:perf_hooks'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { MusicChoreographyEngine } from '../.test-build/choreography.js'
import { configurationFor } from '../.test-build/config.js'
import { emptySnapshot } from '../.test-build/types.js'

const variants=[{name:'current',Engine:MusicChoreographyEngine,times:[]}]
if(process.argv[2]) {
  const baseline=await import(pathToFileURL(resolve(process.argv[2])).href)
  variants.unshift({name:'baseline',Engine:baseline.MusicChoreographyEngine,times:[]})
}
const frames=2400,fps=20
// No freshness timestamp here: the CPU comparison isolates choreography from
// any separate changes to decay of captured transients between render ticks.
const snapshots=Array.from({length:frames},(_,i)=>{
  const beatCount=Math.floor(i/(fps*.5))
  return {...emptySnapshot(),level:.5+.3*Math.sin(i/40),energy:.7,bass:.4,
    kick:i%10===0?1:0,snare:i%20===10?.8:0,beat:i%10===0?1:0,pulse:.3,
    confidence:1,beatConfidence:.8,beatInterval:.5,feltInterval:.5,
    isTempoLocked:true,beatReferenceTime:100+beatCount*.5,beatCount,
    gridBeatPosition:beatCount,beatInBar:beatCount%4}
})
const scenarios=[0,20,100,500].map(segments=>{
  const fixtures=segments?
    [{id:'strip',label:'Strip',transport:'goveeRealtimeSegments',segmentCount:segments,role:'motion'}]:
    Array.from({length:8},(_,i)=>({id:`bulb${i}`,label:`Bulb ${i}`,transport:'lifxLAN',segmentCount:0,role:['wash','hit','accent','motion'][i%4]}))
  return {
    targets:segments||8,
    fixtures,
    topology:{layout:'leftToRight',fixtureOrder:fixtures.map(f=>f.id),excludedFixtureIDs:[]},
    configuration:configurationFor('concert'),
  }
})

if(variants.length===2) {
  for(const scenario of scenarios) {
    const [before,after]=variants.map(variant=>new variant.Engine())
    for(let i=0;i<frames;i++) assert.deepStrictEqual(
      after.makeFrame(snapshots[i],scenario.configuration,scenario.topology,scenario.fixtures,100+i/fps,i),
      before.makeFrame(snapshots[i],scenario.configuration,scenario.topology,scenario.fixtures,100+i/fps,i))
  }
}

// Use the same call site for warmup and measurement. Exercise every topology
// and role before timing any scenario: warming only the first room allowed
// later input shapes to trigger JIT changes and biased the first result.
function renderScenario(variant,scenario) {
  const engine=new variant.Engine(),start=performance.now()
  for(let i=0;i<frames;i++) engine.makeFrame(
    snapshots[i],scenario.configuration,scenario.topology,scenario.fixtures,100+i/fps,i)
  return performance.now()-start
}
for(let round=0;round<4;round++) {
  const order=round%2?[...scenarios].reverse():scenarios
  for(const scenario of order) {
    for(const variant of round%2?[...variants].reverse():variants) renderScenario(variant,scenario)
  }
}

for(const scenario of scenarios) {
  for(const variant of variants) variant.times=[]
  // Retain local warmup and alternate implementation order for each sample.
  for(let round=0;round<12;round++) {
    for(const variant of round%2?[...variants].reverse():variants) {
      const elapsed=renderScenario(variant,scenario)
      if(round>=3) variant.times.push(elapsed)
    }
  }
  const results=variants.map(variant=>({name:variant.name,
    medianMs:variant.times.sort((a,b)=>a-b)[Math.floor(variant.times.length/2)]}))
  console.log(JSON.stringify({metric:'music-choreography-time',targets:scenario.targets,frames,fps,
    results,...(results.length===2?{reductionPercent:(1-results[1].medianMs/results[0].medianMs)*100}: {})}))
}
