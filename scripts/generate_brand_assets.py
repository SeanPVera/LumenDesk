#!/usr/bin/env python3
"""Generate the LumenDesk Spectral Bench app-icon family.

The mark keeps the geometry LumenDesk has always had — a source slot, a beam
widening onto a desk rail — and changes what the beam is made of. Light leaves
the aperture white and lands on the desk as the full visible spectrum: one
input, every colour, one control surface.

The small macOS sizes use hand-tuned geometry instead of mechanically shrinking
one 1024 px source. Run from the repository root with Pillow installed.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "LumenDesk" / "Assets.xcassets" / "AppIcon.appiconset"
BRAND = ROOT / "BrandAssets"
REPO = BRAND / "Repository"
OPTIONAL = BRAND / "AppIcons" / "OptionalAppearances"

COLORS = {
    "void": "#04060A",
    "ink": "#080B11",
    "beam": "#F6FAFF",
    "rail": "#E8EEF7",
}

# The dispersion ramp, short wavelength first. These are the same eight samples
# the app uses for every semantic colour in the interface.
SPECTRUM = ["#6C4BF0", "#3D7BF5", "#21C4DE", "#46D08A",
            "#D9D45F", "#FFB13D", "#FF7A38", "#F1495C"]

MASTER = {
    "slot": (388, 150, 248, 64),
    "beam": [(440, 250), (584, 250), (812, 720), (212, 720)],
    "rail": (140, 762, 744, 96),
}

MICRO = {
    16: {"slot": (6, 3, 4, 1), "beam": [(7, 4), (9, 4), (12, 11), (4, 11)], "rail": (3, 12, 10, 2)},
    24: {"slot": (9, 4, 6, 2), "beam": [(10, 6), (14, 6), (19, 17), (5, 17)], "rail": (4, 18, 16, 3)},
    32: {"slot": (12, 6, 8, 2), "beam": [(14, 8), (18, 8), (24, 22), (8, 22)], "rail": (6, 23, 20, 3)},
    48: {"slot": (18, 9, 12, 3), "beam": [(20, 12), (28, 12), (37, 33), (11, 33)], "rail": (9, 35, 30, 5)},
    64: {"slot": (24, 11, 16, 5), "beam": [(27, 15), (37, 15), (49, 43), (15, 43)], "rail": (11, 45, 42, 7)},
}


def rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def spectrum_at(t: float) -> tuple[int, int, int]:
    """Sample the dispersion ramp, interpolating between stops."""
    t = min(1.0, max(0.0, t))
    span = (len(SPECTRUM) - 1) * t
    low = int(span)
    high = min(low + 1, len(SPECTRUM) - 1)
    local = span - low
    start, end = rgb(SPECTRUM[low]), rgb(SPECTRUM[high])
    return tuple(round(start[i] + (end[i] - start[i]) * local) for i in range(3))


def dispersing_beam(size: int, points) -> Image.Image:
    """The beam: white where it leaves the aperture, dispersed where it lands.

    Colour runs across the beam and saturation runs down it, so the mark reads
    as light separating rather than as a gradient applied to a shape.
    """
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)

    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    width = max(1, right - left)
    height = max(1, bottom - top)
    white = rgb(COLORS["beam"])

    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        fall = min(1.0, max(0.0, (y - top) / height))
        # Hold the beam white briefly, then let it separate.
        mix = min(1.0, max(0.0, (fall - 0.12) / 0.75))
        for x in range(left, right + 1):
            hue = spectrum_at((x - left) / width)
            colour = tuple(round(white[i] + (hue[i] - white[i]) * mix) for i in range(3))
            draw.point((x, y), fill=colour + (255,))
    image.putalpha(mask)
    return image


def scaled_master(size: int, monochrome: bool = False) -> Image.Image:
    scale = size / 1024

    def s(value):
        return round(value * scale)

    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    beam = [(s(x), s(y)) for x, y in MASTER["beam"]]
    sx, sy, sw, sh = (s(value) for value in MASTER["slot"])
    rx, ry, rw, rh = (s(value) for value in MASTER["rail"])

    if monochrome:
        draw = ImageDraw.Draw(image)
        draw.polygon(beam, fill="white")
    else:
        image.alpha_composite(dispersing_beam(size, beam))

    draw = ImageDraw.Draw(image)
    face = "white" if monochrome else COLORS["beam"]
    draw.rounded_rectangle((sx, sy, sx + sw, sy + sh), radius=max(1, s(6)), fill=face)
    draw.rounded_rectangle((rx, ry, rx + rw, ry + rh), radius=max(1, s(6)),
                           fill="white" if monochrome else COLORS["rail"])
    return image


def micro_mark(size: int, monochrome: bool = False) -> Image.Image:
    spec = MICRO[size]
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if monochrome:
        ImageDraw.Draw(image).polygon(spec["beam"], fill="white")
    else:
        image.alpha_composite(dispersing_beam(size, spec["beam"]))
    draw = ImageDraw.Draw(image)
    for key in ("slot", "rail"):
        x, y, w, h = spec[key]
        draw.rectangle((x, y, x + w - 1, y + h - 1),
                       fill="white" if monochrome else COLORS["beam"])
    return image


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size-1, size-1), radius=round(size * 0.225), fill=255)
    return mask


def app_icon(size: int, platform: str, appearance: str = "default") -> Image.Image:
    supersample = 4 if size <= 64 else 1
    canvas_size = size * supersample
    if platform == "ios":
        canvas = Image.new("RGBA", (canvas_size, canvas_size), rgb("#1B2430" if appearance == "tinted" else COLORS["void"]) + (255,))
        tile_origin = (0, 0)
        tile_size = canvas_size
    else:
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        inset = round(canvas_size * 0.055)
        tile_size = canvas_size - inset * 2
        tile_origin = (inset, inset)
        tile = Image.new("RGBA", (tile_size, tile_size), rgb("#1B2430" if appearance == "tinted" else COLORS["void"]) + (255,))
        tile.putalpha(rounded_mask(tile_size))
        canvas.alpha_composite(tile, tile_origin)
    mark_size = round(tile_size * 0.79)
    target_micro = size if size in MICRO else None
    monochrome = appearance == "tinted"
    if target_micro:
        mark = micro_mark(target_micro, monochrome).resize((mark_size, mark_size), Image.Resampling.NEAREST)
    else:
        mark = scaled_master(mark_size, monochrome)
    if appearance == "dark":
        overlay = Image.new("RGBA", canvas.size, (4, 6, 10, 32))
        canvas.alpha_composite(overlay)
    x = tile_origin[0] + (tile_size - mark_size) // 2
    y = tile_origin[1] + round(tile_size * 0.47 - mark_size * 0.48)
    glow = mark.filter(ImageFilter.GaussianBlur(max(1, round(canvas_size * 0.009))))
    glow.putalpha(glow.getchannel("A").point(lambda alpha: round(alpha * 0.18)))
    canvas.alpha_composite(glow, (x, y))
    canvas.alpha_composite(mark, (x, y))
    if supersample > 1:
        canvas = canvas.resize((size, size), Image.Resampling.LANCZOS)
    return canvas


def main() -> None:
    for directory in (CATALOG, REPO, OPTIONAL):
        directory.mkdir(parents=True, exist_ok=True)

    ios = app_icon(1024, "ios").convert("RGB")
    ios.save(CATALOG / "AppIcon-iOS-1024.png", optimize=True)
    app_icon(1024, "ios", "dark").convert("RGB").save(OPTIONAL / "AppIcon-iOS-Dark-1024.png", optimize=True)
    app_icon(1024, "ios", "tinted").convert("RGB").save(OPTIONAL / "AppIcon-iOS-Tinted-1024.png", optimize=True)

    for size in (16, 32, 64, 128, 256, 512, 1024):
        app_icon(size, "mac").save(CATALOG / f"AppIcon-macOS-{size}.png", optimize=True)
    app_icon(1024, "mac", "dark").save(OPTIONAL / "AppIcon-macOS-Dark-1024.png", optimize=True)
    app_icon(1024, "mac", "tinted").save(OPTIONAL / "AppIcon-macOS-Tinted-1024.png", optimize=True)
    app_icon(512, "mac").save(REPO / "LumenDesk-Repository-Avatar-512.png", optimize=True)

    contents = {
        "images": [
            {"filename": "AppIcon-iOS-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"filename": "AppIcon-macOS-16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
            {"filename": "AppIcon-macOS-32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
            {"filename": "AppIcon-macOS-32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
            {"filename": "AppIcon-macOS-64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
            {"filename": "AppIcon-macOS-128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
            {"filename": "AppIcon-macOS-256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
            {"filename": "AppIcon-macOS-256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
            {"filename": "AppIcon-macOS-512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
            {"filename": "AppIcon-macOS-512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
            {"filename": "AppIcon-macOS-1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (CATALOG / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

    expected = {16, 32, 64, 128, 256, 512, 1024}
    for size in expected:
        image = Image.open(CATALOG / f"AppIcon-macOS-{size}.png")
        assert image.size == (size, size)
    assert Image.open(CATALOG / "AppIcon-iOS-1024.png").mode == "RGB"
    print("Generated and validated LumenDesk app-icon assets.")


if __name__ == "__main__":
    main()
