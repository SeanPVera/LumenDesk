#!/usr/bin/env python3
"""Audit the lighting theme catalog and regenerate THEME_CATALOG.md.

The script reads LumenDesk/Models/LightingCatalog.swift directly, so it can
never drift from the shipping data the way a hand-kept copy would. It checks
the palette properties that matter for emitted light rather than for a screen
swatch:

  * every theme is uniquely identified and named
  * no two themes ship the same palette, and no pair sits so close in
    hue/saturation/value that a room could not tell them apart
  * an even-wash theme leads with its brightest colour, because that colour
    fills the whole room and the theme's brightness has to mean what it says
  * palettes span warm and cool, bright and low, saturated and restrained,
    rather than clustering into forty-eight variations on one idea

Scope: this validates catalog *data*. The placement engine that turns a theme
into per-fixture commands lives in Swift and is covered by
LumenDeskTests/LightingThemeTests.swift, which runs on macOS in CI. Nothing is
duplicated between the two.

Usage:
    python3 scripts/audit_lighting_themes.py            # audit only
    python3 scripts/audit_lighting_themes.py --write    # audit and write docs
"""

from __future__ import annotations

import argparse
import colorsys
import itertools
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "LumenDesk" / "Models" / "LightingCatalog.swift"
DOC = ROOT / "THEME_CATALOG.md"

ORIGINAL_IDS = {
    "aurora", "afterglow", "tidepool", "forest-bath", "wildflowers", "moon-garden",
    "ember", "candy-cloud", "synthwave", "arcade", "festival", "ice-cream",
    "deep-work", "reading-nook", "creative-spark", "calm", "desert", "galaxy",
}

ROW = re.compile(
    r'add\("(?P<id>[^"]+)",\s*"(?P<name>[^"]+)",\s*"(?P<summary>[^"]*)",\s*'
    r'\.(?P<category>\w+),\s*"(?P<icon>[^"]*)",\s*\[(?P<colors>[^\]]*)\],\s*'
    r'(?P<brightness>[0-9.]+),\s*\.(?P<distribution>\w+)\)'
)

DISTRIBUTION_SUMMARY = {
    "wash": "One colour fills the room; strips carry a faint second tone.",
    "anchored": "One colour holds the room; the others appear as accents.",
    "gradient": "The palette ramps in order across the room and along strips.",
    "alternating": "Colours change from fixture to fixture in even blocks.",
    "scattered": "Colours spread so neighbouring fixtures never match.",
}

FAMILY_ORDER = [
    ("warmth", "Warm and intimate"),
    ("nature", "Natural and atmospheric"),
    ("atmosphere", "Natural and atmospheric"),
    ("jewel", "Jewel-toned and dramatic"),
    ("nightlife", "Neon and nightlife"),
    ("celebration", "Neon and nightlife"),
    ("dreamy", "Soft and dreamy"),
    ("focus", "Restrained everyday"),
    ("everyday", "Restrained everyday"),
]


