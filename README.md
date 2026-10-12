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
| `test_episode_press.sh` | Offline tests for the episode_press decision logic. |
| `make_artwork.sh` | Regenerates `assets/itunes.png` cover art. |
| `_includes/feed.xml` | The one feed template; `rss/*.xml` are per-speed wrappers. |

## Local Development

```sh
bundle install
bundle exec jekyll serve
```

`just test` runs `test_episode_press.sh`, then builds the site and verifies
the feeds. It falls back to `nix-shell -p jekyll` when Ruby is not installed.
The press tests stub out the network and the audio toolchain, so they need
nothing but bash.

## Episode metadata

Each speed produces a different file from the same text, so posts carry
`length_<wpm>` and `duration_<wpm>` in front matter rather than one shared
value. These are filled in by `backfill_metadata.py`, which reads the true
sizes from archive.org's item metadata — six HTTP requests, no per-episode
crawling. The feed template omits any episode with no recorded size, so it
never advertises audio that was not uploaded.

A new episode appears in the feeds one run after it is uploaded. A 200 from
archive.org's S3 endpoint does not publish the file at `archive.org/download/`
-- that needs the item's derive task, which lags by minutes to hours. Until it
completes `backfill_metadata.py` cannot read the real size, and `feed.xml`
deliberately skips any item with no recorded size rather than emit an enclosure
that 404s. The next scheduled run fills the sizes in and the episode appears.
For the same reason `episode_press.sh` does not verify uploads by reading them
back: that would be asking about a refresh it has not requested yet. A missing
upload is caught instead by the following run's existence check, inside the
seven-day backfill window.
