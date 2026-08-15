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
#   1b. Run cr-thread-audit.sh (INF-280) and REFUSE to continue the round
#      while any CodeRabbit thread is unresolved — exit 3 with the listing
#      instead of exec'ing the watcher. Everything auto-resolve did not
#      close is a finding nobody disposed of, and reporting the round
#      complete over the top of it is the failure this gate exists to stop
#      (mileometer-frontend PR #263 / MYST-67: 2 unresolved threads survived
#      five reported-complete rounds). Override: ALLOW_UNRESOLVED_THREADS=1.
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
# Exit:   3 — ROUND_INCOMPLETE: unresolved CodeRabbit threads remain; the
#             watcher was NOT launched (INF-280).
#         otherwise inherits wait_for_review_change.sh's exit code (0/1/2
#         per that script's contract).

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
  # INF-260: leftover-findings.log lives in the per-repo scratch gates dir
  # (outside the repo). Resolve via the sibling helper; fall back to the legacy
  # repo-relative .gates/ ONLY when the resolver is unavailable or produces no
  # path — never let an empty resolution build a root-relative `/gates/...`.
  _CR_SCRATCH=""
  [ -f "$SCRIPT_DIR/kit-scratch-dir.sh" ] && _CR_SCRATCH="$(bash "$SCRIPT_DIR/kit-scratch-dir.sh" 2>/dev/null)"
  if [ -n "$_CR_SCRATCH" ]; then
    LEFTOVER="${_CR_SCRATCH%/}/gates/leftover-findings.log"
  else
    LEFTOVER=".gates/leftover-findings.log"   # repo-relative fallback (never root)
  fi
  ( umask 077; mkdir -p "$(dirname "$LEFTOVER")" ) 2>/dev/null || mkdir -p "$(dirname "$LEFTOVER")"
  printf '%s\n' "AUTO_RESOLVE_FAILED pr=${PR_NUMBER} sha=${PUSHED_SHA:0:8} reason=${EXIT_REASON_VALUE:-NO_LOG} log=${AUTO_RESOLVE_LOG} ts=$(date -u +%FT%TZ)" >> "$LEFTOVER"
  emit "[WARN] auto_resolve_addressed_threads.sh emitted EXIT_REASON=${EXIT_REASON_VALUE:-<missing>} (status=$AUTO_RESOLVE_STATUS) — appended to $LEFTOVER and continuing to watcher per the v3.1.0 leftover-findings flow."
fi

# 1b. Thread-level audit (INF-280). auto-resolve above closes the threads whose
#     fix is demonstrably in the just-pushed diff; whatever is STILL unresolved
#     is, by definition, a finding nobody has disposed of. Before this gate the
#     script went straight to the watcher, so a round could be reported complete
#     with open findings — mileometer-frontend PR #263 (MYST-67) carried two
#     unresolved threads through five reported-complete rounds, one of the later
#     ones a MAJOR correctness bug, and the operator found them, not the run.
#
#     The audit produces a COUNT the agent did not choose. When it is non-zero
#     the round does not continue: no watcher, exit 3, listing on stdout. The
#     agent must classify each surfaced thread (FIX / DEFER-WITH-TICKET /
#     REJECT-WITH-RATIONALE) and re-run. Deliberate override:
#     ALLOW_UNRESOLVED_THREADS=1, logged — mirrors ALLOW_STAGING_MERGE and
#     ALLOW_UNVERIFIED_GROUND.
#
#     Infrastructure failure (exit 2) is NOT a verdict: it means the audit could
#     not look, so it must not read as clean and must not block either. Log and
#     continue to the watcher, exactly as the auto-resolve soft-fail does.
# Resolve the gates dir once — the audited count is persisted there (see
# below) so the skill can read it AFTER the background task completes rather
# than racing the /tmp log (CR round 1.1, Major).
_cr_gates_dir() {
  local scratch=""
  [ -f "$SCRIPT_DIR/kit-scratch-dir.sh" ] && scratch="$(bash "$SCRIPT_DIR/kit-scratch-dir.sh" 2>/dev/null)"
  if [ -n "$scratch" ]; then printf '%s/gates' "${scratch%/}"; else printf '.gates'; fi
}
GATES_DIR="$(_cr_gates_dir)"
AUDIT_COUNT_FILE="${GATES_DIR}/cr-thread-audit-count"

