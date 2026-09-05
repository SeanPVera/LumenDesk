import type { Metre, TimeFeel } from "./types";

const CANDIDATES: Metre[] = [3, 4, 5, 6, 7];

export class MetreTracker {
  private readonly kickHistory: number[] = [];
  private readonly evenEnergy = { even: 0, odd: 0 };
  private metre: Metre = 4;
  private metreConfidence = 0;
  private feel: TimeFeel = "straight";
  private lastBeat = -1;

  reset(): void {
    this.kickHistory.length = 0;
    this.evenEnergy.even = 0;
    this.evenEnergy.odd = 0;
    this.metre = 4;
    this.metreConfidence = 0;
    this.feel = "straight";
    this.lastBeat = -1;
  }

  observe(beatCount: number, kick: number, tempo: number, locked: boolean): void {
    if (beatCount === this.lastBeat) return;
    this.lastBeat = beatCount;
    this.kickHistory.push(Math.max(0, kick));
    if (this.kickHistory.length > 64) this.kickHistory.shift();

    const decay = 0.92;
    if (beatCount % 2 === 0) this.evenEnergy.even = this.evenEnergy.even * decay + kick;
    else this.evenEnergy.odd = this.evenEnergy.odd * decay + kick;

    if (!locked || this.kickHistory.length < 12) return;

    // Score four first so a tied prominence cannot be stolen by 3 listed first.
    let best: Metre = 4;
    let bestScore = this.scoreMetre(4);
    const scores: Partial<Record<Metre, number>> = { 4: bestScore };
    for (const n of CANDIDATES) {
      if (n === 4) continue;
      const score = this.scoreMetre(n);
      scores[n] = score;
      if (score > bestScore) {
        bestScore = score;
        best = n;
      }
    }

    const fourScore = scores[4] ?? 0;
    const adopt = best === this.metre || bestScore > fourScore * 1.12;
    const next = adopt ? best : this.metre;
    if (next !== this.metre) {
      if (bestScore > this.metreConfidence + 0.08) this.metre = next;
    } else {
      this.metre = next;
    }
    this.metreConfidence = Math.max(0, Math.min(1, bestScore));

    const even = this.evenEnergy.even;
    const odd = this.evenEnergy.odd;
    const ratio = even / Math.max(0.0001, odd);
    if (tempo >= 125 && ratio > 2.15) this.feel = "half";
    else if (tempo <= 88 && ratio < 1.25 && even + odd > 0.4) this.feel = "double";
    else this.feel = "straight";
  }

  current(): { metre: Metre; metreConfidence: number; feel: TimeFeel } {
    return {
      metre: this.metre,
      metreConfidence: this.metreConfidence,
      feel: this.feel,
    };
  }

  private scoreMetre(n: Metre): number {
    const bins = new Array(n).fill(0);
    const counts = new Array(n).fill(0);
    const oldest = this.lastBeat - this.kickHistory.length + 1;
    for (let i = 0; i < this.kickHistory.length; i += 1) {
      const beat = oldest + i;
      const slot = ((beat % n) + n) % n;
      bins[slot] += this.kickHistory[i];
      counts[slot] += 1;
    }
    for (let i = 0; i < n; i += 1) {
      if (counts[i] > 0) bins[i] /= counts[i];
    }
    const max = Math.max(...bins);
    if (max <= 1e-6) return 0;
    const mean = bins.reduce((a, b) => a + b, 0) / n;
    const prominence = (max - mean) / max;
    const downbeatIndex = bins.indexOf(max);
    let grouped = 0;
    if (n === 6) {
      const a = bins[0] + bins[3];
      const b = bins[1] + bins[4];
      const c = bins[2] + bins[5];
      // Waltz (equal weight on 1 and 4 of a 6-count) must not outscore 3/4.
      if (a > b && a > c && bins[0] > bins[3] * 1.15) grouped = 0.18;
    }
    const alignment = downbeatIndex === 0 ? 0.12 : 0;
    return Math.max(0, Math.min(1, prominence * 0.85 + grouped + alignment));
  }
}
