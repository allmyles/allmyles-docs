#!/bin/bash
# SessionStart hook: warns when the consumer's installed claude-kit version
# disagrees with the kit master HEAD on github.com/allmyles/claude-kit.
#
# DASH-2179 / DASH-2177 option B (session-start drift advisory). Consumers
# install the kit once and silently drift behind kit master as new versions
# are published. This hook fires on every session start, reads the kit-pin
# sidecar at `${CLAUDE_PROJECT_DIR}/.claude/claude-kit-pin.json`, compares
# the pinned SHA against the upstream master HEAD, and emits a single-line
# stderr advisory on mismatch (or on missing pin file).
#
# Structural clone of the proven pattern in
# `plugins/claude-kit/hooks/check-claude-version-drift.sh` (DASH-2063 —
# Claude Code version drift). Both hooks share:
#   - session_id whitelisting + per-session marker for one-warning-per-session
#   - silence-on-match
#   - always exits 0 (advisory only; never blocks session start)
#   - belt-and-braces `set +e` so any parse/network failure degrades to
#     "no warning" rather than "broken hook"
#
# Pin file schema (`.claude/claude-kit-pin.json`, consumer-side):
#   {
#     "kitSha": "<40-char>",
#     "lastUpgradeAt": "<ISO-8601 UTC>"
#   }
# Written by `plugins/claude-kit/scripts/setup-project.sh` at the end of a
# successful run. See MIGRATION.md § "Kit drift advisory (DASH-2179)" for the
# full lifecycle (install → pin → drift → upgrade → re-pin).
#
# Behavior:
#   - Pin missing → advisory "pin file not found — run setup-project.sh".
#   - Pin matches upstream → silent.
#   - Pin behind upstream → advisory with N-commits-behind + recovery command.
#   - Network failure / `gh` unavailable / `jq` missing → silent (degrade).
#   - Per-session marker `/tmp/claude-kit-drift-<sid>.flag` → one warning
#     per session, even if the consumer somehow triggers SessionStart twice.

set +e  # belt-and-braces: never fail the hook on a parse/network error

# Read hook stdin JSON; Claude Code includes session_id in the payload.
INPUT="$(cat || true)"

# Extract session_id robustly. Falls back to the shell's PPID
# (bash builtin — passed as argv[1] because `PPID` is NOT exported to
# child processes, so `os.environ.get('PPID')` returns None inside the
# python3 subprocess). The fallback is a deterministic per-shell value
# so the marker still de-duplicates within the same child process even
# if Claude Code's payload format changes.
# Whitelist the session_id to [A-Za-z0-9_-]+ before using it as a path
# component — Claude Code controls the stdin, but path-traversal hardening
# costs nothing and avoids any future misuse if the field shape changes.
SESSION_ID="$(echo "$INPUT" | python3 -c "
import sys, json, re
ppid = sys.argv[1] if len(sys.argv) > 1 else '0'
try:
    data = json.load(sys.stdin)
    sid = data.get('session_id') or data.get('sessionId') or ''
    if not sid:
        sid = ppid
    # Whitelist filesystem-safe chars only.
    sid = re.sub(r'[^A-Za-z0-9_-]', '_', str(sid))[:64]
    print(sid if sid else '0')
except Exception:
    print(re.sub(r'[^0-9]', '', str(ppid)) or '0')
" "$PPID" 2>/dev/null || echo "0")"

MARKER_FILE="/tmp/claude-kit-drift-${SESSION_ID}.flag"

# Already warned this session → silent.
if [ -e "$MARKER_FILE" ]; then
    exit 0
fi

# Locate the pin file relative to the consumer root. Prefer
# $CLAUDE_PROJECT_DIR (set by Claude Code for hooks); otherwise resolve
# from PWD. The pin lives in the consumer's `.claude/` tree — it is
# consumer-side state about which kit version was last installed.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PIN_FILE="${PROJECT_DIR}/.claude/claude-kit-pin.json"