AUDIT_UNRESOLVED=""
if [ -x "$SCRIPT_DIR/cr-thread-audit.sh" ]; then
  AUDIT_OUT=$("$SCRIPT_DIR/cr-thread-audit.sh" "$PR_NUMBER" 2>&1)
  AUDIT_STATUS=$?
  printf '%s\n' "$AUDIT_OUT" >> "$LOG"
  AUDIT_UNRESOLVED=$(printf '%s\n' "$AUDIT_OUT" | grep -E '^UNRESOLVED=' | tail -1 | cut -d= -f2)

  case "$AUDIT_STATUS" in
    1)
      emit "THREAD_AUDIT unresolved=${AUDIT_UNRESOLVED:-?} — round is NOT complete."
      printf '%s\n' "$AUDIT_OUT" | grep -E '^  - ' | tee -a "$LOG"
      if [ "${ALLOW_UNRESOLVED_THREADS:-}" = "1" ]; then
        emit "[WARN] ALLOW_UNRESOLVED_THREADS=1 — proceeding to the watcher with ${AUDIT_UNRESOLVED} unresolved thread(s). This override is logged; the completion report still carries the count."
      else
        ( umask 077; mkdir -p "$GATES_DIR" ) 2>/dev/null || mkdir -p "$GATES_DIR"
        printf 'unresolved=%s pr=%s sha=%s ts=%s\n' \
          "$AUDIT_UNRESOLVED" "$PR_NUMBER" "${PUSHED_SHA:0:8}" "$(date -u +%FT%TZ)" \
          > "$AUDIT_COUNT_FILE" 2>/dev/null || true
        emit "ROUND_INCOMPLETE pr=${PR_NUMBER} unresolved=${AUDIT_UNRESOLVED} ts=$(date -u +%FT%TZ)"
        emit "Classify each thread above (FIX / DEFER-WITH-TICKET / REJECT-WITH-RATIONALE) per Step 9b, then re-run. Override: ALLOW_UNRESOLVED_THREADS=1."
        emit "EXIT_REASON=ROUND_INCOMPLETE"
        exit 3
      fi
      ;;
    0)
      emit "THREAD_AUDIT unresolved=0 — every CodeRabbit thread on this PR is resolved."
      ;;
    *)
      emit "[WARN] cr-thread-audit.sh exited ${AUDIT_STATUS} (infrastructure failure, not a verdict) — the round's thread state is UNVERIFIED. Continuing to the watcher; the completion report reports unresolved=unknown."
      AUDIT_UNRESOLVED="unknown"
      ;;
  esac
else
  emit "[WARN] cr-thread-audit.sh not found next to this script — thread state UNVERIFIED for this round (INF-280)."
  AUDIT_UNRESOLVED="unknown"
fi

# 2. Fetch the commit timestamp. Soft-fail to "now" if gh is offline —
#    the watcher's strict-greater-than gate will still work because the
#    watcher captures its own SUBMITTED_EPOCH per review.
COMMIT_TS=$(gh api "repos/$(gh repo view --json nameWithOwner --jq '.nameWithOwner')/commits/${PUSHED_SHA}" --jq '.commit.committer.date' 2>/dev/null)
if [ -z "$COMMIT_TS" ]; then
  COMMIT_TS=$(date -u +%FT%TZ)
  emit "[WARN] gh api commit-timestamp lookup failed — falling back to now ($COMMIT_TS) as LAST_COMMIT_TS gate."
fi

# Persist the audited count BEFORE exec'ing the watcher. The exec replaces this
# process, and the agent reads the count only after the background task reports
# completion — so the value must already be on disk in a stable location. The
# /tmp audit log is written by the audit itself and is fine for diagnostics, but
# reading it right after a run_in_background launch races the launch and yields
# nothing, which would report `unresolved=unknown` after a perfectly good audit.
( umask 077; mkdir -p "$GATES_DIR" ) 2>/dev/null || mkdir -p "$GATES_DIR"
printf 'unresolved=%s pr=%s sha=%s ts=%s\n' \
  "${AUDIT_UNRESOLVED:-unknown}" "$PR_NUMBER" "${PUSHED_SHA:0:8}" "$(date -u +%FT%TZ)" \
  > "$AUDIT_COUNT_FILE" 2>/dev/null || emit "[WARN] could not persist audited count to $AUDIT_COUNT_FILE"

emit "WATCHER_START pr=${PR_NUMBER} last_commit_ts=${COMMIT_TS} timeout=${TIMEOUT_SECONDS} unresolved=${AUDIT_UNRESOLVED:-unknown}"

# 3. exec into the watcher so the agent sees one process and one
#    background-task notification, not two.
exec "$SCRIPT_DIR/wait_for_review_change.sh" "$PR_NUMBER" "$COMMIT_TS" "$TIMEOUT_SECONDS"
