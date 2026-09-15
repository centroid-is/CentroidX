#!/usr/bin/env python3
"""Render every glyph in TfcIcons.ttf to a PNG contact sheet.

Drawing a glyph by its coordinates is cheap; judging whether it reads as a pump
at 24px is not, so the build renders one. Each glyph appears large enough to
check the shape and at the sizes it is actually used at on a page, because an
icon that resolves beautifully at 96px and turns to mush at 24 is a bug.
"""

from __future__ import annotations

import sys

from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont

CELL_W, CELL_H = 190, 210
COLS = 6
BG = (24, 24, 32)
FG = (238, 238, 244)
LABEL = (150, 152, 168)


def main() -> None:
    font_path = sys.argv[1] if len(sys.argv) > 1 else "assets/fonts/TfcIcons.ttf"
    out = sys.argv[2] if len(sys.argv) > 2 else "tools/icons/proof_sheet.png"
    only_new = "--all" not in sys.argv

    cmap = TTFont(font_path).getBestCmap()
    codes = sorted(cmap)
    if only_new:
        codes = [c for c in codes if c >= 0xE809]

    big = ImageFont.truetype(font_path, 104)
    mid = ImageFont.truetype(font_path, 48)
    small = ImageFont.truetype(font_path, 24)
    tiny = ImageFont.truetype(font_path, 16)
    try:
        text_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
    except OSError:
        text_font = ImageFont.load_default()

    rows = (len(codes) + COLS - 1) // COLS
    img = Image.new("RGB", (COLS * CELL_W, rows * CELL_H), BG)
    d = ImageDraw.Draw(img)

    for i, code in enumerate(codes):
        col, row = i % COLS, i // COLS
        ox, oy = col * CELL_W, row * CELL_H
        ch = chr(code)
        d.text((ox + CELL_W / 2, oy + 74), ch, font=big, fill=FG, anchor="mm")
        # The small sizes sit on one baseline so the set can be scanned for
        # anything that has gone muddy.
        d.text((ox + 42, oy + 156), ch, font=mid, fill=FG, anchor="mm")
        d.text((ox + 92, oy + 156), ch, font=small, fill=FG, anchor="mm")
        d.text((ox + 126, oy + 156), ch, font=tiny, fill=FG, anchor="mm")
        d.text(
            (ox + CELL_W / 2, oy + 192),
            f"{cmap[code]}  {code:04X}",
            font=text_font,
            fill=LABEL,
            anchor="mm",
        )
        d.rectangle(
            [ox, oy, ox + CELL_W - 1, oy + CELL_H - 1], outline=(52, 52, 64)
        )

    img.save(out)
    print(f"wrote {out} ({len(codes)} glyphs)")


if __name__ == "__main__":
    main()
