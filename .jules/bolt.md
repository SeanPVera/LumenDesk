## 2026-03-31 - Hoisting Trig Lookups in Radix-2 Real FFT Butterfly Loop
**Learning:** In JS/TS DSP routines like RealFFT, loop-interchanging the butterfly loops ($k$ indices vs $i$ block offsets) allows hoisting trigonometric array lookups (`cos[index]`, `sin[index]`) out of the innermost loop. This reduces array access overhead and improves CPU cache efficiency in JS runtimes without changing floating-point accuracy.
**Action:** When working with FFT or spectral audio processing loops, ensure inner loops process contiguous memory blocks and hoist constant angle/twiddle factor calculations.

## 2026-10-11 - Consolidating audio and Shapes hot paths
**Learning:** Overlapping ring-buffer optimizations should be combined once: use a power-of-two mask for the fixed audio window, split window reads into two contiguous spans, and use conditional wrapping for the beat history's variable capacity. Hoist repeated array references and decay calculations while preserving sample ordering, channel fallbacks, and independent snapshot arrays. Shapes operations can reuse one wall rotation and collect bounds in a single pass.
**Action:** Verify equivalent output across wrap boundaries, channel changes, arbitrary orientations, and geometry ties before comparing performance. Measure the consolidated implementation on the same runtime rather than combining speedup percentages from separate microbenchmarks.

## 2026-04-01 - Indexed TypedArrays for Choreography Envelopes and Roles
**Learning:** Replacing string Map lookups with an indexed Float64Array for target brightness envelopes and pre-caching fixture roles into a Uint8Array avoids string hashing and object allocation during per-frame lighting calculations. Always guard cached TypedArrays in `makeFrame` against length changes to prevent stale or out-of-bounds reads after engine resets.
**Action:** Use Float64Array/Uint8Array indexing parallel to cached target arrays for per-fixture frame state, and ensure array length validity checks exist on every frame entry.
