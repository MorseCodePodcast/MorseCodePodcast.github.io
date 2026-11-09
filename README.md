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
| `episode_press.sh` | Generates and uploads episodes. Backfills up to 7 days, then repairs the archive gap. |
| `backfill_metadata.py` | Writes true episode size/duration into post front matter. |
| `verify_feeds.py` | Asserts the built feeds are consumable by podcast clients. |
| `test_episode_press.sh` | Offline tests for the episode_press decision logic. |
| `test_backfill_metadata.py` | Offline tests for the metadata rewrite and its outage tolerance. |
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

## The archive gap

476 dates (as of 2026-11-09) have a published post but no audio on archive.org
— most of 2025 plus the tail of 2024. Those posts were listed in the feed with
`length="0"` before the enclosure fix, so a subscription older than that still
holds ~476 items whose enclosures 404 and retries them on every refresh.

Each daily run presses `REPAIR_PER_RUN` of them (default 3, capped at 20) after
the seven-day window, **newest missing first**. Newest first because the feed
only carries the newest 100 items that have audio, which reaches back about
three months: filling a 2025 date is invisible to a new subscriber and exists
purely to stop existing clients retrying a dead URL. The repair is
self-limiting — with no gap it presses nothing — and a historical date that
fails never fails the run or blocks the deploy.

Each run prints the remaining count to the job summary. A count that stops
falling means one date is permanently unpressable and is eating the budget
every run; there is no skip-list, so that flat number is the only signal.

`BACKFILL_DATES="2025-06-15 2025-06-16" ./episode_press.sh 05 10 15 20 25 30`
presses specific dates instead of the window. A date whose post exists reuses
that post's stored `message:` text and never calls `fortune`, so regenerated
audio still matches the published show note.

## Feed verification

`verify_feeds.py` checks **every** enclosure in all six feeds against
archive.org's item metadata — six HTTP requests total, no sampling. It replaced
a three-random-HEADs-per-feed spot check that a single bad item passed most of
the time. archive.org being unreachable, erroring, or returning the bare `{}` it
serves for an unreadable item is a warning, not a failure: an upstream blip must
not stop the site deploying. `backfill_metadata.py` tolerates the same
conditions by leaving that speed's existing values alone rather than stripping
them, which is how a blip would otherwise empty all six feeds.
