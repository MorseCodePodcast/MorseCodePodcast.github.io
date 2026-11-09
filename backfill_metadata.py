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
import time
import urllib.error
import urllib.request
from pathlib import Path

WPMS = ("05", "10", "15", "20", "25", "30")
POSTS = Path(__file__).parent / "_posts"
MANAGED = re.compile(r"^(length|duration)(_\d+)?\s*:", re.IGNORECASE)


def fetch(wpm: str, attempts: int = 3) -> tuple[dict[str, tuple[str, str]] | None, str]:
    """Return ({date: (size_bytes, duration_seconds)}, "") else (None, reason).

    Same shape and tolerance as verify_feeds.py:metadata. None means
    archive.org gave us no usable answer: unreachable, timing out, 4xx/5xx,
    unparseable, or the bare `{}` / `{"files": []}` it serves for an item it
    cannot read. That is upstream weather, not a defect in our posts, so the
    caller warns and leaves that speed's existing `length_*` / `duration_*`
    values exactly as they are. Raising took the whole step down and stopped
    the deploy; clearing the keys would silently empty the feeds.
    """
    url = f"https://archive.org/metadata/mcp.{wpm}.WPM"
    pat = re.compile(rf"(\d{{4}}-\d{{2}}-\d{{2}})\.{wpm}\.WPM\.mp3")
    reason = ""
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                files = json.load(r).get("files")
            if files:
                out = {}
                for f in files:
                    m = pat.fullmatch(f.get("name") or "")
                    if not m or not f.get("size"):
                        continue
                    # `length` is seconds as a float string; itunes:duration
                    # accepts seconds.
                    secs = f.get("length")
                    out[m.group(1)] = (f["size"],
                                       str(round(float(secs))) if secs else "")
                return out, ""
            reason = "no file list in metadata document"
        except urllib.error.HTTPError as e:
            reason = f"HTTP {e.code}"
        except (OSError, ValueError) as e:
            reason = f"{type(e).__name__}: {e}"
        if i + 1 < attempts:
            time.sleep(2 * (i + 1))
    return None, reason


def rewrite(path: Path, rows: dict[str, tuple[str, str]], dry: bool,
            keep: frozenset[str] = frozenset()) -> str:
    """Rewrite one post's managed keys. `keep` names speeds to leave untouched."""
    text = path.read_text()
    lines = text.split("\n")
    if lines[0].strip() != "---":
        return "skipped-no-frontmatter"
    try:
        end = lines.index("---", 1)
    except ValueError:
        return "skipped-unterminated"

    # Every managed key is stripped and re-emitted in WPMS order below, so the
    # front matter has one canonical key order. Keeping an unreadable speed's
    # lines *in place* instead would reorder the file whenever the unreadable
    # speed is not the first one: a single partial archive.org outage then lands
    # a 1559-post reordering commit, and the next healthy run lands another one
    # undoing it. Same values either way; the churn is the bug.
    kept: dict[str, tuple[str, str]] = {}
    body = []
    for ln in lines[1:end]:
        m = MANAGED.match(ln)
        if not m:
            body.append(ln)
            continue
        # The legacy unsuffixed `length:` / `duration:` always go: they are the
        # hardcoded wrong ones this script exists to replace.
        wpm = (m.group(2) or "")[1:]
        if wpm in keep:
            # A speed whose item we could not read keeps the values it already
            # has; stripping them is how an archive.org blip empties the feeds.
            size, secs = kept.get(wpm, ("", ""))
            value = ln.split(":", 1)[1].strip().strip('"')
            kept[wpm] = (value, secs) if ln.lower().lstrip().startswith("length") \
                else (size, value)
    for wpm in WPMS:
        source = kept if wpm in keep else rows
        if wpm not in source:
            continue
        size, secs = source[wpm]
        if size:
            body.append(f'length_{wpm}: "{size}"')
        if secs:
            body.append(f'duration_{wpm}: "{secs}"')

    new = "\n".join([lines[0], *body, *lines[end:]])
    if new == text:
        return "unchanged"
    if not dry:
        path.write_text(new)
    if rows:
        return "updated"
    return "kept" if keep else "cleared"


def main() -> int:
    dry = "--dry-run" in sys.argv
    print(f"Fetching metadata for {len(WPMS)} items...")
    by_wpm = {}
    unreadable: dict[str, str] = {}
    for wpm in WPMS:
        rows, why = fetch(wpm)
        if rows is None:
            unreadable[wpm] = why
            print(f"  mcp.{wpm}.WPM: unreadable ({why}); "
                  f"leaving existing length_{wpm}/duration_{wpm} alone")
            continue
        by_wpm[wpm] = rows
        print(f"  mcp.{wpm}.WPM: {len(rows)} episodes")

    keep = frozenset(unreadable)
    counts: dict[str, int] = {}
    no_audio = []
    for path in sorted(POSTS.glob("*-Post.md")):
        date = path.name[:10]
        rows = {w: by_wpm[w][date] for w in by_wpm if date in by_wpm[w]}
        # Only meaningful when every item answered: otherwise "no audio" would
        # just be restating which items archive.org would not serve.
        if not rows and not keep:
            no_audio.append(date)
        status = rewrite(path, rows, dry, keep)
        counts[status] = counts.get(status, 0) + 1

    print("\n" + ("DRY RUN: " if dry else "") + str(dict(sorted(counts.items()))))
    if keep:
        print(f"warnings ({len(unreadable)}), not fatal:")
        for wpm, why in unreadable.items():
            print(f"  - mcp.{wpm}.WPM unreadable ({why}); "
                  f"its existing values were left as they were")
    else:
        print(f"posts with no audio on archive.org: {len(no_audio)}")
        if no_audio:
            print(f"  oldest {no_audio[0]}  newest {no_audio[-1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
