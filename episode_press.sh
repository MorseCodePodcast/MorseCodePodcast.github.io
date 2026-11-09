#!/bin/bash
# Morse Code Podcast Episode Generator
# Generates Morse code episodes and uploads to Archive.org
# Supports backfill for the last 7 days if episodes were missed
# BACKFILL_DATES="2025-06-15 2025-06-16" presses exactly those dates instead,
# for historical dates the 7-day window can no longer reach.
# REPAIR_PER_RUN=N (default 3) additionally repairs the N newest dates that have
# a post but no audio, after the window has been processed.

set -euo pipefail

PODCAST_WPM=("$@")
MAX_BACKFILL_DAYS=7
# Dates with a post but no audio to repair per run, after the window. 0 is off.
# Each date is ~67s for all six speeds, so this is the per-run cost knob.
REPAIR_PER_RUN=${REPAIR_PER_RUN:-3}
MAX_REPAIR_PER_RUN=20

# Track which items need derive tasks triggered
ITEMS_TO_DERIVE=()
# Track failed uploads for reporting
FAILED_UPLOADS=()
# Repair failures are kept out of FAILED_UPLOADS on purpose: FAILED_UPLOADS
# exits 1, which turns the whole run red via the `report` job in build.yml.
# Today's episode failing is worth that; a 2025 date that cannot be pressed is
# not, and one permanently dead historical date would otherwise make every
# daily run red forever and train everyone to ignore the signal.
REPAIR_FAILURES=()

# Trigger derive task to refresh an item's page on Archive.org
trigger_derive() {
  local item=$1
  echo "  Triggering derive for $item..."
  curl --silent --show-error --max-time 60 \
    -X POST "https://archive.org/services/tasks.php" \
    -H "Authorization: LOW $S3_ACCESS:$S3_SECRET" \
    -H "Content-Type: application/json" \
    -d "{\"identifier\":\"$item\",\"cmd\":\"derive.php\",\"args\":{}}" \
    | grep -q '"success":true' && echo "  Derive task queued for $item" \
    || echo "  Warning: Failed to queue derive for $item"
}

# Every "<date>.<wpm>.WPM.mp3" already on archive.org, filled in by
# prefetch_existing_audio before any date is looked at.
declare -A EXISTING_AUDIO=()

