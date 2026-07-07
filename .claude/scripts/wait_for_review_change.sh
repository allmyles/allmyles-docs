#!/usr/bin/env bash
# Watch a PR's CodeRabbit review state in the background and emit one
# stdout line per state change. Designed to be invoked from the
# /develop skill (Step 9b Phase 1) via Bash(run_in_background=true)
# and observed via Monitor — replaces the foreground `gh run watch`
# pattern that parked the Claude session inside a single Bash tool call.
#
# See .claude/skills/develop/SKILL.md → "Helper: wait_for_review_change"
# for the rationale and invocation pattern.
#
# Args: PR_NUMBER LAST_COMMIT_TS [TIMEOUT_SECONDS=3600]
# Exit: 0 with EXIT_REASON=APPROVED|CHANGES_REQUESTED on actionable state,
#       1 with EXIT_REASON=TIMEOUT after the hard deadline.

set -u

if [ "$#" -lt 2 ]; then
  echo "usage: $0 PR_NUMBER LAST_COMMIT_TS [TIMEOUT_SECONDS=3600]" >&2
  exit 2
fi

PR_NUMBER="$1"
LAST_COMMIT_TS="$2"
TIMEOUT_SECONDS="${3:-3600}"
LOG="/tmp/wait-for-review-${PR_NUMBER}.log"
: > "$LOG"

# Fixed polling interval. Per DASH-1915 AC, this MUST stay <= 120 s
# so a CodeRabbit state change surfaces within at most two minutes.
# Do NOT introduce backoff here — a backed-off watcher caused the
# DASH-1897 round-2 regression where state changes lagged the push by
# multiple minutes.
POLL_INTERVAL_SECONDS=30

emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }

# `gh` returns commit timestamps in UTC ("Z"-suffixed); git's --format=%cI
# uses the committer's local TZ. Lexicographic compare on mixed formats
# can return wrong answers (e.g., "2026-04-28T05:45:12Z" lex-compares as
# LESS than "2026-04-28T07:36:37+02:00" even though chronologically it
# is GREATER). Convert both to epoch seconds via Python's fromisoformat,
# which understands both forms, before comparing.
ts_to_epoch() {
  python3 -c "import datetime,sys; t=sys.argv[1].strip(); print(int(datetime.datetime.fromisoformat(t.replace('Z','+00:00')).timestamp()) if t else 0)" "$1" 2>/dev/null || echo 0
}

OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$OWNER_REPO" ]; then
  warn "gh repo view returned empty nameWithOwner — not in a GitHub repo, or gh CLI unauthenticated"
  emit "EXIT_REASON=ERROR_GH_REPO"
  exit 2
fi

LAST_COMMIT_EPOCH=$(ts_to_epoch "$LAST_COMMIT_TS")

PREV_STATE=""
PREV_SHA=""
WARNED_ZERO_EPOCH=0
DEADLINE=$((SECONDS + TIMEOUT_SECONDS))

while [ $SECONDS -lt $DEADLINE ]; do
  STATE_LINE=$(gh api "repos/${OWNER_REPO}/pulls/${PR_NUMBER}/reviews" \
    --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | last
          | "\(.state // "NONE")|\(.submitted_at // "")"' 2>>"$LOG" || { warn "gh api reviews failed (PR $PR_NUMBER) — using NONE fallback"; echo "NONE|"; })
  STATE=${STATE_LINE%%|*}
  SUBMITTED_AT=${STATE_LINE#*|}
  SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>>"$LOG" || { warn "gh pr view failed (PR $PR_NUMBER) — using empty SHA fallback"; echo ""; })

  if [ "$STATE" != "$PREV_STATE" ] || [ "$SHA" != "$PREV_SHA" ]; then
    emit "STATE=$STATE SUBMITTED_AT=$SUBMITTED_AT SHA=${SHA:0:8} TS=$(date -u +%FT%TZ)"
    PREV_STATE=$STATE
    PREV_SHA=$SHA
  fi

  case "$STATE" in
    APPROVED|CHANGES_REQUESTED)
      # Compare epochs to handle mixed TZ formats correctly. The
      # watcher MUST NOT exit on a stale review (one whose
      # submitted_at predates the latest push). DASH-1897 round 2 hit
      # exactly this: a parse failure on the local-TZ commit timestamp
      # silently set LAST_COMMIT_EPOCH=0, the watcher took the "exit
      # immediately" branch, and reported the round-1 review as the
      # round-2 verdict. Per DASH-1915 we no longer have an
      # exit-immediately path — if the timestamp can't be parsed we
      # warn once and keep polling; the hard timeout still bounds the
      # wait.
      if [ "$LAST_COMMIT_EPOCH" -eq 0 ]; then
        if [ "$WARNED_ZERO_EPOCH" = "0" ]; then
          warn "LAST_COMMIT_EPOCH=0 — could not parse '$LAST_COMMIT_TS'; will keep polling and rely on the hard timeout instead of exiting on the first observed review"
          WARNED_ZERO_EPOCH=1
        fi
      else
        SUBMITTED_EPOCH=$(ts_to_epoch "$SUBMITTED_AT")
        if [ "$SUBMITTED_EPOCH" -gt "$LAST_COMMIT_EPOCH" ]; then
          emit "EXIT_REASON=$STATE"
          exit 0
        fi
      fi
      ;;
  esac

  sleep "$POLL_INTERVAL_SECONDS"
done

emit "EXIT_REASON=TIMEOUT"
exit 1
