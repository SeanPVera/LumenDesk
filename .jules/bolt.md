## 2026-03-31 - Hoisting Trig Lookups in Radix-2 Real FFT Butterfly Loop
**Learning:** In JS/TS DSP routines like RealFFT, loop-interchanging the butterfly loops ($k$ indices vs $i$ block offsets) allows hoisting trigonometric array lookups (`cos[index]`, `sin[index]`) out of the innermost loop. This reduces array access overhead and improves CPU cache efficiency in JS runtimes without changing floating-point accuracy.
**Action:** When working with FFT or spectral audio processing loops, ensure inner loops process contiguous memory blocks and hoist constant angle/twiddle factor calculations.

## 2026-03-31 - Bitwise Masking and Property Hoisting in Audio Ring Buffers
**Learning:** In high-frequency JS audio DSP loops with power-of-two window sizes (e.g. 2048), modulo operations (`% WINDOW`) incur integer division overhead. Replacing modulo with bitwise masking `& (WINDOW - 1)`, hoisting `this` property accesses (`ringWrite`, `hann`, `windowed`), and avoiding megamorphic key access (`this[key]`) yields an ~11.5% speedup in feature analysis.
**Action:** When working with ring buffers or spectral flux loops in audio JS code, ensure window sizes are power-of-two and use bitwise masking with hoisted local array references.
