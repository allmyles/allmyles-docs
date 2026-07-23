#!/usr/bin/env bash
# upgrade-kit.sh (INF-154) — run the kit setup and HARD-GUARD the result so a
# kit upgrade can never touch anything outside .claude/.
#
# Invoked by the /upgrade-kit skill AFTER the agent has run
# `claude plugin marketplace update`. This script does the mechanical +
# safety-critical part: run setup-project.sh, then refuse (RESULT=BLOCKED) if
# the upgrade changed any file outside .claude/ (the agent-tooling tree). It is
# deterministic and testable, and it does NOT commit or open a PR — the skill
# does that so a human approves via the PR.
#
# Final stdout line is always `RESULT=OK|NOCHANGE|BLOCKED` for the skill to
# parse; a human-readable summary precedes it.
#
# Exit codes:
#   0  RESULT=OK        — only .claude/ changed; safe to commit + PR
#   0  RESULT=NOCHANGE  — nothing changed; already current
#   2  RESULT=BLOCKED   — a guardrail tripped (non-.claude change, dirty tree)
#   3  RESULT=BLOCKED   — setup-project.sh missing or failed
#   4  RESULT=BLOCKED   — not a git repo

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
# Validate PROJECT_ROOT is an actual git worktree regardless of how it was
# resolved. CLAUDE_PROJECT_DIR is used verbatim if set, so it could point at a
# non-git directory — the empty-check alone would miss that and let a later
# `git status` fail in a confusing way. Fail cleanly as BLOCKED instead.
if [ -z "$PROJECT_ROOT" ] || ! git -C "$PROJECT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Not a git repository (or CLAUDE_PROJECT_DIR is not a git worktree) — cannot verify the upgrade safely." >&2
    echo "RESULT=BLOCKED"; exit 4
fi
cd "$PROJECT_ROOT" || { echo "RESULT=BLOCKED"; exit 4; }

# Refuse on a dirty tree: we must be able to attribute the whole diff to the
# upgrade. Pre-existing uncommitted changes would blur that.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "Your working tree already has uncommitted changes. Commit or stash them" >&2
    echo "first so the upgrade's changes can be reviewed cleanly on their own." >&2
    echo "RESULT=BLOCKED"; exit 2
fi

