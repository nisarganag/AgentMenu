#!/usr/bin/env python3
"""Generate AgentMenu.icns.

The icon is the app's own signature visual: three segmented meters in the three
agent accent colours (Claude coral, Codex blue, opencode green), at different
fill levels so it reads as a live monitor rather than a static logo.

Drawn 4x oversampled and downsampled for clean antialiasing. Follows the
macOS Big Sur+ grid: 1024 canvas, ~824 squircle, ~185 corner radius.
"""
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4                      # supersample factor
C = 1024 * S               # canvas
BODY = 824 * S             # icon shape
RAD = 185 * S              # corner radius
OFF = (C - BODY) // 2

# Palette — the app's dark-mode accents, verbatim from Theme.swift
BG_TOP    = (32, 35, 41)
BG_BOTTOM = (18, 20, 24)
CLAUDE    = (232, 132, 92)
CODEX     = (111, 194, 232)
OPENCODE  = (91, 217, 138)
# Pre-blended: 9% white over the body gradient. ImageDraw REPLACES pixels
# rather than compositing, so an alpha fill here would punch a hole, not tint.
EMPTY     = (46, 49, 55)


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size[1]))
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        grad.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize(size, Image.BILINEAR)


def squircle_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def build():
    img = Image.new("RGBA", (C, C), (0, 0, 0, 0))

    # body: subtle vertical gradient inside a squircle
    body = vertical_gradient((BODY, BODY), BG_TOP, BG_BOTTOM).convert("RGBA")
    body.putalpha(squircle_mask((BODY, BODY), RAD))
    img.alpha_composite(body, (OFF, OFF))

    # a soft inner top highlight, the way real macOS icons catch light
    hi = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
    ImageDraw.Draw(hi).rounded_rectangle(
        [0, 0, BODY - 1, BODY - 1], radius=RAD, outline=(255, 255, 255, 38), width=3 * S)
    hi = hi.filter(ImageFilter.GaussianBlur(2 * S))
    hi.putalpha(Image.eval(hi.split()[3], lambda a: a))
    img.alpha_composite(hi, (OFF, OFF))

    d = ImageDraw.Draw(img)

    # three segmented meters — one per agent, differing fill = "live"
    bars = [(CLAUDE, 5), (CODEX, 7), (OPENCODE, 3)]
    segs = 7
    bar_w = 132 * S
    gap = 68 * S
    seg_h = 52 * S
    seg_gap = 20 * S
    seg_r = 14 * S

    total_w = len(bars) * bar_w + (len(bars) - 1) * gap
    x0 = (C - total_w) // 2
    stack_h = segs * seg_h + (segs - 1) * seg_gap
    y_bottom = (C + stack_h) // 2

    for i, (colour, filled) in enumerate(bars):
        bx = x0 + i * (bar_w + gap)
        for s in range(segs):
            y1 = y_bottom - s * (seg_h + seg_gap)
            y0 = y1 - seg_h
            lit = s < filled
            d.rounded_rectangle(
                [bx, y0, bx + bar_w, y1], radius=seg_r,
                fill=(*colour, 255) if lit else (*EMPTY, 255))

    # glow under the lit segments so it reads as emitting, not painted
    glow = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i, (colour, filled) in enumerate(bars):
        bx = x0 + i * (bar_w + gap)
        top_y = y_bottom - (filled - 1) * (seg_h + seg_gap) - seg_h
        gd.rounded_rectangle([bx, top_y, bx + bar_w, y_bottom], radius=seg_r,
                             fill=(*colour, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(22 * S))
    img.alpha_composite(glow)

    # redraw the lit segments over the glow so edges stay crisp
    for i, (colour, filled) in enumerate(bars):
        bx = x0 + i * (bar_w + gap)
        for s in range(filled):
            y1 = y_bottom - s * (seg_h + seg_gap)
            d.rounded_rectangle([bx, y1 - seg_h, bx + bar_w, y1], radius=seg_r,
                                fill=(*colour, 255))

    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    master = build()
    png = os.path.join(here, "AppIcon-1024.png")
    master.save(png)

    iconset = os.path.join(here, "AppIcon.iconset")
    subprocess.run(["rm", "-rf", iconset], check=True)
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        master.resize((size, size), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{size}x{size}.png"))
        master.resize((size * 2, size * 2), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{size}x{size}@2x.png"))

    icns = os.path.join(here, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    subprocess.run(["rm", "-rf", iconset], check=True)
    print(f"wrote {icns} ({os.path.getsize(icns)} bytes)")
    print(f"wrote {png}")


if __name__ == "__main__":
    sys.exit(main())
