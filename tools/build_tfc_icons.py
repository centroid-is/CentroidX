#!/usr/bin/env python3
"""Generate the custom TfcIcons glyphs and merge them into assets/fonts/TfcIcons.ttf.

TfcIcons.ttf was originally produced by Fontello, but no Fontello config was kept
in the repo. Rather than round-trip the whole font through Fontello again (which
would risk shifting the existing code points that lib/converter/icon.dart hard
codes), this script appends new glyphs to the existing font in place.

The icons are built out of axis-aligned rectangles and straight-edged polygons
only, so the glyph outlines are described directly in font units and the
matching SVG sources are written out for reference / future re-generation.

Design space: the usual Fontello 1000x1000 viewBox with y pointing down and the
baseline at ascent = 850 font units, i.e. fontY = 850 - svgY.

Usage:  python3 tools/build_tfc_icons.py
"""

from __future__ import annotations

import os

from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_PATH = os.path.join(REPO, "assets", "fonts", "TfcIcons.ttf")
SVG_DIR = os.path.join(REPO, "tools", "icon-sources")

ASCENT = 850  # font units above the baseline; svgY 0 maps here
EM = 1000
ADVANCE = 1000

# A shape is either a rectangle (x0, y0, x1, y1) or a polygon, a list of
# (x, y) points. Both are in SVG coordinates.
Rect = tuple[float, float, float, float]
Polygon = list[tuple[float, float]]

# --------------------------------------------------------------------------
# Icon geometry (SVG coordinates: 0..1000, y down)
# --------------------------------------------------------------------------


def pallet_top_rects() -> list[Rect]:
    """Pallet seen from above: five deck boards over three stringers."""
    left, right = 70, 930
    top, bottom = 210, 790

    board_h = 88
    gap = 35
    rects = []
    for i in range(5):
        y0 = top + i * (board_h + gap)
        rects.append((left, y0, right, y0 + board_h))

    # Stringers running under the deck boards; they only show in the gaps but
    # drawing them full height is what unions the shape together.
    stringer_w = 76
    for cx in (left + stringer_w / 2, (left + right) / 2, right - stringer_w / 2):
        rects.append((cx - stringer_w / 2, top, cx + stringer_w / 2, bottom))

    return rects


def pallet_stack_rects() -> list[Rect]:
    """Pallet from the side carrying ten rows of boxes."""
    left, right = 60, 940
    rects = []

    # --- pallet ---------------------------------------------------------
    deck_top, deck_bottom = 880, 912
    foot_bottom = 958
    base_bottom = 990
    rects.append((left, deck_top, right, deck_bottom))  # top deck board
    foot_w = 112
    for x0 in (left, (left + right) / 2 - foot_w / 2, right - foot_w):
        rects.append((x0, deck_bottom, x0 + foot_w, foot_bottom))  # blocks
    rects.append((left, foot_bottom, right, base_bottom))  # bottom board

    # --- ten rows of boxes ----------------------------------------------
    box_left, box_right = 95, 905
    row_h = 58
    row_gap = 13
    seam = 14  # vertical gap between boxes in the same row
    # Leave a hairline above the deck board so the pallet does not merge into
    # the bottom row of boxes at small sizes.
    stack_bottom = deck_top - 16
    for i in range(10):
        y1 = stack_bottom - i * (row_h + row_gap)
        y0 = y1 - row_h
        # Alternate the seam position so the rows read as boxes, not stripes.
        seam_x = 500 if i % 2 == 0 else 365
        rects.append((box_left, y0, seam_x - seam / 2, y1))
        rects.append((seam_x + seam / 2, y0, box_right, y1))

    return rects


def ethercat_polygons() -> list[Polygon]:
    """The EtherCAT mark: a right-pointing arrow over a left-pointing one.

    Each arrow is a bar with a half arrowhead, its slanted edge running out to
    the bar's far corner. Measured off the 152 px touch icon ethercat.org
    publishes (the red arrow in the upper half, the black one below), then
    scaled 6.5x and centred in the 1000 box. The glyph is one colour; the icon
    asset's colour picker stands in for the red and black.
    """
    upper = [(58, 321), (585, 321), (585, 191), (942, 471), (58, 471)]
    lower = [(143, 529), (942, 529), (942, 679), (494, 679), (494, 809)]
    return [upper, lower]


ICONS = {
    "pallet_top": (0xE806, pallet_top_rects),
    "pallet_stack": (0xE807, pallet_stack_rects),
    "ethercat": (0xE808, ethercat_polygons),
}


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def _is_rect(shape) -> bool:
    return isinstance(shape, tuple) and len(shape) == 4


def _outline(shape) -> Polygon:
    """Any shape as a polygon in SVG coordinates."""
    if _is_rect(shape):
        x0, y0, x1, y1 = shape
        # Bottom-left first, then up: the order the rectangle-only version of
        # this script drew in, so the existing glyphs rebuild byte-identical.
        return [(x0, y1), (x0, y0), (x1, y0), (x1, y1)]
    return list(shape)


def write_svg(name: str, shapes) -> None:
    os.makedirs(SVG_DIR, exist_ok=True)
    lines = []
    for shape in shapes:
        if _is_rect(shape):
            x0, y0, x1, y1 = shape
            lines.append(
                '  <rect x="{:g}" y="{:g}" width="{:g}" height="{:g}"/>'.format(
                    x0, y0, x1 - x0, y1 - y0
                )
            )
        else:
            points = " ".join("{:g},{:g}".format(x, y) for x, y in shape)
            lines.append('  <polygon points="{}"/>'.format(points))
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {em} {em}" '
        'width="{em}" height="{em}">\n{body}\n</svg>\n'
    ).format(em=EM, body="\n".join(lines))
    path = os.path.join(SVG_DIR, name + ".svg")
    with open(path, "w") as fh:
        fh.write(svg)
    print("wrote", os.path.relpath(path, REPO))


def draw_glyph(shapes):
    """Shapes -> a TrueType glyph.

    Every contour is wound clockwise in font (y-up) space, so overlapping
    shapes union under the non-zero fill rule and no boolean op is needed.
    """
    pen = TTGlyphPen(None)
    for shape in shapes:
        # svg y down -> font y up
        points = [(x, ASCENT - y) for x, y in _outline(shape)]
        # Shoelace sum; positive means counter-clockwise in y-up space.
        area = sum(
            x0 * y1 - x1 * y0
            for (x0, y0), (x1, y1) in zip(points, points[1:] + points[:1])
        )
        if area > 0:
            points.reverse()
        pen.moveTo(points[0])
        for point in points[1:]:
            pen.lineTo(point)
        pen.closePath()
    return pen.glyph()


def main() -> None:
    font = TTFont(FONT_PATH)
    glyf = font["glyf"]
    hmtx = font["hmtx"]
    order = font.getGlyphOrder()

    for name, (codepoint, builder) in ICONS.items():
        shapes = builder()
        write_svg(name, shapes)

        if name not in order:
            order = list(order) + [name]
        glyf[name] = draw_glyph(shapes)
        hmtx[name] = (ADVANCE, 0)

        for table in font["cmap"].tables:
            if table.isUnicode():
                table.cmap[codepoint] = name
        print("glyph {} at U+{:04X}".format(name, codepoint))

    font.setGlyphOrder(order)
    font["maxp"].numGlyphs = len(order)
    font.save(FONT_PATH)
    print("updated", os.path.relpath(FONT_PATH, REPO))


if __name__ == "__main__":
    main()
