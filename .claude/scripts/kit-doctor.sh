#!/usr/bin/env bash
# kit-doctor.sh (INF-195) — one-shot, operator-friendly readiness check
# for a claude-kit consumer checkout. Answers "is THIS session ready to
# run /develop?" with a ✅/❌ checklist and a remedy next to every ❌,
# so a non-developer never has to diagnose the plugin/repo split by hand
# (the mileometer-frontend MYST-9 incident, 2026-07-16: repo fully
# kit-adopted, plugin never installed on the machine, nothing warned).
#
# Usage (from the consumer repo root):
#   bash .claude/scripts/kit-doctor.sh
#
# What it checks, in dependency order:
#   1. jq present (everything below parses JSON)
#   2. Repo-side kit artifacts (.claude/develop-config.json, scripts/,
#      hooks/, settings.json, claude-kit-pin.json) — delivered by the
#      release fan-out / setup-project.sh
#   3. Machine-side plugin install (installed_plugins.json entry for
#      claude-kit@allmyles-claude-kit, preferring this project's scope)
#      and its installPath existing on disk — REQUIRED for skills like
#      /develop to exist in a session
#   4. Pin vs installed-plugin SHA (setup-project.sh freshness)
#   5. Pin vs upstream kit master (best-effort, needs gh + network)
#
# Exit codes: 0 = all required checks green (warnings allowed),
#             1 = at least one ❌.
#
# Env overrides (tests): KIT_DOCTOR_HOME (default $HOME),
# CLAUDE_PROJECT_DIR (default $PWD), KIT_DOCTOR_SKIP_UPSTREAM=1 to skip
# the network check.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DOCTOR_HOME="${KIT_DOCTOR_HOME:-$HOME}"
INSTALLED_JSON="${DOCTOR_HOME}/.claude/plugins/installed_plugins.json"
PLUGIN_KEY="claude-kit@allmyles-claude-kit"
# INF-196: prefer the ONE-TIME user-scope install — it makes the kit
# available in EVERY repo on this machine (current and future consumers),
# with each repo's committed enabledPlugins declaration keeping it active.
INSTALL_PAIR="claude plugin marketplace update allmyles-claude-kit && claude plugin install claude-kit@allmyles-claude-kit --scope user"

PASS=0; FAIL=0; WARNINGS=0
ok()    { printf '✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '❌ %s\n' "$1"; [ -n "${2:-}" ] && printf '   → fix: %s\n' "$2"; FAIL=$((FAIL + 1)); }
warnl() { printf '⚠️  %s\n' "$1"; [ -n "${2:-}" ] && printf '   → %s\n' "$2"; WARNINGS=$((WARNINGS + 1)); }
note()  { printf 'ℹ️  %s\n' "$1"; }

echo "── kit-doctor: claude-kit session readiness for ${PROJECT_DIR}"

# ── 1. jq ─────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
    ok "jq available"
else
    bad "jq not found — every check below needs it" "brew install jq (macOS) / apt-get install jq (Linux)"
    echo "── verdict: ❌ NOT READY (${FAIL} problem(s))"
    exit 1
fi

# ── 2. Repo-side kit artifacts ────────────────────────────────────────
# CR round 1.1: validate CONTENT, not just existence — a corrupt or
# wrong-shaped file would pass an -f check and then break /develop at
# runtime, which is exactly the class of surprise this doctor exists to
# catch before a run.
if [ -f "${PROJECT_DIR}/.claude/develop-config.json" ]; then
    if ! jq -e . "${PROJECT_DIR}/.claude/develop-config.json" >/dev/null 2>&1; then
        bad "develop-config.json is not valid JSON — /develop's config loader will fall back to mileometer defaults" "re-run setup-project.sh or restore the file from the default branch"
    else
        SHAPE="$(jq -r '.shape // "staging-master"' "${PROJECT_DIR}/.claude/develop-config.json" 2>/dev/null)"
        case "$SHAPE" in
            single-branch|staging-master)
                ok "develop-config.json valid (repo shape: ${SHAPE})"
                ;;
            *)
                bad "develop-config.json has an unknown shape '${SHAPE}' (expected single-branch or staging-master)" "fix the shape field or re-run setup-project.sh"
                ;;
        esac
    fi
else
    bad "develop-config.json missing — /develop cannot determine the repo shape" "bash <kit>/scripts/setup-project.sh, or pull the latest default branch (the fan-out delivers it)"
