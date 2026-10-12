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
  : > "$EXISTING"; : > "$UPLOADED"

  # Stub archive.org: --head answers from $EXISTING, --upload-file appends to
  # it, anything else is the derive POST.
  cat > "$TD/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"; obj="${url##*/}"
[[ " $(cat "$EXISTING") " == *" $obj "* ]] && head_rc=0 || head_rc=1
for a in "$@"; do [[ $a == --head ]] && exit "$head_rc"; done
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
  # expects one -- it asserts the rendered episode is not 0 bytes.
  cat > "$TD/bin/ebook2cw" <<'STUB'
#!/usr/bin/env bash
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

teardown() { cd /; rm -rf "$TD"; unset FAIL_DATE; }

have_audio() { for w in "${WPM[@]}"; do printf ' %s.%s.WPM.mp3 ' "$1" "$w" >> "$EXISTING"; done; }
posts() { find "$TD/work/_posts" -name '*-Post.md' | wc -l; }
run() { bash ./episode_press.sh "${WPM[@]}" > "$TD/out" 2>&1; }

echo "nothing exists -> full backfill of every date in the window"
setup
run; rc=$?
check "exits 0" "$rc"
check "uploads ${#DATES[@]}x${#WPM[@]} files" "$([[ $(wc -l < "$UPLOADED") -eq $((${#DATES[@]} * ${#WPM[@]})) ]] && echo 0 || echo 1)"
check "creates one post per date" "$([[ $(posts) -eq ${#DATES[@]} ]] && echo 0 || echo 1)"
check "refreshes the archive.org item pages" "$(grep -q 'Triggering derive' "$TD/out" && echo 0 || echo 1)"
check "does not read back /download/ inline" "$(grep -qi 'verif' "$TD/out" && echo 1 || echo 0)"
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

echo
if [[ $failures -eq 0 ]]; then
  echo "episode_press: all checks passed"
else
  echo "episode_press: $failures check(s) failed" >&2
  exit 1
fi
