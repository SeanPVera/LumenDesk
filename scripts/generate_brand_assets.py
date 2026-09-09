#!/usr/bin/env python3
"""Generate the LumenDesk app-icon family.

The mark is the product: a drawing of a home with the lights on. An exterior
envelope, one dominant room sharing walls with two smaller ones, and light
pooling onto the floors of the two that are lit — the same thing the Plan
workspace puts on screen, reduced until it survives at 16 px.

The rooms are lopsided on purpose. Equal rooms behind a heavy frame read as a
window with lit panes; a plan is uneven, and its exterior wall is heavier than
its partitions because line weight is how a drawing states what is structural.

It follows the one rule the visual system has: chrome is achromatic, colour
means light. Every wall is a cool grey. The only colour in the icon is the
light itself, and there are two of them — a warm lamp and a cool one — because
two says "these are different lights" and eight says "RGB gaming peripheral".

The small macOS sizes take hand-tuned line weights from ``MICRO`` rather than
mechanically shrinking the 1024 px master, because a partition that renders at
0.4 px reads as a smudge. Run from the repository root with Pillow installed.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

NL = "\n"

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "LumenDesk" / "Assets.xcassets" / "AppIcon.appiconset"
BRAND = ROOT / "BrandAssets"
REPO = BRAND / "Repository"
OPTIONAL = BRAND / "AppIcons" / "OptionalAppearances"
LOGO = BRAND / "Logo"

COLORS = {
    # The tile the mark sits on, and the floor of a room. The floor is a step
    # lighter so the drawing reads as a sheet laid on the ground.
    "stage": "#05080C",
    "floor": "#0E141D",
    # Line weight is how a drawing states hierarchy: the envelope is
    # structural and heavier, the partitions are not.
    "wallOuter": "#8AACC6",
    "wall": "#3B5468",
    "tinted": "#1B2430",
    "source": "#FFFFFF",
}

# Geometry is expressed as fractions of the mark's box so one description
# serves every size. ``envelope`` is (left, top, right, bottom); the two
# partitions are a full-height vertical and a horizontal that only spans the
# right of it, which is what makes the plan asymmetric instead of a grid.
MASTER = {
    "envelope": (0.055, 0.055, 0.945, 0.945),
    # Deliberately lopsided. Equal rooms and a heavy frame read as a window
    # with lit panes; one dominant room against two small ones reads as a
    # plan, which is the thing the app actually draws.
    "partitionX": 0.585,
    "partitionY": 0.385,
    "wallOuter": 0.020,
    "wall": 0.0115,
    "source": 0.0095,
    "falloff": 1.35,
    "ceiling": 1.0,
    # (x, y, radius, core, edge, room) — room 0 is the left, 1 is top-right.
    "pools": (
        (0.285, 0.600, 0.320, "#FFEBCB", "#FF9330", 0),
        (0.795, 0.180, 0.215, "#E6F1FF", "#3F7FCB", 1),
    ),
}

# Below 64 px the master's proportional weights fall under a pixel. These are
# the sizes Finder, the Dock and the menu bar actually ask for, so they get
# their own weights; 16 px drops the second partition entirely, because three
# rooms in eleven usable pixels is a smudge and two is a plan.
MICRO = {
    16: {
        "wallOuter": 0.036, "wall": 0.028, "source": 0.0,
        "partitionY": None, "falloff": 1.0, "ceiling": 1.0,
        "pools": (
            (0.270, 0.580, 0.400, "#FFE3B8", "#FF8A20", 0),
            (0.795, 0.420, 0.300, "#DDEBFF", "#3070C4", 1),
        ),
    },
    24: {
        "wallOuter": 0.031, "wall": 0.023, "source": 0.0,
        "partitionY": None, "falloff": 1.1,
        "pools": (
            (0.270, 0.600, 0.380, "#FFE3B8", "#FF8A20", 0),
            (0.795, 0.400, 0.290, "#DDEBFF", "#3070C4", 1),
        ),
    },
    32: {
        "wallOuter": 0.027, "wall": 0.019, "source": 0.0, "falloff": 1.15,
        "pools": (
            (0.275, 0.610, 0.350, "#FFE7C2", "#FF8E28", 0),
            (0.795, 0.180, 0.245, "#E2EEFF", "#3676C8", 1),
        ),
    },
    48: {"wallOuter": 0.024, "wall": 0.0155, "source": 0.0, "falloff": 1.25},
    64: {"wallOuter": 0.022, "wall": 0.0135, "source": 0.010, "falloff": 1.3},
}


def rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def spec_for(size: int) -> dict:
    """The master geometry with any hand-tuned overrides for this size."""
    spec = dict(MASTER)
    spec.update(MICRO.get(size, {}))
    return spec


def light_pool(size: int, centre: tuple[float, float], radius: float,
               core: str, edge: str, clip: tuple[float, float, float, float],
               ceiling: float, falloff: float) -> Image.Image:
    """Light falling on a floor.

    Concentric rings rather than a blur, so the falloff is the same curve at
    every size instead of a filter radius that has to be re-guessed. The pool
    is clipped to its own room, because a wall stops light.
    """
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    inner, outer = rgb(core), rgb(edge)
    steps = max(32, int(radius))
    cx, cy = centre
    for index in range(steps, 0, -1):
        t = index / steps
        r = radius * t
        colour = tuple(round(inner[k] + (outer[k] - inner[k]) * t) for k in range(3))
        alpha = round(255 * (1 - t) ** falloff * ceiling)
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=colour + (alpha,))

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rectangle(clip, fill=255)
    layer.putalpha(Image.composite(layer.getchannel("A"),
                                   Image.new("L", (size, size), 0), mask))
    return layer


def draw_mark(size: int, spec: dict, monochrome: bool = False) -> Image.Image:
    """The plan itself, drawn into a transparent square of ``size``."""
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    left, top, right, bottom = (value * size for value in spec["envelope"])
    width, height = right - left, bottom - top

    partition_x = left + width * spec["partitionX"]
    partition_y = None
    if spec["partitionY"] is not None:
        partition_y = top + height * spec["partitionY"]

    draw = ImageDraw.Draw(image)
    if not monochrome:
        draw.rectangle((left, top, right, bottom), fill=rgb(COLORS["floor"]) + (255,))

    # Each room's own bounds, used to clip its pool.
    rooms = [
        (left, top, partition_x, bottom),
        (partition_x, top, right, partition_y if partition_y else bottom),
    ]

    for x, y, radius, core, edge, room in spec["pools"]:
        centre = (left + width * x, top + height * y)
        if monochrome:
            core = edge = COLORS["source"]
        image.alpha_composite(light_pool(size, centre, width * radius, core, edge,
                                         rooms[room], spec["ceiling"] * (0.55 if monochrome else 1.0),
                                         spec["falloff"]))
        if spec["source"] > 0:
            dot = size * spec["source"]
            ImageDraw.Draw(image).ellipse(
                (centre[0] - dot, centre[1] - dot, centre[0] + dot, centre[1] + dot),
                fill=(255, 255, 255, 240))

    # Partitions first, envelope over them: where they meet, the structural
    # line is the one that survives.
    draw = ImageDraw.Draw(image)
    wall = "white" if monochrome else rgb(COLORS["wall"]) + (255,)
    envelope = "white" if monochrome else rgb(COLORS["wallOuter"]) + (255,)
    draw.line((partition_x, top, partition_x, bottom), fill=wall,
              width=max(1, round(size * spec["wall"])))
    if partition_y is not None:
        draw.line((partition_x, partition_y, right, partition_y), fill=wall,
                  width=max(1, round(size * spec["wall"])))
    draw.rectangle((left, top, right, bottom), outline=envelope,
                   width=max(1, round(size * spec["wallOuter"])))
    return image


def svg_pool(index: int, spec: dict, pool, box) -> tuple[str, str]:
    """One pool as a radial gradient, sampling the same falloff the PNGs use.

    Ten stops is enough to be indistinguishable from the ring rendering at any
    size anyone will view the SVG at, and it keeps the file readable.
    """
    left, top, width, height = box
    x, y, radius, core, edge, room = pool
    cx, cy, r = left + width * x, top + height * y, width * radius
    inner, outer = rgb(core), rgb(edge)
    stops = []
    for step in range(11):
        t = step / 10
        colour = tuple(round(inner[k] + (outer[k] - inner[k]) * t) for k in range(3))
        alpha = (1 - t) ** spec["falloff"] * spec["ceiling"]
        stops.append(
            f'      <stop offset="{t * 100:.0f}%" stop-color="#{colour[0]:02X}{colour[1]:02X}'
            f'{colour[2]:02X}" stop-opacity="{alpha:.3f}"/>')
    gradient = (f'    <radialGradient id="pool{index}" cx="0.5" cy="0.5" r="0.5">' + NL
                + NL.join(stops) + NL + "    </radialGradient>")
    circle = (f'  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" '
              f'fill="url(#pool{index})" clip-path="url(#room{room})"/>')
    return gradient, circle


def write_svgs() -> None:
    """The mark as SVG, generated so it can never drift from the PNGs."""
    LOGO.mkdir(parents=True, exist_ok=True)
    spec = spec_for(1024)
    size = 1024
    left, top, right, bottom = (value * size for value in spec["envelope"])
    width, height = right - left, bottom - top
    px = left + width * spec["partitionX"]
    py = top + height * spec["partitionY"]
    box = (left, top, width, height)
    wall = size * spec["wall"]
    envelope = size * spec["wallOuter"]
    dot = size * spec["source"]

    rooms = [(left, top, px, bottom), (px, top, right, py)]
    clips = NL.join(
        f'    <clipPath id="room{i}"><rect x="{a:.1f}" y="{b:.1f}" '
        f'width="{c - a:.1f}" height="{d - b:.1f}"/></clipPath>'
        for i, (a, b, c, d) in enumerate(rooms))

    gradients, circles, dots = [], [], []
    for index, pool in enumerate(spec["pools"]):
        gradient, circle = svg_pool(index, spec, pool, box)
        gradients.append(gradient)
        circles.append(circle)
        x, y, *_ = pool
        dots.append(f'  <circle cx="{left + width * x:.1f}" cy="{top + height * y:.1f}" '
                    f'r="{dot:.1f}" fill="#FFFFFF" fill-opacity="0.94"/>')

    # The envelope insets by half its stroke, because Pillow draws an outline
    # inside the rectangle's bounds and SVG centres a stroke on the path.
    half = envelope / 2
    walls = (
        f'  <line x1="{px:.1f}" y1="{top:.1f}" x2="{px:.1f}" y2="{bottom:.1f}" '
        f'stroke="{{wall}}" stroke-width="{wall:.1f}"/>' + NL +
        f'  <line x1="{px:.1f}" y1="{py:.1f}" x2="{right:.1f}" y2="{py:.1f}" '
        f'stroke="{{wall}}" stroke-width="{wall:.1f}"/>' + NL +
        f'  <rect x="{left + half:.1f}" y="{top + half:.1f}" '
        f'width="{width - envelope:.1f}" height="{height - envelope:.1f}" '
        f'fill="none" stroke="{{envelope}}" stroke-width="{envelope:.1f}"/>')

    header = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
              'viewBox="0 0 1024 1024">')
    floor = (f'  <rect x="{left:.1f}" y="{top:.1f}" width="{width:.1f}" '
             f'height="{height:.1f}" fill="{COLORS["floor"]}"/>')

    colour_svg = NL.join([
        header,
        "  <defs>",
        clips,
        NL.join(gradients),
        "  </defs>",
        floor,
        NL.join(circles),
        NL.join(dots),
        walls.format(wall=COLORS["wall"], envelope=COLORS["wallOuter"]),
        "</svg>",
    ]) + NL

    def mono(ink: str) -> str:
        flat = NL.join(
            f'  <rect x="{a:.1f}" y="{b:.1f}" width="{c - a:.1f}" height="{d - b:.1f}" '
            f'fill="{ink}" fill-opacity="0.12"/>'
            for a, b, c, d in rooms)
        return NL.join([header, flat,
                        walls.format(wall=ink, envelope=ink), "</svg>"]) + NL

    (LOGO / "LumenDesk-Mark-Plan-Color.svg").write_text(colour_svg)
    (LOGO / "LumenDesk-Mark-Plan-Mono-White.svg").write_text(mono("#F4F8FE"))
    (LOGO / "LumenDesk-Mark-Plan-Mono-Black.svg").write_text(mono("#05080C"))


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1),
                                           radius=round(size * 0.225), fill=255)
    return mask


def app_icon(size: int, platform: str, appearance: str = "default") -> Image.Image:
    supersample = 4 if size <= 64 else 1
    canvas_size = size * supersample
    ground = COLORS["tinted"] if appearance == "tinted" else COLORS["stage"]

    if platform == "ios":
        canvas = Image.new("RGBA", (canvas_size, canvas_size), rgb(ground) + (255,))
        tile_origin = (0, 0)
        tile_size = canvas_size
    else:
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        inset = round(canvas_size * 0.055)
        tile_size = canvas_size - inset * 2
        tile_origin = (inset, inset)
        tile = Image.new("RGBA", (tile_size, tile_size), rgb(ground) + (255,))
        tile.putalpha(rounded_mask(tile_size))
        canvas.alpha_composite(tile, tile_origin)

    mark_size = round(tile_size * 0.80)
    # The weights are chosen for the size the icon is *seen* at, not the
    # supersampled canvas it is drawn on.
    spec = spec_for(size if size in MICRO else 1024)
    mark = draw_mark(mark_size, spec, monochrome=appearance == "tinted")

    if appearance == "dark":
        canvas.alpha_composite(Image.new("RGBA", canvas.size, (4, 6, 10, 32)))

    x = tile_origin[0] + (tile_size - mark_size) // 2
    y = tile_origin[1] + (tile_size - mark_size) // 2
    glow = mark.filter(ImageFilter.GaussianBlur(max(1, round(canvas_size * 0.008))))
    glow.putalpha(glow.getchannel("A").point(lambda alpha: round(alpha * 0.16)))
    canvas.alpha_composite(glow, (x, y))
    canvas.alpha_composite(mark, (x, y))

    if supersample > 1:
        canvas = canvas.resize((size, size), Image.Resampling.LANCZOS)
    return canvas


def main() -> None:
    for directory in (CATALOG, REPO, OPTIONAL, LOGO):
        directory.mkdir(parents=True, exist_ok=True)

    write_svgs()

    app_icon(1024, "ios").convert("RGB").save(CATALOG / "AppIcon-iOS-1024.png", optimize=True)
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

    for size in (16, 32, 64, 128, 256, 512, 1024):
        assert Image.open(CATALOG / f"AppIcon-macOS-{size}.png").size == (size, size)
    assert Image.open(CATALOG / "AppIcon-iOS-1024.png").mode == "RGB"
    print("Generated and validated LumenDesk app-icon assets.")


if __name__ == "__main__":
    main()
