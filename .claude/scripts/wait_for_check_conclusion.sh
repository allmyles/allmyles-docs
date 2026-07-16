#!/usr/bin/env bash
# Watch a named GitHub check-run on a PR's head SHA in the background
# and emit one stdout line per status/conclusion change. Designed to be
# invoked from the /develop skill (Step 9b Phase 2) via
# Bash(run_in_background=true) and observed via Monitor.
#
# See .claude/skills/develop/SKILL.md → "Helper: wait_for_check_conclusion"
# for rationale and invocation pattern.
#
# Args: PR_NUMBER CHECK_NAME [TIMEOUT_SECONDS=1800]
# Exit: 0 with EXIT_REASON=<conclusion> on ANY terminal conclusion
#       (success | failure | cancelled | timed_out | action_required |
#       stale — INF-187: the non-success/failure terminals previously
#       polled until the full TIMEOUT even though the check would never
#       conclude differently),
#       1 with EXIT_REASON=TIMEOUT after the hard deadline.

set -u

if [ "$#" -lt 2 ]; then
  echo "usage: $0 PR_NUMBER CHECK_NAME [TIMEOUT_SECONDS=1800]" >&2
  exit 2
fi

PR_NUMBER="$1"
CHECK_NAME="$2"
TIMEOUT_SECONDS="${3:-1800}"
LOG="/tmp/wait-for-check-${PR_NUMBER}.log"
: > "$LOG"

# Fixed polling interval. Per DASH-1915 AC, this MUST stay <= 120 s
# so a check-run conclusion surfaces within at most two minutes.
POLL_INTERVAL_SECONDS=30

emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }

OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$OWNER_REPO" ]; then
  warn "gh repo view returned empty nameWithOwner — not in a GitHub repo, or gh CLI unauthenticated"
  emit "EXIT_REASON=ERROR_GH_REPO"
  exit 2
fi

PREV_STATUS=""
PREV_CONCLUSION=""
DEADLINE=$((SECONDS + TIMEOUT_SECONDS))

while [ $SECONDS -lt $DEADLINE ]; do
  HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>>"$LOG" || { warn "gh pr view failed (PR $PR_NUMBER)"; echo ""; })
  if [ -z "$HEAD_SHA" ]; then
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi

  # DASH-2173: query the statusCheckRollup union (CheckRun + StatusContext)
  # instead of the check-runs-only REST endpoint. Legacy commit-status
  # aggregates like `feature-pipeline-passed` only surface via StatusContext;
  # the prior `gh api .../check-runs` call missed them and timed out.
  ROLLUP_JSON=$(gh pr view "$PR_NUMBER" --json statusCheckRollup 2>>"$LOG" || { warn "gh pr view statusCheckRollup failed (PR $PR_NUMBER) — using empty fallback"; echo '{"statusCheckRollup":[]}'; })
  ROW=$(printf '%s' "$ROLLUP_JSON" | jq -r --arg n "$CHECK_NAME" '
    [(.statusCheckRollup // [])[]
     | select(
         (.__typename == "CheckRun"
            and .name == $n
            and ((.conclusion // "") | ascii_downcase) != "skipped")
         or (.__typename == "StatusContext" and .context == $n)
       )]
    | last
    | if . == null then
        "none|"
      elif .__typename == "CheckRun" then
        "\(((.status // "none") | ascii_downcase))|\(((.conclusion // "") | ascii_downcase))"
      else
        (.state // "PENDING") as $s
        | if   $s == "SUCCESS" then "completed|success"
          elif $s == "FAILURE" or $s == "ERROR" then "completed|failure"
          else "in_progress|"
          end
      end
  ' 2>>"$LOG" || { warn "jq filter failed (PR $PR_NUMBER, SHA ${HEAD_SHA:0:8}) — using none fallback"; echo "none|"; })
  STATUS=${ROW%%|*}
  CONCLUSION=${ROW#*|}

  if [ "$STATUS" != "$PREV_STATUS" ] || [ "$CONCLUSION" != "$PREV_CONCLUSION" ]; then
    emit "CHECK=$CHECK_NAME STATUS=$STATUS CONCLUSION=$CONCLUSION SHA=${HEAD_SHA:0:8} TS=$(date -u +%FT%TZ)"
    PREV_STATUS=$STATUS
    PREV_CONCLUSION=$CONCLUSION
  fi

  # INF-187: every terminal conclusion exits immediately with its actual
  # value. `cancelled`/`timed_out`/`action_required`/`stale` previously
  # fell through and polled until the 30-min TIMEOUT — the check-run was
  # already concluded and could never flip to success/failure. Downstream
  # (SKILL.md Step 9b item 7b) routes any non-success/failure token into
  # the leftover-findings degrade path, so new values are safe to emit.
  case "$CONCLUSION" in
    success|failure|cancelled|timed_out|action_required|stale)
      emit "EXIT_REASON=$CONCLUSION"
      exit 0
      ;;
  esac

  sleep "$POLL_INTERVAL_SECONDS"
done

emit "EXIT_REASON=TIMEOUT"
exit 1
