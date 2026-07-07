#!/bin/bash
# DASH-2160: Deterministic "do what CI does, locally" command.
#
# Runs the same formatter set CI runs (feature_pipeline.yaml lint +
# frontend-lint jobs) on the FULL working tree, with byte-identical
# command shapes, executed inside the meo_dashboard docker container
# so the binary IS the requirements-dev.txt-pinned one (not the
# operator's manually-installed .venv version that may have drifted).
#
# Why this exists: pre-DASH-2160 the agent's QA step ran
# ``docker compose exec ... black --line-length 100 --check <touched-file>``
# which differs from CI in three ways: (a) ``--line-length 100`` vs CI's
# ``--config pyproject.toml`` (different config-discovery path), (b) only
# checks touched files vs CI's whole tree, (c) uses .venv/bin/black via
# the pre-commit-format-check.sh fallback (broken get-ci-formatters.sh
# path; see DASH-2160 plan). Any one of those can produce a local "PASS"
# while CI says "would reformat" — exactly the round 1.2 Black-drift we
# hit on PR #2510. This script eliminates all three asymmetries.
#
# Usage:
#   .claude/scripts/run-all-formatters.sh           # check mode (CI parity)
#   .claude/scripts/run-all-formatters.sh --check   # same; explicit
#   .claude/scripts/run-all-formatters.sh --fix     # apply formatters (dev mode)
#   .claude/scripts/run-all-formatters.sh --python  # python-only
#   .claude/scripts/run-all-formatters.sh --js      # js-only
#
# ``--check`` and ``--fix`` can be combined with ``--python`` / ``--js``.
#
# Exit codes:
#   0 = all formatter checks pass
#   1 = configuration error (formatter list empty, CI yaml missing,
#       docker not running, etc.)
#   2 = at least one formatter reported a difference (check mode) OR
#       a formatter command exited non-zero

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GET_FORMATTERS="$REPO_ROOT/.claude/scripts/get-ci-formatters.sh"

# CR round 1.3: anchor `docker compose` invocations to REPO_ROOT.
# Pre-1.3 the script computed REPO_ROOT but never cd'd into it; a manual
# run from a subdirectory would resolve compose against the CWD and
# either fail (no compose file) or pick up the wrong project. Hooks
# invoke from the project root so the bug was latent.
cd "$REPO_ROOT" || {
    echo "ERROR: cannot cd to repo root $REPO_ROOT" >&2
    exit 1
}

if [ ! -x "$GET_FORMATTERS" ]; then
    echo "ERROR: get-ci-formatters.sh not found or not executable at $GET_FORMATTERS" >&2
    exit 1
fi

# Verify docker is reachable BEFORE doing any work — failing later inside
# a per-formatter loop produces noisier output than failing up front.
if ! docker ps > /dev/null 2>&1; then
    echo "ERROR: Docker is not running. Start Docker Desktop or OrbStack, then" >&2
    echo "       \`docker compose up -d meo_dashboard\`, then re-run this script." >&2
    exit 1
fi
if ! docker compose ps --services --status running 2>/dev/null | grep -qx "meo_dashboard"; then
    echo "ERROR: meo_dashboard container is not running. Bring it up with" >&2
    echo "       \`docker compose up -d meo_dashboard\` and re-run this script." >&2
    exit 1
fi

# Parse args. Two orthogonal axes: mode (check/fix) and language filter
# (python/js/all). Default mode = check (CI parity); default language = all.
MODE="check"
LANG_FILTER=""

for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --fix)   MODE="fix" ;;
        --python) LANG_FILTER="--python" ;;
        --js)    LANG_FILTER="--js" ;;
        --help|-h)
            sed -n '4,30p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

FORMATTER_OUTPUT=$("$GET_FORMATTERS" $LANG_FILTER)
if [ -z "$FORMATTER_OUTPUT" ]; then
    echo "ERROR: get-ci-formatters.sh produced no entries (LANG_FILTER=$LANG_FILTER)" >&2
    exit 1
fi

# Container-side working directory. The docker-compose volume
# ``./mileometer:/opt/code`` plus the explicit
# ``./pyproject.toml:/opt/code/pyproject.toml:ro`` mount means that:
#   - Host repo-root ``pyproject.toml`` is visible to the container at
#     /opt/code/pyproject.toml (the 907-byte one with [tool.black]).
#   - Host ``mileometer/`` contents are visible at /opt/code/*.
#   - Host ``mileometer/package.json`` is at /opt/code/package.json.
# So a single cwd ``/opt/code`` lets us run BOTH the lint job's commands
# (which CI runs from repo root) and the frontend-lint job's commands
# (which CI runs from ./mileometer) without any conditional cd — the
# container collapses both views into one filesystem.
CONTAINER_CWD="/opt/code"

