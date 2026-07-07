#!/bin/bash
# DASH-2160: Pre-push hook — full-diff formatter check.
#
# Differs from the pre-commit hook in scope: pre-commit only checks
# files modified locally (staged + working tree). Pre-push must mirror
# CI's full-tree scope so a file that drifted in via a prior staging
# merge (the 187-commit case from DASH-2148) is also covered.
#
# Implementation: run get-ci-formatters.sh, then for each formatter
# invoke it INSIDE the meo_dashboard container against the full diff
# vs the PR's base branch. Per CI's actual lint job which uses ``.``
# (whole tree from repo root), we mirror that — not just the diff —
# because Black's stylistic decisions are file-level and CI may flag
# a file whose pre-existing formatting Black now prefers differently
# (the round 1.2 list-comprehension drift we hit on PR #2510).
#
# Why "full tree" not "files in diff"? CI runs ``black --check
# --config pyproject.toml .`` which scans every .py file. If a file
# we DIDN'T touch happens to be Black-dirty (e.g., a staging merge
# brought it in pre-reformat), CI will fail. Mirroring CI's whole-tree
# scope here catches that before the push wastes a CI cycle.
#
# Exit codes:
#   0 = all formatters pass (push allowed)
#   2 = at least one formatter failed (push blocked)
#
# Permissions / behaviour notes:
#   - Docker must be running (the hook delegates to
#     run-all-formatters.sh which checks this itself).
#   - The hook runs in --check mode only (never --fix); fixing happens
#     via the dev's own `.claude/scripts/run-all-formatters.sh --fix`.
#   - Single-push bypass: ALLOW_FORMAT_DRIFT=1 git push  (only use this
#     when you've confirmed the failure is a known-CI-passing case
#     that the local container can't reproduce — e.g., a flake8
#     plugin version mismatch).

set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$PROJECT_ROOT" ]; then
    echo "BLOCKED: pre-push-format-check cannot determine project root" >&2
    exit 2
fi

# Single-push escape hatch. Mirrors the
# pre-push-block-staging-merge.sh pattern (DASH-2148): the env var is
# read here and only here, so an accidental `export
# ALLOW_FORMAT_DRIFT=1` in shell profile would be visible on every
# push and easy to spot.
if [ "${ALLOW_FORMAT_DRIFT:-}" = "1" ]; then
    echo "⚠️  pre-push-format-check: bypassed via ALLOW_FORMAT_DRIFT=1 — CI may still reject" >&2
    exit 0
fi

# Skip if the diff has no Python or JS/JSON files. Saves the
# docker-exec round-trip on docs-only or branch-protection PRs.
#
# Compare against origin/master (the canonical base for feature
# branches per CLAUDE.md). If we can't resolve origin/master (fresh
# clone, no fetch yet), fall back to a tree-wide check — better to
# over-run formatters than under-run them.
BASE_REF="origin/master"
if ! git rev-parse --quiet --verify "$BASE_REF" > /dev/null 2>&1; then
    BASE_REF=""
fi

if [ -n "$BASE_REF" ]; then
    DIFF_FILES=$(git diff --name-only "$BASE_REF...HEAD" 2>/dev/null)
    HAS_RELEVANT=$(echo "$DIFF_FILES" | grep -E '\.(py|js|jsx|ts|tsx|json|css|md|yml|yaml)$' | head -1)
    if [ -z "$HAS_RELEVANT" ]; then
        echo "pre-push-format-check: no formatter-relevant files in diff vs $BASE_REF — skipping"
        exit 0
    fi
fi

# Delegate to run-all-formatters.sh. The script already routes through
# docker so the binary versions match CI; this hook adds the pre-push
# trigger + full-tree-vs-touched-files distinction.
RUNNER="$PROJECT_ROOT/.claude/scripts/run-all-formatters.sh"
if [ ! -x "$RUNNER" ]; then
    echo "BLOCKED: pre-push-format-check requires $RUNNER (DASH-2160)" >&2
    echo "         Run: chmod +x $RUNNER" >&2
    exit 2
fi

echo "pre-push-format-check: running CI-parity formatters via docker container..."
if "$RUNNER" --check; then
    echo "pre-push-format-check: all formatters passed. Push allowed."
    exit 0
fi

# A formatter failed. The script already printed the failing-formatter
# diagnostic; add the hook-specific recovery instructions.
cat >&2 <<EOF

BLOCKED: pre-push-format-check found formatter failures. CI will reject this push.

To fix locally with CI-parity tooling:
  .claude/scripts/run-all-formatters.sh --fix      # apply all formatters
  .claude/scripts/run-all-formatters.sh --check    # verify, then push again

To bypass for a single push (use only when you have an explicit reason
the local container can't match CI — e.g., a docker image rebuild
pending):
  ALLOW_FORMAT_DRIFT=1 git push

The bypass is for one push at a time, not a permanent skip.
EOF
exit 2
