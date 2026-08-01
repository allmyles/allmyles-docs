#!/usr/bin/env bash
# kit-home.sh (INF-262) — print the effective kit SCRIPTS directory for the
# current repo, so /develop's helper invocations are COPY-LOCATION-AGNOSTIC:
# they work whether or not the repo has `.claude/scripts/` copies.
#
# This is the foundation of the zero-footprint "solo mode" (epic INF-259): the
# skill resolves `KIT=$(kit-home.sh)` once and then invokes every helper as
# `$KIT/<helper>`. An ADOPTED repo resolves to its committed `.claude/scripts/`
# (unchanged); a repo WITHOUT copies resolves to the PLUGIN's scripts dir.
#
# Resolution order (mirrors upgrade-kit.sh's setup-project resolution):
#   1. KIT_HOME_SCRIPTS env override (tests set this).
#   2. $PROJECT_ROOT/.claude/scripts — the adopted-repo copies, when present.
#   3. ${SCRIPT_DIR} — the dir THIS script lives in, when it is a plugin scripts
#      dir (i.e. kit-home.sh was invoked from the plugin tree, the solo case).
#   4. ${CLAUDE_PLUGIN_ROOT}/scripts — the plugin root Claude Code exports.
#   5. installed_plugins.json — the project-scope install's installPath, else
#      any claude-kit install.
# Prints the resolved absolute dir + exits 0; exits 1 (no output) if none
# resolve (the caller then falls back to `.claude/scripts` or errors clearly).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$PWD"

# A dir "is a kit scripts dir" if it holds a signature helper. Use kit-gate.sh
# (INF-260 — present in both the plugin tree and every up-to-date consumer copy).
_is_kit_scripts() { [ -n "$1" ] && [ -f "$1/kit-gate.sh" ]; }

# 1. Explicit override.
if [ -n "${KIT_HOME_SCRIPTS:-}" ]; then
    printf '%s\n' "$KIT_HOME_SCRIPTS"; exit 0
fi

# 2. Adopted repo: committed .claude/scripts/ copies.
if _is_kit_scripts "${PROJECT_ROOT}/.claude/scripts"; then
    printf '%s\n' "${PROJECT_ROOT}/.claude/scripts"; exit 0
fi

# 3. This script's own dir, when invoked from a plugin scripts dir (solo case).
if _is_kit_scripts "$SCRIPT_DIR"; then
    printf '%s\n' "$SCRIPT_DIR"; exit 0
fi

# 4. CLAUDE_PLUGIN_ROOT (exported by Claude Code for plugin-run contexts).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && _is_kit_scripts "${CLAUDE_PLUGIN_ROOT}/scripts"; then
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/scripts"; exit 0
fi

# 5. installed_plugins.json — project-scope install first, then any claude-kit.
installed="${HOME}/.claude/plugins/installed_plugins.json"
if [ -r "$installed" ] && command -v jq >/dev/null 2>&1; then
    ip="$(jq -r --arg pwd "$PROJECT_ROOT" '
        (.plugins["claude-kit@allmyles-claude-kit"] // [])
        | (map(select(.projectPath == $pwd)) + .)
        | first | .installPath // empty' "$installed" 2>/dev/null)"
    if _is_kit_scripts "${ip}/scripts"; then
        printf '%s\n' "${ip}/scripts"; exit 0
    fi
fi

exit 1
