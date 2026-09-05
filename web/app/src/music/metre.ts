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

    let best: Metre = 4;
    let bestScore = -1;
    const scores: Partial<Record<Metre, number>> = {};
    for (const n of CANDIDATES) {
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
    const hist = this.kickHistory;
    for (let i = 0; i < hist.length; i += 1) {
      bins[i % n] += hist[hist.length - 1 - i];
    }
    const max = Math.max(...bins);
    if (max <= 1e-6) return 0;
    const mean = bins.reduce((a, b) => a + b, 0) / n;
    const prominence = (max - mean) / max;
    const downbeat = Math.max(...bins);
    const downbeatIndex = bins.indexOf(downbeat);
    let grouped = 0;
    if (n === 6) {
      const a = bins[0] + bins[3];
      const b = bins[1] + bins[4];
      const c = bins[2] + bins[5];
      grouped = a > b && a > c ? 0.18 : 0;
    }
    const alignment = downbeatIndex === 0 ? 0.12 : 0;
    return Math.max(0, Math.min(1, prominence * 0.85 + grouped + alignment));
  }
}
