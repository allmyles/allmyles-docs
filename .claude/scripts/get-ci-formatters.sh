#!/bin/bash
# Extracts the list of formatters from the CI deployment pipeline.
#
# Source of truth: .github/workflows/feature_pipeline.yaml
# DASH-2160: was incorrectly pointed at .github/workflows/general_deploy_pipeline.yaml
# which was renamed/replaced by feature_pipeline.yaml — that broke the
# get-ci-formatters → pre-commit hook chain, which silently fell back to
# hardcoded .venv/bin/black checks. The .venv path drifts from CI even when
# the requirements-dev.txt pin matches, producing the local-passes-but-CI-
# fails noise the ticket exists to eliminate.
#
# Usage:
#   .claude/scripts/get-ci-formatters.sh              # prints all formatters
#   .claude/scripts/get-ci-formatters.sh --python     # prints Python formatters only
#   .claude/scripts/get-ci-formatters.sh --js         # prints JS formatters only
#   .claude/scripts/get-ci-formatters.sh --check      # prints check commands (CI mode)
#   .claude/scripts/get-ci-formatters.sh --fix        # prints fix commands (dev mode)
#
# Output format (default): one formatter per line as
#   "name|check_cmd|fix_cmd|language|cwd"
#
# The trailing ``cwd`` field is the working directory the command must run
# in, relative to the repo root. CI sets ``working-directory: ./mileometer``
# for the frontend-lint job and runs from repo root for the lint (Python)
# job; emit the same so callers (run-all-formatters.sh, pre-commit hook,
# pre-push hook) can cd before exec and match CI verdicts byte-for-byte.
#
# Exit codes:
#   0 = success
#   1 = CI pipeline file not found

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIPELINE_FILE="$REPO_ROOT/.github/workflows/feature_pipeline.yaml"

if [ ! -f "$PIPELINE_FILE" ]; then
    echo "ERROR: CI pipeline file not found: $PIPELINE_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse formatter steps from the CI pipeline YAML.
#
# Each entry maps:
#   CI check command  →  local check command  →  local fix command  →  cwd
#
# The check/fix commands match CI's invocation byte-for-byte (DASH-2160) so
# a local pre-push run produces identical Black/Flake8/Prettier/ESLint
# verdicts to the CI runner. The hardcoded shapes deliberately exclude
# .venv/bin/* paths — those drift across operator laptops and were the
# original DASH-2158 round 1.2 Black-disagreement smoking gun.
#
# The fifth ``cwd`` field is honored by callers: lint (Python) runs from
# repo root (.); frontend-lint (JS) runs from ./mileometer per
# feature_pipeline.yaml lines 380, 384, 388.
# ---------------------------------------------------------------------------

declare -a FORMATTERS=()

# --- Python formatters (from "lint" job, runs from repo root) -------------

if grep -q "Run black" "$PIPELINE_FILE"; then
    # CI exact: ``black --check --config pyproject.toml .`` (feature_pipeline.yaml:358)
    FORMATTERS+=("black|black --check --config pyproject.toml|black --config pyproject.toml|python|.")
fi

if grep -q "Run flake8" "$PIPELINE_FILE"; then
    # CI exact: ``flake8 . --count --show-source --statistics`` (feature_pipeline.yaml:361)
    # No fix mode for flake8 — same command for check; emit it twice so
    # callers iterating over the entry don't need to special-case.
    FORMATTERS+=("flake8|flake8 --count --show-source --statistics|flake8 --count --show-source --statistics|python|.")
fi

# --- JavaScript formatters (from "frontend-lint" job, runs from ./mileometer) -

if grep -q "Run Prettier" "$PIPELINE_FILE"; then
    # CI exact: ``npm run format:check`` from ./mileometer (feature_pipeline.yaml:383-384)
    # which resolves via package.json's "format:check" script. Keep the
    # script-invocation shape so any future package.json change to that
    # script (e.g., new --ignore-path flag) propagates automatically.
    FORMATTERS+=("prettier|npm run format:check|npm run format|js|mileometer")
fi

if grep -q "Run ESLint" "$PIPELINE_FILE"; then
    # CI exact: ``npm run lint`` from ./mileometer (feature_pipeline.yaml:387-388)
    # Same package.json-indirection rationale as prettier.
    FORMATTERS+=("eslint|npm run lint|npm run lint:fix|js|mileometer")
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

FILTER="${1:-}"

for entry in "${FORMATTERS[@]}"; do
    IFS='|' read -r name check_cmd fix_cmd lang cwd <<< "$entry"

    case "$FILTER" in
        --python)
            [ "$lang" != "python" ] && continue
            ;;
        --js)
            [ "$lang" != "js" ] && continue
            ;;
        --check)
            echo "$check_cmd"
            continue
            ;;
        --fix)
            echo "$fix_cmd"
            continue
            ;;
        --names)
            echo "$name"
            continue
            ;;
    esac

    # Default and --python / --js: full entry. Five fields.
    echo "$name|$check_cmd|$fix_cmd|$lang|$cwd"
done
