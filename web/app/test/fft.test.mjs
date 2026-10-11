import { test } from 'node:test'
import assert from 'node:assert/strict'
import { RealFFT, hannWindow } from '../.test-build/fft.js'

// Independent direct DFT reference checks the packing identity and normalization.
function referenceMagnitudes(input, size) {
  return Float64Array.from({length:size/2},(_,bin)=>{
    let real=0, imag=0
    for(let i=0;i<size;i++) {
      const angle=-2*Math.PI*bin*i/size, sample=input[i]??0
      real+=sample*Math.cos(angle); imag+=sample*Math.sin(angle)
    }
    return Math.hypot(real,imag)*(bin===0?1:2)/size
  })
}
function assertClose(actual, expected, message='') {
  assert.equal(actual.length,expected.length)
  for(let i=0;i<actual.length;i++) {
    assert.ok(Math.abs(actual[i]-expected[i])<2e-12,`${message} bin ${i}: ${actual[i]} vs ${expected[i]}`)
  }
}
function referenceStereo(left,right,size) {
  const a=referenceMagnitudes(left,size), b=referenceMagnitudes(right,size)
  return a.map((value,i)=>Math.sqrt((value*value+b[i]*b[i])/2))
}

test('mono and packed stereo FFT match direct DFT for asymmetric multitone signals',()=>{
  for(const size of [2,4,8,32,128]) {
    const window=hannWindow(size)
    const left=Float64Array.from({length:size},(_,i)=>window[i]*(.27+Math.sin(2*Math.PI*3*i/size)+.21*Math.cos(2*Math.PI*7*i/size+.35)))
    const right=Float64Array.from({length:size},(_,i)=>window[i]*(-.11+.42*Math.sin(2*Math.PI*5*i/size+.73)+.17*Math.cos(2*Math.PI*3*i/size)))
    const fft=new RealFFT(size), output=new Float64Array(size/2)
    fft.stereoMagnitudes(left,right,output)
    assertClose(output,referenceStereo(left,right,size),`stereo size ${size}`)
    // Reuse the same transform after stereo to expose stale imaginary state.
    fft.magnitudes(left,output)
    assertClose(output,referenceMagnitudes(left,size),`mono size ${size}`)
    fft.stereoMagnitudes(right,left,output)
    assertClose(output,referenceStereo(right,left,size),`swapped size ${size}`)
  }
})

test('packed stereo preserves opposite phase and scales hard-panned channel energy',()=>{
  const size=256, signal=Float64Array.from({length:size},(_,i)=>Math.sin(2*Math.PI*11*i/size)), silence=new Float64Array(size)
  const fft=new RealFFT(size), output=new Float64Array(size/2), expected=referenceMagnitudes(signal,size)
  for(const [left,right,factor] of [[signal,signal,1],[signal,signal.map(v=>-v),1],[signal,silence,Math.SQRT1_2],[silence,signal,Math.SQRT1_2]]) {
    fft.stereoMagnitudes(left,right,output)
    assertClose(output,expected.map(value=>value*factor))
    assert.ok(Math.abs(output[11]-factor)<2e-12)
  }
})

test('packed stereo uses DC normalization and accepts full-scale channel samples',()=>{
  const size=64, fft=new RealFFT(size), output=new Float64Array(size/2)
  for(const [a,b] of [[1,1],[1,-1],[1,0],[0,-1],[.25,-.75],[0,0]]) {
    const left=new Float64Array(size).fill(a), right=new Float64Array(size).fill(b)
    fft.stereoMagnitudes(left,right,output)
    assert.ok(Math.abs(output[0]-Math.sqrt((a*a+b*b)/2))<2e-12)
    assert.ok(output.slice(1).every(value=>value<2e-12))
  }
  const alternating=Float64Array.from({length:size},(_,i)=>i%2?-1:1)
  fft.stereoMagnitudes(alternating,alternating.map(v=>-v),output)
  // The API intentionally excludes the Nyquist bin.
  assert.ok(output.every(value=>value<2e-12))
})

test('packed stereo zero-pads short inputs independently across reused calls',()=>{
  const size=32, fft=new RealFFT(size), output=new Float64Array(size/2)
  fft.stereoMagnitudes(new Float64Array(size).fill(1),new Float64Array(size).fill(-1),output)
  const left=[1,-.2,.5],right=[.1]
  fft.stereoMagnitudes(left,right,output)
  assertClose(output,referenceStereo(left,right,size))
  fft.stereoMagnitudes([],[],output)
  assert.ok(output.every(value=>value===0))
})

test('half-size mono transform preserves all bins and zero-padding after stereo reuse',()=>{
  for (const size of [2,4,8,16,64,256]) {
    const fft = new RealFFT(size), output = new Float64Array(size / 2)
    let seed = 0x76543210
    const noise = Float64Array.from({length:size},()=>{
      seed = (Math.imul(seed,1664525)+1013904223)>>>0
      return seed / 0x80000000 - 1
    })
    const cases = [noise,[-.3,.7,.11],new Float64Array(size).fill(-.4),
      Float64Array.from({length:size},(_,i)=>i%2?-1:1),[]]
    for (const input of cases) {
      fft.stereoMagnitudes(noise,noise.map(value=>-value),output)
      fft.magnitudes(input,output)
      assertClose(output,referenceMagnitudes(input,size),`mono size ${size}`)
    }
  }
})
