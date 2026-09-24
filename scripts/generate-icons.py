#!/usr/bin/env python3
"""Build Token Health's app icon, menu bar mark and appearance variants.

The drawing lives in AppSupport/GourdBrand/gourd-transparent.png: a gourd tipped
over, a ribbon knotted at its mouth, white liquid standing at a level. Nothing
here draws it — this script frames it and paints the tile underneath.

Three things come out of it:
  * AppSupport/TokenHealth.icns (+ the 1024 master) — the icon Finder and the DMG
    show, on a cool mid-grey tile so both the black line and the white liquid read.
  * Sources/.../TokenHealthMark.png — the gourd alone as a template image for the
    menu bar, where macOS tints it for light and dark bars by itself.
  * Sources/.../TokenHealthIcon{Light,Dark}.png — the same icon tinted for both
    appearances; the dark one is the light one with the ink reversed to white.

Apple's grid: an 824 pt body centred on a 1024 canvas, with a continuous corner
(a superellipse of exponent ~5.3, which fits Apple's corner path far better than
a circular arc).

Requires Pillow and NumPy.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "AppSupport"
RESOURCES = ROOT / "Sources/TokenHealth/Resources"
ARTWORK = SUPPORT / "GourdBrand/gourd-transparent.png"
PNG_1024 = SUPPORT / "TokenHealth-1024.png"
ICONSET = SUPPORT / "TokenHealth.iconset"
ICNS = SUPPORT / "TokenHealth.icns"
MENU_MARK = RESOURCES / "TokenHealthMark.png"
ICON_LIGHT = RESOURCES / "TokenHealthIconLight.png"
ICON_DARK = RESOURCES / "TokenHealthIconDark.png"

CANVAS = 1024
BODY = 824           # Apple's icon grid: an 824x824 body, centred
SQUIRCLE_N = 5.3
ART_FILL = 0.86      # how much of the tile the drawing takes up
INK_CUTOFF = 110     # luma below this is ink, and gets reversed for the dark icon
MENU_MARK_SIZE = 72  # 4x the 18 pt menu bar mark

# Cool grey, mid lightness: black line and white liquid both stay readable.
TILE_LIGHT = ("#B9C0CA", "#98A2B0")
TILE_DARK = ("#2B313B", "#161A20")


def rgb(spec: str) -> np.ndarray:
    spec = spec.lstrip("#")
    return np.array([int(spec[i : i + 2], 16) for i in (0, 2, 4)], np.float32)


def squircle_path(size: int, steps: int = 2048) -> list[tuple[float, float]]:
    a = size / 2
    t = np.linspace(0, 2 * np.pi, steps, endpoint=False)
    ct, st = np.cos(t), np.sin(t)
    xs = a + a * np.sign(ct) * np.abs(ct) ** (2 / SQUIRCLE_N)
    ys = a + a * np.sign(st) * np.abs(st) ** (2 / SQUIRCLE_N)
    return list(zip(xs, ys))


def squircle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(squircle_path(size), fill=255)
    return mask


def load_artwork() -> Image.Image:
    """The drawing, cropped to its own ink."""
    art = Image.open(ARTWORK).convert("RGBA")
    box = art.getchannel("A").getbbox()
    if box is None:
        raise ValueError(f"{ARTWORK} has no opaque pixels to draw")
    return art.crop(box)


def fit_into(art: Image.Image, side: int) -> Image.Image:
    """Scale to fit a `side` box, keeping the aspect ratio."""
    scale = side / max(art.width, art.height)
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    return art.resize(size, Image.Resampling.LANCZOS)


def reversed_ink(art: Image.Image) -> Image.Image:
    """The dark tile's turn: black line to white, and the liquid a shade down.

    If the liquid stayed pure white it would fuse with the white contour and the
    lower half of the gourd would read as one blob.
    """
    arr = np.asarray(art).copy()
    luma = arr[..., :3].astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    opaque = arr[..., 3] > 0
    ink = opaque & (luma < INK_CUTOFF)
    liquid = opaque & ~ink
    arr[ink, 0:3] = rgb("#FFFFFF")
    arr[liquid, 0:3] = rgb("#D6DDE8")
    return Image.fromarray(arr, "RGBA")


def tile_background(dark: bool, size: int) -> Image.Image:
    top, bottom = TILE_DARK if dark else TILE_LIGHT
    y = np.mgrid[0:size, 0:size][0].astype(np.float32) / max(1, size - 1)
    ramp = rgb(bottom)[None, None, :] * y[..., None] + rgb(top)[None, None, :] * (1 - y[..., None])
    return Image.fromarray(ramp.astype(np.uint8), "RGB").convert("RGBA")


def render_icon(dark: bool = False) -> Image.Image:
    """The icon on Apple's grid: tile, drawing, rounded corner."""
    art = load_artwork()
    if dark:
        art = reversed_ink(art)
    art = fit_into(art, round(BODY * ART_FILL))

    body = tile_background(dark, BODY)
    body.alpha_composite(art, ((BODY - art.width) // 2, (BODY - art.height) // 2))
    body.putalpha(ImageChops.multiply(body.getchannel("A"), squircle_mask(BODY)))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(body, ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2), body)
    return canvas


def render_menu_mark(size: int = MENU_MARK_SIZE) -> Image.Image:
    """The gourd alone, as a template: alpha carries the shape, macOS tints it.

    Template images are tinted by the system, so one asset covers the light and
    the dark menu bar.
    """
    art = load_artwork()
    art = fit_into(art, size)
    mark = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mark.paste((0, 0, 0, 255), ((size - art.width) // 2, (size - art.height) // 2), art)
    return mark


def write_iconset(source: Image.Image) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for name, size in specs:
        source.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / name)


def main() -> None:
    SUPPORT.mkdir(parents=True, exist_ok=True)
    RESOURCES.mkdir(parents=True, exist_ok=True)

    light = render_icon(dark=False)
    dark = render_icon(dark=True)
    light.save(PNG_1024)
    light.save(ICON_LIGHT)
    dark.save(ICON_DARK)
    write_iconset(light)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    render_menu_mark().save(MENU_MARK)

    print(ICNS)
    print(MENU_MARK)
    print(ICON_LIGHT)
    print(ICON_DARK)


if __name__ == "__main__":
    main()
