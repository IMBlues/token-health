#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "AppSupport"
PNG_1024 = SUPPORT / "TokenHealth-1024.png"
ICONSET = SUPPORT / "TokenHealth.iconset"
ICNS = SUPPORT / "TokenHealth.icns"


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def draw_icon(size: int = 1024) -> Image.Image:
    scale = size / 1024
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = rounded_rect_mask(size, int(225 * scale))

    base = Image.new("RGBA", (size, size), (246, 248, 250, 255))
    base_draw = ImageDraw.Draw(base)
    base_draw.rounded_rectangle(
        (int(18 * scale), int(18 * scale), int(1006 * scale), int(1006 * scale)),
        radius=int(210 * scale),
        outline=(224, 228, 232, 255),
        width=int(4 * scale),
    )
    icon.alpha_composite(Image.composite(base, Image.new("RGBA", (size, size)), mask))

    draw = ImageDraw.Draw(icon)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        [int(226 * scale), int(214 * scale), int(798 * scale), int(810 * scale)],
        radius=int(190 * scale),
        fill=(38, 53, 68, 24),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(20 * scale)))
    icon.alpha_composite(shadow)

    ring_box = [int(224 * scale), int(224 * scale), int(800 * scale), int(800 * scale)]
    draw.ellipse(ring_box, outline=(40, 47, 55, 255), width=int(42 * scale))

    needle = [
        (int(320 * scale), int(535 * scale)),
        (int(415 * scale), int(535 * scale)),
        (int(462 * scale), int(410 * scale)),
        (int(548 * scale), int(660 * scale)),
        (int(604 * scale), int(488 * scale)),
        (int(706 * scale), int(488 * scale)),
    ]
    draw.line(needle, fill=(40, 47, 55, 255), width=int(42 * scale), joint="curve")

    accent = [
        (int(556 * scale), int(638 * scale)),
        (int(604 * scale), int(488 * scale)),
        (int(706 * scale), int(488 * scale)),
    ]
    draw.line(accent, fill=(31, 142, 255, 255), width=int(20 * scale), joint="curve")

    dot_r = int(31 * scale)
    dot = (int(708 * scale), int(488 * scale))
    draw.ellipse(
        [dot[0] - dot_r, dot[1] - dot_r, dot[0] + dot_r, dot[1] + dot_r],
        fill=(31, 142, 255, 255),
    )

    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.rounded_rectangle(
        [int(92 * scale), int(70 * scale), int(932 * scale), int(390 * scale)],
        radius=int(150 * scale),
        fill=(255, 255, 255, 44),
    )
    highlight = Image.composite(highlight, Image.new("RGBA", (size, size)), mask)
    icon.alpha_composite(highlight)
    return icon


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
    image = draw_icon()
    image.save(PNG_1024)
    write_iconset(image)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(ICNS)


if __name__ == "__main__":
    main()
