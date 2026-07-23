#!/usr/bin/env bash
# establish-ground-truth.sh (INF-212) — deterministic repo/branch/ticket
# fact gatherer for the anti-speculation gate.
#
# Motivation: an agent characterized a target repo as "mid-work / possible
# uncommitted WIP" purely from a checked-out branch NAME, when the ticket
# was in fact Closed + merged and the branch a stale pointer. Guidance
# ("verify before claiming") already existed and was still violated — so the
# fix is to move fact-gathering OUT of the model and INTO a script whose
# output is deterministic, and to gate branch-creation on its having run
# (see check-ground-truth-before-branch.sh).
#
# This script gathers facts from commands (zero model discretion), prints a
# GROUND_TRUTH block, and — on clean local-git gathering — writes the gate
# marker .gates/ground-truth-verified stamped with the repo + HEAD SHA + UTC
# timestamp. The agent RELAYS this output; it does not characterize repo
# state from inference.
#
# Fail-closed boundary: the LOCAL git facts (git repo present, status, branch,
# merged-check) are load-bearing — if they can't be gathered the gate is NOT
# written and the script exits non-zero. NETWORK facts (kit master SHA, Jira
# ticket status) are best-effort: their unavailability degrades to an explicit
# "unverified" annotation but does NOT block the gate — a Jira/network outage
# must not wedge every /develop run, and "unverified" is itself honest ground
# truth for the agent to relay (vs. guessing "closed").
#
# Usage: establish-ground-truth.sh <repo-path> [ticket-key]
#   <repo-path>   — target repo working copy (absolute preferred)
#   [ticket-key]  — e.g. INF-212 / MYST-41; when given, the ticket's Jira
#                   status is looked up (best-effort, keychain creds).
#
# Exit codes:
#   0 — ground truth established; .gates/ground-truth-verified written
#   1 — could not gather local git facts (not a git repo / git failure) — no gate
#   2 — usage error
#
# Env (tests): KIT_GT_GH (gh bin), KIT_GT_JIRA_BASE, KIT_GT_KIT_MASTER
#              (inject the kit master SHA, skip network), KIT_GT_TICKET_STATUS
#              (inject ticket status, skip Jira), KIT_GT_STALE_SECONDS.

set -uo pipefail

REPO="${1:-}"
TICKET="${2:-}"
if [ -z "$REPO" ]; then
    echo "usage: establish-ground-truth.sh <repo-path> [ticket-key]" >&2
    exit 2
fi

GH="${KIT_GT_GH:-gh}"
JIRA_BASE="${KIT_GT_JIRA_BASE:-https://allmyles.atlassian.net}"

# ── Resolve to an absolute repo root and confirm it is a git checkout ──
if ! REPO_ABS="$(cd "$REPO" 2>/dev/null && pwd)"; then
    echo "GROUND_TRUTH repo=$REPO status=ERROR reason=path-unreachable" >&2
    echo "❌ ground-truth: '$REPO' is not a reachable directory — cannot gather facts." >&2
    exit 1
fi
if ! git -C "$REPO_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "GROUND_TRUTH repo=$REPO_ABS status=ERROR reason=not-a-git-repo" >&2
    echo "❌ ground-truth: '$REPO_ABS' is not a git repository — cannot gather facts." >&2
    exit 1
fi
REPO_ROOT="$(git -C "$REPO_ABS" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$REPO_ABS"

g() { git -C "$REPO_ROOT" "$@"; }

# ── Local git facts (load-bearing — fail closed on error) ──
HEAD_SHA="$(g rev-parse HEAD 2>/dev/null || echo "")"
if [ -z "$HEAD_SHA" ]; then
    echo "GROUND_TRUTH repo=$REPO_ROOT status=ERROR reason=no-head" >&2
    echo "❌ ground-truth: could not resolve HEAD (empty repo?) — no gate written." >&2
    exit 1
fi
# CR round 1.1: fail closed on a branch-resolve error rather than stamping
# a gate with CUR_BRANCH="?" (a false local fact).
if ! CUR_BRANCH="$(g rev-parse --abbrev-ref HEAD 2>/dev/null)" || [ -z "$CUR_BRANCH" ]; then
    echo "GROUND_TRUTH repo=$REPO_ROOT status=ERROR reason=no-branch" >&2
    echo "❌ ground-truth: could not resolve current branch — no gate written." >&2
    exit 1
fi
DEFAULT_BRANCH="$(g config --get init.defaultBranch 2>/dev/null || echo master)"
# Prefer origin/HEAD's target when available.
ORIGIN_HEAD="$(g symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##')"
[ -n "$ORIGIN_HEAD" ] && DEFAULT_BRANCH="$ORIGIN_HEAD"

# status --porcelain MUST succeed (it's the WIP truth). A failure here is a
# real git problem → fail closed.
if ! STATUS_OUT="$(g status --porcelain 2>/dev/null)"; then
    echo "GROUND_TRUTH repo=$REPO_ROOT status=ERROR reason=git-status-failed" >&2
    echo "❌ ground-truth: 'git status' failed — no gate written." >&2
    exit 1
fi
if [ -z "$STATUS_OUT" ]; then
    TREE="clean"
    DIRTY_COUNT=0
else
    TREE="dirty"
    DIRTY_COUNT="$(printf '%s\n' "$STATUS_OUT" | grep -c . )"
fi