fi
if [ -d "${PROJECT_DIR}/.claude/scripts" ] && [ -n "$(ls -A "${PROJECT_DIR}/.claude/scripts" 2>/dev/null)" ]; then
    ok ".claude/scripts/ helpers present"
else
    bad ".claude/scripts/ missing or empty — /develop's watchers and helpers can't run" "pull the latest default branch, or run setup-project.sh"
fi
if [ -d "${PROJECT_DIR}/.claude/hooks" ] && [ -n "$(ls -A "${PROJECT_DIR}/.claude/hooks" 2>/dev/null)" ]; then
    ok ".claude/hooks/ present"
else
    bad ".claude/hooks/ missing or empty — gate enforcement and advisories are off" "pull the latest default branch, or run setup-project.sh"
fi
if [ -f "${PROJECT_DIR}/.claude/settings.json" ]; then
    if ! jq -e . "${PROJECT_DIR}/.claude/settings.json" >/dev/null 2>&1; then
        bad ".claude/settings.json is not valid JSON — hooks and the shared allowlist will not load" "re-run setup-project.sh to regenerate it"
    elif ! jq -e 'has("hooks")' "${PROJECT_DIR}/.claude/settings.json" >/dev/null 2>&1; then
        bad ".claude/settings.json has no hooks block — gate enforcement and advisories are not registered" "re-run setup-project.sh (it merges the kit's settings template)"
    elif ! jq -e 'has("permissions")' "${PROJECT_DIR}/.claude/settings.json" >/dev/null 2>&1; then
        warnl ".claude/settings.json has no permissions block — /develop will prompt for every command class" "re-run setup-project.sh to merge the shared allowlist"
    else
        ok ".claude/settings.json valid (hooks registered + shared allowlist)"
    fi
else
    bad ".claude/settings.json missing — hooks are not registered" "pull the latest default branch, or run setup-project.sh"
