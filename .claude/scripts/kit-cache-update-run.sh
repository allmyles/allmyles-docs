#!/usr/bin/env bash
# kit-cache-update-run.sh (INF-201) — the worker for the default-on
# plugin-cache auto-update.
#
# Invoked (backgrounded, detached) by the check-plugin-cache-drift.sh
# SessionStart hook when the repo pin's kitSha differs from the installed
# plugin cache's gitCommitSha. Runs the marketplace refresh + plugin update
# so the NEXT session start loads the current skills — the operator types
# nothing (the update leg of the INF-196 "no copy-pasting" agreement).
#
# SAFETY / CONTRACT:
#   - Touches ONLY the per-machine plugin cache (`claude plugin ...`); never
#     the repo working tree, never git state.
#   - mkdir-lock so concurrent session starts don't race the same update.
#   - Every call is bounded (INF-187 _bounded pattern: timeout / gtimeout /
#     shell watchdog) — a detached worker must never hang invisibly.
#   - Never interactive; all output to the log; exits 0 on every path.
#     Failure is benign: the drift persists, so the next session start
#     retries and the hook's advisory remains the fallback signal.
#
# Usage: kit-cache-update-run.sh [LOG_FILE]
# Env:   KIT_CACHE_UPDATE_CLAUDE — claude binary override (tests)

set -uo pipefail

LOG="${1:-/tmp/kit-cache-update.log}"
CLAUDE_BIN="${KIT_CACHE_UPDATE_CLAUDE:-claude}"
LOCK="/tmp/kit-cache-update.lock"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo now)" "$*" >> "$LOG"; }

# ── Bounded execution (INF-187 pattern) ─────────────────────────────────
TIMEOUT_BIN=""
for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }; done
_bounded() {
    local _secs="$1"; shift
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" "$_secs" "$@"
    else
        # Shell watchdog: background the command, kill at the deadline.
        "$@" &
        local _pid=$!
        ( sleep "$_secs"; kill "$_pid" 2>/dev/null ) &
        local _watchdog=$!
        wait "$_pid" 2>/dev/null
        local _rc=$?
        kill "$_watchdog" 2>/dev/null
        wait "$_watchdog" 2>/dev/null
        return "$_rc"
    fi
}

# ── Single-flight lock (concurrent sessions may both detect drift) ──────
if ! mkdir "$LOCK" 2>/dev/null; then
    log "another cache update is in flight (lock $LOCK held) — exiting"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { log "claude binary '$CLAUDE_BIN' not found — cannot update the cache"; exit 0; }

log "cache update starting (marketplace refresh + plugin update)"

if ! _bounded 120 "$CLAUDE_BIN" plugin marketplace update allmyles-claude-kit >> "$LOG" 2>&1; then
    log "marketplace update failed or timed out — drift persists; next session start retries"
    exit 0
fi

if ! _bounded 180 "$CLAUDE_BIN" plugin update claude-kit@allmyles-claude-kit >> "$LOG" 2>&1; then
    log "plugin update failed or timed out — drift persists; next session start retries"
    exit 0
fi

# Best-effort: record what the cache landed on (diagnostic only).
INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"
if command -v jq >/dev/null 2>&1 && [ -r "$INSTALLED_JSON" ]; then
    NEW_SHA="$(jq -r '(.plugins["claude-kit@allmyles-claude-kit"] // []) | first | .gitCommitSha // "unknown"' "$INSTALLED_JSON" 2>/dev/null)"
    log "cache update complete — installed plugin now at ${NEW_SHA:0:8}. Restart Claude Code sessions to load it."
else
    log "cache update complete. Restart Claude Code sessions to load it."
fi
exit 0
