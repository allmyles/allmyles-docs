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
#   - Pin PRESENT but plugin not installed (installed_plugins.json
#     missing, or no claude-kit entry in it) → LOUD advisory with the
#     exact install commands (INF-195). The repo is kit-adopted — the
#     fan-out delivered .claude/ — but this machine has never installed
#     the plugin, so /develop and every other kit skill DOES NOT EXIST
#     in the session and nothing else warns (the /develop cross-repo
#     BLOCK can't fire without the skill; the mileometer-frontend
#     MYST-9 incident, 2026-07-16). Repos WITHOUT the pin stay silent —
#     they never adopted the kit and nagging them is noise.
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

# INF-195: at this point the pin file EXISTS — this checkout is a
# kit-adopted consumer. If the plugin is not installed on this machine,
# no kit skill (/develop, /review, …) exists in the session and nothing
# else warns; emit the exact remedy instead of staying silent. Shared by
# the missing-file and missing-entry branches below.
plugin_missing_advisory() {
    touch "$MARKER_FILE" 2>/dev/null || true
    printf '%s\n' "⚠️ This repo is claude-kit-adopted (pin present) but the claude-kit PLUGIN is not installed for this machine/project — kit skills like /develop are unavailable in this session. Fix: claude plugin marketplace update allmyles-claude-kit && claude plugin install claude-kit@allmyles-claude-kit --scope project — then RESTART Claude Code (skills load from the plugin cache at startup). Diagnose anytime with: bash .claude/scripts/kit-doctor.sh" >&2
    exit 0
}

# installed_plugins.json missing: no plugin has ever been installed on
# this machine — but the pin says this repo expects one (INF-195).
if [ ! -r "$INSTALLED_JSON" ]; then
    plugin_missing_advisory
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
    # installed for any project on this machine, while the pin says this
    # repo expects it. LOUD (INF-195; was silent pre-0.4.15, which is
    # how the mileometer-frontend MYST-9 session ended up with no
    # /develop skill and no warning).
    plugin_missing_advisory
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
#
# INF-187: resolve setup-project.sh from the plugin's actual installPath
# in installed_plugins.json (same source upgrade-kit.sh uses) — installed
# plugins are cached OUTSIDE the project tree, so the previously
# hardcoded `.claude/plugins/claude-kit/...` path never exists on a
# standard install. Prefer the project-scoped entry; fall back to the
# /upgrade-kit skill when no resolvable path is found.
SETUP_PATH="$(jq -r --arg pwd "$PROJECT_DIR" '
    (.plugins["claude-kit@allmyles-claude-kit"] // [])
    | (map(select(.projectPath == $pwd)) + .)
    | first
    | .installPath // empty
' "$INSTALLED_JSON" 2>/dev/null || echo "")"
if [ -n "$SETUP_PATH" ] && [ -f "${SETUP_PATH}/scripts/setup-project.sh" ]; then
    # Quote the resolved path in the copy-pasteable command — plugin
    # cache paths can contain spaces (CR round 1.1).
    REMEDY="run: bash '${SETUP_PATH}/scripts/setup-project.sh'"
else
    REMEDY="run the /upgrade-kit skill (setup-project.sh path could not be resolved from installed_plugins.json)"
fi
touch "$MARKER_FILE" 2>/dev/null || true
printf '%s\n' "⚠️ claude-kit plugin cache (${PLUGIN_SHA:0:8}) is ahead of consumer pin (${PINNED_SHA:0:8}) — ${REMEDY} && restart Claude Code so the refreshed hooks + scripts take effect." >&2

exit 0
