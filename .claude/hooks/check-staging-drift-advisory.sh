#!/bin/bash
# SessionStart hook: warns when the default branch (master) has fallen behind
# the PR base branch (staging) — i.e. unpromoted feature merges have piled up
# and the post-deploy "sync staging with master" job hasn't reconciled them.
#
# DASH-2338: the structural signal for the DASH-2335 incident, where staging
# drifted 9 commits ahead of master and a clean, approved feature PR became
# un-mergeable. This hook surfaces the drift on every session start so it never
# accumulates silently again. It is the advisory sibling of the hard STOP gate
# in .claude/skills/develop/SKILL.md (Init); both share the core measurement in
# .claude/scripts/check-staging-drift.sh.
#
# Pattern mirror: this is a structural clone of check-claude-version-drift.sh
# (DASH-2063) and check-kit-drift.sh (DASH-2177) — single stderr advisory on
# mismatch, silent on match, idempotent per session via a /tmp marker, exits 0
# unconditionally (advisory only, NEVER blocks session start).
#
# Behavior:
#   - Silent when in sync (DRIFT_COUNT == 0) or shape is not staging-master.
#   - On drift: one stderr advisory line with the count + recovery hint.
#     advisory verdict (below block threshold) and block verdict (at/above)
#     both emit; the gate in /develop is what actually STOPs a run.
#   - Idempotent within a session via /tmp/staging-drift-advisory-<sid>.flag.
#   - Exits 0 unconditionally. Any failure (no git, no refs, missing core
#     script) degrades to "no warning" rather than a blocked session.
#   - Uses --no-fetch to stay fast; compares existing remote-tracking refs.
#     /develop's Init gate does a fresh fetch before its authoritative check.

set +e  # belt-and-braces: never fail the hook on an error

INPUT="$(cat || true)"

# Extract session_id robustly (same approach as check-claude-version-drift.sh).
# PPID is passed as argv[1] because it is not exported to the python child.
SESSION_ID="$(echo "$INPUT" | python3 -c "
import sys, json, re
ppid = sys.argv[1] if len(sys.argv) > 1 else '0'
try:
    data = json.load(sys.stdin)
    sid = data.get('session_id') or data.get('sessionId') or ''
    if not sid:
        sid = ppid
    sid = re.sub(r'[^A-Za-z0-9_-]', '_', str(sid))[:64]
    print(sid if sid else '0')
except Exception:
    print(re.sub(r'[^0-9]', '', str(ppid)) or '0')
" "$PPID" 2>/dev/null || echo "0")"

MARKER_FILE="/tmp/staging-drift-advisory-${SESSION_ID}.flag"

# Already advised this session → silent.
if [ -e "$MARKER_FILE" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# Locate the core script. As a claude-kit plugin, sibling scripts live under
# ${CLAUDE_PLUGIN_ROOT}/scripts — the portable, install-location-independent
# reference for intra-plugin files (per the Claude Code plugin docs). Fall back
# to the consumer-local .claude/scripts/ path for the non-plugin (e.g.
# mileometer-local) checkout, where CLAUDE_PLUGIN_ROOT is unset.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/check-staging-drift.sh" ]; then
  CORE="${CLAUDE_PLUGIN_ROOT}/scripts/check-staging-drift.sh"
else
  CORE="${PROJECT_DIR}/.claude/scripts/check-staging-drift.sh"
fi

if [ ! -x "$CORE" ]; then
  # Core script missing (fresh checkout that hasn't pulled DASH-2338 yet, or
  # local edits). Silent — advisory only.
  exit 0
fi

OUT="$("$CORE" --no-fetch 2>/dev/null)" || OUT=""

VERDICT=$(printf '%s\n' "$OUT" | grep -E '^VERDICT=' | tail -1 | cut -d= -f2)
MESSAGE=$(printf '%s\n' "$OUT" | grep -E '^MESSAGE=' | tail -1 | cut -d= -f2-)

# Silent unless there is actual drift to report.
case "$VERDICT" in
  advisory|block) ;;
  *) exit 0 ;;
esac

# Write the marker and emit the single advisory line.
touch "$MARKER_FILE" 2>/dev/null || true

if [ "$VERDICT" = "block" ]; then
  # MESSAGE already states the count, threshold, and recovery; prepend only
  # the consequence (a /develop run will STOP) so nothing is double-stated.
  printf '%s\n' "⚠️ Staging drift (DASH-2338) — a new /develop run will STOP until reconciled. ${MESSAGE}" >&2
else
  printf '%s\n' "⚠️ Staging drift (DASH-2338). ${MESSAGE}" >&2
fi

exit 0