# archive.org lists every file of an item in one metadata document, so six
# requests answer existence for the whole archive. One HEAD per (date, wpm) was
# 42 requests for the 7-day window but would be 2850 for the 475-date backfill,
# which archive.org throttles.
prefetch_existing_audio() {
  local wpm meta names name count

  # The one predicate this script uses to decide an episode exists, written to
  # agree with verify_feeds.py:metadata and backfill_metadata.py:fetch: a
  # "<date>.<wpm>.WPM.mp3" entry that also carries a size. An entry without a
  # size read as "audio exists" here while both of those read it as "no audio",
  # so the post was kept, the feed never emitted the date, and plan_repair
  # skipped it forever. A missing `name` key used to yield the literal string
  # "null" as a filename, which inflated the count without naming any episode.
  #
  # The empty case errors rather than printing nothing: archive.org answers
  # `{}` AND `{"files":[]}` for an item it cannot read, and jq exits 0 on the
  # latter. Reading either as "no episodes exist" re-presses every window and
  # repair date -- 60 uploads over enclosures subscribers are downloading --
  # every run until archive.org recovers, with nothing going red because the
  # press step is continue-on-error.
  local files_filter='
    if has("files") and (.files | length) > 0 then
      .files[]
      | select((.name? // "") | test(
          "^[0-9]{4}-[0-9]{2}-[0-9]{2}\\.[0-9]+\\.WPM\\.mp3$"))
      | select(((.size? // "") | tostring) != "")
      | .name
    else
      error("no file list in metadata document")
    end'

  for wpm in "${PODCAST_WPM[@]}"; do
    # Retried like upload_with_retry below: one transient 503 on one of these
    # six GETs used to abort the prefetch and press zero episodes that day.
    # --max-time is per attempt; the document is a few MB of JSON at most.
    if ! meta=$(curl --fail --silent --show-error --location \
      --retry 3 --retry-all-errors --retry-delay 5 --max-time 120 \
      "https://archive.org/metadata/mcp.$wpm.WPM"); then
      echo "FAILED: could not fetch metadata for mcp.$wpm.WPM" >&2
      return 1
    fi

    if ! names=$(jq --raw-output "$files_filter" <<< "$meta"); then
      echo "FAILED: no file list in metadata for mcp.$wpm.WPM" >&2
      return 1
    fi

    count=0
    while read -r name; do
      [[ -n $name ]] || continue
      EXISTING_AUDIO[$name]=1
      ((count++)) || true
    done <<< "$names"
    echo "  mcp.$wpm.WPM: $count episodes"
  done
}

# Dates to press, oldest first.
DATES_TO_PRESS=()

# Fill DATES_TO_PRESS. BACKFILL_DATES (whitespace- or newline-separated)
# replaces the rolling window for that one run: a historical date is outside
# MAX_BACKFILL_DAYS, so it can never self-heal, and the window is the only
# thing an explicit list is allowed to change. Unset, the window is unchanged.
plan_dates() {
  local date fmt i
  local bad=()

  if [[ -z ${BACKFILL_DATES:-} ]]; then
    # Process from oldest to newest (so today is last)
    for ((i = MAX_BACKFILL_DAYS - 1; i >= 0; i--)); do
      # GNU date vs BSD date compatibility
      DATES_TO_PRESS+=("$(date -d "$i days ago" +%F 2>/dev/null \
        || date -v-"$i"d +%F)")
    done
    return 0
  fi

  # Unquoted on purpose: this is the whitespace/newline split.
  for date in ${BACKFILL_DATES}; do
    # Shape alone would accept 2026-02-31 and press a nonexistent day, so the
    # date must also round-trip through date(1).
    fmt=$(date -d "$date" +%F 2>/dev/null \
      || date -j -f %Y-%m-%d "$date" +%F 2>/dev/null) || fmt=
    if [[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $fmt == "$date" ]]; then
      DATES_TO_PRESS+=("$date")
    else
      bad+=("$date")
    fi
  done

  # Loud, because a typo that silently pressed nothing would look like success.
  if (( ${#bad[@]} > 0 )); then
    printf 'FAILED: not a valid YYYY-MM-DD date in BACKFILL_DATES: %s\n' \
      "${bad[@]}" >&2
    return 1
  fi
  if (( ${#DATES_TO_PRESS[@]} == 0 )); then
    echo "FAILED: BACKFILL_DATES is set but names no dates" >&2
    return 1
  fi
}

# Loud, not clamped -- a fat-fingered REPAIR_PER_RUN=30 is ~34 minutes of extra
# runner time, so silently pressing 20 instead would hide the typo -- but never
# fatal. This used to be validated inside plan_dates, which gates the whole run
# before any network call, so REPAIR_PER_RUN=30 meant today's episode was never
# pressed. An optional repair knob must not stop the podcast.
validate_repair_per_run() {
  # 10# forces base 10: this repo writes speeds zero-padded (05, 10), so
  # REPAIR_PER_RUN=010 is a plausible fat-finger, and bash would otherwise read
  # it as octal and quietly repair 8 dates while the log said 010.
  if [[ $REPAIR_PER_RUN =~ ^[0-9]+$ ]] \
    && (( 10#$REPAIR_PER_RUN <= MAX_REPAIR_PER_RUN )); then
    REPAIR_PER_RUN=$((10#$REPAIR_PER_RUN))
    return 0
  fi
  echo "WARNING: REPAIR_PER_RUN must be 0..$MAX_REPAIR_PER_RUN," \
    "got '$REPAIR_PER_RUN' -- repair disabled for this run, the window is" \
    "pressed as usual" >&2
  REPAIR_PER_RUN=0
}

# Check if episode exists on Archive.org. Answers from the prefetched set, and
# stays the only place that decides whether an episode exists.
check_episode_exists() {
  local date=$1
  local wpm=$2
  [[ -n ${EXISTING_AUDIO["$date.$wpm.WPM.mp3"]:-} ]]
}

# Check if ALL WPM variants exist for a given date
all_episodes_exist() {
  local date=$1
  for wpm in "${PODCAST_WPM[@]}"; do
    if ! check_episode_exists "$date" "$wpm"; then
      return 1
    fi
  done
  return 0
}

# The REPAIR_PER_RUN newest repair candidates, and the full gap count.
REPAIR_DATES=()
REPAIR_GAP=0

# Fill REPAIR_DATES with the dates that have a post but incomplete audio --
# i.e. a published feed entry whose enclosure 404s for everyone subscribed.
#
# NEWEST FIRST, deliberately: the feed only lists the newest 100 items that
# have audio, so filling an old date is invisible to new subscribers. The repair
# exists solely to stop clients that already hold a broken enclosure retrying
# it, and the most recently broken dates are the ones still live in those
# clients. Do not "improve" this to oldest-first.
#
# Costs nothing on the network: existence comes from the prefetched set, so an
# empty gap means this is a few thousand array lookups and no requests.
plan_repair() {
  local post date i
  local -A planned=()
  local posts=(_posts/*-Post.md)

  # The window already covers these; the repair must never redo them.
  for date in "${DATES_TO_PRESS[@]}"; do planned[$date]=1; done

  # Glob expansion is sorted, and YYYY-MM-DD sorts chronologically, so walking
  # it backwards is newest first.
  for ((i = ${#posts[@]} - 1; i >= 0; i--)); do
    post=${posts[i]##*/}
    date=${post%-Post.md}
    [[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    all_episodes_exist "$date" && continue
    # Counted before the window is excluded: REPAIR_GAP is reported as "dates
    # with a published post but no audio", which is just as true of a window
    # date whose press failed. Only the repair *budget* skips those -- the
    # press loop above already covered them. Seeding the count from the same
    # exclusion under-reported the real gap by up to 7.
    ((REPAIR_GAP++)) || true
    [[ -z ${planned[$date]:-} ]] || continue
    if (( ${#REPAIR_DATES[@]} < REPAIR_PER_RUN )); then
      REPAIR_DATES+=("$date")
    fi
  done
}

# Upload with retry and exponential backoff
upload_with_retry() {
  local file=$1
  local url=$2
  local wpm=$3
  local max_attempts=3
  local attempt=1
  local delay=5

  while (( attempt <= max_attempts )); do
    # --max-time is per attempt. 300s for a few-MB mp3 is a ~17 kB/s floor:
    # generous for a slow runner, and the only thing standing between a hung
    # transfer and the 90-minute job cap -- curl waits forever by default, and
    # a window plus repair is up to 60 uploads, so one hang used to be able to
    # eat the cap and leave the commit and deploy steps unrun.
    if curl --fail --location --silent --show-error --max-time 300 \
      --header 'x-amz-auto-make-bucket:1' \
      --header 'x-archive-meta01-collection:opensource_audio' \
      --header 'x-archive-meta-mediatype:audio' \
      --header "x-archive-meta-title:Morse Code Podcast ${wpm}.WPM" \
      --header "authorization: LOW $S3_ACCESS:$S3_SECRET" \
      --upload-file "$file" \
      "$url"; then
      return 0
    fi
    echo "  Upload attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay * 3))
    ((attempt++))
  done
  return 1
}

# Fresh show-note text. Newlines/tabs become spaces rather than being deleted,
# otherwise adjacent sentences weld together. Double quotes are dropped because
# the message is embedded in a double-quoted YAML scalar.
new_message() {
  fortune -s \
    | tr '\n\b\t' '   ' \
    | tr -cd '[:print:]' \
    | tr '"' ' ' \
    | tr -s ' ' \
    | sed 's/^ *//; s/ *$//'
}

# Get or create message for a date
get_message() {
  local date=$1
  local post_file="_posts/$date-Post.md"

  if [[ -f "$post_file" ]]; then
    grep -oP "^message:\s+\K.*" "$post_file" | tr -d '"' || new_message
  else
    new_message
  fi
}

# Create post file if it doesn't exist
create_post() {
  local date=$1
  local message=$2
  local post_file="_posts/$date-Post.md"

  if [[ ! -f "$post_file" ]]; then
    cat > "$post_file" << EOF
---
layout: post
title: "$date"
today: "$date"
date: $date 00:00:00 0000
file:
file_itunes:
excerpt:
summary: "$message"
message: "$message"
explicit: "no"
block: "no"
---
$message
EOF
    echo "Created post for $date"
  fi
}

# Generate and upload episodes for a specific date
process_date() {
  local date=$1
  local wpms_to_process=()

  echo "Checking episodes for $date..."

  # Check which WPM variants are missing
  for wpm in "${PODCAST_WPM[@]}"; do
    if ! check_episode_exists "$date" "$wpm"; then
      wpms_to_process+=("$wpm")
    else
      echo "  $wpm WPM already exists, skipping"
    fi
  done

  # All audio present. Reached only when the post is missing, so create it:
  # otherwise a date whose uploads landed but whose post was skipped stays
  # invisible in the feed forever.
  if [[ ${#wpms_to_process[@]} -eq 0 ]]; then
    echo "All episodes exist for $date, creating missing post"
    create_post "$date" "$(get_message "$date")"
    return 0
  fi

  echo "Processing ${#wpms_to_process[@]} missing WPM variants for $date"

  # Get the message (from existing post or generate new one).
  # Checked explicitly: process_date runs on the left of a `||`, which disables
  # errexit inside it, so a failing `fortune` would otherwise sail through and
  # publish an episode of silence with an empty show note.
  local message
  if ! message=$(get_message "$date") || [[ -z $message ]]; then
    echo "  FAILED: could not get a show-note message for $date"
    return 1
  fi

  # Get human-readable date for intro
  local readable_date
  readable_date=$(date -d "$date" +'%A %B %e %Y' 2>/dev/null || date -j -f "%Y-%m-%d" "$date" +'%A %B %e %Y')

  # Generate intro if needed
  if [[ ! -s "$date-intro.mp3" ]]; then
    espeak "This is the Morse Code Podcast for $readable_date" --stdout | \
      sox - -t mp3 -r 44100 "$date"-intro.mp3 || {
        echo "  FAILED: could not render intro for $date"
        return 1
      }
  fi

  # Generate outro if needed
  if [[ ! -s "$date-outro.mp3" ]]; then
    espeak "This concludes our transmission" --stdout | \
      sox - -t mp3 -r 44100 "$date"-outro.mp3 || {
        echo "  FAILED: could not render outro for $date"
        return 1
      }
  fi

  # Upload each missing WPM variant, track success
  local all_uploaded=true

  for wpm in "${wpms_to_process[@]}"; do
    echo "  Generating $wpm WPM for $date..."

    # Generate Morse code audio, then combine intro + message + outro.
    # Both are guarded, and the result is required to be non-empty, so a
    # toolchain failure cannot put a 0-byte "episode" on archive.org.
    if ! echo "$message" | ebook2cw -c "" -w 30 -e "$wpm" -s 44100 -o "$date"-message-"$wpm" \
      || ! sox --combine concatenate "$date"-intro.mp3 "$date"-message-"$wpm".mp3 \
           "$date"-outro.mp3 "$date"."$wpm".WPM.mp3 \
      || [[ ! -s "$date.$wpm.WPM.mp3" ]]; then
      echo "  FAILED: could not render $wpm WPM audio for $date"
      FAILED_UPLOADS+=("$date.$wpm.WPM.mp3 (render error)")
      all_uploaded=false
      continue
    fi

    # A 200 from archive.org's S3 endpoint is the authoritative ack. There is
    # deliberately no read-back check here: /download/ only reflects an upload
    # after the item's derive task runs, and derive is triggered once at the
    # end of main -- so an inline poll was asking about a refresh that had not
    # been requested yet. It cost ~140s per variant and still reported healthy
    # uploads as failed, which suppressed the post; the next run then saw the
    # audio, called the date complete, and never created the post, leaving
    # episodes on archive.org that nothing in the feed pointed at. Existence is
    # re-checked on the next run instead, after derive has had time to land.
    echo "  Uploading $wpm WPM to Archive.org..."
    local upload_url="https://s3.us.archive.org/mcp.$wpm.WPM/$date.$wpm.WPM.mp3"

    if upload_with_retry "$date.$wpm.WPM.mp3" "$upload_url" "$wpm"; then
      echo "  Uploaded: $date.$wpm.WPM.mp3"
      # The prefetched set is a startup snapshot, so record the new file:
      # a later check in this same run must not see it as missing.
      EXISTING_AUDIO["$date.$wpm.WPM.mp3"]=1
      # Track this item for derive task (avoid duplicates)
      if [[ ! " ${ITEMS_TO_DERIVE[*]:-} " =~ " mcp.$wpm.WPM " ]]; then
        ITEMS_TO_DERIVE+=("mcp.$wpm.WPM")
      fi
    else
      echo "  FAILED: $date.$wpm.WPM.mp3 upload failed after retries"
      FAILED_UPLOADS+=("$date.$wpm.WPM.mp3")
      all_uploaded=false
    fi
  done

  # Only create post if ALL WPM variants uploaded: a partial date would
  # publish a feed entry whose enclosures 404 for some WPM variants.
  if $all_uploaded; then
    create_post "$date" "$message"
  else
    echo "  Skipping post creation for $date (some uploads failed)"
  fi

  # Cleanup temp files
  rm -f "$date"-intro.mp3 "$date"-outro.mp3 "$date"-message-*.mp3 "$date".*.WPM.mp3 2>/dev/null || true
}

# Report the repair outcome and what is left. The remaining count goes to the
# job summary so "how much of the archive is still silent" is one number on the
# run page instead of a grep through 40 minutes of log.
report_repair() {
  local date
  local repaired=0

  # Recounted rather than inferred from REPAIR_FAILURES: a date whose uploads
  # partly failed is still in the gap, and the prefetched set has already been
  # updated with whatever landed.
  for date in "${REPAIR_DATES[@]}"; do
    all_episodes_exist "$date" && ((repaired++)) || true
  done

  echo ""
  echo "Audio gap: $REPAIR_GAP date(s) with a post but no audio," \
    "repaired $repaired this run, $((REPAIR_GAP - repaired)) remaining"
  if (( ${#REPAIR_FAILURES[@]} > 0 )); then
    echo "Repair failures (not fatal, a later run retries them):"
    printf '  - %s\n' "${REPAIR_FAILURES[@]}"
  fi

  [[ -n ${GITHUB_STEP_SUMMARY:-} ]] || return 0
  {
    echo "## Episode audio gap"
    echo ""
    echo "\`$((REPAIR_GAP - repaired))\` date(s) have a published post but no" \
      "audio on archive.org (was \`$REPAIR_GAP\` before the repair)."
    echo "Repaired \`$repaired\` this run, newest first," \
      "\`REPAIR_PER_RUN=$REPAIR_PER_RUN\`."
    if (( ${#REPAIR_FAILURES[@]} > 0 )); then
      echo ""
      echo "Repair failures, deliberately **not** fatal to the daily run:"
      printf -- '- \`%s\`\n' "${REPAIR_FAILURES[@]}"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
}

# Main: process today and backfill missed days (up to MAX_BACKFILL_DAYS)
main() {
  if [[ ${#PODCAST_WPM[@]} -eq 0 ]]; then
    echo "Usage: $0 <WPM1> [WPM2] [WPM3] ..."
    echo "Example: $0 05 10 15 20 25 30"
    exit 1
  fi

  # Before the network: a bad date list must fail without touching anything.
  plan_dates || exit 1
  validate_repair_per_run

  echo "Morse Code Podcast Generator"
  echo "WPM variants: ${PODCAST_WPM[*]}"
  if [[ -n ${BACKFILL_DATES:-} ]]; then
    echo "Explicit dates: ${DATES_TO_PRESS[*]}"
  else
    echo "Backfill window: $MAX_BACKFILL_DAYS days"
  fi
  echo ""

  # Fails the run rather than guessing: a wrong answer here either re-uploads
  # thousands of episodes or publishes posts for audio that is not there.
  echo "Listing existing episodes on archive.org..."
  prefetch_existing_audio || exit 1
  echo ""

  local processed=0
  local date

  for date in "${DATES_TO_PRESS[@]}"; do
    if ! all_episodes_exist "$date" || [[ ! -f "_posts/$date-Post.md" ]]; then
      # Isolated on purpose: set -e used to abort the whole loop on the oldest
      # failing date, so one broken day blocked the six newer ones from ever
      # being generated (fortune data outage, 2026-10-06 .. 2026-10-12).
      process_date "$date" || FAILED_UPLOADS+=("$date (processing error, see log above)")
      ((processed++)) || true
    fi
  done

  # After the window, never instead of it: today's episode is the urgent one, a
  # historical date is not. Skipped for an explicit BACKFILL_DATES run so a
  # targeted manual press stays exactly what was asked for.
  if [[ -z ${BACKFILL_DATES:-} ]] && (( REPAIR_PER_RUN > 0 )); then
    local failed_before=${#FAILED_UPLOADS[@]}

    plan_repair
    for date in "${REPAIR_DATES[@]}"; do
      echo ""
      echo "Repairing $date (post published, audio missing)"
      # process_date only returns non-zero before it uploads anything (no
      # message, no intro/outro), so this never double-counts the entries the
      # upload loop pushes into FAILED_UPLOADS.
      process_date "$date" || REPAIR_FAILURES+=("$date (repair aborted)")
      ((processed++)) || true
    done

    # process_date reports into FAILED_UPLOADS, which exits 1. Move anything a
    # repair date added: see the REPAIR_FAILURES comment at the top.
    if (( ${#FAILED_UPLOADS[@]} > failed_before )); then
      REPAIR_FAILURES+=("${FAILED_UPLOADS[@]:failed_before}")
      FAILED_UPLOADS=("${FAILED_UPLOADS[@]:0:failed_before}")
    fi
    report_repair
  fi

  if [[ $processed -eq 0 ]]; then
    echo "All episodes up to date. Nothing to do."
  else
    echo ""
    echo "Processed $processed date(s)"

    # Trigger derive tasks to refresh item pages on Archive.org
    if [[ ${#ITEMS_TO_DERIVE[@]} -gt 0 ]]; then
      echo ""
      echo "Triggering item page refreshes..."
      for item in "${ITEMS_TO_DERIVE[@]}"; do
        trigger_derive "$item"
      done
    fi
  fi

  # Report failures
  if [[ ${#FAILED_UPLOADS[@]} -gt 0 ]]; then
    echo ""
    echo "========================================="
    echo "FAILURES (${#FAILED_UPLOADS[@]}):"
    printf '  - %s\n' "${FAILED_UPLOADS[@]}"
    echo "========================================="

    # Write to GitHub Actions job summary if available
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "## :warning: Episode Failures"
        echo ""
        printf -- '- \`%s\`\n' "${FAILED_UPLOADS[@]}"
        echo ""
        echo "These episodes were not published. Posts were **not** created for dates with failures."
        # The old text promised the 7-day window for every failure, which is
        # wrong for an explicit list (nothing re-reads it) and for a repair date
        # (it comes back via the repair budget, not the window).
        if [[ -n ${BACKFILL_DATES:-} ]]; then
          echo "These dates came from \`BACKFILL_DATES\`; nothing retries them automatically -- re-run the workflow with the same list."
        else
          echo "These dates are inside the ${MAX_BACKFILL_DAYS}-day window, so the next run retries them. Historical repair dates never reach this list -- they are reported under *Episode audio gap* above and retried as the repair budget reaches them."
        fi
      } >> "$GITHUB_STEP_SUMMARY"
    fi

    exit 1
  fi
}

main
