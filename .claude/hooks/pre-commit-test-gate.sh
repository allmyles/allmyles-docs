#!/bin/bash
# Pre-commit test gate hook for Claude Code
# Blocks commits if tests haven't been run recently.
#
# How it works:
# - /test skill creates .test-passed marker after successful run
# - This hook checks if that marker exists and is fresh (< 30 min old)
# - If missing or stale, blocks the commit (exit 2) with instructions
#
# Exit codes:
#   0 = allow commit (also fires when the /develop test convention is not in
#       use in this repo — see the self-no-op guard below)
#   2 = block commit (Claude sees stderr message)

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && exit 0

# INF-260: /develop scratch (the gates dir + the test-passed marker) now lives
# OUTSIDE the repo, in the per-repo scratch dir. Resolve it via the sibling
# helper; fall back to the legacy in-repo paths so a repo mid-transition (or the
# kit's own in-flight /develop run) still enforces correctly.
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null)"
_SCRATCH_RES="${_HOOK_DIR}/../scripts/kit-scratch-dir.sh"
SCRATCH=""
[ -f "$_SCRATCH_RES" ] && SCRATCH="$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$_SCRATCH_RES" --no-create 2>/dev/null)"
_gates_present() { { [ -n "$SCRATCH" ] && [ -d "$SCRATCH/gates" ]; } || [ -d "$PROJECT_ROOT/.gates" ]; }
_resolve_marker() {
    if [ -n "$SCRATCH" ] && [ -f "$SCRATCH/test-passed" ]; then printf '%s' "$SCRATCH/test-passed"
    else printf '%s' "$PROJECT_ROOT/.test-passed"; fi
}

# Self-no-op: the /develop test convention (gate files + test-passed marker)
# is only used in repos where /develop is enabled. If neither the gates dir nor
# the marker exists (in EITHER location), this repo doesn't participate — exit 0.
# (DASH-2122: kit consumers opt in to /develop via their CLAUDE.md overlay;
#  hooks must self-no-op for consumers that don't.)
if ! _gates_present && [ ! -f "$(_resolve_marker)" ]; then
    exit 0
fi

# INF-272: the legacy in-repo fallback STAYS (it is fail-safe — removing it
# would silently drop enforcement on a repo whose scratch cannot resolve), but
# it no longer engages silently. Every consumer runs
# permissions.defaultMode=bypassPermissions, so pruning the retired
# `Bash(touch .gates/*)` allowlist entry restores NO prompt — this is the only
# signal that a /develop run wrote its scratch into the repo instead of the
# scratch dir.
#
# The two conditions are NOT the same and must not be reported as one (CR round
# 1.1): scratch can hold the live gates while a stale in-repo .gates/ merely
# sits there from a pre-INF-260 run. Only the resolved paths tell you which is
# actually enforcing, so decide from those, not from mere existence.
_legacy_in_use() {
    # Gates: in use when scratch holds none but the repo does.
    if { [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH/gates" ]; } && [ -d "$PROJECT_ROOT/.gates" ]; then
        return 0
    fi
    # Marker: in use when _resolve_marker actually resolved to the repo copy.
    if [ "$(_resolve_marker)" = "$PROJECT_ROOT/.test-passed" ] && [ -f "$PROJECT_ROOT/.test-passed" ]; then
        return 0
    fi
    return 1
}
if _legacy_in_use; then
    printf '⚠️  claude-kit: enforcing from the LEGACY in-repo /develop scratch (.gates/ or .test-passed). INF-260 moved scratch to the per-repo scratch dir — a run that wrote here did not apply the kit-gate.sh / kit-scratch-dir.sh convention (INF-272).\n' >&2
elif [ -d "$PROJECT_ROOT/.gates" ] || [ -f "$PROJECT_ROOT/.test-passed" ]; then
    printf 'ℹ️  claude-kit: stale in-repo /develop scratch present (.gates/ or .test-passed) but NOT in use — the per-repo scratch dir is enforcing. Safe to delete the leftovers (INF-260/INF-272).\n' >&2
fi

MARKER_FILE="$(_resolve_marker)"
MAX_AGE_MINUTES=30

# Check if marker exists
if [ ! -f "$MARKER_FILE" ]; then
    echo "BLOCKED: No test results found. Run /test before committing." >&2
    echo "Tests must pass before any commit is allowed." >&2
    exit 2
fi

# Check if marker is fresh (modified within MAX_AGE_MINUTES)
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    MARKER_MOD=$(stat -f %m "$MARKER_FILE")
else
    # Linux
    MARKER_MOD=$(stat -c %Y "$MARKER_FILE")
fi

NOW=$(date +%s)
AGE_SECONDS=$((NOW - MARKER_MOD))
AGE_MINUTES=$((AGE_SECONDS / 60))

if [ "$AGE_MINUTES" -gt "$MAX_AGE_MINUTES" ]; then
    echo "BLOCKED: Test results are stale (${AGE_MINUTES}min old, max ${MAX_AGE_MINUTES}min)." >&2
    echo "Run /test again before committing." >&2
    exit 2
fi

# Tests are fresh - allow commit
echo "Tests passed ${AGE_MINUTES}min ago. Commit allowed."
exit 0