class Theme:
    def __init__(self, match: re.Match[str]) -> None:
        self.id = match["id"]
        self.name = match["name"]
        self.summary = match["summary"]
        self.category = match["category"]
        self.icon = match["icon"]
        self.brightness = float(match["brightness"])
        self.distribution = match["distribution"]
        self.colors = [int(c.strip(), 16) for c in match["colors"].split(",")]
        self.is_new = self.id not in ORIGINAL_IDS

    # --- colour maths, mirroring PaletteTone ---

    def hsv(self) -> list[tuple[float, float, float]]:
        out = []
        for hexv in self.colors:
            r, g, b = rgb(hexv)
            out.append(colorsys.rgb_to_hsv(r, g, b))
        return out

    def levels(self) -> list[float]:
        """Values normalised against the palette's brightest entry, floored the
        way LightingTheme.normalizedTones floors them."""
        values = [v for _, _, v in self.hsv()]
        peak = max(values) or 1.0
        return [max(0.2, v / peak) for v in values]

    def emitted(self) -> list[float]:
        """Relative light output per entry once the theme's brightness applies."""
        return [level * self.brightness for level in self.levels()]

    def mean_luminance(self) -> float:
        return sum(luminance(c) for c in self.colors) / len(self.colors)

    def mean_saturation(self) -> float:
        return sum(s for _, s, _ in self.hsv()) / len(self.colors)

    def warmth(self) -> float:
        """Positive leans warm (red/amber), negative leans cool (cyan/blue)."""
        return sum(rgb(c)[0] - rgb(c)[2] for c in self.colors) / len(self.colors)

    def shares(self, room: int = 8) -> list[float]:
        """Mirrors LightingTheme.distributionShares for the catalog table."""
        count = len(self.colors)
        if count < 2:
            return [1.0]
        room = max(count, room)
        if self.distribution == "gradient":
            counts = [1.0] * count
        else:
            counts = [0.0] * count
            for position in range(room):
                counts[palette_index(self.distribution, position, count)] += 1
        raw = [max(0.06, c / room) for c in counts]
        total = sum(raw)
        return [value / total for value in raw]


def rgb(hexv: int) -> tuple[float, float, float]:
    return ((hexv >> 16 & 255) / 255, (hexv >> 8 & 255) / 255, (hexv & 255) / 255)


