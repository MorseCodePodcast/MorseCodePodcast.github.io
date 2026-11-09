#!/usr/bin/env python3
"""Offline checks for backfill_metadata.py's archive.org outage tolerance.

The one that matters: an item archive.org will not serve must leave each post's
existing `length_*` / `duration_*` keys exactly as they are. Clearing them
silently empties the feeds, and raising takes the whole build step down two
steps before the deploy.

Usage: ./test_backfill_metadata.py
"""
from __future__ import annotations

import io
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import backfill_metadata as bm  # noqa: E402

bm.time.sleep = lambda _s: None  # the retry backoff must not slow the suite

failures = 0


def check(desc: str, cond: bool) -> None:
    global failures
    print(f"  {'ok  ' if cond else 'FAIL'} - {desc}")
    if not cond:
        failures += 1


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def serve(payload, calls: list[str]):
    def urlopen(url, timeout=None):
        calls.append(url)
        if isinstance(payload, Exception):
            raise payload
        return FakeResponse(json.dumps(payload).encode())
    return urlopen


POST = """---
layout: post
title: "2025-06-15"
length: 11444
duration: "01:00"
length_05: "999"
duration_05: "60"
---
body
"""


def write_post() -> Path:
    path = Path(tempfile.mkdtemp()) / "2025-06-15-Post.md"
    path.write_text(POST)
    return path


print("an unreadable item is an outage, not an empty archive")
for payload, desc in (({}, "a bare {}"),
                      ({"files": []}, "an empty files array"),
                      ({"files": None}, "a null files key"),
                      (bm.urllib.error.URLError("boom"), "a transient error")):
    calls: list[str] = []
    bm.urllib.request.urlopen = serve(payload, calls)
    rows, why = bm.fetch("05")
    check(f"{desc} reads as unreadable", rows is None)
    check(f"{desc} is retried 3x before giving up", len(calls) == 3)
    check(f"{desc} names a reason", why != "")

print("a readable item is parsed with the same predicate as the other readers")
calls = []
bm.urllib.request.urlopen = serve({"files": [
    {"name": "mcp.05.WPM_meta.xml", "size": "9"},
    {"name": "2025-06-15.05.WPM.mp3", "size": "123456", "length": "61.4"},
    {"name": "2025-06-16.05.WPM.mp3"},
    {"size": "7"},
]}, calls)
rows, why = bm.fetch("05")
check("takes only the sized episode files",
      rows == {"2025-06-15": ("123456", "61")})
check("does not retry a readable item", len(calls) == 1)

print("an unreadable speed keeps the values the post already has")
path = write_post()
status = bm.rewrite(path, {}, False, frozenset(bm.WPMS))
text = path.read_text()
check("reports that values were kept, not cleared", status == "kept")
check("length_05 survives", 'length_05: "999"' in text)
check("duration_05 survives", 'duration_05: "60"' in text)
check("the hardcoded legacy length is still dropped", "length: 11444" not in text)

print("a readable speed is rewritten")
path = write_post()
status = bm.rewrite(path, {"05": ("123456", "61")}, False, frozenset())
text = path.read_text()
check("reports an update", status == "updated")
check("length_05 is the real size", 'length_05: "123456"' in text)
check("the stale value is gone", '"999"' not in text)

print("every speed unreadable and nothing managed in the post -> no write")
path = write_post()
path.write_text('---\nlayout: post\ntitle: "x"\n---\nbody\n')
before = path.read_text()
status = bm.rewrite(path, {}, False, frozenset(bm.WPMS))
check("left byte-identical", path.read_text() == before)
check("reported unchanged", status == "unchanged")

print()
if failures:
    print(f"backfill_metadata: {failures} check(s) failed", file=sys.stderr)
    raise SystemExit(1)
print("backfill_metadata: all checks passed")
