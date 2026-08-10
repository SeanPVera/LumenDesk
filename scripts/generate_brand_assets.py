#!/usr/bin/env python3
"""Generate the LumenDesk Lighting Desk app-icon family.

The small macOS sizes use hand-tuned geometry instead of mechanically shrinking
one 1024 px source. Run from the repository root with Pillow installed.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "LumenDesk" / "Assets.xcassets" / "AppIcon.appiconset"
BRAND = ROOT / "BrandAssets"
REPO = BRAND / "Repository"
OPTIONAL = BRAND / "AppIcons" / "OptionalAppearances"

COLORS = {
    "black": "#0B0C0A",
    "graphite": "#191B17",
    "ivory": "#F1EFE8",
    "amber": "#E7B35A",
    "amber_light": "#FFD68A",
    "copper": "#C97852",
    "cyan": "#73B4BD",
    "green": "#83B67A",
}

MASTER = {
    "beam": [(440, 246), (584, 246), (788, 700), (236, 700)],
    "slot": (388, 184, 248, 70),
    "desk": (180, 716, 664, 92),
    "nodes": [(449, 752, 24), (500, 752, 24), (551, 752, 24)],
}

MICRO = {
    16: {"beam": [(7,4),(9,4),(12,11),(4,11)], "slot": (6,3,4,1), "desk": (3,12,10,2), "nodes": [(7,12),(8,12),(9,12)]},
    24: {"beam": [(10,6),(14,6),(19,17),(5,17)], "slot": (9,4,6,2), "desk": (4,18,16,3), "nodes": [(10,19),(12,19),(14,19)]},
    32: {"beam": [(14,8),(18,8),(24,22),(8,22)], "slot": (12,6,8,2), "desk": (6,23,20,3), "nodes": [(13,24),(16,24),(19,24)]},
    48: {"beam": [(20,12),(28,12),(37,33),(11,33)], "slot": (18,9,12,3), "desk": (9,35,30,5), "nodes": [(20,37),(24,37),(28,37)]},
    64: {"beam": [(27,15),(37,15),(49,43),(15,43)], "slot": (24,11,16,5), "desk": (11,45,42,7), "nodes": [(26,48),(32,48),(38,48)]},
}


def rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def gradient(size: int, points, top: str, bottom: str) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    start, end = rgb(top), rgb(bottom)
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(round(start[i] + (end[i] - start[i]) * t) for i in range(3)) + (255,)
        draw.line((0, y, size, y), fill=color)
    image.putalpha(mask)
    return image


def scaled_master(size: int, monochrome: bool = False) -> Image.Image:
    scale = size / 1024
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    beam = [(round(x * scale), round(y * scale)) for x, y in MASTER["beam"]]
    slot = tuple(round(value * scale) for value in MASTER["slot"])
    desk = tuple(round(value * scale) for value in MASTER["desk"])
    if monochrome:
        draw = ImageDraw.Draw(image)
        draw.polygon(beam, fill="white")
        for x, y, w, h in (slot, desk):
            draw.rounded_rectangle((x, y, x + w, y + h), radius=max(1, h // 3), fill="white")
        return image
    image.alpha_composite(gradient(size, beam, COLORS["amber_light"], COLORS["amber"]))
    draw = ImageDraw.Draw(image)
    for x, y, w, h in (slot, desk):
        draw.rounded_rectangle((x, y, x + w, y + h), radius=max(1, h // 3), fill=COLORS["ivory"])
    for (x, y, diameter), color in zip(MASTER["nodes"], (COLORS["cyan"], COLORS["amber"], COLORS["green"])):
        left, top, d = round(x * scale), round(y * scale), max(2, round(diameter * scale))
        draw.ellipse((left, top, left + d, top + d), fill=color)
    return image


def micro_mark(size: int, monochrome: bool = False) -> Image.Image:
    spec = MICRO[size]
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if monochrome:
        draw.polygon(spec["beam"], fill="white")
        for key in ("slot", "desk"):
            x, y, w, h = spec[key]
            draw.rectangle((x, y, x+w-1, y+h-1), fill="white")
        return image
    image.alpha_composite(gradient(size, spec["beam"], COLORS["amber_light"], COLORS["amber"]))
    for key in ("slot", "desk"):
        x, y, w, h = spec[key]
        draw.rectangle((x, y, x+w-1, y+h-1), fill=COLORS["ivory"])
    for (x, y), color in zip(spec["nodes"], (COLORS["cyan"], COLORS["amber"], COLORS["green"])):
        draw.point((x, y), fill=color)
    return image


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size-1, size-1), radius=round(size * 0.225), fill=255)
    return mask


def app_icon(size: int, platform: str, appearance: str = "default") -> Image.Image:
    supersample = 4 if size <= 64 else 1
    canvas_size = size * supersample
    if platform == "ios":
        canvas = Image.new("RGBA", (canvas_size, canvas_size), rgb("#3B321F" if appearance == "tinted" else COLORS["black"]) + (255,))
        tile_origin = (0, 0)
        tile_size = canvas_size
    else:
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        inset = round(canvas_size * 0.055)
        tile_size = canvas_size - inset * 2
        tile_origin = (inset, inset)
        tile = Image.new("RGBA", (tile_size, tile_size), rgb("#3B321F" if appearance == "tinted" else COLORS["black"]) + (255,))
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
        overlay = Image.new("RGBA", canvas.size, (18, 20, 15, 32))
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
