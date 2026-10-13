#!/usr/bin/env python3
"""Generates the Espazio brand assets (Resources/Brand/*.svg).

The mark reuses the exact silhouette of `NotchShape` (Sources/EspazioUI/NotchShape.swift):
outward top curves merging into the screen edge, rounded bottom corners. Inside, the
"peek" state: an icon on the left, a monochrome progress bar on the right
(EZProgressBar: track white 18 %, fill white). Monochrome only (docs/DESIGN_SYSTEM.md).

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
RAISED = "#1C1C1C"         # EZColor.notchRaised (white 0.11)
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


def capsule(x, y, w, h):
    r = h / 2
    return (f"M{f(x + r)} {f(y)} H{f(x + w - r)} A{f(r)} {f(r)} 0 0 1 {f(x + w - r)} {f(y + h)} "
            f"H{f(x + r)} A{f(r)} {f(r)} 0 0 1 {f(x + r)} {f(y)} Z")


def circle(cx, cy, r):
    return (f"M{f(cx - r)} {f(cy)} A{f(r)} {f(r)} 0 1 0 {f(cx + r)} {f(cy)} "
            f"A{f(r)} {f(r)} 0 1 0 {f(cx - r)} {f(cy)} Z")


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


def peek(x, y, w, h, top, scale):
    """Peek content inside a notch: icon (dot) left, progress bar right."""
    inner_l, inner_r = x + top, x + w - top
    cy = y + h * 0.54
    dot = circle(inner_l + 64 * scale, cy, 26 * scale)
    bar_w, bar_h = 132 * scale, 22 * scale
    bar_x = inner_r - 64 * scale - bar_w
    track = capsule(bar_x, cy - bar_h / 2, bar_w, bar_h)
    fill = capsule(bar_x, cy - bar_h / 2, bar_w * 0.62, bar_h)
    return dot, track, fill


def svg(w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(w)} {f(h)}" '
            f'width="{f(w)}" height="{f(h)}" role="img" aria-label="{title}">\n'
            f"<title>{title}</title>\n{body}</svg>\n")


def app_icon(dark):
    """A display seen from the front: black bezel, screen, notch dropping from the bezel.
    The NotchShape top curves merge into the bezel exactly as the real notch merges into the
    menu bar. macOS grid: 1024 canvas, 824 body, continuous corner ≈ 185."""
    bx, by, bs, br = 100, 100, 824, 185.4
    inset = 40
    sx, sy, ss, sr = bx + inset, by + inset, bs - 2 * inset, 72
    nw, nh, nt, nb = 480, 220, 30, 76
    nx = 512 - nw / 2
    body_path = continuous_rect(bx, by, bs, bs, br)
    screen_path = continuous_rect(sx, sy, ss, ss, sr)
    dot, track, fill = peek(nx, sy, nw, nh, nt, 1.0)
    screen = RAISED if dark else SCREEN
    return svg(1024, 1024, (
        f'<defs><clipPath id="screen"><path d="{screen_path}"/></clipPath></defs>\n'
        f'<path d="{body_path}" fill="{BLACK}"/>\n'
        f'<path d="{screen_path}" fill="{screen}"/>\n'
        f'<g clip-path="url(#screen)">\n'
        f'  <path d="{notch_path(nx, sy - 0.5, nw, nh, nt, nb)}" fill="{BLACK}"/>\n'
        f'  <path d="{dot}" fill="#FFFFFF"/>\n'
        f'  <path d="{track}" fill="#FFFFFF" fill-opacity="0.18"/>\n'
        f'  <path d="{fill}" fill="#FFFFFF"/>\n'
        f"</g>\n"
        f'<path d="{body_path}" fill="none" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="2"/>\n'
    ), "Espazio")


def mark_shapes(ox, oy, s):
    """Standalone symbol: screen edge (capsule) + notch hanging from it, peek punched out.
    Returns (solid path, cut-out path) in a 512×232 box scaled by s."""
    edge_h = 28 * s
    edge = capsule(ox, oy, 512 * s, edge_h)
    nw, nh, nt, nb = 352 * s, 196 * s, 22 * s, 64 * s
    nx = ox + (512 * s - nw) / 2
    ny = oy + edge_h / 2
    notch = notch_path(nx, ny, nw, nh, nt, nb)
    dot, track, fill = peek(nx, ny, nw, nh, nt, 0.82 * s)
    return [edge, notch], dot, track, fill


def mark(color, title="Espazio"):
    solid, dot, track, fill = mark_shapes(0, 0, 1)
    return svg(512, 224, (
        f'<defs><mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="224">'
        f'<rect width="512" height="224" fill="#fff"/>'
        f'<path d="{dot}" fill="#000"/><path d="{track}" fill="#000" fill-opacity="0.18"/>'
        f'<path d="{fill}" fill="#000"/></mask></defs>\n'
        f'<g fill="{color}" mask="url(#cut)"><path d="{solid[0]}"/><path d="{solid[1]}"/></g>\n'
    ), title)


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


def lockup(color):
    size = 132
    text, tw = wordmark_path("Espazio", 0, 0, size)
    ms = 0.42  # mark scale → 215×94
    mw, mh = 512 * ms, 224 * ms
    gap = 44
    cap = 0.73 * size  # cap height ≈ 0.73 em for Inter Display
    baseline = 30 + cap
    text, _ = wordmark_path("Espazio", mw + gap, baseline, size)
    my = baseline - cap / 2 - (28 * ms + 196 * ms) / 2 + 2
    solid, dot, track, fill = mark_shapes(0, my, ms)
    W, H = mw + gap + tw + 2, baseline + 40
    return svg(W, H, (
        f'<defs><mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="{f(W)}" height="{f(H)}">'
        f'<rect width="{f(W)}" height="{f(H)}" fill="#fff"/>'
        f'<path d="{dot}" fill="#000"/><path d="{track}" fill="#000" fill-opacity="0.18"/>'
        f'<path d="{fill}" fill="#000"/></mask></defs>\n'
        f'<g fill="{color}" mask="url(#cut)"><path d="{solid[0]}"/><path d="{solid[1]}"/></g>\n'
        f'<path d="{text}" fill="{color}"/>\n'
    ), "Espazio")


def main():
    if not os.path.exists(FONT):
        sys.exit(f"Police introuvable : {FONT} (définir ESPAZIO_FONT)")
    os.makedirs(OUT, exist_ok=True)
    files = {
        "AppIcon.svg": app_icon(dark=False),
        "AppIcon-Dark.svg": app_icon(dark=True),
        "Mark-Black.svg": mark(BLACK),
        "Mark-White.svg": mark("#FFFFFF"),
        "Logo-Black.svg": lockup(BLACK),
        "Logo-White.svg": lockup("#FFFFFF"),
    }
    for name, content in files.items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as fh:
            fh.write(content)
        print("wrote", os.path.relpath(os.path.join(OUT, name), ROOT))


if __name__ == "__main__":
    main()
