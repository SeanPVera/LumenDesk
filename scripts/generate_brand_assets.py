#!/usr/bin/env python3
"""Generate the LumenDesk Open Aperture app-icon family.

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
    "black": "#090B12",
    "graphite": "#171B26",
    "ivory": "#FFF0C2",
    "amber": "#F5A33B",
    "rose": "#D84982",
    "violet": "#7357E8",
    "blue": "#3977E8",
    "cyan": "#30B9C8",
}

MASTER = {
    "left": [(183, 782), (424, 168), (365, 782)],
    "center": [(483, 148), (541, 148), (620, 704), (404, 704)],
    "right": [(841, 782), (600, 168), (659, 782)],
    "base": [(157, 764, 238, 42), (416, 764, 192, 42), (629, 764, 238, 42)],
}

MICRO = {
    16: {"left": [(2,13),(7,2),(6,13)], "center": [(7,2),(9,2),(10,12),(6,12)], "right": [(14,13),(9,2),(10,13)], "base": [(2,13,4,1),(6,13,4,1),(10,13,4,1)]},
    24: {"left": [(3,20),(10,3),(8,20)], "center": [(11,3),(13,3),(15,18),(9,18)], "right": [(21,20),(14,3),(16,20)], "base": [(3,20,6,2),(9,20,6,2),(15,20,6,2)]},
    32: {"left": [(4,27),(13,4),(11,27)], "center": [(15,4),(17,4),(20,24),(12,24)], "right": [(28,27),(19,4),(21,27)], "base": [(4,26,8,2),(12,26,8,2),(20,26,8,2)]},
    48: {"left": [(7,40),(20,7),(17,40)], "center": [(22,6),(26,6),(30,36),(18,36)], "right": [(41,40),(28,7),(31,40)], "base": [(7,39,12,3),(20,39,8,3),(29,39,12,3)]},
    64: {"left": [(9,53),(27,9),(23,53)], "center": [(30,8),(34,8),(40,47),(24,47)], "right": [(55,53),(37,9),(41,53)], "base": [(9,51,16,4),(26,51,12,4),(39,51,16,4)]},
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
    shapes = {
        key: [(round(x * scale), round(y * scale)) for x, y in MASTER[key]]
        for key in ("left", "center", "right")
    }
    if monochrome:
        draw = ImageDraw.Draw(image)
        for key in ("left", "center", "right"):
            draw.polygon(shapes[key], fill="white")
        for x, y, w, h in MASTER["base"]:
            draw.rounded_rectangle((round(x*scale), round(y*scale), round((x+w)*scale), round((y+h)*scale)), radius=max(1, round(h*scale/2)), fill="white")
        return image
    image.alpha_composite(gradient(size, shapes["left"], "#A187FF", COLORS["rose"]))
    image.alpha_composite(gradient(size, shapes["center"], "#FFFFFF", COLORS["amber"]))
    image.alpha_composite(gradient(size, shapes["right"], "#78DEFF", COLORS["cyan"]))
    draw = ImageDraw.Draw(image)
    for (x, y, w, h), color in zip(MASTER["base"], (COLORS["violet"], COLORS["ivory"], COLORS["blue"])):
        draw.rounded_rectangle((round(x*scale), round(y*scale), round((x+w)*scale), round((y+h)*scale)), radius=max(1, round(h*scale/2)), fill=color)
    return image


def micro_mark(size: int, monochrome: bool = False) -> Image.Image:
    spec = MICRO[size]
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if monochrome:
        for key in ("left", "center", "right"):
            draw.polygon(spec[key], fill="white")
        for x, y, w, h in spec["base"]:
            draw.rectangle((x, y, x+w-1, y+h-1), fill="white")
        return image
    image.alpha_composite(gradient(size, spec["left"], "#A187FF", COLORS["rose"]))
    image.alpha_composite(gradient(size, spec["center"], "#FFFFFF", COLORS["amber"]))
    image.alpha_composite(gradient(size, spec["right"], "#78DEFF", COLORS["cyan"]))
    for (x, y, w, h), color in zip(spec["base"], (COLORS["violet"], COLORS["ivory"], COLORS["blue"])):
        draw.rectangle((x, y, x+w-1, y+h-1), fill=color)
    return image


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size-1, size-1), radius=round(size * 0.225), fill=255)
    return mask


def app_icon(size: int, platform: str, appearance: str = "default") -> Image.Image:
    supersample = 4 if size <= 64 else 1
    canvas_size = size * supersample
    if platform == "ios":
        canvas = Image.new("RGBA", (canvas_size, canvas_size), rgb("#24104F" if appearance == "tinted" else COLORS["black"]) + (255,))
        tile_origin = (0, 0)
        tile_size = canvas_size
    else:
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        inset = round(canvas_size * 0.055)
        tile_size = canvas_size - inset * 2
        tile_origin = (inset, inset)
        tile = Image.new("RGBA", (tile_size, tile_size), rgb("#24104F" if appearance == "tinted" else COLORS["black"]) + (255,))
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
        overlay = Image.new("RGBA", canvas.size, (26, 11, 64, 28))
        canvas.alpha_composite(overlay)
    x = tile_origin[0] + (tile_size - mark_size) // 2
    y = tile_origin[1] + round(tile_size * 0.47 - mark_size * 0.48)
    glow = mark.filter(ImageFilter.GaussianBlur(max(1, round(canvas_size * 0.012))))
    glow.putalpha(glow.getchannel("A").point(lambda alpha: round(alpha * 0.42)))
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
