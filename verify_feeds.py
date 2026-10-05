#!/usr/bin/env python3
"""Assert the published feeds are things a podcast client will actually accept.

Guards the specific failures that stopped AntennaPod downloading: a bogus
enclosure MIME type, a declared size that did not match the file, and items
pointing at audio that was never uploaded.

Usage: ./verify_feeds.py <site-dir> [--sample N]
"""
from __future__ import annotations

import random
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


def head(url: str, attempts: int = 3) -> tuple[int, int]:
    """HEAD a URL, retrying server errors.

    Archive.org returns a sporadic 500 on healthy files, so a single bad
    response must not fail the build; a 404 is ours and is never retried.
    """
    status = 0
    for i in range(attempts):
        req = urllib.request.Request(url, method="HEAD")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, int(r.headers.get("Content-Length") or 0)
        except urllib.error.HTTPError as e:
            status = e.code
            if e.code < 500:
                return e.code, 0
        except OSError:
            status = 0
        if i + 1 < attempts:
            time.sleep(2 * (i + 1))
    return status, 0


def main() -> int:
    site = Path(sys.argv[1])
    sample_n = int(sys.argv[sys.argv.index("--sample") + 1]) if "--sample" in sys.argv else 5

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

        # Spot-check that the declared size is the real one.
        for e in random.sample(encs, min(sample_n, len(encs))):
            url, declared = e.get("url"), int(e.get("length"))
            status, actual = head(url)
            if status == 200:
                check(actual == declared,
                      f"{wpm}: {url} declared {declared} but server says {actual}")
            elif status >= 500 or status == 0:
                # Archive.org being unavailable is not a defect in our feed.
                warnings.append(f"{wpm}: {url} -> HTTP {status or 'no response'} (upstream)")
            else:
                failures.append(f"{wpm}: {url} -> HTTP {status}")
        print(f"{wpm}WPM: {len(items)} items, {path.stat().st_size // 1024} KB, "
              f"{sample_n} enclosures spot-checked")

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
