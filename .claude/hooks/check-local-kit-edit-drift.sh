#!/bin/bash
# SessionStart hook: warns when a consumer's LOCAL copy of a kit-managed
# file (.claude/{scripts,hooks}/<name>) differs from the version shipped in
# the installed claude-kit plugin.
#
# INF-151 (epic INF-150). The existing drift hooks — check-kit-drift.sh
# (INF-133/DASH-2179) and check-plugin-cache-drift.sh (INF-134) — only detect
# the "consumer is BEHIND kit master" direction. They miss the opposite,
# more insidious direction: the consumer has edited its local copy of a
# kit-managed file and never upstreamed it, so the local `.claude/` silently
# diverges from the kit. That is exactly the drift that accumulated between
# mileometer and claude-kit over months before the INF-141 reconciliation.
#
# This hook closes that gap. On every session start it compares each file that
# exists in BOTH the plugin (${CLAUDE_PLUGIN_ROOT}/{scripts,hooks}) AND the
# consumer (${CLAUDE_PROJECT_DIR}/.claude/{scripts,hooks}); any byte difference
# is a local edit (or a stale copy) that should be reconciled with the kit.
# Comparing only files present in both places means genuinely-local files
# (settings.local.json, develop-config.json, project-only scripts) never
# false-positive — they simply have no plugin counterpart.
#
# Structural clone of check-kit-drift.sh (DASH-2179): session_id whitelisting
# + per-session marker (one warning per session), silence-on-match, always
# exits 0 (advisory only, never blocks), `set +e` so any failure degrades to
# "no warning" rather than "broken hook".
#
# Behavior:
#   - CLAUDE_PLUGIN_ROOT unset / plugin dir missing → silent (can't compare;
#     e.g. the hook is running outside a plugin install).
#   - All shared files match → silent.
#   - One or more shared files differ → single-line advisory listing them +
#     the recovery command.
#   - Per-session marker /tmp/claude-kit-localedit-drift-<sid>.flag → one
#     warning per session.

set +e  # belt-and-braces: never fail the hook on an unexpected error

INPUT="$(cat || true)"

# Extract session_id robustly (verbatim pattern from check-kit-drift.sh).
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

MARKER_FILE="/tmp/claude-kit-localedit-drift-${SESSION_ID}.flag"

# Already warned this session → silent.
if [ -e "$MARKER_FILE" ]; then
    exit 0
fi

# The plugin root is where the kit's canonical files live. Claude Code sets
# CLAUDE_PLUGIN_ROOT when running a plugin hook; without it we cannot compare.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    exit 0
fi

# The consumer's .claude/ tree (its editable installed copies).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CONSUMER_CLAUDE="${PROJECT_DIR}/.claude"
if [ ! -d "$CONSUMER_CLAUDE" ]; then
    exit 0
fi

# Compare every file present in BOTH the plugin and the consumer, across the
# two kit-managed subtrees. Only intersection files are checked, so local-only
# files (no plugin counterpart) are never flagged.
DIVERGED=""
for sub in scripts hooks; do
    plugin_sub="${PLUGIN_ROOT}/${sub}"
    consumer_sub="${CONSUMER_CLAUDE}/${sub}"
    [ -d "$plugin_sub" ] && [ -d "$consumer_sub" ] || continue
    for pf in "$plugin_sub"/*; do
        [ -f "$pf" ] || continue
        name="$(basename "$pf")"
        cf="${consumer_sub}/${name}"
        [ -f "$cf" ] || continue           # only-in-plugin → not a local-edit case
        if ! cmp -s "$pf" "$cf"; then
            DIVERGED="${DIVERGED}${DIVERGED:+, }${sub}/${name}"
        fi
    done
done

if [ -n "$DIVERGED" ]; then
    touch "$MARKER_FILE" 2>/dev/null || true
    printf '%s\n' "⚠️ claude-kit local-edit drift: your local copy differs from the installed kit for: ${DIVERGED}. Either upstream these edits to allmyles/claude-kit (INF PR) — do NOT keep editing kit-managed files locally — or discard the local change by restoring the kit copy over it, e.g. \`cp \"\${CLAUDE_PLUGIN_ROOT}/<subdir>/<name>\" .claude/<subdir>/<name>\`. (Re-running setup-project.sh alone will NOT reset an already-edited file — its copy step skips a destination that isn't older than the kit source.)" >&2
fi

exit 0
