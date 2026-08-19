// Conversions between the UI's sRGB/percent values and each vendor's wire
// units. LIFX speaks HSBK with 16-bit channels; Govee speaks 8-bit RGB.

export function rgbToHsv({ r, g, b }) {
  const rr = r / 255
  const gg = g / 255
  const bb = b / 255
  const max = Math.max(rr, gg, bb)
  const min = Math.min(rr, gg, bb)
  const delta = max - min

  let hue = 0
  if (delta !== 0) {
    if (max === rr) hue = ((gg - bb) / delta) % 6
    else if (max === gg) hue = (bb - rr) / delta + 2
    else hue = (rr - gg) / delta + 4
  }
  hue *= 60
  if (hue < 0) hue += 360

  return { h: hue, s: max === 0 ? 0 : delta / max, v: max }
}

export function hsvToRgb({ h, s, v }) {
  const c = v * s
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = v - c
  let rgb
  if (h < 60) rgb = [c, x, 0]
  else if (h < 120) rgb = [x, c, 0]
  else if (h < 180) rgb = [0, c, x]
  else if (h < 240) rgb = [0, x, c]
  else if (h < 300) rgb = [x, 0, c]
  else rgb = [c, 0, x]
  return {
    r: Math.round((rgb[0] + m) * 255),
    g: Math.round((rgb[1] + m) * 255),
    b: Math.round((rgb[2] + m) * 255),
  }
}

/** LIFX HSBK (16-bit channels) -> sRGB, ignoring kelvin for unsaturated white. */
export function hsbkToRgb({ hue, saturation, brightness }) {
  return hsvToRgb({
    h: (hue / 65535) * 360,
    s: saturation / 65535,
    v: brightness / 65535,
  })
}

export function clampPercent(value) {
  return Math.max(0, Math.min(100, Math.round(Number(value) || 0)))
}

export function percentToU16(percent) {
  return Math.max(0, Math.min(65535, Math.round((clampPercent(percent) / 100) * 65535)))
}

export function u16ToPercent(value) {
  return Math.round((value / 65535) * 100)
}