# ── JS toolchain readiness (DASH-2337) ──
# CI's frontend-lint job runs `npm install` then prettier/eslint on EVERY PR,
# unconditionally (feature_pipeline.yaml `frontend-lint` has no `if:` gate).
# Local parity must do the same: a silently-skipped JS check is a false green —
# the DASH-2335 incident, where a misformatted financial_documents.js passed
# local QA and only failed CI frontend-lint, costing a full merge-readiness
# cycle. So when JS formatters are in scope we ENSURE the pinned toolchain is
# present (installing it on demand, exactly as CI does), and if it cannot be
# made available we mark JS as a HARD FAILURE rather than skipping.
#
# Detection probes the actual binaries (node_modules/.bin/prettier|eslint),
# NOT just `[ -d node_modules ]` — a partial install leaves the directory but
# no binaries (the literal state that produced both the false-green skip AND
# the false-red exit-127 this gate exists to eliminate).
JS_TOOLCHAIN="n/a"   # n/a (no js formatters in scope) | ready | unavailable
js_bins_present() {
    docker compose exec -T -w "$CONTAINER_CWD" meo_dashboard \
        bash -c '[ -x node_modules/.bin/prettier ] && [ -x node_modules/.bin/eslint ]' \
        < /dev/null > /dev/null 2>&1
}
if printf '%s\n' "$FORMATTER_OUTPUT" | grep -q '|js|'; then
    if js_bins_present; then
        JS_TOOLCHAIN="ready"
    else
        echo "→ [js] toolchain not present in container — installing pinned deps (npm install, CI parity)..."
        NPM_LOG="/tmp/run-all-formatters-npm-install.log"
        if docker compose exec -T -w "$CONTAINER_CWD" meo_dashboard npm install \
                < /dev/null > "$NPM_LOG" 2>&1 && js_bins_present; then
            echo "  ✓ JS toolchain installed (prettier/eslint now resolvable)"
            JS_TOOLCHAIN="ready"
        else
            echo "  ✗ JS toolchain install failed (see $NPM_LOG)"
            JS_TOOLCHAIN="unavailable"
        fi
    fi
fi

PASSED=0
FAILED=0
FAILED_NAMES=()

SKIPPED_NAMES=()

while IFS='|' read -r name check_cmd fix_cmd lang cwd; do
    [ -z "$name" ] && continue

    # Pick the command for the current mode.
    if [ "$MODE" = "check" ]; then
        cmd="$check_cmd"
    else
        cmd="$fix_cmd"
    fi

    # CI applies the formatter to the entire working tree; our local
    # parity command does the same. Black/Flake8 take a trailing ``.``
    # (the CI YAML literally uses ``.``); npm scripts already have the
    # scope encoded in package.json so no path append is needed.
    if [[ "$cmd" =~ ^npm[[:space:]] ]]; then
        full_cmd="$cmd"
        # DASH-2337: the JS toolchain was ensured (and installed if needed)
        # before the loop. If it is still unavailable, FAIL LOUDLY rather than
        # silently skipping — a skipped JS check is a false green that lets a
        # prettier/eslint violation reach CI frontend-lint undetected. The QA
        # gate must block on this, so it counts as a failure.
        if [ "$JS_TOOLCHAIN" != "ready" ]; then
            echo "→ [$lang] $name  (FAILED — JS toolchain unavailable; npm install could not provide prettier/eslint)"
            echo "  CI's frontend-lint runs these on every PR; a local skip would be a false green."
            echo "  Fix: give the container network access for 'npm install', or run it manually:"
            echo "       docker compose exec -w $CONTAINER_CWD meo_dashboard npm install"
            FAILED=$((FAILED + 1))
            FAILED_NAMES+=("$name")
            continue
        fi
    else
        full_cmd="$cmd ."
    fi

    echo "→ [$lang] $name"
    echo "  \$ docker compose exec -T -w $CONTAINER_CWD meo_dashboard $full_cmd"
    # Redirect docker-exec's stdin from /dev/null. Without this, the
    # ``-T`` flag attaches the parent shell's stdin (which is the
    # while-loop's here-string of formatter entries), and docker-exec
    # silently consumes the remaining lines — so only the FIRST
    # formatter runs. With the redirection, each iteration gets a
    # clean stdin for docker-exec and the loop iterates over every
    # entry as intended.
    OUTPUT=$(docker compose exec -T -w "$CONTAINER_CWD" meo_dashboard \
        bash -c "$full_cmd" < /dev/null 2>&1)
    STATUS=$?
    # Indent the output for readability.
    if [ -n "$OUTPUT" ]; then
        printf '%s\n' "$OUTPUT" | sed 's/^/  /'
    fi
    if [ "$STATUS" -eq 0 ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
        echo "  ✗ $name exited $STATUS"
    fi
done <<< "$FORMATTER_OUTPUT"

echo ""
SKIPPED=${#SKIPPED_NAMES[@]}
if [ "$SKIPPED" -gt 0 ]; then
    echo "Summary: $PASSED passed, $FAILED failed, $SKIPPED skipped"
    echo "Skipped: ${SKIPPED_NAMES[*]}"
else
    echo "Summary: $PASSED passed, $FAILED failed"
fi
if [ "$FAILED" -gt 0 ]; then
    echo "Failed: ${FAILED_NAMES[*]}"
    exit 2
fi
exit 0