# Is the current HEAD already contained in a remote default branch (i.e. this
# branch's work is merged)? A stale feature-branch pointer whose tip is on
# origin/<default> is NOT in-flight work — the exact distinction the
# motivating slip missed. CR round 1.1: distinguish "definitely not merged"
# from "cannot tell" — when origin/<default> is absent locally or the
# contains-check errors, emit an explicit `unverified` rather than a false
# `merged=no` (fail-honest, not fail-wrong).
MERGED="no"
if ! g rev-parse --verify --quiet "origin/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    MERGED="unverified(no-origin-${DEFAULT_BRANCH})"
elif ! CONTAINS_OUT="$(g branch -r --contains HEAD 2>/dev/null)"; then
    MERGED="unverified(contains-failed)"
elif printf '%s\n' "$CONTAINS_OUT" | grep -qE "origin/(${DEFAULT_BRANCH}|master|main)\b"; then
    MERGED="yes"
fi

# Ahead/behind origin/<default> (best-effort; needs the remote ref locally).
AHEAD="?"; BEHIND="?"
if g rev-parse --verify --quiet "origin/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    LR="$(g rev-list --left-right --count "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")"
    if [ -n "$LR" ]; then
        BEHIND="$(printf '%s' "$LR" | awk '{print $1}')"
        AHEAD="$(printf '%s' "$LR" | awk '{print $2}')"
    fi
fi

# ── Kit currency (best-effort annotation — never fail-close) ──
PIN_SHA="$(jq -r '.kitSha // ""' "$REPO_ROOT/.claude/claude-kit-pin.json" 2>/dev/null || echo "")"
KIT_MASTER="${KIT_GT_KIT_MASTER:-}"
if [ -z "$KIT_MASTER" ] && command -v "$GH" >/dev/null 2>&1; then
    KIT_MASTER="$("$GH" api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null || echo "")"
fi
if [ -z "$PIN_SHA" ]; then
    KIT_CURRENCY="no-pin"
elif [ -z "$KIT_MASTER" ]; then
    KIT_CURRENCY="unverified(kit-master-unreachable)"
elif [ "$PIN_SHA" = "$KIT_MASTER" ]; then
    KIT_CURRENCY="current"
else
    KIT_CURRENCY="behind(pin=${PIN_SHA:0:8},master=${KIT_MASTER:0:8})"
fi

# ── Ticket status (best-effort annotation — never fail-close) ──
TICKET_STATUS="n/a"
if [ -n "$TICKET" ]; then
    if [ -n "${KIT_GT_TICKET_STATUS:-}" ]; then
        TICKET_STATUS="$KIT_GT_TICKET_STATUS"
    else
        JE="$(security find-generic-password -s JIRA_EMAIL -w 2>/dev/null || echo "")"
        JT="$(security find-generic-password -s JIRA_API_TOKEN -w 2>/dev/null || echo "")"
        if [ -n "$JE" ] && [ -n "$JT" ]; then
            # CR round 1.1: bound the best-effort Jira fetch so an
            # unreachable endpoint degrades to `unverified` instead of
            # stalling the whole gate step.
            TICKET_STATUS="$(curl -sS --connect-timeout 5 --max-time 15 -u "$JE:$JT" "${JIRA_BASE}/rest/api/3/issue/${TICKET}?fields=status" 2>/dev/null \
                | jq -r '.fields.status.name // "unverified(lookup-failed)"' 2>/dev/null || echo "unverified(lookup-failed)")"
            [ -z "$TICKET_STATUS" ] && TICKET_STATUS="unverified(lookup-failed)"
        else
            TICKET_STATUS="unverified(no-jira-creds)"
        fi
    fi
fi

# ── Emit the GROUND_TRUTH block (machine line + human lines) ──
echo "GROUND_TRUTH repo=$REPO_ROOT branch=$CUR_BRANCH head=${HEAD_SHA:0:8} tree=$TREE dirty=$DIRTY_COUNT merged=$MERGED ahead=$AHEAD behind=$BEHIND default=$DEFAULT_BRANCH kit=$KIT_CURRENCY ticket=${TICKET:-none} ticket_status=$TICKET_STATUS"
echo "── ground truth (${REPO_ROOT}):"
echo "   branch: $CUR_BRANCH @ ${HEAD_SHA:0:8}  (default: $DEFAULT_BRANCH)"
echo "   working tree: $TREE${DIRTY_COUNT:+ (${DIRTY_COUNT} path(s))}"
echo "   branch merged into origin/$DEFAULT_BRANCH: $MERGED"
echo "   vs origin/$DEFAULT_BRANCH: ahead $AHEAD, behind $BEHIND"
echo "   kit currency: $KIT_CURRENCY"
[ -n "$TICKET" ] && echo "   ticket $TICKET: $TICKET_STATUS"

# ── Write the gate marker (local facts gathered cleanly to reach here) ──
GATES_DIR="$REPO_ROOT/.gates"
if ! mkdir -p "$GATES_DIR" 2>/dev/null; then
    echo "⚠️ ground-truth: could not create ${GATES_DIR} — facts printed above but gate NOT written." >&2
    exit 1
fi
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'repo=%s sha=%s branch=%s ts=%s\n' "$REPO_ROOT" "${HEAD_SHA:0:8}" "$CUR_BRANCH" "$NOW_UTC" \
    > "$GATES_DIR/ground-truth-verified"
echo "✅ ground truth established — .gates/ground-truth-verified written (repo=$REPO_ROOT sha=${HEAD_SHA:0:8})."
exit 0