fi
# INF-198: playwright-first testing gate readiness. Warning-level — the
# /develop Step 8/10 gates degrade gracefully to the manual prompt when the
# playwright MCP server is absent, so a missing declaration never blocks.
# CR round 1.1: validate SHAPE, not just presence — `"playwright": {}` has
# no runnable command and must not report ready. Runnable = object with a
# non-empty command AND a version-pinned @playwright/mcp package in args.
if [ -f "${PROJECT_DIR}/.mcp.json" ] && jq -e '
        .mcpServers.playwright
        | (type == "object")
          and ((.command // "") != "")
          and (((.args // []) | map(tostring)) | any(startswith("@playwright/mcp@")))
    ' "${PROJECT_DIR}/.mcp.json" >/dev/null 2>&1; then
    ok ".mcp.json declares a runnable, version-pinned playwright MCP server (playwright-first testing gate ready)"
else
    warnl ".mcp.json missing or its playwright server is absent/not runnable — /develop testing gates fall back to the manual prompt" "re-run setup-project.sh (ships the kit's mcp.template.json), restart Claude Code; ensure Google Chrome is installed (the pinned MCP drives the chrome channel)"
fi
PIN_SHA=""
if [ -f "${PROJECT_DIR}/.claude/claude-kit-pin.json" ]; then
    PIN_SHA="$(jq -r '.kitSha // ""' "${PROJECT_DIR}/.claude/claude-kit-pin.json" 2>/dev/null)"
    if [ -n "$PIN_SHA" ] && [ "$PIN_SHA" != "null" ]; then
        ok "kit pin present (${PIN_SHA:0:8})"
    else
        bad "claude-kit-pin.json present but has no kitSha" "re-run setup-project.sh to regenerate the pin"
        PIN_SHA=""
    fi
else
    bad "claude-kit-pin.json missing — this checkout has never been kit-initialized" "pull the latest default branch, or run setup-project.sh"
fi

# ── 3. Machine-side plugin install (what makes /develop EXIST) ────────
PLUGIN_SHA=""
INSTALL_PATH=""
if [ ! -r "$INSTALLED_JSON" ]; then
    bad "claude-kit plugin is NOT installed on this machine — kit skills (/develop, /review, …) do not exist in your sessions" "${INSTALL_PAIR} — then RESTART Claude Code"
else
    # Selection order (INF-196): exact project match → user-scope
    # (machine-wide, the recommended steady state) → any other entry.
    ENTRY="$(jq -r --arg pwd "$PROJECT_DIR" --arg key "$PLUGIN_KEY" '
        (.plugins[$key] // [])
        | (map(select(.projectPath == $pwd))
           + map(select(.scope == "user"))
           + .)
        | first // empty
        | @json' "$INSTALLED_JSON" 2>/dev/null)"
    if [ -z "$ENTRY" ]; then
        bad "claude-kit plugin is NOT installed (no entry in installed_plugins.json) — kit skills do not exist in your sessions" "${INSTALL_PAIR} — then RESTART Claude Code"
    else
        # ENTRY holds the entry object as plain JSON text (jq -r + @json
        # emits the object's JSON without extra quoting) — parse directly.
        PLUGIN_SHA="$(printf '%s' "$ENTRY" | jq -r '.gitCommitSha // ""' 2>/dev/null)"
        INSTALL_PATH="$(printf '%s' "$ENTRY" | jq -r '.installPath // ""' 2>/dev/null)"
        PROJECT_MATCH="$(printf '%s' "$ENTRY" | jq -r --arg pwd "$PROJECT_DIR" 'if .projectPath == $pwd then "yes" else "no" end' 2>/dev/null)"
        ENTRY_SCOPE="$(printf '%s' "$ENTRY" | jq -r '.scope // ""' 2>/dev/null)"
        if [ "$PROJECT_MATCH" = "yes" ]; then
            ok "plugin installed for THIS project (${PLUGIN_SHA:0:8})"
        elif [ "$ENTRY_SCOPE" = "user" ]; then
            # INF-196: a user-scope install covers every repo on the
            # machine — this is the RECOMMENDED steady state, not a warning.
            ok "plugin installed machine-wide (user scope, ${PLUGIN_SHA:0:8}) — covers this and every consumer repo"
        else
            warnl "plugin installed on this machine (${PLUGIN_SHA:0:8}) but only for other projects (scope: ${ENTRY_SCOPE:-unknown})" "one-time fix for ALL repos: ${INSTALL_PAIR} — then restart Claude Code"
        fi
        if [ -n "$INSTALL_PATH" ] && [ -d "$INSTALL_PATH" ]; then
            ok "plugin cache exists on disk"
        else
            bad "plugin registered but its cache directory is missing (${INSTALL_PATH:-unknown})" "${INSTALL_PAIR} — then RESTART Claude Code"
        fi
    fi
fi

# ── 4. Pin vs installed plugin (setup-project freshness) ─────────────
if [ -n "$PIN_SHA" ] && [ -n "$PLUGIN_SHA" ]; then
    if [ "$PIN_SHA" = "$PLUGIN_SHA" ]; then
        ok "repo .claude/ copies match the installed plugin (same SHA)"
    else
        warnl "installed plugin (${PLUGIN_SHA:0:8}) differs from the repo pin (${PIN_SHA:0:8})" "if the plugin is newer: run setup-project.sh to refresh .claude/; if the repo is newer: ${INSTALL_PAIR}. Restart Claude Code afterwards."
    fi
fi

# ── 5. Pin vs upstream kit master (best-effort; needs gh + network) ──
if [ "${KIT_DOCTOR_SKIP_UPSTREAM:-0}" != "1" ] && [ -n "$PIN_SHA" ] && command -v gh >/dev/null 2>&1; then
    UPSTREAM_SHA="$(gh api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null || echo "")"
    if [ -n "$UPSTREAM_SHA" ]; then
        if [ "$UPSTREAM_SHA" = "$PIN_SHA" ]; then
            ok "pin matches the latest kit master (${UPSTREAM_SHA:0:8})"
        else
            BEHIND="$(gh api "/repos/allmyles/claude-kit/compare/${PIN_SHA}...master" --jq .ahead_by 2>/dev/null || echo "?")"
            warnl "kit master has moved on (pin is ${BEHIND:-?} commit(s) behind ${UPSTREAM_SHA:0:8})" "usually fine — the next release fan-out catches you up automatically; force it now with the install pair + setup-project.sh"
        fi
    else
        note "could not reach github to compare against kit master (offline or gh unauthenticated) — skipped"
    fi
else
    note "upstream comparison skipped (no gh, no pin, or KIT_DOCTOR_SKIP_UPSTREAM=1)"
fi

# ── Verdict ───────────────────────────────────────────────────────────
echo "──"
if [ "$FAIL" -gt 0 ]; then
    echo "verdict: ❌ NOT READY — ${FAIL} problem(s), ${WARNINGS} warning(s). Apply the fixes above, restart Claude Code, then re-run this script."
    exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
    echo "verdict: ✅ READY (with ${WARNINGS} warning(s) above) — /develop should work in this checkout."
else
    echo "verdict: ✅ READY — /develop should work in this checkout."
fi
exit 0
