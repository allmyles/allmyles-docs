#!/usr/bin/env bash
# Per-round continuation helper for /develop Step 9b.
#
# Replaces the manual three-step orchestration the agent previously
# performed between every CodeRabbit round (auto-resolve, fetch the new
# HEAD's commit timestamp, relaunch wait_for_review_change.sh) with a
# single invocation. The agent's round-by-round action set is reduced
# to: edit → commit → push → cr_round_continuation.sh (one Bash call).
#
# Sequence:
#   1. Run auto_resolve_addressed_threads.sh PR_NUMBER PUSHED_SHA.
#      Treat any EXIT_REASON other than "OK" as a soft failure: append
#      to .gates/leftover-findings.log and continue. Only a
#      hard exec failure halts the script (the watcher would have
#      nothing useful to watch in that case).
#   2. Fetch PUSHED_SHA's commit timestamp via gh api. The watcher
#      uses it as the strict-greater-than gate for "new review"
#      detection.
#   3. exec into wait_for_review_change.sh with the same PR_NUMBER and
#      the just-fetched timestamp. The exec means this script's PID
#      becomes the watcher's PID — agents launching this in the
#      background see one process, not a parent + child.
#
# Args: PR_NUMBER PUSHED_SHA [TIMEOUT_SECONDS=3600]
# Output: tee'd to /tmp/cr-round-<PR>.log, then watcher's own log
#         (/tmp/wait-for-review-<PR>.log).
# Exit:   inherits wait_for_review_change.sh's exit code (0/1/2 per
#         that script's contract).

set -u

if [ "$#" -lt 2 ]; then
  echo "usage: $0 PR_NUMBER PUSHED_SHA [TIMEOUT_SECONDS=3600]" >&2
  exit 2
fi

PR_NUMBER="$1"
PUSHED_SHA="$2"
TIMEOUT_SECONDS="${3:-3600}"
LOG="/tmp/cr-round-${PR_NUMBER}.log"
: > "$LOG"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

emit() { printf '%s\n' "$*" | tee -a "$LOG"; }

emit "ROUND_START pr=${PR_NUMBER} sha=${PUSHED_SHA:0:8} ts=$(date -u +%FT%TZ)"

# 1. Auto-resolve threads addressed by the just-pushed commit.
"$SCRIPT_DIR/auto_resolve_addressed_threads.sh" "$PR_NUMBER" "$PUSHED_SHA" >> "$LOG" 2>&1
AUTO_RESOLVE_STATUS=$?

AUTO_RESOLVE_LOG="/tmp/auto-resolve-${PR_NUMBER}.log"
EXIT_REASON_LINE=$(grep -E '^EXIT_REASON=' "$AUTO_RESOLVE_LOG" 2>/dev/null | tail -1)
EXIT_REASON_VALUE=${EXIT_REASON_LINE#EXIT_REASON=}

if [ "$EXIT_REASON_VALUE" != "OK" ]; then
  # Soft-fail per DASH-1916 goal C: log + continue rather than STOP.
  # The leftover-findings log is the canonical surface — Step 12's
  # completion report grep's it on every run.
  LEFTOVER=".gates/leftover-findings.log"
  mkdir -p "$(dirname "$LEFTOVER")"
  printf '%s\n' "AUTO_RESOLVE_FAILED pr=${PR_NUMBER} sha=${PUSHED_SHA:0:8} reason=${EXIT_REASON_VALUE:-NO_LOG} log=${AUTO_RESOLVE_LOG} ts=$(date -u +%FT%TZ)" >> "$LEFTOVER"
  emit "[WARN] auto_resolve_addressed_threads.sh emitted EXIT_REASON=${EXIT_REASON_VALUE:-<missing>} (status=$AUTO_RESOLVE_STATUS) — appended to $LEFTOVER and continuing to watcher per the v3.1.0 leftover-findings flow."
fi

# 2. Fetch the commit timestamp. Soft-fail to "now" if gh is offline —
#    the watcher's strict-greater-than gate will still work because the
#    watcher captures its own SUBMITTED_EPOCH per review.
COMMIT_TS=$(gh api "repos/$(gh repo view --json nameWithOwner --jq '.nameWithOwner')/commits/${PUSHED_SHA}" --jq '.commit.committer.date' 2>/dev/null)
if [ -z "$COMMIT_TS" ]; then
  COMMIT_TS=$(date -u +%FT%TZ)
  emit "[WARN] gh api commit-timestamp lookup failed — falling back to now ($COMMIT_TS) as LAST_COMMIT_TS gate."
fi

emit "WATCHER_START pr=${PR_NUMBER} last_commit_ts=${COMMIT_TS} timeout=${TIMEOUT_SECONDS}"

# 3. exec into the watcher so the agent sees one process and one
#    background-task notification, not two.
exec "$SCRIPT_DIR/wait_for_review_change.sh" "$PR_NUMBER" "$COMMIT_TS" "$TIMEOUT_SECONDS"
