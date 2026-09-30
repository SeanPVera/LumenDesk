## 2025-09-30 - RealFFT Hot Loop Optimization
**Learning:** `Math.hypot` in JS/V8 introduces noticeable overhead compared to direct `Math.sqrt(x * x + y * y)` inside hot loops (such as real-time audio FFT magnitude calculation), and pre-computing bit-reversal permutations in a lookup table avoids repetitive bitwise loop calculations per audio frame.
**Action:** Always precompute static index permutations and prefer direct `Math.sqrt(r * r + i * i)` over `Math.hypot` in high-frequency audio DSP hot paths.
