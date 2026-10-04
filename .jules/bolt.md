## 2026-03-31 - Hoisting Trig Lookups in Radix-2 Real FFT Butterfly Loop
**Learning:** In JS/TS DSP routines like RealFFT, loop-interchanging the butterfly loops ($k$ indices vs $i$ block offsets) allows hoisting trigonometric array lookups (`cos[index]`, `sin[index]`) out of the innermost loop. This reduces array access overhead and improves CPU cache efficiency in JS runtimes without changing floating-point accuracy.
**Action:** When working with FFT or spectral audio processing loops, ensure inner loops process contiguous memory blocks and hoist constant angle/twiddle factor calculations.
