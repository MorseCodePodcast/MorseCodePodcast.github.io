#!/usr/bin/env bash
# Offline tests for episode_press.sh decision logic.
#
# Everything the script reaches the network or the audio toolchain with is
# stubbed, so this runs anywhere in about a second. It covers the three
# regressions that took the daily build down for a week in October 2026:
#
#   1. missing fortune data must fail the run, not publish empty episodes
#   2. a date whose audio exists but whose post does not must still get a post
#   3. one unpublishable date must not abort the rest of the backfill window

set -euo pipefail

SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/episode_press.sh
WPM=(05 10 15 20 25 30)
DATES=()
for i in $(seq 6 -1 0); do DATES+=("$(date -d "$i days ago" +%F)"); done

failures=0
check() { # check <description> <condition-result>
  if [[ $2 == 0 ]]; then echo "  ok   - $1"; else echo "  FAIL - $1"; failures=$((failures + 1)); fi
}

setup() { # setup [fortune-broken]
  TD=$(mktemp -d)
  mkdir -p "$TD/bin" "$TD/work/_posts"
  cp "$SCRIPT" "$TD/work/"
  export EXISTING="$TD/existing" UPLOADED="$TD/uploaded" FAIL_DATE="${FAIL_DATE:-}"
  export MESSAGES="$TD/messages"
  export GITHUB_STEP_SUMMARY="$TD/summary"
  # Every request the script makes, by kind, so assertions can count them
  # instead of guessing from the log.
  export METADATA_READS="$TD/metadata_reads" DOWNLOAD_READS="$TD/download_reads"
  : > "$EXISTING"; : > "$UPLOADED"; : > "$MESSAGES"; : > "$GITHUB_STEP_SUMMARY"
  : > "$METADATA_READS"; : > "$DOWNLOAD_READS"

  # Stub archive.org: /metadata/ serves $EXISTING as an item file list,
  # --upload-file appends to it, anything else is the derive POST.
  # METADATA_DOC overrides the file list with a literal document.
  cat > "$TD/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"; obj="${url##*/}"
# Any read-back of archive.org/download/ is the forbidden inline poll: that path
# only reflects an upload once the item's derive task has run, and derive is
# triggered once at the end of main. Recorded AND refused, so re-introducing
# the poll cannot look successful -- the stub used to answer every unrecognised
# URL with {"success":true}, which is what made the guard assertion vacuous.
if [[ $url == */download/* ]]; then
  printf '%s\n' "$url" >> "$DOWNLOAD_READS"
  echo "stub: refusing a /download/ read-back of $url" >&2
  exit 22
fi
if [[ $url == */metadata/* ]]; then
  printf '%s\n' "$url" >> "$METADATA_READS"
  if [[ -n ${METADATA_DOC:-} ]]; then printf '%s\n' "$METADATA_DOC"; exit 0; fi
  # A real item always lists its own _meta.xml, and every uploaded file carries
  # a size: the presser requires both, exactly as verify_feeds.py and
  # backfill_metadata.py do.
  printf '{"files":[{"name":"%s_meta.xml","size":"1024"}' "$obj"
  for f in $(< "$EXISTING"); do printf ',{"name":"%s","size":"123456"}' "$f"; done
  printf ']}\n'
  exit 0
fi
for a in "$@"; do
  if [[ $a == --upload-file ]]; then
    [[ -n ${FAIL_DATE:-} && $obj == "$FAIL_DATE".* ]] && exit 22
    printf '%s\n' "$obj" >> "$UPLOADED"
    printf ' %s ' "$obj" >> "$EXISTING"
    exit 0
  fi
done
printf '{"success":true}\n'
STUB

  # The audio toolchain only has to leave a non-empty file where the script
  # expects one -- it asserts the rendered episode is not 0 bytes. The show
  # note arrives on stdin, so $MESSAGES records what was actually keyed.
  cat > "$TD/bin/ebook2cw" <<'STUB'
#!/usr/bin/env bash
cat >> "$MESSAGES"
prev=
for a in "$@"; do [[ $prev == -o ]] && { printf 'ID3stub' > "$a.mp3"; exit 0; }; prev=$a; done
STUB
  cat > "$TD/bin/sox" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ $a == *.mp3 ]] && out=$a; done
[[ -n ${out:-} ]] && printf 'ID3stub' > "$out"; exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/bin/espeak"
  # Keeps the deliberate upload-retry backoff from making the suite slow.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/bin/sleep"

  if [[ ${1:-} == fortune-broken ]]; then
    printf '#!/usr/bin/env bash\necho "No fortunes found" >&2\nexit 1\n' > "$TD/bin/fortune"
  else
    printf '#!/usr/bin/env bash\necho "a stub fortune"\n' > "$TD/bin/fortune"
  fi

  chmod +x "$TD/bin"/*
  export PATH="$TD/bin:$PATH" S3_ACCESS=stub S3_SECRET=stub
  cd "$TD/work"
}

teardown() {
  cd /; rm -rf "$TD"
  unset FAIL_DATE BACKFILL_DATES REPAIR_PER_RUN METADATA_DOC
}

have_audio() { for w in "${WPM[@]}"; do printf ' %s.%s.WPM.mp3 ' "$1" "$w" >> "$EXISTING"; done; }
# A published post for a historical date, with the show note already in it.
have_post() { # have_post <date> <message>
  printf -- '---\ntitle: "%s"\nsummary: "%s"\nmessage: "%s"\n---\n%s\n' \
    "$1" "$2" "$2" "$2" > "$TD/work/_posts/$1-Post.md"
}
# The whole 7-day window already published, so only repair work is left.
window_published() {
  for d in "${DATES[@]}"; do have_audio "$d"; : > "$TD/work/_posts/$d-Post.md"; done
}
posts() { find "$TD/work/_posts" -name '*-Post.md' | wc -l; }
run() { bash ./episode_press.sh "${WPM[@]}" > "$TD/out" 2>&1; }

echo "nothing exists -> full backfill of every date in the window"
setup
run; rc=$?
check "exits 0" "$rc"
check "uploads ${#DATES[@]}x${#WPM[@]} files" "$([[ $(wc -l < "$UPLOADED") -eq $((${#DATES[@]} * ${#WPM[@]})) ]] && echo 0 || echo 1)"
check "creates one post per date" "$([[ $(posts) -eq ${#DATES[@]} ]] && echo 0 || echo 1)"
check "refreshes the archive.org item pages" "$(grep -q 'Triggering derive' "$TD/out" && echo 0 || echo 1)"
check "makes no /download/ request at all" "$([[ ! -s $DOWNLOAD_READS ]] && echo 0 || echo 1)"
check "makes exactly one metadata request per speed" "$([[ $(wc -l < "$METADATA_READS") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
check "says nothing about verifying an upload" "$(grep -qi 'verif' "$TD/out" && echo 1 || echo 0)"
teardown

echo "everything already published -> no work, no uploads"
setup
for d in "${DATES[@]}"; do have_audio "$d"; : > "$TD/work/_posts/$d-Post.md"; done
run; rc=$?
check "exits 0" "$rc"
check "says it is up to date" "$(grep -q 'All episodes up to date' "$TD/out" && echo 0 || echo 1)"
check "uploads nothing" "$([[ ! -s $UPLOADED ]] && echo 0 || echo 1)"
teardown

echo "audio exists but post does not -> post is created, audio is not re-uploaded"
setup
orphan=${DATES[1]}
for d in "${DATES[@]}"; do have_audio "$d"; [[ $d != "$orphan" ]] && : > "$TD/work/_posts/$d-Post.md"; done
run; rc=$?
check "exits 0" "$rc"
check "creates the missing post for $orphan" "$([[ -s $TD/work/_posts/$orphan-Post.md ]] && echo 0 || echo 1)"
check "uploads nothing" "$([[ ! -s $UPLOADED ]] && echo 0 || echo 1)"
teardown

echo "one date cannot upload -> every other date still publishes"
FAIL_DATE=${DATES[2]}
setup
run && rc=0 || rc=$?
check "exits non-zero" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "skips the post for $FAIL_DATE" "$([[ ! -f $TD/work/_posts/$FAIL_DATE-Post.md ]] && echo 0 || echo 1)"
check "publishes the other $((${#DATES[@]} - 1)) dates" "$([[ $(posts) -eq $((${#DATES[@]} - 1)) ]] && echo 0 || echo 1)"
check "names the failure in the report" "$(grep -q 'FAILURES' "$TD/out" && echo 0 || echo 1)"
teardown

echo "fortune has no data -> run fails instead of publishing empty episodes"
setup fortune-broken
run && rc=0 || rc=$?
check "exits non-zero" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "creates no posts" "$([[ $(posts) -eq 0 ]] && echo 0 || echo 1)"
teardown

echo "explicit historical date -> pressed from its published post, post untouched"
# fortune-broken on purpose: regenerating the show note would make the audio
# disagree with the post text already in the feed, so this date must press
# without fortune existing at all.
setup fortune-broken
old=2025-06-15
note="the already published show note"
cat > "$TD/work/_posts/$old-Post.md" <<EOF
---
layout: post
title: "$old"
today: "$old"
date: $old 00:00:00 0000
summary: "$note"
message: "$note"
---
$note
EOF
before=$(cksum < "$TD/work/_posts/$old-Post.md")
export BACKFILL_DATES=$old
run && rc=0 || rc=$?
after=$(cksum < "$TD/work/_posts/$old-Post.md")
check "exits 0" "$rc"
check "uploads ${#WPM[@]} files for $old" "$([[ $(grep -c "^$old\." "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
check "uploads nothing else" "$([[ $(wc -l < "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
check "keys the post's own message" "$(grep -q "$note" "$MESSAGES" && echo 0 || echo 1)"
check "never runs fortune" "$(grep -q 'No fortunes found' "$TD/out" && echo 1 || echo 0)"
check "leaves the post byte-identical" "$([[ $before == "$after" ]] && echo 0 || echo 1)"
check "adds no post" "$([[ $(posts) -eq 1 ]] && echo 0 || echo 1)"
teardown

echo "a typo in BACKFILL_DATES -> loud failure instead of a silent no-op"
setup
export BACKFILL_DATES="2025-6-15 2025-02-30"
run && rc=0 || rc=$?
check "exits non-zero" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "names 2025-6-15" "$(grep -q '2025-6-15' "$TD/out" && echo 0 || echo 1)"
check "names the impossible 2025-02-30" "$(grep -q '2025-02-30' "$TD/out" && echo 0 || echo 1)"
check "uploads nothing" "$([[ ! -s $UPLOADED ]] && echo 0 || echo 1)"
check "creates no posts" "$([[ $(posts) -eq 0 ]] && echo 0 || echo 1)"
teardown

echo "a gap -> the newest N missing dates are repaired, older ones are left"
# fortune-broken on purpose: a repair date must press the show note already in
# its post, never a fresh one that would disagree with the published text.
setup fortune-broken
window_published
for d in 2025-06-11 2025-06-12 2025-06-13 2025-06-14 2025-06-15; do
  have_post "$d" "note for $d"
done
export REPAIR_PER_RUN=3
run && rc=0 || rc=$?
check "exits 0" "$rc"
check "uploads 3x${#WPM[@]} files" "$([[ $(wc -l < "$UPLOADED") -eq $((3 * ${#WPM[@]})) ]] && echo 0 || echo 1)"
for d in 2025-06-15 2025-06-14 2025-06-13; do
  check "repairs $d" "$([[ $(grep -c "^$d\." "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
done
for d in 2025-06-12 2025-06-11; do
  check "leaves the older $d alone" "$(grep -q "^$d\." "$UPLOADED" && echo 1 || echo 0)"
done
check "keys the post's own message" "$(grep -q 'note for 2025-06-15' "$MESSAGES" && echo 0 || echo 1)"
check "never runs fortune" "$(grep -q 'No fortunes found' "$TD/out" && echo 1 || echo 0)"
check "reports the remaining gap in the job summary" "$(grep -q '`2` date(s) have a published post' "$TD/summary" && echo 0 || echo 1)"
teardown

echo "no gap -> the repair presses nothing"
setup
window_published
have_post 2025-06-15 "an old note"; have_audio 2025-06-15
run; rc=$?
check "exits 0" "$rc"
check "says it is up to date" "$(grep -q 'All episodes up to date' "$TD/out" && echo 0 || echo 1)"
check "uploads nothing" "$([[ ! -s $UPLOADED ]] && echo 0 || echo 1)"
check "reports a zero gap" "$(grep -q 'Audio gap: 0 date(s)' "$TD/out" && echo 0 || echo 1)"
teardown

echo "a dead historical date -> run still succeeds and today still publishes"
today=${DATES[6]}
FAIL_DATE=2026-01-05
setup
for d in "${DATES[@]}"; do
  [[ $d == "$today" ]] && continue
  have_audio "$d"; : > "$TD/work/_posts/$d-Post.md"
done
have_post "$FAIL_DATE" "a published note"
run && rc=0 || rc=$?
check "exits 0 despite the repair failure" "$rc"
check "presses today's ${#WPM[@]} variants" "$([[ $(grep -c "^$today\." "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
check "creates today's post" "$([[ -s $TD/work/_posts/$today-Post.md ]] && echo 0 || echo 1)"
check "names the repair failure" "$(grep -q 'Repair failures' "$TD/out" && echo 0 || echo 1)"
check "does not report it as a press failure" "$(grep -q 'FAILURES (' "$TD/out" && echo 1 || echo 0)"
teardown

echo "archive.org serves an item it cannot read -> loud failure, nothing pressed"
# jq exits 0 on `{"files":[]}` while printing nothing, so this used to read as
# "this item has no episodes" and re-press every window and repair date over
# enclosures subscribers are actively downloading.
for doc in '{}' 'null' '{"files":[]}' '{"files":null}' '{"files":[{'; do
  setup
  export METADATA_DOC=$doc
  run && rc=0 || rc=$?
  check "$doc exits non-zero" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
  check "$doc uploads nothing" "$([[ ! -s $UPLOADED ]] && echo 0 || echo 1)"
  check "$doc creates no posts" "$([[ $(posts) -eq 0 ]] && echo 0 || echo 1)"
  teardown
done

echo "a files entry with no size or no name -> not existing audio"
# The shape the three readers of this document used to disagree about: a
# sizeless entry read as "audio exists" to the presser but "no audio" to the
# feed and the backfill, so the post stayed published pointing at an enclosure
# nothing could download and plan_repair skipped the date forever. A missing
# name key used to arrive as the literal filename "null".
setup
export METADATA_DOC='{"files":[{"name":"mcp_meta.xml","size":"1024"},{"size":"123"},{"name":"2025-06-15.05.WPM.mp3"},{"name":"2025-06-15.10.WPM.mp3","size":""}]}'
export BACKFILL_DATES=2025-06-15
run && rc=0 || rc=$?
check "exits 0" "$rc"
check "counts no existing episodes" "$(grep -q 'WPM: 0 episodes' "$TD/out" && echo 0 || echo 1)"
check "presses all ${#WPM[@]} variants for 2025-06-15" "$([[ $(grep -c "^2025-06-15\." "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
teardown

echo "a mis-set REPAIR_PER_RUN -> warns, disables the repair, still presses today"
# An optional repair knob must never stop the podcast: this used to be
# validated inside plan_dates, which aborts before any network call.
setup
today=${DATES[6]}
for d in "${DATES[@]}"; do
  [[ $d == "$today" ]] && continue
  have_audio "$d"; : > "$TD/work/_posts/$d-Post.md"
done
have_post 2025-06-15 "a published note"
export REPAIR_PER_RUN=30
run && rc=0 || rc=$?
check "exits 0 instead of aborting the run" "$rc"
check "warns about the bad value" "$(grep -q 'REPAIR_PER_RUN must be 0' "$TD/out" && echo 0 || echo 1)"
check "presses today's ${#WPM[@]} variants" "$([[ $(grep -c "^$today\." "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
check "repairs nothing" "$(grep -q "^2025-06-15\." "$UPLOADED" && echo 1 || echo 0)"
teardown

echo "REPAIR_PER_RUN=0 -> a clean off switch, no repair and no gap report"
setup
today=${DATES[6]}
for d in "${DATES[@]}"; do
  [[ $d == "$today" ]] && continue
  have_audio "$d"; : > "$TD/work/_posts/$d-Post.md"
done
have_post 2025-06-15 "a published note"
export REPAIR_PER_RUN=0
run && rc=0 || rc=$?
check "exits 0" "$rc"
check "presses today's ${#WPM[@]} variants" "$([[ $(grep -c "^$today\." "$UPLOADED") -eq ${#WPM[@]} ]] && echo 0 || echo 1)"
check "repairs nothing" "$(grep -q "^2025-06-15\." "$UPLOADED" && echo 1 || echo 0)"
check "reports no gap at all" "$(grep -q 'Audio gap' "$TD/out" && echo 1 || echo 0)"
check "warns about nothing" "$(grep -q 'REPAIR_PER_RUN must be 0' "$TD/out" && echo 1 || echo 0)"
teardown

echo
if [[ $failures -eq 0 ]]; then
  echo "episode_press: all checks passed"
else
  echo "episode_press: $failures check(s) failed" >&2
  exit 1
fi