# Dependency check: `jq` is required for clean JSON parsing. If missing,
# fail silent — the hook is advisory; falling back to grep/cut would be
# fragile and would conflict with the "degrade silently on infra issues"
# contract.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

if [ ! -r "$PIN_FILE" ]; then
    # Pin missing — fresh consumer install that hasn't run setup-project.sh
    # yet, or the file was hand-deleted. Emit the bootstrap advisory.
    touch "$MARKER_FILE" 2>/dev/null || true
    printf '%s\n' "⚠️ claude-kit pin file not found at .claude/claude-kit-pin.json — run \`bash .claude/plugins/claude-kit/scripts/setup-project.sh\` to baseline." >&2
    exit 0
fi

# Read the pinned SHA. `jq -r` returns "null" literal if the path is
# missing; normalize to empty string for clean comparison.
PINNED_SHA="$(jq -r '.kitSha // ""' "$PIN_FILE" 2>/dev/null || echo "")"

if [ -z "$PINNED_SHA" ] || [ "$PINNED_SHA" = "null" ]; then
    # Pin file present but kitSha absent / blank / literal "null" — treat
    # as missing pin (the consumer needs to baseline). Same advisory.
    touch "$MARKER_FILE" 2>/dev/null || true
    printf '%s\n' "⚠️ claude-kit pin file at .claude/claude-kit-pin.json has no kitSha — run \`bash .claude/plugins/claude-kit/scripts/setup-project.sh\` to baseline." >&2
    exit 0
fi

# Dependency check: `gh` is required to query the upstream master HEAD.
# If missing, fail silent — same rationale as `jq` above.
if ! command -v gh >/dev/null 2>&1; then
    exit 0
fi

# Network call: query upstream master HEAD. 8s per-call timeout bounds
# the worst case (slow network, transient GitHub unavailability) so
# SessionStart never feels stalled. Both this call and the compare
# call below use the same 8s budget — combined worst case ≤16s, which
# leaves headroom under hooks.json's 20s SessionStart timeout for the
# surrounding shell. DASH-2179 CR round 1.1 caught the prior 15s
# value: 15+15=30s exceeded the hook budget, so a slow network could
# kill the hook mid-second-call.
#
# `timeout` is a coreutils binary; on macOS it ships as `gtimeout` via
# Homebrew's coreutils — fall back to no-timeout if neither is present
# (the silent-degradation contract still applies if the call hangs,
# but the hook is a per-session one-shot so the blast radius is
# bounded).
if command -v timeout >/dev/null 2>&1; then
    UPSTREAM_SHA="$(timeout 8 gh api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null || echo "")"
elif command -v gtimeout >/dev/null 2>&1; then
    UPSTREAM_SHA="$(gtimeout 8 gh api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null || echo "")"
else
    UPSTREAM_SHA="$(gh api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null || echo "")"
fi

# Network failure / gh CLI unauthenticated / rate-limited → silent.
# Don't false-alarm when we can't reach upstream.
if [ -z "$UPSTREAM_SHA" ]; then
    exit 0
fi

# Match → silent. The pinned SHA equals upstream master; consumer is current.
if [ "$PINNED_SHA" = "$UPSTREAM_SHA" ]; then
    exit 0
fi

# Mismatch → count commits behind via the compare API. Same timeout/
# fallback pattern as the master HEAD call.
if command -v timeout >/dev/null 2>&1; then
    BEHIND_COUNT="$(timeout 8 gh api "/repos/allmyles/claude-kit/compare/${PINNED_SHA}...master" --jq .ahead_by 2>/dev/null || echo "")"
elif command -v gtimeout >/dev/null 2>&1; then
    BEHIND_COUNT="$(gtimeout 8 gh api "/repos/allmyles/claude-kit/compare/${PINNED_SHA}...master" --jq .ahead_by 2>/dev/null || echo "")"
else
    BEHIND_COUNT="$(gh api "/repos/allmyles/claude-kit/compare/${PINNED_SHA}...master" --jq .ahead_by 2>/dev/null || echo "")"
