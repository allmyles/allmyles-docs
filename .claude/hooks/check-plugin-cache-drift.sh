#!/bin/bash
# SessionStart hook: warns when the consumer's pinned claude-kit SHA
# (last `setup-project.sh` run) disagrees with the SHA the installed
# plugin cache is currently at.
#
# INF-134 Item 1 / INF-128 Q3 follow-up. Distinct from check-kit-drift.sh:
#   - check-kit-drift.sh: pin SHA vs upstream github.com/allmyles/claude-kit
#     master — catches "kit master moved beyond your last setup-project.sh".
#     Requires network.
#   - This hook: pin SHA vs `~/.claude/plugins/installed_plugins.json`'s
#     gitCommitSha for claude-kit@allmyles-claude-kit — catches "operator
#     ran `claude plugin marketplace update` (plugin cache moved) but
#     forgot `bash setup-project.sh` (.claude/scripts/ and .claude/hooks/
#     are stale)". LOCAL ONLY — no network.
#
# Why both hooks: check-kit-drift catches the most common case (operator
# hasn't run plugin update yet). This hook catches the offline-or-forgot-
# setup-project case where the plugin cache HAS been updated but the
# consumer's .claude/ tree hasn't been refreshed.
#
# Structural clone of check-kit-drift.sh; reuses the same session_id
# whitelisting, per-session marker, silent-degradation contract. Always
# exits 0 (advisory only; never blocks session start).
#
# Behavior:
#   - Pin missing → SILENT (let check-kit-drift.sh emit the bootstrap
#     advisory; this hook adds nothing on first-install).
#   - installed_plugins.json missing → silent (no plugin installed,
#     can't determine cache SHA).
#   - Plugin SHA == pin SHA → silent (consumer is in sync with their
#     installed plugin cache).
#   - Plugin SHA != pin SHA → advisory "operator ran plugin update but
#     hasn't run setup-project.sh".

set +e  # belt-and-braces: never fail the hook on a parse error

INPUT="$(cat || true)"

# Extract session_id robustly. Falls back to the shell's PPID
# (same pattern as check-kit-drift.sh — see that file for the rationale
# of the python3 sub-shell + PPID fallback).
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

# Distinct marker prefix so this hook doesn't share state with
# check-kit-drift.sh — both can fire in the same session if both
# conditions are independently true.
MARKER_FILE="/tmp/claude-plugin-cache-drift-${SESSION_ID}.flag"

if [ -e "$MARKER_FILE" ]; then
    exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PIN_FILE="${PROJECT_DIR}/.claude/claude-kit-pin.json"
INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"

# jq required for clean JSON parsing; silent skip otherwise (same
# contract as check-kit-drift.sh).
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Pin missing: NOT this hook's job. check-kit-drift.sh emits the
# bootstrap advisory ("pin file not found — run setup-project.sh");
# duplicating it here is noise. Silent.
if [ ! -r "$PIN_FILE" ]; then
    exit 0
fi

# installed_plugins.json missing: plugin not installed via the
# marketplace path, OR Claude Code's first-run before any install. We
# can't determine the plugin cache SHA, so we can't detect drift.
# Silent (the contract is "advise on detectable drift", not "advise on
# every possible inconsistency").
if [ ! -r "$INSTALLED_JSON" ]; then
    exit 0
fi

# Read the pinned SHA. `// ""` normalizes a missing field or literal
# null to empty.
PINNED_SHA="$(jq -r '.kitSha // ""' "$PIN_FILE" 2>/dev/null || echo "")"
if [ -z "$PINNED_SHA" ] || [ "$PINNED_SHA" = "null" ]; then
    # Pin file present but kitSha absent — same case as missing pin
    # semantically. check-kit-drift.sh handles the advisory; we stay
    # silent.
    exit 0
fi

# Read the installed plugin's SHA. Priority order MATCHES setup-project.sh:
# project-scope match (by projectPath==$PROJECT_DIR) first, then any
# claude-kit entry. The hook compares against the same SHA
# setup-project.sh would WRITE to the pin — otherwise this would
# false-positive on a multi-scope install.
PLUGIN_SHA="$(jq -r --arg pwd "$PROJECT_DIR" '
    (.plugins["claude-kit@allmyles-claude-kit"] // [])
    | map(select(.projectPath == $pwd))
    | first
    | .gitCommitSha // empty
' "$INSTALLED_JSON" 2>/dev/null || echo "")"

if [ -z "$PLUGIN_SHA" ]; then
    PLUGIN_SHA="$(jq -r '
        (.plugins["claude-kit@allmyles-claude-kit"] // [])
        | first
        | .gitCommitSha // empty
    ' "$INSTALLED_JSON" 2>/dev/null || echo "")"
fi

if [ -z "$PLUGIN_SHA" ] || [ "$PLUGIN_SHA" = "null" ]; then
    # No claude-kit entry in installed_plugins.json — plugin not
    # installed. Silent (same rationale as missing installed_plugins.json).
    exit 0
fi

# Match → silent. Consumer's pin file is in sync with the installed
# plugin cache; nothing to advise.
if [ "$PINNED_SHA" = "$PLUGIN_SHA" ]; then
    exit 0
fi

# Mismatch → emit the advisory. Operator updated the plugin cache (via
# `claude plugin marketplace update`) but the `.claude/` tree hasn't
# been refreshed by `setup-project.sh`. Hooks and helper scripts in
# `.claude/{hooks,scripts}/` may be behind the current plugin's version.
touch "$MARKER_FILE" 2>/dev/null || true
printf '%s\n' "⚠️ claude-kit plugin cache (${PLUGIN_SHA:0:8}) is ahead of consumer pin (${PINNED_SHA:0:8}) — run: bash .claude/plugins/claude-kit/scripts/setup-project.sh && restart Claude Code so the refreshed hooks + scripts take effect." >&2

exit 0
