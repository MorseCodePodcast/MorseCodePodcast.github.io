#!/bin/bash
# Morse Code Podcast Episode Generator
# Generates Morse code episodes and uploads to Archive.org
# Supports backfill for the last 7 days if episodes were missed

# Continue on errors - uploads may fail but we should keep trying
set +e

PODCAST_WPM=("$@")
MAX_BACKFILL_DAYS=7

# Check if episode exists on Archive.org
check_episode_exists() {
  local date=$1
  local wpm=$2
  curl --head --fail --silent --output /dev/null --location-trusted \
    "https://archive.org/download/mcp.$wpm.WPM/$date.$wpm.WPM.mp3"
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

# Get or create message for a date
get_message() {
  local date=$1
  local post_file="_posts/$date-Post.md"

  if [[ -f "$post_file" ]]; then
    grep -oP "^message:\s+\K.*" "$post_file" || fortune -s | tr -d '\n' | tr -s '\t' ' ' | tr -s '"' ' ' | tr -s '  '
  else
    fortune -s | tr -d '\n' | tr -s '\t' ' ' | tr -s '"' ' ' | tr -s '  '
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
duration: "01:00"
length: "11444"
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

  # If all episodes exist, nothing to do
  if [[ ${#wpms_to_process[@]} -eq 0 ]]; then
    echo "All episodes exist for $date"
    return 0
  fi

  echo "Processing ${#wpms_to_process[@]} missing WPM variants for $date"

  # Get or create the message
  local message
  message=$(get_message "$date")
  create_post "$date" "$message"

  # Get human-readable date for intro
  local readable_date
  readable_date=$(date -d "$date" +'%A %B %e %Y' 2>/dev/null || date -j -f "%Y-%m-%d" "$date" +'%A %B %e %Y')

  # Generate intro if needed
  if [[ ! -f "$date-intro.mp3" ]]; then
    espeak "This is the Morse Code Podcast for $readable_date" --stdout | \
      sox - -t mp3 -r 44100 "$date"-intro.mp3
  fi

  # Generate outro if needed
  if [[ ! -f "$date-outro.mp3" ]]; then
    espeak "This concludes our transmission" --stdout | \
      sox - -t mp3 -r 44100 "$date"-outro.mp3
  fi

  # Process each missing WPM variant
  for wpm in "${wpms_to_process[@]}"; do
    echo "  Generating $wpm WPM for $date..."

    # Generate Morse code audio
    echo "$message" | ebook2cw -c "" -w 30 -e "$wpm" -s 44100 -o "$date"-message-"$wpm"

    # Combine intro + message + outro
    sox --combine concatenate "$date"-intro.mp3 "$date"-message-"$wpm".mp3 "$date"-outro.mp3 "$date"."$wpm".WPM.mp3

    # Upload to Archive.org
    echo "  Uploading $wpm WPM to Archive.org..."
    if curl --location --silent --show-error \
      --header 'x-amz-auto-make-bucket:1' \
      --header 'x-archive-meta01-collection:opensource_audio' \
      --header 'x-archive-meta-mediatype:audio' \
      --header "x-archive-meta-title:Morse Code Podcast $wpm.WPM" \
      --header "authorization: LOW $S3_ACCESS:$S3_SECRET" \
      --upload-file "$date.$wpm.WPM.mp3" \
      "https://s3.us.archive.org/mcp.$wpm.WPM/$date.$wpm.WPM.mp3"; then
      echo "  Uploaded $date.$wpm.WPM.mp3"
    else
      echo "  Warning: Failed to upload $date.$wpm.WPM.mp3 (will retry next run)"
    fi
  done

  # Cleanup temp files
  rm -f "$date"-intro.mp3 "$date"-outro.mp3 "$date"-message-*.mp3 "$date".*.WPM.mp3 2>/dev/null || true
}

# Main: process today and backfill missed days (up to MAX_BACKFILL_DAYS)
main() {
  if [[ ${#PODCAST_WPM[@]} -eq 0 ]]; then
    echo "Usage: $0 <WPM1> [WPM2] [WPM3] ..."
    echo "Example: $0 05 10 15 20 25 30"
    exit 1
  fi

  echo "Morse Code Podcast Generator"
  echo "WPM variants: ${PODCAST_WPM[*]}"
  echo "Backfill window: $MAX_BACKFILL_DAYS days"
  echo ""

  local processed=0

  # Process from oldest to newest (so today is last)
  for ((i = MAX_BACKFILL_DAYS - 1; i >= 0; i--)); do
    local date
    # GNU date vs BSD date compatibility
    date=$(date -d "$i days ago" +%F 2>/dev/null || date -v-"$i"d +%F)

    if ! all_episodes_exist "$date"; then
      process_date "$date"
      ((processed++))
    fi
  done

  if [[ $processed -eq 0 ]]; then
    echo "All episodes up to date. Nothing to do."
  else
    echo ""
    echo "Processed $processed date(s)"
  fi
}

main
