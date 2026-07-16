#!/usr/bin/env bash
# auto-upgrade-kit-run.sh (INF-155) — the worker for the zero-click auto-upgrade.
#
# Invoked (backgrounded, detached) by the auto-upgrade-kit.sh SessionStart hook
# ONLY when: kit.auto_upgrade is enabled AND the kit is behind AND no kit-upgrade
# PR is already open. It does the guardrailed upgrade, opens a PR, and enables
# GitHub auto-merge — so the upgrade lands with zero operator action.
#
# ISOLATION (critical): all work happens in a throwaway `git worktree`, never in
# the operator's live checkout. The background job therefore CANNOT switch the
# operator's branch, touch their working tree, or interfere with active work.
# The worktree is removed on every exit path via a trap.
#
# SAFETY: the upgrade goes through upgrade-kit.sh (INF-154), which HARD-REFUSES
# any change outside .claude/. If it returns anything but RESULT=OK, this worker
# commits/merges NOTHING. So an auto-merge can only ever ship agent tooling —
# never app/infra/code.
#
# Never interactive; all output to a log; exits 0 on every path.
#
# Usage: auto-upgrade-kit-run.sh <PROJECT_ROOT> [LOG_FILE]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${1:?PROJECT_ROOT required}"
LOG="${2:-/tmp/kit-auto-upgrade.log}"
UPGRADE="${AUTO_UPGRADE_KIT_UPGRADE:-${SCRIPT_DIR}/upgrade-kit.sh}"
GH="${AUTO_UPGRADE_KIT_GH:-gh}"
CLAUDE_BIN="${AUTO_UPGRADE_KIT_CLAUDE:-claude}"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo now)" "$*" >> "$LOG"; }

WT=""; WT_PARENT=""; REFRESH_LOCK=""
cleanup() {
    # Single cleanup path for every exit: release the refresh lock (if this
    # worker holds it) and remove the isolated worktree. The operator's live
    # checkout is never involved, so there is nothing to restore.
    [ -n "$REFRESH_LOCK" ] && rmdir "$REFRESH_LOCK" 2>/dev/null
    if [ -n "$WT" ]; then
        git -C "$PROJECT_ROOT" worktree remove --force "$WT" 2>>"$LOG" || true
    fi
    [ -n "$WT_PARENT" ] && rm -rf "$WT_PARENT" 2>/dev/null
}
trap cleanup EXIT

cd "$PROJECT_ROOT" 2>/dev/null || { log "cannot cd to $PROJECT_ROOT"; exit 0; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { log "$PROJECT_ROOT is not a git repo"; exit 0; }
log "auto-upgrade worker starting in $PROJECT_ROOT"

# INF-187: EVERY network-touching call in this detached worker is bounded
# by a finite timeout (previously only the plugin-refresh calls were —
# a hung `git fetch`/`git push`/`gh pr create` could park the worker
# forever with the operator none the wiser). When no timeout/gtimeout
# binary exists, `_bounded` degrades to a shell watchdog (background the
# command, kill it at the deadline) instead of running unbounded — the
# worker is detached, so an unbounded hang is invisible (CR round 1.1).
TIMEOUT_BIN=""
for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }; done
_bounded() {
    local _secs="$1"; shift
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" "$_secs" "$@"
        return $?
    fi
    "$@" &
    local _pid=$!
    ( sleep "$_secs"; kill "$_pid" 2>/dev/null ) &
    local _wd=$!
    local _rc=0
    wait "$_pid" || _rc=$?
    kill "$_wd" 2>/dev/null
    wait "$_wd" 2>/dev/null
    return "$_rc"
}

