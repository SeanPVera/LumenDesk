## 2026-03-31 - Hoisting Trig Lookups in Radix-2 Real FFT Butterfly Loop
**Learning:** In JS/TS DSP routines like RealFFT, loop-interchanging the butterfly loops ($k$ indices vs $i$ block offsets) allows hoisting trigonometric array lookups (`cos[index]`, `sin[index]`) out of the innermost loop. This reduces array access overhead and improves CPU cache efficiency in JS runtimes without changing floating-point accuracy.
**Action:** When working with FFT or spectral audio processing loops, ensure inner loops process contiguous memory blocks and hoist constant angle/twiddle factor calculations.

## 2026-03-31 - Splitting Ring Buffer Loops to Eliminate Modulo Arithmetic
**Learning:** In JS audio DSP loops (like FFT windowing or history buffers), using modulo `% WINDOW` inside element-by-element loops introduces integer division overhead and prevents JIT vectorization. Splitting circular buffer reads into two contiguous linear slice loops (`0..WINDOW - writeIndex` and `0..writeIndex`) eliminates all modulo operations and enables unit-stride TypedArray reads, achieving ~20% speedup.
**Action:** Replace per-element `%` ring buffer indexing with split contiguous loops or bitwise AND `& (size - 1)` (when size is a power of 2) in hot DSP paths.
