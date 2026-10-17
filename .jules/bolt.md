## 2026-03-31 - Hoisting Trig Lookups in Radix-2 Real FFT Butterfly Loop
**Learning:** In JS/TS DSP routines like RealFFT, loop-interchanging the butterfly loops ($k$ indices vs $i$ block offsets) allows hoisting trigonometric array lookups (`cos[index]`, `sin[index]`) out of the innermost loop. This reduces array access overhead and improves CPU cache efficiency in JS runtimes without changing floating-point accuracy.
**Action:** When working with FFT or spectral audio processing loops, ensure inner loops process contiguous memory blocks and hoist constant angle/twiddle factor calculations.

## 2026-10-11 - Consolidating audio and Shapes hot paths
**Learning:** Overlapping ring-buffer optimizations should be combined once: use a power-of-two mask for the fixed audio window, split window reads into two contiguous spans, and use conditional wrapping for the beat history's variable capacity. Hoist repeated array references and decay calculations while preserving sample ordering, channel fallbacks, and independent snapshot arrays. Shapes operations can reuse one wall rotation and collect bounds in a single pass.
**Action:** Verify equivalent output across wrap boundaries, channel changes, arbitrary orientations, and geometry ties before comparing performance. Measure the consolidated implementation on the same runtime rather than combining speedup percentages from separate microbenchmarks.

## 2026-10-12 - Backward Day-Stepping for Schedule Evaluation
**Learning:** Replacing minute-by-minute scanning in schedule evaluation with backward day-stepping reduces complexity from $O(\text{minutes})$ to $O(\text{days})$. Re-constructing `Date` instances per calendar day instead of mutating a single `Date` object avoids hour drift caused by JS Date hour-adjustments across DST spring-forward transitions.
**Action:** In date/time interval matching, iterate over candidate days and re-instantiate local-time components per candidate date to safely handle DST boundaries without minute-walking.