fi

# Compare API failed (e.g., pinned SHA no longer exists upstream after a
# force-push, or 422 from the API) → emit the advisory without the count
# rather than going silent. The mismatch is real even if we can't
# enumerate it.
touch "$MARKER_FILE" 2>/dev/null || true

# ── INF-206: both-stale self-heal ──────────────────────────────────────
# The INF-201 auto-updater triggers on pin↔cache MISMATCH — which misses
# the COMMON case where checkout and cache lag master together (fan-out
# updated the remote, nobody pulled locally: the two stale values match
# and nothing fires; operator incident 2026-07-22). This hook already
# knows the upstream truth, so when the CACHE also lags upstream, launch
# the same bounded background worker here. When the cache is already
# current, only the checkout lags — say so with the right remedy (git
# pull / next /develop Init) instead of the misleading plugin-update
# advisory.
DRIFT_HOME="${KIT_CACHE_DRIFT_HOME:-$HOME}"
INSTALLED_JSON="${DRIFT_HOME}/.claude/plugins/installed_plugins.json"
CACHE_SHA=""
if [ -r "$INSTALLED_JSON" ]; then
    # Prefer the canonical user-scope entry (INF-196), fall back to any.
    CACHE_SHA="$(jq -r '
        (.plugins["claude-kit@allmyles-claude-kit"] // [])
        | (map(select(.scope == "user")) + .)
        | first | .gitCommitSha // empty
    ' "$INSTALLED_JSON" 2>/dev/null)"
fi
read_auto_update() {
    jq -r 'if (.kit // {}) | has("auto_cache_update") then (.kit.auto_cache_update | tostring) else empty end' "$1" 2>/dev/null
}
AUTO_UPDATE="$(read_auto_update "${PROJECT_DIR}/.claude/settings.local.json")"
[ -z "$AUTO_UPDATE" ] && AUTO_UPDATE="$(read_auto_update "${PROJECT_DIR}/.claude/settings.json")"
UPDATE_WORKER="${KIT_CACHE_UPDATE_WORKER:-$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd)/kit-cache-update-run.sh}"

if [ -n "$CACHE_SHA" ] && [ "$CACHE_SHA" != "$UPSTREAM_SHA" ] \
   && [ "$AUTO_UPDATE" != "false" ] && [ -f "$UPDATE_WORKER" ]; then
    UPDATE_LOG="/tmp/kit-cache-update-${SESSION_ID}.log"
    nohup bash "$UPDATE_WORKER" "$UPDATE_LOG" >/dev/null 2>&1 &
    printf '%s\n' "🔄 claude-kit is ${BEHIND_COUNT:-?} commit(s) behind master and the plugin cache (${CACHE_SHA:0:8}) lags too — updating the cache in the background (INF-206). The checkout syncs at the next /develop Init (or git pull). Restart to load the refreshed skills. Log: ${UPDATE_LOG}" >&2
    exit 0
fi
if [ -n "$CACHE_SHA" ] && [ "$CACHE_SHA" = "$UPSTREAM_SHA" ]; then
    printf '%s\n' "⚠️ claude-kit checkout is ${BEHIND_COUNT:-?} commit(s) behind master (plugin cache already current) — git pull, or the next /develop run's Init syncs it automatically." >&2
    exit 0
fi

if [ -n "$BEHIND_COUNT" ] && [ "$BEHIND_COUNT" != "null" ]; then
    printf '%s\n' "⚠️ claude-kit is ${BEHIND_COUNT} commit(s) behind master — run: claude plugin marketplace update allmyles-claude-kit && bash .claude/plugins/claude-kit/scripts/setup-project.sh" >&2
else
    printf '%s\n' "⚠️ claude-kit is behind master (pin ${PINNED_SHA:0:8} != upstream ${UPSTREAM_SHA:0:8}) — run: claude plugin marketplace update allmyles-claude-kit && bash .claude/plugins/claude-kit/scripts/setup-project.sh" >&2
fi

exit 0
