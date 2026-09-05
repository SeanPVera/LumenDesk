import type {
  FixtureTopology,
  MusicFixtureDescriptor,
  MusicLightingFrame,
  MusicLightingState,
} from "./types";

export const DEMO_ROOM: MusicFixtureDescriptor[] = [
  { id: "lifx:downstage-l", label: "Downstage L", transport: "lifxLAN", segmentCount: 0, role: "hit" },
  { id: "lifx:downstage-r", label: "Downstage R", transport: "lifxLAN", segmentCount: 0, role: "hit" },
  { id: "govee:cob-desk", label: "Desk COB", transport: "goveeRealtimeSegments", segmentCount: 20, role: "motion" },
  { id: "govee:string", label: "Window string", transport: "goveeRealtimeSegments", segmentCount: 12, role: "motion" },
  { id: "lifx:wash-c", label: "Wash C", transport: "lifxLAN", segmentCount: 0, role: "wash" },
  { id: "lifx:rear", label: "Rear accent", transport: "lifxLAN", segmentCount: 0, role: "accent" },
  { id: "govee:uplighter", label: "Uplighter", transport: "goveeLAN", segmentCount: 0, role: "wash" },
];

export type BenchKind = "par" | "uplighter" | "bar";

export interface BenchPlacement {
  id: string;
  kind: BenchKind;
  x: number;
  z: number;
  y: number;
  barTo?: { x: number; z: number; y: number };
  aim?: { x: number; z: number };
}

export const BENCH_LAYOUT: BenchPlacement[] = [
  { id: "lifx:downstage-l", kind: "par", x: 0.2, z: 0.1, y: 0.42, aim: { x: 0.3, z: 0.38 } },
  { id: "lifx:downstage-r", kind: "par", x: 0.8, z: 0.1, y: 0.42, aim: { x: 0.7, z: 0.38 } },
  { id: "govee:uplighter", kind: "uplighter", x: 0.16, z: 0.46, y: 0.02, aim: { x: 0.2, z: 0.42 } },
  {
    id: "govee:cob-desk",
    kind: "bar",
    x: 0.16,
    z: 0.3,
    y: 0.2,
    barTo: { x: 0.84, z: 0.3, y: 0.2 },
  },
  { id: "lifx:wash-c", kind: "par", x: 0.5, z: 0.52, y: 0.74, aim: { x: 0.5, z: 0.48 } },
  {
    id: "govee:string",
    kind: "bar",
    x: 0.1,
    z: 0.8,
    y: 0.6,
    barTo: { x: 0.9, z: 0.8, y: 0.6 },
  },
  { id: "lifx:rear", kind: "par", x: 0.7, z: 0.84, y: 0.52, aim: { x: 0.54, z: 0.58 } },
];

export function defaultTopology(fixtures: MusicFixtureDescriptor[] = DEMO_ROOM): FixtureTopology {
  return {
    layout: "leftToRight",
    fixtureOrder: fixtures.map((f) => f.id),
    excludedFixtureIDs: [],
  };
}

export interface Rgb {
  r: number;
  g: number;
  b: number;
}

export function hsvToRgb(h: number, s: number, v: number): Rgb {
  const hue = ((h % 1) + 1) % 1;
  const i = Math.floor(hue * 6);
  const f = hue * 6 - i;
  const p = v * (1 - s);
  const q = v * (1 - f * s);
  const t = v * (1 - (1 - f) * s);
  let r = 0;
  let g = 0;
  let b = 0;
  switch (i % 6) {
    case 0:
      r = v;
      g = t;
      b = p;
      break;
    case 1:
      r = q;
      g = v;
      b = p;
      break;
    case 2:
      r = p;
      g = v;
      b = t;
      break;
    case 3:
      r = p;
      g = q;
      b = v;
      break;
    case 4:
      r = t;
      g = p;
      b = v;
      break;
    default:
      r = v;
      g = p;
      b = q;
      break;
  }
  return { r: Math.round(r * 255), g: Math.round(g * 255), b: Math.round(b * 255) };
}

export function hsbToCss(state: MusicLightingState | undefined, fallback = "transparent"): string {
  if (!state) return fallback;
  const { r, g, b } = hsvToRgb(state.hue, state.saturation, Math.max(0.05, state.brightness));
  return `rgb(${r} ${g} ${b})`;
}

export function rgbCss(rgb: Rgb, alpha = 1): string {
  return `rgba(${rgb.r}, ${rgb.g}, ${rgb.b}, ${alpha})`;
}

export function statesByFixture(frame: MusicLightingFrame | null): Map<string, MusicLightingState[]> {
  const map = new Map<string, MusicLightingState[]>();
  if (!frame) return map;
  for (const state of frame.states) {
    const list = map.get(state.fixtureID) ?? [];
    list.push(state);
    map.set(state.fixtureID, list);
  }
  return map;
}

export function lerpHue(a: number, b: number, t: number): number {
  const delta = ((((b - a) % 1) + 1.5) % 1) - 0.5;
  const wrapped = (a + delta * t) % 1;
  return wrapped < 0 ? wrapped + 1 : wrapped;
}
