# MorseCodePodcast

Automated podcast that releases daily episodes to help train Morse Code
recognition. `fortune` supplies the text, `espeak` the spoken intro/outro and
`ebook2cw` the Morse audio at six speeds; episodes are uploaded to archive.org
and published as six RSS feeds, one per speed, via GitHub Actions.

Feeds: `https://morsecodepodcast.github.io/rss/<NN>WPM.xml` for `NN` in
05, 10, 15, 20, 25, 30.

## Layout

| Path | Purpose |
| --- | --- |
| `episode_press.sh` | Generates and uploads episodes. Backfills up to 7 days. |
| `backfill_metadata.py` | Writes true episode size/duration into post front matter. |
| `verify_feeds.py` | Asserts the built feeds are consumable by podcast clients. |
| `make_artwork.sh` | Regenerates `assets/itunes.png` cover art. |
| `_includes/feed.xml` | The one feed template; `rss/*.xml` are per-speed wrappers. |

## Local Development

```sh
bundle install
bundle exec jekyll serve
```

`just test` builds the site and verifies the feeds. It falls back to
`nix-shell -p jekyll` when Ruby is not installed.

## Episode metadata

Each speed produces a different file from the same text, so posts carry
`length_<wpm>` and `duration_<wpm>` in front matter rather than one shared
value. These are filled in by `backfill_metadata.py`, which reads the true
sizes from archive.org's item metadata — six HTTP requests, no per-episode
crawling. The feed template omits any episode with no recorded size, so it
never advertises audio that was not uploaded.
