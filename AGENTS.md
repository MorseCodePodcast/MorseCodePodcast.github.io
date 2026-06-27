# Agent Instructions — MorseCodePodcast

## Project scope

Jekyll-based podcast website for the Morse Code Podcast. Publishes episode show notes,
an RSS feed, and static pages. Source content lives in `_posts/` and `rss/`.

## Non-goals

- Don't modify audio files or hosting infrastructure (not in this repo).
- Don't add dependencies that require a Node/npm toolchain — this is a pure Ruby/Bundler project.
- Don't redesign the site layout without explicit direction from @rain.

## Conventions

- **VCS**: jj (Jujutsu) in collocated mode. Use `jj describe`, `jj bookmark`, `jj git push`. Never `git commit` directly.
- **Dependencies**: Ruby + Bundler. Run `bundle install` before `bundle exec jekyll build/serve`.
- **Issue tracking**: `.beads/` — use `bd ready` to find available work, `bd update <id> --claim` to claim it.
- **Universal recipes**: `just lint`, `just test`, `just build`, `just verify`, `just commit "msg"`.
- **RSS feed**: `rss/` contains hand-maintained feed files. Control characters and encoding issues have caused past corruption — validate XML before committing changes to those files.
- **Episode posts**: follow the existing filename convention `YYYY-MM-DD-title.md` in `_posts/`. Front matter fields (title, date, enclosure, duration) must be present for RSS to render correctly.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   # This repo is jj-collocated — use jj equivalents instead of raw git:
   jj git fetch
   jj git push
   # (Fallback if jj unavailable: git pull --rebase && git push)
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
