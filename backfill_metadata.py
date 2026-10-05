#!/usr/bin/env python3
"""Write real episode size/duration into post front matter.

Every post used to carry a hardcoded `length: 11444` / `duration: 01:00`, which
is wrong by up to 170x. Podcast clients trust those values, so downloads either
truncated or were rejected outright.

Archive.org publishes the true size and duration of every file in one metadata
document per item, so this costs six HTTP requests regardless of archive size --
no per-episode crawling.

Each speed produces a different file from the same text, so values are stored
per speed as `length_<wpm>` / `duration_<wpm>`. A post whose audio was never
uploaded gets no keys at all, and the feed template skips it.

Usage: ./backfill_metadata.py [--dry-run]
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

WPMS = ("05", "10", "15", "20", "25", "30")
POSTS = Path(__file__).parent / "_posts"
MANAGED = re.compile(r"^(length|duration)(_\d+)?\s*:", re.IGNORECASE)


def fetch(wpm: str) -> dict[str, tuple[str, str]]:
    """Return {date: (size_bytes, duration_seconds)} for one speed."""
    url = f"https://archive.org/metadata/mcp.{wpm}.WPM"
    with urllib.request.urlopen(url, timeout=120) as r:
        meta = json.load(r)
    pat = re.compile(rf"(\d{{4}}-\d{{2}}-\d{{2}})\.{wpm}\.WPM\.mp3")
    out = {}
    for f in meta.get("files", []):
        m = pat.fullmatch(f.get("name", ""))
        if not m or not f.get("size"):
            continue
        # `length` is seconds as a float string; itunes:duration accepts seconds.
        secs = f.get("length")
        out[m.group(1)] = (f["size"], str(round(float(secs))) if secs else "")
    return out


def rewrite(path: Path, rows: dict[str, tuple[str, str]], dry: bool) -> str:
    text = path.read_text()
    lines = text.split("\n")
    if lines[0].strip() != "---":
        return "skipped-no-frontmatter"
    try:
        end = lines.index("---", 1)
    except ValueError:
        return "skipped-unterminated"

    body = [ln for ln in lines[1:end] if not MANAGED.match(ln)]
    for wpm in WPMS:
        if wpm not in rows:
            continue
        size, secs = rows[wpm]
        body.append(f'length_{wpm}: "{size}"')
        if secs:
            body.append(f'duration_{wpm}: "{secs}"')

    new = "\n".join([lines[0], *body, *lines[end:]])
    if new == text:
        return "unchanged"
    if not dry:
        path.write_text(new)
    return "updated" if rows else "cleared"


def main() -> int:
    dry = "--dry-run" in sys.argv
    print(f"Fetching metadata for {len(WPMS)} items...")
    by_wpm = {}
    for wpm in WPMS:
        by_wpm[wpm] = fetch(wpm)
        print(f"  mcp.{wpm}.WPM: {len(by_wpm[wpm])} episodes")

    counts: dict[str, int] = {}
    no_audio = []
    for path in sorted(POSTS.glob("*-Post.md")):
        date = path.name[:10]
        rows = {w: by_wpm[w][date] for w in WPMS if date in by_wpm[w]}
        if not rows:
            no_audio.append(date)
        status = rewrite(path, rows, dry)
        counts[status] = counts.get(status, 0) + 1

    print("\n" + ("DRY RUN: " if dry else "") + str(dict(sorted(counts.items()))))
    print(f"posts with no audio on archive.org: {len(no_audio)}")
    if no_audio:
        print(f"  oldest {no_audio[0]}  newest {no_audio[-1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
