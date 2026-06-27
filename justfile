# justfile — MorseCodePodcast
#
# Universal recipe API per rain/just-spec (no-version variant).
# Project has no versioned package; bump is a no-op.

default:
    @just --list --unsorted

# Verify Gemfile dependencies are satisfied (skips gracefully if bundle unavailable)
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v bundle &>/dev/null; then
        bundle check
    else
        echo "lint: bundle not found, skipping Gemfile check"
    fi

# No automated tests; stub returns success so verify chain works
test:
    @echo "test: no test suite (TODO: add Jekyll build smoke-test)"

# Build the Jekyll site (skips gracefully if bundle unavailable)
build:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v bundle &>/dev/null; then
        bundle exec jekyll build
    else
        echo "build: bundle not found, skipping Jekyll build"
    fi

# Pre-push gate: lint + test + build
verify: lint test build

# No versioned package — bump is a no-op
bump level="patch":
    @echo "bump: no versioned package; skipping"

# No profilable workload — profile is a no-op per just-spec api.md
profile:
    @echo "no profilable workload for this project; profile is a no-op"

# Serve the site locally for development
serve:
    bundle exec jekyll serve

# End-to-end: verify + commit + push
commit +message:
    #!/usr/bin/env bash
    set -euo pipefail
    MESSAGE={{ quote(message) }}
    SKIP_VERIFY=0
    case " $MESSAGE " in
        *" --no-verify "*)
            SKIP_VERIFY=1
            MESSAGE="${MESSAGE/ --no-verify/}"
            MESSAGE="${MESSAGE/--no-verify /}"
            MESSAGE="${MESSAGE/--no-verify/}"
            ;;
    esac
    [ -n "$MESSAGE" ] || { echo "error: commit message required" >&2; exit 1; }
    [ "$SKIP_VERIFY" = 1 ] || just verify
    if command -v jj &>/dev/null && [ -d ".jj" ]; then
        jj describe -m "$MESSAGE"
        BOOKMARK=$(jj log -r '@ | @-' --no-graph -T 'bookmarks ++ "\n"' 2>/dev/null \
            | tr ' ' '\n' | grep -v '@' | grep -v '^$' | sed 's/[*?]\+$//' | head -1)
        if [ -z "$BOOKMARK" ]; then
            for n in trunk main master; do
                if jj bookmark list "$n" 2>/dev/null | grep -q "^$n:"; then
                    BOOKMARK="$n"; break
                fi
            done
        fi
        [ -n "$BOOKMARK" ] || { echo "error: no main/trunk/master bookmark found" >&2; exit 1; }
        jj bookmark set "$BOOKMARK" -r @
        REMOTES=$(jj git remote list | awk '{print $1}')
        [ -n "$REMOTES" ] || { echo "warn: no remotes configured, skipping push" >&2; exit 0; }
        for remote in $REMOTES; do
            echo "» push → $remote"
            jj git push --remote "$remote" --bookmark "$BOOKMARK" --allow-new \
                || echo "warn: push to $remote failed"
        done
        jj new
    else
        echo "warn: jj not found; falling back to git" >&2
        git add -A
        git commit -m "$MESSAGE"
        REMOTES=$(git remote)
        [ -n "$REMOTES" ] || { echo "warn: no remotes configured, skipping push" >&2; exit 0; }
        for remote in $REMOTES; do
            echo "» push → $remote"
            git push "$remote" HEAD || echo "warn: push to $remote failed"
        done
    fi