# Run setup-project.sh (a test may substitute it via UPGRADE_KIT_SETUP).
#
# INF-164: resolve it across install layouts. The pre-INF-164 default
# (${SCRIPT_DIR}/setup-project.sh) only works when this script runs from the
# plugin tree; the consumer-copied .claude/scripts/upgrade-kit.sh (it IS in
# HELPERS_TO_COPY) has no setup-project.sh sibling — that file is
# intentionally not copied into consumers. Resolution order mirrors
# setup-project.sh's own pin-SHA discovery:
#   1. UPGRADE_KIT_SETUP env (explicit override; tests use this)
#   2. ${SCRIPT_DIR}/setup-project.sh (plugin-tree invocation)
#   3. ${CLAUDE_PLUGIN_ROOT}/scripts/setup-project.sh (hook/skill context)
#   4. installed_plugins.json — project-scope entry's installPath first,
#      then any claude-kit install
resolve_setup() {
    if [ -n "${UPGRADE_KIT_SETUP:-}" ]; then
        printf '%s\n' "$UPGRADE_KIT_SETUP"
        return 0
    fi
    if [ -f "${SCRIPT_DIR}/setup-project.sh" ]; then
        printf '%s\n' "${SCRIPT_DIR}/setup-project.sh"
        return 0
    fi
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/setup-project.sh" ]; then
        printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/scripts/setup-project.sh"
        return 0
    fi
    local installed="${HOME}/.claude/plugins/installed_plugins.json"
    if [ -r "$installed" ] && command -v jq >/dev/null 2>&1; then
        local ip
        ip="$(jq -r --arg pwd "$PROJECT_ROOT" '
            (.plugins["claude-kit@allmyles-claude-kit"] // [])
            | (map(select(.projectPath == $pwd)) + .)
            | first
            | .installPath // empty
        ' "$installed" 2>/dev/null)"
        if [ -n "$ip" ] && [ -f "${ip}/scripts/setup-project.sh" ]; then
            printf '%s\n' "${ip}/scripts/setup-project.sh"
            return 0
        fi
    fi
    return 1
}
SETUP="$(resolve_setup)" || SETUP=""
if [ -z "$SETUP" ] || [ ! -f "$SETUP" ]; then
    echo "setup-project.sh not found (checked UPGRADE_KIT_SETUP, ${SCRIPT_DIR}/, CLAUDE_PLUGIN_ROOT, installed_plugins.json) — is the claude-kit plugin installed?" >&2
    echo "RESULT=BLOCKED"; exit 3
fi
# INF-164: unique log path via mktemp — a fixed /tmp name is symlink/race
# prone (CWE-377) and collides across concurrent runs.
SETUP_LOG="$(mktemp -t upgrade-kit-setup.XXXXXX 2>/dev/null || printf '%s' "/tmp/upgrade-kit-setup.$$.log")"
if ! bash "$SETUP" > "$SETUP_LOG" 2>&1; then
    echo "setup-project.sh failed — see ${SETUP_LOG}" >&2
    echo "RESULT=BLOCKED"; exit 3
fi

# What changed? Strip the 2 status chars + space; keep the new path for renames.
# INF-198: the repo-root `.mcp.json` joins `.claude/` as kit-managed — it is
# the ONLY place Claude Code reads project MCP-server declarations from (the
# playwright-first testing gate needs it), so setup-project.sh writes it at
# the root by necessity. Exact-path whitelist — `.mcp.json.bak` or any other
# root file still BLOCKs.
# INF-208: `.github/workflows/staging_auto_merge.yaml` joins the whitelist —
# setup-project.sh installs the kit-managed staging auto-merge bot there on
# staging-master consumers (marker-guarded; see the installer block). Exact
# path only — any other workflow file still BLOCKs.
# CR round 1.2: keep BOTH sides of rename entries — `s/.* -> //` dropped
# the source path, so `outside-secret.json -> .mcp.json` would have been
# judged only by its destination and slipped the guard. Splitting the
# arrow onto two lines validates source AND destination independently.
# --untracked-files=all (INF-208): default porcelain collapses an untracked
# directory to `dir/` (e.g. `.github/`), which can neither match an
# exact-path whitelist entry nor name the offending file in the BLOCKED
# diagnostic. -uall lists every untracked file individually — same blocking
# semantics, precise paths on both the whitelist and the error message.
paths_outside() {
    git status --porcelain --untracked-files=all | sed 's/^...//' | awk '{gsub(/ -> /, "\n"); print}' | grep -vE '^\.claude/' | grep -vE '^(")?\.mcp\.json(")?$' | grep -vE '^(")?\.github/workflows/staging_auto_merge\.yaml(")?$' || true
}
CHANGED_COUNT="$(git status --porcelain --untracked-files=all | wc -l | tr -d ' ')"

if [ "$CHANGED_COUNT" = "0" ]; then
    echo "Already up to date — the kit made no changes."
    echo "RESULT=NOCHANGE"; exit 0
fi

# HARD GUARDRAIL: nothing may change outside .claude/.
OUTSIDE="$(paths_outside)"
if [ -n "$OUTSIDE" ]; then
    echo "BLOCKED — the upgrade changed files OUTSIDE .claude/ (i.e. beyond agent tooling):" >&2
    # INF-164: quote the expansion — unquoted $OUTSIDE word-splits on ALL
    # whitespace (not just newlines) and can glob-expand path segments
    # (ShellCheck SC2086). Prefix each line via sed instead.
    printf '%s\n' "$OUTSIDE" | sed 's/^/  - /' >&2
    echo "A kit upgrade must only touch .claude/. Not proceeding; a developer should investigate." >&2
    echo "RESULT=BLOCKED"; exit 2
fi

# Soft check: confirm the drift hooks made it in (advisory only — never blocks).
for want in check-local-kit-edit-drift.sh pre-commit-kit-edit-guard.sh; do
    [ -f ".claude/hooks/${want}" ] || echo "note: expected hook .claude/hooks/${want} not present after setup" >&2
done

PIN_SHA="$(jq -r '.kitSha // ""' .claude/claude-kit-pin.json 2>/dev/null | cut -c1-8)"
echo "OK — ${CHANGED_COUNT} file(s) updated under kit-managed paths (kit ${PIN_SHA:-unknown}). Nothing outside .claude/ + .mcp.json + staging_auto_merge.yaml was touched."
echo "RESULT=OK"; exit 0
