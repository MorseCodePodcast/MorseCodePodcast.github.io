#!/bin/bash

TODAY=$(date +%F)
PODCAST_WPM=($(printf "%s " "$@"))

# If there's a preset MESSAGE for TODAY, use that one. Otherwise pick one at random.
if test -f "_posts/$TODAY-Post.md"; then
  MESSAGE="$(grep -oP "^message:\s+\K.*" _posts/$TODAY-Post.md)"
else
  MESSAGE="$(fortune -s | tr -d '\n' | tr -s '\t' ' '| tr -s '"' ' ' | tr -s '  ')"
  echo "\
---
layout: post
title: \"$TODAY\"
date: $TODAY 00:00:00 -0600
file:
file_itunes:
excerpt:
summary: \"$MESSAGE\"
message: $MESSAGE
duration: \"01:00\"
length: \"11444\"
explicit: \"no\"
block: \"no\"
---
$MESSAGE
" > _posts/$(date +%F)-Post.md
fi

# Check if files are already uploaded, for each one that is remove it from the array.
for i in "${PODCAST_WPM[@]}"; do
  curl --head --silent --fail https://archive.org/download/mcp."$i".WPM/"$TODAY"."$i".WPM.mp3 &>/dev/null
if [ $? -eq 0 ]; then
  unset PODCAST_WPM[0]
  PODCAST_WPM=("${PODCAST_WPM[@]:0}")
  if [ -z "$PODCAST_WPM" ]; then 
    echo "Everything already happened and I'm late to the party"; exit 0 
  fi
fi
done
# Compose the intro
if test -f "$TODAY-intro.mp3"; then
  true
else
  espeak "This is the Morse Code Podcast for $(date  +'%A %B %e %Y')" --stdout | sox - -t mp3 -r 44100 "$TODAY"-intro.mp3
fi

# Compose the outro
if test -f "$TODAY-outro.mp3"; then
  true
else
  espeak "This concludes our transmission" --stdout | sox - -t mp3 -r 44100 "$TODAY"-outro.mp3
fi

# Compose each message with WPM setting
for i in "${PODCAST_WPM[@]}"; do
	echo "$MESSAGE" | ebook2cw -c "" -w 30 -e "$i" -s 44100 -o "$TODAY"-message-"$i"; done

# Press each episode
for i in "${PODCAST_WPM[@]}"; do
  sox --combine concatenate "$TODAY"-intro.mp3 "$TODAY"-message-"$i".mp3 "$TODAY"-outro.mp3 "$TODAY"."$i".WPM.mp3; done

# Upload each episode to Archive.org for hosting
for i in "${PODCAST_WPM[@]}"; do
  curl --location --header 'x-amz-auto-make-bucket:1' \
       --header 'x-archive-meta01-collection:opensource_audio' \
       --header 'x-archive-meta-mediatype:audio' \
       --header "x-archive-meta-title:Morse Code Podcast $i.WPM" \
       --header "authorization: LOW ${{ secrets.S3_ACCESS }}:${{ secrets.S3_SECRET }}" \
       --upload-file "$TODAY"."$i".WPM.mp3 \
       http://s3.us.archive.org/mcp."$i".WPM/"$TODAY"."$i".WPM.mp3

exit 0
