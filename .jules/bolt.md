## 2026-03-31 - Hoisting Trig Lookups in Radix-2 Real FFT Butterfly Loop
**Learning:** In JS/TS DSP routines like RealFFT, loop-interchanging the butterfly loops ($k$ indices vs $i$ block offsets) allows hoisting trigonometric array lookups (`cos[index]`, `sin[index]`) out of the innermost loop. This reduces array access overhead and improves CPU cache efficiency in JS runtimes without changing floating-point accuracy.
**Action:** When working with FFT or spectral audio processing loops, ensure inner loops process contiguous memory blocks and hoist constant angle/twiddle factor calculations.

## 2026-04-01 - Eliminating Ring Buffer Modulo Operations in Real-Time Audio Loops
**Learning:** In high-frequency JS/TS audio processing loops (e.g. 48kHz sample loops or 2048-sample windowing routines), calculating array indices with modulo `% WINDOW` prevents V8 from optimizing array access strides. Splitting ring buffer reads into two contiguous un-modded loops (`0 .. WINDOW - r` and `0 .. r`) and replacing per-sample `% WINDOW` with `if (++ringWrite === WINDOW) ringWrite = 0;` eliminates hundreds of thousands of modulo calculations per second and improves DSP pipeline throughput.
**Action:** When traversing ring buffers or windowing audio frames in JS, split the traversal into two linear contiguous bounds loops instead of modulo-indexing on every iteration.
