#!/usr/bin/env python3
"""Assert the published feeds are things a podcast client will actually accept.

Guards the specific failures that stopped AntennaPod downloading: a bogus
enclosure MIME type, a declared size that did not match the file, and items
pointing at audio that was never uploaded.

Checks EVERY enclosure in every feed, not a sample: one archive.org metadata
document per speed -- the same six documents backfill_metadata.py reads --
lists the name and size of every file in the item, so full coverage costs six
requests instead of one per enclosure. A sampled gate let a feed with a single
bad item pass most of the time, which defeats the point of a gate.

Usage: ./verify_feeds.py <site-dir>
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ITUNES = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"
WPMS = ("05", "10", "15", "20", "25", "30")
failures: list[str] = []
warnings: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


def metadata(wpm: str, attempts: int = 3) -> tuple[dict[str, str] | None, str]:
    """Return ({filename: size_bytes}, "") for one item, else (None, reason).

    None means archive.org gave us no usable answer: unreachable, timing out,
    5xx, unparseable, or the bare `{}` it serves for an item it cannot read.
    None of that is a defect in our feed, so the caller warns rather than
    failing -- reading an empty document as "every file is missing" would turn
    one archive.org blip into six failed feeds and a blocked deploy.
    """
    url = f"https://archive.org/metadata/mcp.{wpm}.WPM"
    reason = ""
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                files = json.load(r).get("files")
            if files:
                # Mirror backfill_metadata.py: an entry with no size is not a
                # file we can validate a declared length against.
                return {f["name"]: f["size"] for f in files
                        if f.get("name") and f.get("size")}, ""
            reason = "no file list in metadata document"
        except urllib.error.HTTPError as e:
            reason = f"HTTP {e.code}"
        except (OSError, ValueError) as e:
            reason = f"{type(e).__name__}: {e}"
        if i + 1 < attempts:
            time.sleep(2 * (i + 1))
    return None, reason


def main() -> int:
    site = Path(sys.argv[1])

    check((site / "assets/itunes.png").exists(), "assets/itunes.png missing from build")

    for wpm in WPMS:
        path = site / "rss" / f"{wpm}WPM.xml"
        if not path.exists():
            failures.append(f"{path} missing")
            continue
        ch = ET.parse(path).getroot().find("channel")

        check((ch.findtext("language") or "").strip() != "", f"{wpm}: empty <language>")
        check((ch.findtext("title") or "").strip() != "", f"{wpm}: empty <title>")
        art = ch.find(f"{ITUNES}image")
        check(art is not None and art.get("href", "").endswith(".png"),
              f"{wpm}: missing itunes:image")
        # An empty address is worse than none; it gets the feed rejected.
        for tag in ("managingEditor", "webMaster"):
            el = ch.findtext(tag)
            check(el is None or el.strip() not in ("", "()"), f"{wpm}: malformed <{tag}>")

        items = ch.findall("item")
        check(len(items) > 0, f"{wpm}: no items")

        encs = []
        for it in items:
            e = it.find("enclosure")
            check(e is not None, f"{wpm}: item without enclosure")
            if e is None:
                continue
            encs.append(e)
            check(e.get("type") == "audio/mpeg",
                  f"{wpm}: enclosure type {e.get('type')!r}, want audio/mpeg")
            size = int(e.get("length") or 0)
            check(size > 1000, f"{wpm}: implausible length={size} for {e.get('url')}")

        sizes = {e.get("length") for e in encs}
        check(len(sizes) > 1, f"{wpm}: every item declares the same length {sizes}")

        # Every declared size against the size archive.org records, in one request.
        files, why = metadata(wpm)
        # Counted, not inferred from `files is None`: the printed figure is what
        # a human reads to decide the feeds are healthy, and it used to say
        # "5/5 enclosures verified" in the same run that reported a missing file.
        verified = 0
        if files is None:
            warnings.append(f"{wpm}: archive.org metadata unavailable ({why}); "
                            f"{len(encs)} enclosures unverified (upstream)")
        else:
            for e in encs:
                url, declared = e.get("url", ""), int(e.get("length") or 0)
                name = url.rsplit("/", 1)[-1]
                actual = files.get(name)
                if actual is None:
                    failures.append(f"{wpm}: {url} -> no such file in archive.org item")
                elif int(actual) != declared:
                    failures.append(f"{wpm}: {url} declared {declared} "
                                    f"but archive.org records {actual}")
                else:
                    verified += 1
        print(f"{wpm}WPM: {len(items)} items, {path.stat().st_size // 1024} KB, "
              f"{verified}/{len(encs)} enclosures verified")

    if warnings:
        print(f"\nwarnings ({len(warnings)}), not fatal:")
        for w in warnings:
            print("  -", w)
    if failures:
        print(f"\nFAIL ({len(failures)}):")
        for f in failures:
            print("  -", f)
        return 1
    print("\nAll feed checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
