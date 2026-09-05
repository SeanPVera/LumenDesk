import { emptySnapshot, synthSpectrum, type AudioReactiveSnapshot, type Metre, type TimeFeel } from "./types";

export interface Groove {
  id: string;
  name: string;
  bpm: number;
  metre: Metre;
  feel: TimeFeel;
  summary: string;
}

export const GROOVES: Groove[] = [
  { id: "four", name: "Four on the floor", bpm: 128, metre: 4, feel: "straight", summary: "Kick every beat, snare on 2 and 4." },
  { id: "halftime", name: "Head-nod", bpm: 140, metre: 4, feel: "half", summary: "140 grid, felt 70. Snare on 3." },
  { id: "waltz", name: "Waltz", bpm: 90, metre: 3, feel: "straight", summary: "Kick on 1, lift on 3." },
  { id: "sixeight", name: "Six-eight", bpm: 72, metre: 6, feel: "straight", summary: "Two groups of three. Weight on 1 and 4." },
  { id: "five", name: "Five-count", bpm: 110, metre: 5, feel: "straight", summary: "Odd metre. Kick on 1, snare on 4." },
  { id: "seven", name: "Seven", bpm: 105, metre: 7, feel: "straight", summary: "3+2+2. Kick on 1, snare on 4 and 6." },
  { id: "breaks", name: "Breaks", bpm: 168, metre: 4, feel: "straight", summary: "Fast grid, snare chatter, hats between." },
];

function hitEnv(phase: number, length: number, decay: number): number {
  if (length <= 0) return 0;
  const t = Math.max(0, Math.min(1, phase / length));
  if (t < 0.018) return t / 0.018;
  return Math.exp(-(t - 0.018) / decay);
}

export function syntheticSnapshot(groove: Groove, startedAt: number, timestamp: number): AudioReactiveSnapshot {
  const elapsed = Math.max(0, timestamp - startedAt);
  const beatLength = 60 / groove.bpm;
  const metre = groove.metre;
  const feelMul = groove.feel === "half" ? 2 : groove.feel === "double" ? 0.5 : 1;
  const feltLength = beatLength * feelMul;
  const beatIndex = Math.floor(elapsed / beatLength);
  const beatPhase = elapsed % beatLength;
  const feltIndex = Math.floor(elapsed / feltLength);
  const feltPhase = elapsed % feltLength;
  const pulse = hitEnv(feltPhase, feltLength, groove.feel === "half" ? 0.28 : 0.16);
  const hatPhase = elapsed % (beatLength / 2);
  const hat = hitEnv(hatPhase, beatLength / 2, 0.08) * (groove.id === "breaks" ? 0.95 : 0.7);
  const beatInBar = ((beatIndex % metre) + metre) % metre;

  let kick = pulse * 0.18;
  let snare = 0.06;
  switch (groove.id) {
    case "halftime":
      kick = beatInBar === 0 || beatInBar === 2 ? pulse : pulse * 0.12;
      snare = beatInBar === 2 ? pulse * 0.95 : 0.05;
      break;
    case "waltz":
      kick = beatInBar === 0 ? pulse : beatInBar === 2 ? pulse * 0.35 : pulse * 0.16;
      snare = beatInBar === 2 ? pulse * 0.55 : 0.07;
      break;
    case "sixeight":
      kick = beatInBar === 0 || beatInBar === 3 ? pulse : pulse * 0.14;
      snare = beatInBar === 3 ? pulse * 0.7 : beatInBar === 1 || beatInBar === 4 ? pulse * 0.22 : 0.06;
      break;
    case "five":
      kick = beatInBar === 0 ? pulse : beatInBar === 2 ? pulse * 0.4 : pulse * 0.16;
      snare = beatInBar === 3 ? pulse * 0.92 : 0.07;
      break;
    case "seven":
      kick = beatInBar === 0 ? pulse : beatInBar === 3 ? pulse * 0.55 : pulse * 0.14;
      snare = beatInBar === 3 || beatInBar === 5 ? pulse * 0.88 : 0.06;
      break;
    case "breaks":
      kick = beatInBar === 0 || beatInBar === 2 ? pulse : pulse * 0.28;
      snare = beatInBar === 1 || beatInBar === 3 ? pulse * 0.95 : hat * 0.35;
      break;
    default:
      kick = pulse;
      snare = beatInBar === 1 || beatInBar === 3 ? pulse * 0.9 : 0.08;
  }

  const energy = Math.min(1, 0.32 + kick * 0.34 + snare * 0.2 + hat * 0.12);
  const phrase = feltIndex % 8;
  const lift = phrase >= 6 ? 0.12 : 0;
  return {
    ...emptySnapshot(),
    level: 0.34 + pulse * 0.36 + lift,
    beat: beatPhase < 0.035 ? Math.max(kick, snare) : 0,
    kick,
    snare,
    percussion: hat,
    bass: 0.3 + kick * 0.55,
    mids: 0.26 + snare * 0.34,
    highs: 0.16 + hat * 0.55,
    energy: Math.min(1, energy + lift),
    mood: 0.4 + hat * 0.22 + (groove.metre === 3 ? 0.08 : 0),
    confidence: 1,
    pulse,
    drop: phrase >= 7 ? 0.7 : energy > 0.72 ? 0.45 : 0.1,
    beatCount: beatIndex,
    tempo: groove.bpm,
    beatInterval: beatLength,
    beatConfidence: 1,
    beatReferenceTime: startedAt + beatIndex * beatLength,
    beatInBar,
    isTempoLocked: true,
    metre,
    metreConfidence: 1,
    timeFeel: groove.feel,
    feltInterval: feltLength,
    feltTempo: groove.bpm / feelMul,
    stereo: 0.5 + 0.1 * Math.sin(elapsed * 0.65),
    chroma: [0.22, 0.04, 0.42, 0.05, 0.72, 0.12, 0.06, 0.5, 0.04, 0.24, 0.08, 0.14],
    spectrum: synthSpectrum(kick, snare, hat, energy + lift, elapsed),
    phrasePosition: phrase,
    energySlope: Math.sin(elapsed / 8) * 0.22 + (phrase >= 6 ? 0.2 : 0),
    sourceDescription: `${groove.name} · demo grid`,
  };
}