# --- Advance the plugin BEFORE copying files (INF-162) ---
# `claude plugin marketplace update` alone only refreshes the marketplace CACHE;
# it does NOT advance the *installed* plugin (so skills would stay on the old
# version) and does NOT re-key installed_plugins.json (so upgrade-kit.sh →
# setup-project.sh would derive and write a STALE pin, leaving the drift +
# auto-upgrade hooks firing forever). `claude plugin update … --scope <scope>`
# is what actually advances the install and re-keys the manifest. Both are
# global (~/.claude) operations — run them against the real checkout (cwd), not
# the isolated worktree. Best-effort: on failure we log and still attempt the
# guardrailed upgrade with whatever is cached (a stale copy + the guardrail is
# safer than aborting the zero-click flow silently).
if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"
    SCOPE="project"
    if command -v jq >/dev/null 2>&1 && [ -r "$INSTALLED_JSON" ]; then
        # Prefer the manifest entry whose projectPath matches THIS repo; fall
        # back to the first entry. Matches setup-project.sh's pin derivation so
        # a multi-scope install can't resolve the wrong scope for this project.
        S="$(jq -r --arg pwd "$PROJECT_ROOT" '
            (.plugins["claude-kit@allmyles-claude-kit"] // [])
            | ((map(select(.projectPath == $pwd)) | first) // first)
            | .scope // "project"
        ' "$INSTALLED_JSON" 2>/dev/null)"
        [ -n "$S" ] && [ "$S" != "null" ] && SCOPE="$S"
    fi

    # These two calls mutate SHARED ~/.claude state (marketplace cache +
    # installed_plugins.json), so serialize concurrent workers with an atomic
    # mkdir lock, and BOUND each network call with a finite timeout so a stall
    # can't hang this detached worker forever. Both degrade gracefully: if
    # another worker holds the lock, or a call times out/fails, we log and
    # proceed with whatever is cached (the guardrail still protects the copy).
    # TIMEOUT_BIN is resolved top-level (INF-187) — reuse it here.
    run_claude() {  # bounded when a timeout binary exists, plain otherwise
        _bounded 120 "$CLAUDE_BIN" "$@"
    }
    LOCK="${HOME}/.claude/plugins/.kit-refresh.lock"
    mkdir -p "$(dirname "$LOCK")" 2>/dev/null
    got_lock=""
    if mkdir "$LOCK" 2>/dev/null; then
        got_lock=1
    else
        # Lock held. Steal it only if clearly stale (>600s) — a crashed worker
        # that skipped its trap must not block all future refreshes forever.
        _m="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)"
        _now="$(date +%s 2>/dev/null || echo 0)"
        if [ "$_m" -gt 0 ] && [ "$_now" -gt 0 ] && [ "$((_now - _m))" -gt 600 ]; then
            log "stale kit-refresh lock (age $((_now - _m))s) — stealing it"
            rmdir "$LOCK" 2>/dev/null
            mkdir "$LOCK" 2>/dev/null && got_lock=1
        fi
    fi
    if [ -n "$got_lock" ]; then
        REFRESH_LOCK="$LOCK"
        run_claude plugin marketplace update allmyles-claude-kit >>"$LOG" 2>&1 \
            || log "marketplace update failed/timed out — proceeding with cached kit"
        run_claude plugin update claude-kit@allmyles-claude-kit --scope "$SCOPE" >>"$LOG" 2>&1 \
            || log "plugin update (scope=$SCOPE) failed/timed out — skills/pin may stay stale"
        rmdir "$LOCK" 2>/dev/null; REFRESH_LOCK=""
    else
        log "another kit-refresh holds the lock — skipping plugin refresh, proceeding with cached kit"
    fi
else
    log "claude CLI ($CLAUDE_BIN) not found — cannot advance installed plugin; proceeding with cached kit"
fi

# Resolve the repo's default branch (kit files live there; PR targets it).
DEFAULT="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -z "$DEFAULT" ] && DEFAULT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -z "$DEFAULT" ] && { log "cannot resolve default branch"; exit 0; }
_bounded 60 git fetch -q origin "$DEFAULT" 2>>"$LOG" || true
BASE_SHA="$(git rev-parse --short "origin/${DEFAULT}" 2>/dev/null || git rev-parse --short HEAD)"
BR="kit-upgrade/${BASE_SHA}"

# --- Isolated worktree: all work happens here, NOT in the operator's checkout ---
WT_PARENT="$(mktemp -d -t kit-upg-wt-XXXXXX 2>/dev/null)" || { log "mktemp failed"; exit 0; }
WT="${WT_PARENT}/wt"
if ! _bounded 60 git worktree add -q -b "$BR" "$WT" "origin/${DEFAULT}" 2>>"$LOG"; then
    log "could not create worktree at $WT (branch $BR may exist) — aborting"; exit 0
fi

# Guardrailed upgrade INSIDE the worktree.
OUT="$(CLAUDE_PROJECT_DIR="$WT" bash "$UPGRADE" 2>&1)"
RESULT="$(printf '%s\n' "$OUT" | grep '^RESULT=' | tail -1 | cut -d= -f2)"
log "upgrade-kit.sh RESULT=${RESULT:-none}"
printf '%s\n' "$OUT" >> "$LOG"

case "$RESULT" in
    OK) : ;;  # proceed
    NOCHANGE) log "already current — nothing to do"; exit 0 ;;
    *)        log "guardrail did not return OK (${RESULT:-none}) — committing/merging NOTHING"; exit 0 ;;
esac

# RESULT=OK ⇒ only .claude/ changed (guardrail proved it). Commit exactly that.
git -C "$WT" add .claude/ 2>>"$LOG"
if [ -z "$(git -C "$WT" diff --cached --name-only)" ]; then
    log "no staged .claude changes after OK — nothing to commit"; exit 0
fi
git -C "$WT" commit -q -m "chore: auto-upgrade claude-kit (only .claude/ changed)" 2>>"$LOG"
if ! _bounded 120 git -C "$WT" push -q -u origin "$BR" 2>>"$LOG"; then
    log "push failed/timed out"; exit 0
fi

# Open the PR and enable native auto-merge. gh resolves the repo from the
# current directory (PROJECT_ROOT — same repo/remote as the worktree), and the
# head branch $BR is already on origin.
PR_URL="$(_bounded 120 "$GH" pr create --base "$DEFAULT" --head "$BR" \
    --title "chore: auto-upgrade claude-kit" \
    --body "Automated kit upgrade (INF-155). Only \`.claude/\` changed — the upgrade-kit guardrail refuses anything else. Set to auto-merge." 2>>"$LOG")"
log "opened PR: ${PR_URL:-<none>}"
_bounded 120 "$GH" pr merge --auto --merge "$BR" >>"$LOG" 2>&1 \
    && log "auto-merge enabled" \
    || log "could not enable auto-merge (repo may require review — merges once mergeable, or run /upgrade-kit)"
exit 0
