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

# Self-no-op: the /develop test convention (gate files + .test-passed marker)
# is only used in repos where /develop is enabled. If neither marker exists,
# this repo doesn't participate in the test gate — exit 0 silently.
# (DASH-2122: kit consumers opt in to /develop via their CLAUDE.md overlay;
#  hooks must self-no-op for consumers that don't.)
if [ ! -d "$PROJECT_ROOT/.gates" ] && [ ! -f "$PROJECT_ROOT/.test-passed" ]; then
    exit 0
fi

MARKER_FILE="$PROJECT_ROOT/.test-passed"
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
