#!/usr/bin/env python3
"""Generates the Espazio brand assets (Resources/Brand/*.svg).

The icon stacks three copies of the exact `NotchShape` silhouette
(Sources/EspazioUI/NotchShape.swift): outward top curves, rounded bottom corners — the notch
opening up. Monochrome only (docs/DESIGN_SYSTEM.md).

The wordmark is outlined from Inter Display SemiBold (SIL OFL), the closest open
equivalent of SF Pro Display, so the SVGs do not depend on installed fonts.
Requires: fonttools (`pip install fonttools`). Output is deterministic.
"""
import os
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "Resources", "Brand")
FONT = os.environ.get("ESPAZIO_FONT", "/usr/share/fonts/opentype/inter/InterDisplay-SemiBold.otf")

BLACK = "#000000"          # EZColor.notchBackground
SCREEN = "#F2F2F2"         # light screen surface (icon only)


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def notch_path(x, y, w, h, top, bottom):
    """Port of NotchShape.path(in:) — same clamping, same quadratic curves."""
    top = min(top, w / 4)
    bottom = min(bottom, (w - 2 * top) / 2, h / 2)
    minx, miny, maxx, maxy = x, y, x + w, y + h
    return " ".join([
        f"M{f(minx)} {f(miny)}",
        f"Q{f(minx + top)} {f(miny)} {f(minx + top)} {f(miny + top)}",
        f"L{f(minx + top)} {f(maxy - bottom)}",
        f"Q{f(minx + top)} {f(maxy)} {f(minx + top + bottom)} {f(maxy)}",
        f"L{f(maxx - top - bottom)} {f(maxy)}",
        f"Q{f(maxx - top)} {f(maxy)} {f(maxx - top)} {f(maxy - bottom)}",
        f"L{f(maxx - top)} {f(miny + top)}",
        f"Q{f(maxx - top)} {f(miny)} {f(maxx)} {f(miny)}",
        "Z",
    ])


def continuous_rect(x, y, w, h, r):
    """Rounded rectangle with continuous (squircle) corners, as SwiftUI `.continuous`."""
    k = [1.52866483, 1.08849299, 0.86840701, 0.63149399, 0.07491100, 0.37282401, 0.16905500, 0.02222201]
    a, b, c, d, e, g, i, j = (v * r for v in k)
    X, Y = x + w, y + h
    p = [f"M{f(x + a)} {f(y)}", f"L{f(X - a)} {f(y)}",
         f"C{f(X - b)} {f(y)} {f(X - c)} {f(y + j)} {f(X - d)} {f(y + e)}",
         f"C{f(X - g)} {f(y + i)} {f(X - i)} {f(y + g)} {f(X - e)} {f(y + d)}",
         f"C{f(X - j)} {f(y + c)} {f(X)} {f(y + b)} {f(X)} {f(y + a)}",
         f"L{f(X)} {f(Y - a)}",
         f"C{f(X)} {f(Y - b)} {f(X - j)} {f(Y - c)} {f(X - e)} {f(Y - d)}",
         f"C{f(X - i)} {f(Y - g)} {f(X - g)} {f(Y - i)} {f(X - d)} {f(Y - e)}",
         f"C{f(X - c)} {f(Y - j)} {f(X - b)} {f(Y)} {f(X - a)} {f(Y)}",
         f"L{f(x + a)} {f(Y)}",
         f"C{f(x + b)} {f(Y)} {f(x + c)} {f(Y - j)} {f(x + d)} {f(Y - e)}",
         f"C{f(x + g)} {f(Y - i)} {f(x + i)} {f(Y - g)} {f(x + e)} {f(Y - d)}",
         f"C{f(x + j)} {f(Y - c)} {f(x)} {f(Y - b)} {f(x)} {f(Y - a)}",
         f"L{f(x)} {f(y + a)}",
         f"C{f(x)} {f(y + b)} {f(x + j)} {f(y + c)} {f(x + e)} {f(y + d)}",
         f"C{f(x + i)} {f(y + g)} {f(x + g)} {f(y + i)} {f(x + d)} {f(y + e)}",
         f"C{f(x + c)} {f(y + j)} {f(x + b)} {f(y)} {f(x + a)} {f(y)}", "Z"]
    return " ".join(p)


def svg(w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(w)} {f(h)}" '
            f'width="{f(w)}" height="{f(h)}" role="img" aria-label="{title}">\n'
            f"<title>{title}</title>\n{body}</svg>\n")


# Nested notch silhouettes, largest to smallest: expanded → peek → collapsed.
ICON_BANDS = [(760, 560, 40, 170), (560, 390, 36, 130), (340, 230, 30, 90)]


def icon_layers(dark, uid="body"):
    """Defs and body of the app icon in the 1024 grid (body 100..924)."""
    bx, by, bs, br = 100, 100, 824, 185.4
    body_path = continuous_rect(bx, by, bs, bs, br)
    if dark:
        bg, colors, stroke = BLACK, ["#2E2E2E", "#8A8A8A", "#FFFFFF"], "#FFFFFF"
    else:
        bg, colors, stroke = SCREEN, ["#D2D2D2", "#8A8A8A", BLACK], BLACK
    bands = "".join(
        f'  <path d="{notch_path(512 - w / 2, by, w, h, t, b)}" fill="{c}"/>\n'
        for (w, h, t, b), c in zip(ICON_BANDS, colors))
    defs = f'<clipPath id="{uid}"><path d="{body_path}"/></clipPath>'
    body = (f'<path d="{body_path}" fill="{bg}"/>\n'
            f'<g clip-path="url(#{uid})">\n{bands}</g>\n'
            f'<path d="{body_path}" fill="none" stroke="{stroke}" stroke-opacity="0.10" stroke-width="2"/>\n')
    return defs, body


