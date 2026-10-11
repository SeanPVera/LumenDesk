export function hannWindow(size: number): Float64Array {
  const window = new Float64Array(size);
  if (size <= 1) return window;
  for (let i = 0; i < size; i += 1) {
    window[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / size));
  }
  return window;
}

/** Radix-2 FFT → magnitudes for bins 0..n/2-1, with reusable transform storage. */
export class RealFFT {
  private readonly n: number;
  private readonly cos: Float64Array;
  private readonly sin: Float64Array;
  private readonly real: Float64Array;
  private readonly imag: Float64Array;
  /** Bit-reversed index of each input sample; the permutation is its own inverse. */
  private readonly bitReversed: Uint32Array;

  constructor(n: number) {
    if (n < 2 || (n & (n - 1)) !== 0) {
      throw new Error("FFT size must be a power of two");
    }
    this.n = n;
    this.cos = new Float64Array(n / 2);
    this.sin = new Float64Array(n / 2);
    this.real = new Float64Array(n);
    this.imag = new Float64Array(n);
    this.bitReversed = new Uint32Array(n);
    for (let i = 0; i < n / 2; i += 1) {
      const angle = (-2 * Math.PI * i) / n;
      this.cos[i] = Math.cos(angle);
      this.sin[i] = Math.sin(angle);
    }

    let j = 0;
    for (let i = 0; i < n; i += 1) {
      this.bitReversed[i] = j;
      let bit = n >> 1;
      while (j & bit) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
    }
  }

  magnitudes(input: ArrayLike<number>, output: Float64Array): void {
    const n = this.n;
    if (n === 2) {
      output[0] = Math.abs((input[0] ?? 0) + (input[1] ?? 0)) / 2;
      return;
    }
    const bins = n / 2;
    const real = this.real;
    const imag = this.imag;
    const bitReversed = this.bitReversed;
    // Pack the even and odd samples into a half-size complex FFT. A real
    // signal's conjugate symmetry recovers every retained bin without running
    // a full-size transform on an imaginary channel containing only zeros.
    for (let i = 0; i < bins; i += 1) {
      const index = bitReversed[i] >>> 1;
      real[index] = input[i * 2] ?? 0;
      imag[index] = input[i * 2 + 1] ?? 0;
    }
    this.transform(bins);

    // Math.hypot's variadic, overflow-safe path is measurably slower here, and
    // windowed audio magnitudes are nowhere near the range where it matters.
    output[0] = Math.abs(real[0] + imag[0]) / n;
    for (let i = 1; i < bins / 2; i += 1) {
      const mirror = bins - i;
      const evenR = real[i] + real[mirror], evenI = imag[i] - imag[mirror];
      const oddR = imag[i] + imag[mirror], oddI = real[mirror] - real[i];
      const c = this.cos[i], s = this.sin[i];
      const rotatedR = c * oddR - s * oddI, rotatedI = s * oddR + c * oddI;
      const r = evenR + rotatedR, im = evenI + rotatedI;
      const mirrorR = evenR - rotatedR, mirrorI = evenI - rotatedI;
      // The unpacking factor 1/2 cancels the one-sided magnitude factor 2.
      output[i] = Math.sqrt(r * r + im * im) / n;
      output[mirror] = Math.sqrt(mirrorR * mirrorR + mirrorI * mirrorI) / n;
    }
    // At a quarter of the sample rate, this bin is its own unpacking partner.
    const quarterR = real[bins / 2], quarterI = imag[bins / 2];
    output[bins / 2] = Math.sqrt(quarterR * quarterR + quarterI * quarterI) * 2 / n;
  }

