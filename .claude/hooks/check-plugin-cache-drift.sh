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
# KIT_CACHE_DRIFT_HOME: test override for the machine-level plugin state
# (INF-201) — production always uses $HOME.
DRIFT_HOME="${KIT_CACHE_DRIFT_HOME:-$HOME}"
INSTALLED_JSON="${DRIFT_HOME}/.claude/plugins/installed_plugins.json"

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
    printf '%s\n' "⚠️ This repo is claude-kit-adopted (pin present) but the claude-kit PLUGIN is not installed for this machine/project — kit skills like /develop are unavailable in this session. One-time fix for ALL repos on this machine (INF-196): claude plugin marketplace update allmyles-claude-kit && claude plugin install claude-kit@allmyles-claude-kit --scope user — then RESTART Claude Code (skills load from the plugin cache at startup). Diagnose anytime with: bash .claude/scripts/kit-doctor.sh" >&2
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

# INF-205: kit-checkout convergence. In the kit repo ITSELF the pin is
# legitimately stale forever (the fan-out never delivers to the kit), so
# pin-vs-cache mismatch would fire the INF-201 auto-updater + notice at
# EVERY session start with no way to converge. The kit checkout's truth
# is its own origin/master: when the installed cache already equals the
# local origin/master ref, the cache is current — stay silent. Local-only
# (no network): the ref is from the last fetch, which the /develop Init
# master-sync refreshes constantly in practice.
SELF_REMOTE="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || echo "")"
case "$SELF_REMOTE" in
    *allmyles/claude-kit*)
        SELF_MASTER="$(git -C "$PROJECT_DIR" rev-parse origin/master 2>/dev/null || echo "")"
        if [ -n "$SELF_MASTER" ] && [ "$PLUGIN_SHA" = "$SELF_MASTER" ]; then
            exit 0
        fi
        ;;
esac

# Mismatch → the pin and the installed cache disagree. Two directions,
# one machine-level remedy each:
#   - pin AHEAD of cache (the INF-201 incident class: the fan-out
#     delivered a new pin but nobody advanced the plugin cache, so
#     sessions keep loading OLD skills) → `claude plugin update`.
#   - cache AHEAD of pin (operator ran plugin update but not
#     setup-project.sh) → setup-project.sh.
# Direction is not reliably determinable offline (SHAs are unordered),
# and running the cache update is safe in BOTH directions (it converges
# the cache on current master; a stale pin is then the fan-out's job).
#
# INF-201 — auto-update by DEFAULT ("the update leg of the no-copy-
# pasting agreement"): unless kit.auto_cache_update is the literal
# false, launch the bounded kit-cache-update-run.sh worker in the
# background (never blocks session start) and say so in one line. The
# next session restart loads the refreshed skills with zero operator
# commands. Opt-out or missing worker → the pre-INF-201 advisory.
# has()-based read: `.kit.auto_cache_update // empty` would swallow the
# JSON literal false (jq treats false as falsy — the DASH-1915
# default_assignee bug class) and erase the opt-out.
read_auto_update() {
    jq -r 'if (.kit // {}) | has("auto_cache_update") then (.kit.auto_cache_update | tostring) else empty end' "$1" 2>/dev/null
}
AUTO_UPDATE="$(read_auto_update "${PROJECT_DIR}/.claude/settings.local.json")"
[ -z "$AUTO_UPDATE" ] && AUTO_UPDATE="$(read_auto_update "${PROJECT_DIR}/.claude/settings.json")"
# KIT_CACHE_UPDATE_WORKER: test override — production resolves the
# worker next to this hook (.claude/hooks/ → .claude/scripts/ on
# consumers; hooks/ → scripts/ in the plugin tree).
UPDATE_WORKER="${KIT_CACHE_UPDATE_WORKER:-$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd)/kit-cache-update-run.sh}"
if [ "$AUTO_UPDATE" != "false" ] && [ -f "$UPDATE_WORKER" ]; then
    touch "$MARKER_FILE" 2>/dev/null || true
    UPDATE_LOG="/tmp/kit-cache-update-${SESSION_ID}.log"
    nohup bash "$UPDATE_WORKER" "$UPDATE_LOG" >/dev/null 2>&1 &
    printf '%s\n' "🔄 claude-kit plugin cache (${PLUGIN_SHA:0:8}) differs from the repo pin (${PINNED_SHA:0:8}) — updating the cache in the background (INF-201). Restart this session (or open a new one) to load the refreshed skills. Opt out with kit.auto_cache_update: false. Log: ${UPDATE_LOG}" >&2
    exit 0
fi

# Opt-out (or worker missing) → advisory only. Operator updated the
# plugin cache (via `claude plugin marketplace update`) but the
# `.claude/` tree hasn't been refreshed by `setup-project.sh` — or the
# reverse. Hooks and helper scripts in `.claude/{hooks,scripts}/` may be
# behind the current plugin's version.
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
printf '%s\n' "⚠️ claude-kit plugin cache (${PLUGIN_SHA:0:8}) differs from the repo pin (${PINNED_SHA:0:8}) — if the cache is stale run: claude plugin update claude-kit@allmyles-claude-kit; if the .claude/ tree is stale ${REMEDY}. Then restart Claude Code so the refreshed skills + hooks take effect. (Auto-update is opted out via kit.auto_cache_update: false.)" >&2

exit 0
