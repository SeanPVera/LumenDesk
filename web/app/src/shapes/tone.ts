// A panel colour as chroma plus its own level, the same split the native
// NanoleafPanelDesign makes: changing the level scales the colour's channels
// and leaves its hue alone, and a level of zero is a panel painted off.

export interface RGB { r: number; g: number; b: number }

/** Hue in degrees, saturation and value (the panel's level) from 0 to 1. */
export interface Tone { h: number; s: number; v: number }

export function toTone({ r, g, b }: RGB): Tone {
  const max = Math.max(r, g, b)
  const delta = max - Math.min(r, g, b)
  let h = 0
  if (delta) {
    if (max === r) h = (((g - b) / delta) % 6 + 6) % 6
    else if (max === g) h = (b - r) / delta + 2
    else h = (r - g) / delta + 4
  }
  return { h: h * 60, s: max ? delta / max : 0, v: max / 255 }
}

export function toRGB({ h, s, v }: Tone): RGB {
  const channel = (n: number) => {
    const k = (n + h / 60) % 6
    // The nudge keeps an exact half (43 at level 0.5 is 21.5) from rounding
    // down on float error, so a level matches a plain per-channel scale.
    return Math.round(255 * (v - v * s * Math.max(0, Math.min(k, 4 - k, 1))) + 1e-9)
  }
  return { r: channel(5), g: channel(3), b: channel(1) }
}