def luminance(hexv: int) -> float:
    def channel(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = rgb(hexv)
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def palette_index(distribution: str, position: int, count: int) -> int:
    """Mirrors ThemeDistribution.paletteIndex for table generation only."""
    if count < 2:
        return 0
    if distribution == "wash":
        return 0
    if distribution == "alternating":
        return position % count
    if distribution == "anchored":
        if position % 3 != 1:
            return 0
        return 1 + ((position // 3) % (count - 1))
    if distribution == "scattered":
        rotation = 0 if count <= 2 else (1 if count == 3 else 2)
        return (position + (position // count) * rotation) % count
    return min(count - 1, position % count)


def separation(a: Theme, b: Theme) -> float:
    """Symmetric mean nearest-neighbour distance between two palettes in a
    cylindrical hue/saturation/value space. Higher means easier to tell apart
    when the two are lit in the same room."""

    def points(theme: Theme) -> list[tuple[float, float, float]]:
        out = []
        for h, s, v in theme.hsv():
            out.append((s * math.cos(h * 2 * math.pi), s * math.sin(h * 2 * math.pi), v))
        return out

    left, right = points(a), points(b)

    def half(xs, ys):
        return sum(min(math.dist(x, y) for y in ys) for x in xs) / len(xs)

    return (half(left, right) + half(right, left)) / 2


def parse() -> list[Theme]:
    source = CATALOG.read_text(encoding="utf-8")
    themes = [Theme(m) for m in ROW.finditer(source)]
    declared = source.count('        add("')
    if len(themes) != declared:
        raise SystemExit(f"parsed {len(themes)} rows but the file declares {declared}")
    return themes


def audit(themes: list[Theme]) -> list[str]:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    check(len(themes) == 48, f"expected 48 themes, found {len(themes)}")
    check(len({t.id for t in themes}) == len(themes), "duplicate theme identifier")
    check(len({t.name for t in themes}) == len(themes), "duplicate theme name")

    present = {t.id for t in themes}
    missing = ORIGINAL_IDS - present
    check(not missing, f"original theme identifiers dropped: {sorted(missing)}")

    added = [t for t in themes if t.is_new]
    check(len(added) == 30, f"expected 30 new themes, found {len(added)}")

    for family in ("warmth", "nature", "jewel", "nightlife", "dreamy", "everyday"):
        count = len([t for t in added if t.category == family])
        check(count == 5, f"mood family {family} carries {count} new themes, expected 5")

    seen: dict[frozenset[int], str] = {}
    for theme in themes:
        key = frozenset(theme.colors)
        if key in seen:
            failures.append(f"{theme.id} ships the same palette as {seen[key]}")
        seen[key] = theme.id

    for theme in themes:
        check(3 <= len(theme.colors) <= 5,
              f"{theme.id} has {len(theme.colors)} colours; 3-5 keeps a room legible")
        check(0.05 <= theme.brightness <= 1.0, f"{theme.id} brightness {theme.brightness} out of range")
        check(bool(theme.summary), f"{theme.id} has no summary")
        check(theme.distribution in DISTRIBUTION_SUMMARY, f"{theme.id} has an unknown distribution")
        check(min(theme.levels()) >= 0.2, f"{theme.id} has an entry that emits nothing")
        if theme.distribution == "wash":
            values = [v for _, _, v in theme.hsv()]
            ratio = values[0] / max(values)
            check(ratio >= 0.85,
                  f"{theme.id} washes the room with a colour at {ratio:.0%} of its own palette peak")

    # Nothing should be a near-duplicate of anything else. Pale, low-chroma
    # palettes legitimately cluster near the achromatic axis, so a tight pair
    # passes when it is clearly separated on warmth or on output instead.
    for a, b in itertools.combinations(themes, 2):
        gap = separation(a, b)
        if gap >= 0.10:
            continue
        warm_gap = abs(a.warmth() - b.warmth())
        lum_gap = abs(a.mean_luminance() - b.mean_luminance())
        bright_gap = abs(a.brightness - b.brightness)
        if warm_gap >= 0.08 or lum_gap >= 0.10 or bright_gap >= 0.15:
            continue
        failures.append(
            f"{a.id} and {b.id} are near-duplicates "
            f"(gap {gap:.3f}, warmth {warm_gap:.2f}, luminance {lum_gap:.2f}, output {bright_gap:.2f})"
        )

    # A catalog that is all one temperature, or all one output level, is not a
    # balanced collection however many rows it has.
    warm = [t for t in themes if t.warmth() > 0.12]
    cool = [t for t in themes if t.warmth() < -0.05]
    check(len(warm) >= 12, f"only {len(warm)} warm-leaning themes")
    check(len(cool) >= 8, f"only {len(cool)} cool-leaning themes")
    check(len([t for t in themes if t.brightness <= 0.4]) >= 6, "too few low-output themes")
    check(len([t for t in themes if t.brightness >= 0.75]) >= 6, "too few high-output themes")
    check(len([t for t in themes if t.mean_saturation() <= 0.30]) >= 8,
          "too few restrained, low-saturation themes")
    check(len({t.distribution for t in themes}) == 5, "not every distribution is used")

    # The README prints a count per mood. A table that drifts from the catalog
    # is worse than no table, so hold it to the data.
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for line in readme.splitlines():
        row = re.match(r"\|\s*(\w+)\s*\|\s*(\d+)\s*\|", line)
        if not row:
            continue
        category = row[1].lower()
        if category not in {t.category for t in themes}:
            continue
        actual = len([t for t in themes if t.category == category])
        check(int(row[2]) == actual,
              f"README says {category} has {row[2]} themes; the catalog has {actual}")
    check(f"includes {len(themes)} curated static themes" in readme,
          "README does not state the current theme count")
    return failures


def document(themes: list[Theme]) -> str:
    lines: list[str] = []
    add = lines.append
    add("# LumenDesk theme catalog")
    add("")
    add("Generated by `scripts/audit_lighting_themes.py` from")
    add("`LumenDesk/Models/LightingCatalog.swift`. Do not hand-edit: the next run")
    add("overwrites it.")
    add("")
    add(f"{len(themes)} themes. **Output** is the theme's overall brightness. **Spread**")
    add("is how the palette is meant to land across a room and along a strip.")
    add("**Distribution** shows each colour's share of the fixtures at that spread.")
    add("")
    add("Palettes are authored as chroma plus level. The colour travels to the light at")
    add("full value and the level rides the brightness channel, so a LIFX bulb and a")
    add("Govee bulb given the same entry emit the same thing.")
    add("")

    families: dict[str, list[Theme]] = {}
    for key, label in FAMILY_ORDER:
        families.setdefault(label, [])
    for theme in themes:
        label = dict(FAMILY_ORDER).get(theme.category, theme.category.title())
        families.setdefault(label, []).append(theme)

    add("## Contents")
    add("")
    for label, group in families.items():
        if group:
            add(f"- [{label}](#{label.lower().replace(' ', '-')}) — {len(group)} themes")
    add("")

    for label, group in families.items():
        if not group:
            continue
        add(f"## {label}")
        add("")
        add("| Theme | Mood | Output | Spread | Palette | Distribution |")
        add("| --- | --- | --- | --- | --- | --- |")
        for theme in sorted(group, key=lambda t: (not t.is_new, t.name)):
            swatches = " ".join(f"`#{c:06X}`" for c in theme.colors)
            shares = " / ".join(f"{s:.0%}" for s in theme.shares())
            flag = "" if theme.is_new else " *(existing)*"
            add(f"| **{theme.name}**{flag}<br>`{theme.id}` | {theme.summary} "
                f"| {theme.brightness:.0%} | {theme.distribution} | {swatches} | {shares} |")
        add("")

    add("## How a spread behaves")
    add("")
    add("| Spread | Across the room | Inside one strip or matrix |")
    add("| --- | --- | --- |")
    add("| `wash` | Every fixture takes the key colour | The second colour breathes through "
        "the middle at low contrast |")
    add("| `anchored` | The key colour holds roughly two thirds; accents take the rest "
        "| Short accent runs against a key-coloured field |")
    add("| `gradient` | The palette ramps in order from the first fixture to the last "
        "| A smooth ramp, quantised to at most 16 stops |")
    add("| `alternating` | Colours change fixture by fixture | Even blocks, two full cycles "
        "down the strip |")
    add("| `scattered` | No two neighbouring fixtures match | Block-sized spread, phase-offset "
        "per fixture |")
    add("")

    add("## Light character")
    add("")
    add("Mean relative luminance, mean saturation, and warm/cool bias of each palette, "
        "before the theme's own output is applied.")
    add("")
    add("| Theme | Luminance | Saturation | Warm ← → Cool | Lowest entry output |")
    add("| --- | --- | --- | --- | --- |")
    for theme in sorted(themes, key=lambda t: -t.warmth()):
        bias = theme.warmth()
        arrow = "warm" if bias > 0.12 else ("cool" if bias < -0.05 else "neutral")
        add(f"| {theme.name} | {theme.mean_luminance():.2f} | {theme.mean_saturation():.2f} "
            f"| {bias:+.2f} {arrow} | {min(theme.emitted()):.0%} |")
    add("")

    # CI runs `git diff --check`, which rejects a blank line at end of file.
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="regenerate THEME_CATALOG.md")
    args = parser.parse_args()

    themes = parse()
    failures = audit(themes)

    print(f"parsed {len(themes)} themes from {CATALOG.relative_to(ROOT)}")
    print(f"  {len([t for t in themes if t.is_new])} new, "
          f"{len([t for t in themes if not t.is_new])} pre-existing")
    print(f"  distributions in use: {sorted({t.distribution for t in themes})}")
    pairs = sorted((separation(a, b), a.id, b.id) for a, b in itertools.combinations(themes, 2))
    print("  five closest palette pairs:")
    for gap, left, right in pairs[:5]:
        print(f"    {gap:.3f}  {left} / {right}")

    if failures:
        print("\nFAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("\nall catalog checks passed")
    if args.write:
        DOC.write_text(document(themes), encoding="utf-8")
        print(f"wrote {DOC.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