def app_icon(dark):
    """Three nested NotchShape silhouettes hanging from the top edge: the notch opening up
    (collapsed → peek → expanded). Flat greys only. macOS grid: 1024 canvas, 824 body,
    continuous corner ≈ 185."""
    defs, body = icon_layers(dark)
    return svg(1024, 1024, f"<defs>{defs}</defs>\n{body}", "Espazio")


def horizontal_logo(on_dark):
    """App icon tile + "Espazio". Dark icon and black text for light backgrounds; light
    icon and white text for dark backgrounds (the dark tile would vanish on black)."""
    size = 120                      # font size
    cap = 0.73 * size               # Inter Display cap height
    tile = 1.42 * cap               # icon body height
    k = tile / 824
    gap = 0.30 * tile
    pad = 2
    baseline = pad + tile / 2 + cap / 2
    text, tw = wordmark_path("Espazio", pad + tile + gap, baseline, size)
    W, H = pad + tile + gap + tw + pad, tile + 2 * pad
    defs, body = icon_layers(dark=not on_dark, uid="tile")
    color = "#FFFFFF" if on_dark else BLACK
    return svg(W, H, (
        f"<defs>{defs}</defs>\n"
        f'<g transform="translate({f(pad - 100 * k)} {f(pad - 100 * k)}) scale({k:.6f})">\n{body}</g>\n'
        f'<path d="{text}" fill="{color}"/>\n'
    ), "Espazio")


def menu_bar_icon():
    """Template image for the menu bar (22×16 pt): the two outer notch layers of the app icon,
    simplified for 16–18 pt. Pure black on transparent; macOS tints it (isTemplate)."""
    w, h = 22, 16
    outer = notch_path(1, 0, 20, 15, 2.2, 5.2)
    inner = notch_path(5.5, 0, 11, 8.2, 1.6, 3.4)
    body = (f'<path d="{outer}" fill="none" stroke="{BLACK}" stroke-width="1.6" stroke-linejoin="round"/>\n'
            f'<path d="{inner}" fill="{BLACK}"/>\n'
            f'<rect x="0" y="0" width="{w}" height="1.4" fill="{BLACK}"/>\n')
    return svg(w, h, body, "Espazio")


def dmg_background():
    """DMG window background (660×400 pt): horizontal logo, app slot → arrow → Applications.
    Icon positions must match scripts/dmg-settings.py (app at x=180, Applications at x=480, y=230)."""
    W, H = 660, 400
    logo = horizontal_logo(on_dark=False)
    vb = logo.split('viewBox="0 0 ')[1].split('"')[0].split()
    lw, lh = float(vb[0]), float(vb[1])
    scale = 34 / lh
    inner = logo.split("</title>\n", 1)[1].rsplit("</svg>", 1)[0].replace('id="tile"', 'id="dmgtile"').replace("url(#tile)", "url(#dmgtile)")
    x0 = (W - lw * scale) / 2
    arrow_y = 230
    body = (f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>\n'
            f'<g transform="translate({f(x0)} 48) scale({scale:.6f})">\n{inner}</g>\n'
            f'<path d="M262 {arrow_y} L392 {arrow_y}" stroke="#8A8A8A" stroke-width="3" stroke-linecap="round"/>\n'
            f'<path d="M380 {arrow_y - 11} L396 {arrow_y} L380 {arrow_y + 11}" fill="none" stroke="#8A8A8A" '
            f'stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>\n'
            f'<text x="{W / 2}" y="352" text-anchor="middle" font-family="-apple-system, Helvetica, sans-serif" '
            f'font-size="13" fill="#8A8A8A">Glissez Espazio dans Applications</text>\n')
    return svg(W, H, body, "Installer Espazio")


def wordmark_path(text, x, baseline, size):
    font = TTFont(FONT)
    gs = font.getGlyphSet()
    cmap = font.getBestCmap()
    upm = font["head"].unitsPerEm
    sc = size / upm
    tracking = -0.01 * upm
    pen = SVGPathPen(gs)
    cursor = 0
    for ch in text:
        name = cmap[ord(ch)]
        tp = TransformPen(pen, (sc, 0, 0, -sc, x + cursor * sc, baseline))
        gs[name].draw(tp)
        cursor += gs[name].width + tracking
    return pen.getCommands(), (cursor - tracking) * sc


def main():
    if not os.path.exists(FONT):
        sys.exit(f"Police introuvable : {FONT} (définir ESPAZIO_FONT)")
    os.makedirs(OUT, exist_ok=True)
    files = {
        "AppIcon.svg": app_icon(dark=True),
        "AppIcon-Light.svg": app_icon(dark=False),
        "Logo-Horizontal.svg": horizontal_logo(on_dark=False),
        "Logo-Horizontal-White.svg": horizontal_logo(on_dark=True),
        "MenuBarIcon.svg": menu_bar_icon(),
        "DMGBackground.svg": dmg_background(),
    }
    for name, content in files.items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as fh:
            fh.write(content)
        print("wrote", os.path.relpath(os.path.join(OUT, name), ROOT))


if __name__ == "__main__":
    main()
