#!/bin/bash

TODAY=$(date +%F)
MESSAGE=$2
PODCAST_WPM=$1

# Compose the intro
espeak "This is the Morse Code Podcast for $(date  +'%A %B %e %Y')" --stdout | sox - -t mp3 -r 44100 $TODAY-intro.mp3

# Compose the message with WPM setting
echo "$MESSAGE" | ebook2cw -c "" -w 30 -e $PODCAST_WPM -s 44100 -o $TODAY-message-$PODCAST_WPM

# Compose the outro
espeak "This concludes our transmission" --stdout | sox - -t mp3 -r 44100 $TODAY-outro.mp3
# Press the episode
sox --combine concatenate $TODAY-intro.mp3 $TODAY-message-$PODCAST_WPM.mp3 $TODAY-outro.mp3 $TODAY-$PODCAST_WPM.WPM.mp3

# Get message from post notes
# tail -n 1 $TODAY-Post.md | ebook2cw  -c ""  -w 30 -e $PODCAST_WPM -s 44100 -o $TODAY-message

# Get message from fortune.
# fortune -s


function post {
    echo "
        ---
        layout: post
        title: "$TODAY"
        today: "$TODAY"
        wpm: "$PODCAST_WPM"
        date: $TODAY 00:00:00 -0600
        file: https://archive.org/download/MCP_$PODCAST_WPM-WPM/$TODAY-$PODCAST_WPM-WPM.mp3
        file_itunes: //path/
        excerpt: 
        summary: 
        duration: 
        length: "$(<$TODAY.mp3 wc -c)"
        explicit: "no"
        block: "no"
        ---
        "
}

exit 0
