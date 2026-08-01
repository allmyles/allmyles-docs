#!/usr/bin/env bash
# kit-detect-shape.sh (INF-261) — shared repo-shape detection, SOURCED by both
# adopt-kit.sh (INF-258 onboarding) and kit-config.sh (INF-261 config cache) so
# the detection logic lives in exactly ONE place (no divergent copies).
#
# Defines _compute_shape() (sets the SHAPE / DEFAULT_BRANCH / PR_BASE_BRANCH /
# MIGRATION_TOOL / REQUIRED_CHECK globals from the CURRENT working directory —
# the caller cd's to the repo root first) and _print_shape() (dumps them as
# KEY=VALUE lines). This file is meant to be SOURCED, not executed, so it does
# NOT call _compute_shape itself.
#
# SECURITY (INF-258 lesson): git-derived values (branch names) are assigned
# DIRECTLY, never eval'd — a branch name may legally contain shell
# metacharacters, and `eval` on it would be a command-injection vector.

# Bound network calls so a slow/unreachable remote can't hang config-load
# (kit-config.sh runs _compute_shape on every /develop config-load). Prefer GNU
# `timeout` (Linux/CI), then `gtimeout` (macOS + coreutils). When NEITHER exists,
# fall back to a PORTABLE shell watchdog (CR round 1.2 — the plain `"$@"` fallback
# could still hang) that runs the command in the background and SIGTERMs it if it
# outlives the budget. The command inherits stdout (fd 1), so it still works
# inside `$(_kit_bounded …)`; on timeout the command is killed → empty output →
# the caller treats it as "no remote staging".
_kit_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?
    fi
    "$@" &
    local cmd_pid=$!
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
    local killer_pid=$!
    wait "$cmd_pid" 2>/dev/null; local rc=$?
    kill -TERM "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null
    return "$rc"
}

# shellcheck disable=SC2034  # these globals are consumed by the sourcing script
_compute_shape() {
    DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    if [ -z "$DEFAULT_BRANCH" ]; then
        DEFAULT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
    fi
    [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="master"

    if git show-ref --verify --quiet refs/heads/staging 2>/dev/null \
       || git show-ref --verify --quiet refs/remotes/origin/staging 2>/dev/null \
       || [ -n "$(_kit_bounded 5 git ls-remote --heads origin staging 2>/dev/null)" ]; then
        SHAPE="staging-master"
        PR_BASE_BRANCH="staging"
    else
        SHAPE="single-branch"
        PR_BASE_BRANCH="$DEFAULT_BRANCH"
    fi

    if [ -f "manage.py" ]; then
        MIGRATION_TOOL="manage.py"
    else
        MIGRATION_TOOL="null"
    fi

    REQUIRED_CHECK="null"
}

_print_shape() {
    printf 'SHAPE=%s\n' "$SHAPE"
    printf 'DEFAULT_BRANCH=%s\n' "$DEFAULT_BRANCH"
    printf 'PR_BASE_BRANCH=%s\n' "$PR_BASE_BRANCH"
    printf 'MIGRATION_TOOL=%s\n' "$MIGRATION_TOOL"
    printf 'REQUIRED_CHECK=%s\n' "$REQUIRED_CHECK"
}
