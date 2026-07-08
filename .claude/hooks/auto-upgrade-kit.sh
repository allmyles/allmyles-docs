#!/bin/bash
# SessionStart hook: zero-click kit auto-upgrade (INF-155).
#
# When the operator has opted in (`kit.auto_upgrade: true`), this hook — on
# session start, if the kit is behind — launches the guardrailed auto-upgrade
# worker in the BACKGROUND (never blocks session start), which opens a PR and
# enables auto-merge. The operator does nothing.
#
# OPT-IN and safe by construction:
#   - Default OFF. Only runs when kit.auto_upgrade is true in the consumer's
#     .claude/settings.local.json (or settings.json). A hook that auto-commits
#     to a repo must never be default-on.
#   - The actual upgrade goes through upgrade-kit.sh, which HARD-REFUSES any
#     change outside .claude/. So an auto-merge can only ship agent tooling.
#   - Silent when opted out, when current, or when a kit-upgrade PR is already
#     open. One advisory line otherwise. Always exits 0.
#
# Structural sibling of check-kit-drift.sh (session_id marker, silence-on-match,
# set +e, never blocks).

set +e

INPUT="$(cat || true)"
SESSION_ID="$(echo "$INPUT" | python3 -c "
import sys, json, re
ppid = sys.argv[1] if len(sys.argv) > 1 else '0'
try:
    data = json.load(sys.stdin)
    sid = data.get('session_id') or data.get('sessionId') or ''
    if not sid: sid = ppid
    sid = re.sub(r'[^A-Za-z0-9_-]', '_', str(sid))[:64]
    print(sid if sid else '0')
except Exception:
    print(re.sub(r'[^0-9]', '', str(ppid)) or '0')
" "$PPID" 2>/dev/null || echo "0")"
MARKER="/tmp/kit-autoupgrade-${SESSION_ID}.flag"
[ -e "$MARKER" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# INF-164: bound the network calls below so this SessionStart hook can never
# stall session start (its own header contract) on a slow/unresponsive GitHub
# API. GNU `timeout` is absent on stock macOS — fall back to coreutils'
# `gtimeout`, and if neither exists run unbounded (no worse than pre-INF-164).
# Usage: _bounded <seconds> <command...>
_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        "$@"
    fi
}

# --- Opt-in gate (default OFF) ---
read_flag() { jq -r '.kit.auto_upgrade // empty' "$1" 2>/dev/null; }
OPT="$(read_flag "${PROJECT_DIR}/.claude/settings.local.json")"
[ -z "$OPT" ] && OPT="$(read_flag "${PROJECT_DIR}/.claude/settings.json")"
[ "$OPT" = "true" ] || exit 0

# --- Behind check (pin vs upstream master) ---
PIN_FILE="${PROJECT_DIR}/.claude/claude-kit-pin.json"
[ -r "$PIN_FILE" ] || exit 0
PINNED="$(jq -r '.kitSha // ""' "$PIN_FILE" 2>/dev/null)"
[ -z "$PINNED" ] || [ "$PINNED" = "null" ] && exit 0
command -v gh >/dev/null 2>&1 || exit 0
UPSTREAM="$(_bounded 5 gh api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null)"
[ -z "$UPSTREAM" ] && exit 0
touch "$MARKER" 2>/dev/null || true         # one attempt per session regardless of outcome
[ "$PINNED" = "$UPSTREAM" ] && exit 0        # already current → silent

# --- Skip if a kit-upgrade PR is already open ---
EXISTING="$(_bounded 5 gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null | grep -c '^kit-upgrade/' 2>/dev/null)"
if [ "${EXISTING:-0}" != "0" ]; then
    printf '%s\n' "ℹ️ claude-kit is behind, but a kit-upgrade PR is already open — leaving it to merge." >&2
    exit 0
fi

# --- Launch the guardrailed worker in the background (never block session start) ---
WORKER="$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd)/auto-upgrade-kit-run.sh"
if [ ! -f "$WORKER" ]; then
    printf '%s\n' "⚠️ claude-kit is behind and auto-upgrade is on, but the worker script is missing — run /upgrade-kit manually." >&2
    exit 0
fi
LOG="/tmp/kit-auto-upgrade-${SESSION_ID}.log"
nohup bash "$WORKER" "$PROJECT_DIR" "$LOG" >/dev/null 2>&1 &
printf '%s\n' "🔄 claude-kit was behind — auto-upgrade started in the background (guardrailed to .claude/ only; opens an auto-merging PR). Log: ${LOG}" >&2
exit 0