  /** RMS channel magnitudes, preserving energy even for opposite-phase stereo. */
  stereoMagnitudes(left: ArrayLike<number>, right: ArrayLike<number>, output: Float64Array): void {
    const n = this.n;
    const real = this.real;
    const imag = this.imag;
    const bitReversed = this.bitReversed;
    // Pack two real signals into one complex transform: Z = FFT(left + i*right).
    for (let i = 0; i < n; i += 1) {
      const index = bitReversed[i];
      real[index] = left[i] ?? 0;
      imag[index] = right[i] ?? 0;
    }
    this.transform();

    // Real-signal conjugate symmetry gives |L[k]|² + |R[k]|² =
    // (|Z[k]|² + |Z[n-k]|²)/2. Average channel power directly so neither
    // a second transform nor temporary per-channel spectra are needed.
    output[0] = Math.sqrt((real[0] * real[0] + imag[0] * imag[0]) * 0.5) / n;
    for (let i = 1; i < n / 2; i += 1) {
      const mirror = n - i;
      const r = real[i];
      const im = imag[i];
      const mirrorR = real[mirror];
      const mirrorIm = imag[mirror];
      output[i] = Math.sqrt(r * r + im * im + mirrorR * mirrorR + mirrorIm * mirrorIm) / n;
    }
  }

  private transform(n = this.n): void {
    const real = this.real;
    const imag = this.imag;
    const cos = this.cos;
    const sin = this.sin;

    // The first stage has only the unit twiddle. Avoid four multiplications
    // and factor loads for every pair (also the most numerous butterflies).
    for (let i = 0; i < n; i += 2) {
      const r = real[i], im = imag[i];
      real[i] = r + real[i + 1];
      imag[i] = im + imag[i + 1];
      real[i + 1] = r - real[i + 1];
      imag[i + 1] = im - imag[i + 1];
    }
    // Fuse pairs of radix-2 stages. Intermediate butterflies stay in local
    // scalars instead of writing and reading the transform arrays twice.
    let len = 4;
    for (; len * 2 <= n; len *= 4) {
      const pairLength = len * 2;
      const quarter = len / 2;
      const step = this.n / pairLength;
      for (let k = 0; k < quarter; k += 1) {
        const factor = k * step;
        const c = cos[factor], s = sin[factor];
        const cHalf = cos[factor * 2], sHalf = sin[factor * 2];
        const cQuarter = cos[factor + this.n / 4], sQuarter = sin[factor + this.n / 4];
        for (let i = k; i < n; i += pairLength) {
          const b = i + quarter, d = b + len, e = i + len;
          const br = cHalf * real[b] - sHalf * imag[b];
          const bi = cHalf * imag[b] + sHalf * real[b];
          const dr = cHalf * real[d] - sHalf * imag[d];
          const di = cHalf * imag[d] + sHalf * real[d];
          const ar = real[i], ai = imag[i], er = real[e], ei = imag[e];
          const pr = ar + br, pi = ai + bi;
          const qr = ar - br, qi = ai - bi;
          const rr = er + dr, ri = ei + di;
          const sr = er - dr, si = ei - di;
          const tr = c * rr - s * ri, ti = c * ri + s * rr;
          const ur = cQuarter * sr - sQuarter * si;
          const ui = cQuarter * si + sQuarter * sr;
          real[i] = pr + tr; imag[i] = pi + ti;
          real[e] = pr - tr; imag[e] = pi - ti;
          real[b] = qr + ur; imag[b] = qi + ui;
          real[d] = qr - ur; imag[d] = qi - ui;
        }
      }
    }
    // An even log2(size) leaves one unpaired stage.
    for (; len <= n; len <<= 1) {
      const half = len >> 1;
      const step = this.n / len;
      for (let i = 0; i < n; i += len) {
        const odd = i + half;
        const r = real[i], im = imag[i];
        real[i] = r + real[odd];
        imag[i] = im + imag[odd];
        real[odd] = r - real[odd];
        imag[odd] = im - imag[odd];
      }
      for (let k = 1; k < half; k += 1) {
        const index = k * step;
        const c = cos[index];
        const s = sin[index];
        for (let i = k; i < n; i += len) {
          const odd = i + half;
          const rOdd = real[odd];
          const iOdd = imag[odd];
          const tReal = c * rOdd - s * iOdd;
          const tImag = c * iOdd + s * rOdd;
          real[odd] = real[i] - tReal;
          imag[odd] = imag[i] - tImag;
          real[i] += tReal;
          imag[i] += tImag;
        }
      }
    }

  }
}
