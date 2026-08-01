#!/usr/bin/env bash
# kit-scratch-dir.sh (INF-260) — resolve the per-repo /develop SCRATCH directory,
# which lives OUTSIDE the repo tree so the workflow writes nothing into the
# consumer's git history (zero-footprint, epic INF-259).
#
# Prints the scratch dir (creating it if needed) for the current repo, keyed by
# the repo's absolute toplevel so every checkout gets its own stable dir. BOTH
# the /develop skill and the enforcement hooks call this, so they always agree
# on where gates / the test-passed marker / test plans + Playwright evidence
# live.
#
# Location:
#   ${CLAUDE_KIT_SCRATCH_HOME:-${XDG_STATE_HOME:-$HOME/.claude}/kit-scratch}/<repo-key>
#
# Security (CWE-377, per the INF-258 lesson): the base is a USER-OWNED path
# under $HOME (or $XDG_STATE_HOME), never a world-writable predictable /tmp path.
# The dir is created with a 0700 umask so other users can't pre-create or read
# it. CLAUDE_KIT_SCRATCH_HOME is an explicit override (tests set it).
#
# Usage:
#   kit-scratch-dir.sh          → print (and create) the repo's scratch dir
#   kit-scratch-dir.sh --key    → print just the repo-key (no dir creation)
#   kit-scratch-dir.sh --no-create → print the path without creating it
set -uo pipefail

MODE="dir"
CREATE=true
for arg in "$@"; do
    case "$arg" in
        --key) MODE="key" ;;
        --no-create) CREATE=false ;;
        *) echo "kit-scratch-dir.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

# Resolve the repo toplevel. CLAUDE_PROJECT_DIR (set by Claude Code) wins; fall
# back to git, then $PWD. Canonicalise with `cd -P` so a symlinked path
# (e.g. macOS /tmp -> /private/var) hashes to ONE stable key regardless of which
# form the caller passes — otherwise the skill and a hook could derive different
# dirs for the same repo.
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$ROOT" ] && ROOT="$PWD"
ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || ROOT="$PWD"

# Repo key: a filesystem-safe, collision-resistant digest of the absolute path.
# Prefer sha256 (shasum on macOS, sha256sum on GNU); fall back to cksum.
if command -v shasum >/dev/null 2>&1; then
    KEY="$(printf '%s' "$ROOT" | shasum -a 256 2>/dev/null | cut -c1-16)"
elif command -v sha256sum >/dev/null 2>&1; then
    KEY="$(printf '%s' "$ROOT" | sha256sum 2>/dev/null | cut -c1-16)"
else
    KEY="$(printf '%s' "$ROOT" | cksum | tr -d ' ' | cut -c1-16)"
fi
[ -z "$KEY" ] && KEY="unknown"

if [ "$MODE" = "key" ]; then
    printf '%s\n' "$KEY"
    exit 0
fi

BASE="${CLAUDE_KIT_SCRATCH_HOME:-${XDG_STATE_HOME:-$HOME/.claude}/kit-scratch}"
DIR="${BASE}/${KEY}"

if [ "$CREATE" = true ]; then
    # 0700 so the scratch (which can hold Playwright screenshots of rendered
    # pages) is private to this user. Fail loudly if creation fails, and ALWAYS
    # tighten the mode afterwards — `umask` only affects the mode of a dir this
    # call CREATES, so a pre-existing 0755 key dir would otherwise stay readable
    # by other local users (CR round 1.1).
    if ! ( umask 077; mkdir -p "$DIR" ); then
        echo "kit-scratch-dir.sh: could not create scratch dir $DIR" >&2
        exit 1
    fi
    chmod 700 "$DIR" 2>/dev/null || true
fi
printf '%s\n' "$DIR"
