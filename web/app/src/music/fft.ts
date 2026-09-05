export function hannWindow(size: number): Float64Array {
  const window = new Float64Array(size);
  if (size <= 1) return window;
  for (let i = 0; i < size; i += 1) {
    window[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (size - 1)));
  }
  return window;
}

/** In-place radix-2 real FFT → magnitudes for bins 0..n/2-1. */
export class RealFFT {
  private readonly n: number;
  private readonly nLog2: number;
  private readonly cos: Float64Array;
  private readonly sin: Float64Array;
  private readonly real: Float64Array;
  private readonly imag: Float64Array;

  constructor(n: number) {
    if (n < 2 || (n & (n - 1)) !== 0) {
      throw new Error("FFT size must be a power of two");
    }
    this.n = n;
    this.nLog2 = Math.log2(n);
    this.cos = new Float64Array(n / 2);
    this.sin = new Float64Array(n / 2);
    this.real = new Float64Array(n);
    this.imag = new Float64Array(n);
    for (let i = 0; i < n / 2; i += 1) {
      const angle = (-2 * Math.PI * i) / n;
      this.cos[i] = Math.cos(angle);
      this.sin[i] = Math.sin(angle);
    }
  }

  magnitudes(input: ArrayLike<number>, output: Float64Array): void {
    const n = this.n;
    const real = this.real;
    const imag = this.imag;
    for (let i = 0; i < n; i += 1) {
      real[i] = input[i] ?? 0;
      imag[i] = 0;
    }

    let j = 0;
    for (let i = 1; i < n; i += 1) {
      let bit = n >> 1;
      while (j & bit) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        const tr = real[i];
        real[i] = real[j];
        real[j] = tr;
      }
    }

    for (let len = 2; len <= n; len <<= 1) {
      const half = len >> 1;
      const step = n / len;
      for (let i = 0; i < n; i += len) {
        for (let k = 0; k < half; k += 1) {
          const index = k * step;
          const even = i + k;
          const odd = even + half;
          const tReal = this.cos[index] * real[odd] - this.sin[index] * imag[odd];
          const tImag = this.cos[index] * imag[odd] + this.sin[index] * real[odd];
          real[odd] = real[even] - tReal;
          imag[odd] = imag[even] - tImag;
          real[even] += tReal;
          imag[even] += tImag;
        }
      }
    }

    const bins = n / 2;
    const scale = 2 / n;
    for (let i = 0; i < bins; i += 1) {
      output[i] = Math.hypot(real[i], imag[i]) * scale;
    }
    output[0] *= 0.5;
  }
}
