#!/usr/bin/env bash
# Regenerate assets/itunes.png, the podcast cover art referenced by every feed.
# 1400x1400 is the minimum Apple accepts; most clients want >=1400 square.
# Requires: imagemagick, a DejaVu Sans Bold (or any bold sans) via fontconfig.
set -euo pipefail
cd "$(dirname "$0")"

SANS=$(fc-match -f '%{file}' "DejaVu Sans:bold")
MVG=$(mktemp); trap 'rm -f "$MVG"' EXIT

# "MORSE" spelled in actual morse, drawn as rounded bars (no font dependency).
python3 - > "$MVG" <<'PY'
S, ACCENT = 1400, "#38bdf8"
MORSE = {"M": "--", "O": "---", "R": ".-.", "S": "...", "E": "."}
unit, gap, letter_gap, h, y = 26, 18, 70, 26, 790

widths = [
    sum(unit if s == "." else unit * 3 for s in MORSE[c]) + gap * (len(MORSE[c]) - 1)
    for c in "MORSE"
]
out = [f"fill {ACCENT}", "stroke none"]
x = (S - (sum(widths) + letter_gap * (len(widths) - 1))) // 2
for ch, w in zip("MORSE", widths):
    cx = x
    for i, sym in enumerate(MORSE[ch]):
        if i:
            cx += gap
        ln = unit if sym == "." else unit * 3
        out.append(f"roundrectangle {cx},{y} {cx+ln},{y+h} {h//2},{h//2}")
        cx += ln
    x += w + letter_gap
print("\n".join(out))
PY

magick -size 1400x1400 xc:'#0b1d2a' \
  -draw "@$MVG" \
  -font "$SANS" -fill '#ecf0f3' \
  -pointsize 150 -gravity north -annotate +0+420 'MORSE CODE' \
  -pointsize 150 -gravity north -annotate +0+570 'PODCAST' \
  -pointsize 46 -fill '#38bdf8' -gravity north -annotate +0+900 'DAILY CW PRACTICE  ·  05-30 WPM' \
  -depth 8 -strip assets/itunes.png

identify assets/itunes.png
