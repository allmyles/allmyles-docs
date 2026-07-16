#!/usr/bin/env bash
# Add a Jira issue to the latest active sprint on a board, with retries.
# Designed to be invoked from `jira-policies/SKILL.md` § "Atomic Create-
# Issue Procedure" immediately after `mcp__claude_ai_Atlassian_Rovo__createJiraIssue`.
#
# This script exists because the sprint-add step is the second-most-
# forgotten lifecycle action after assignment (DASH-1990, DASH-1981,
# DASH-1982 all landed in backlog). Binding it to a one-call helper
# removes "remember to paste the curl" as a failure mode — the skill now
# says `bash .claude/scripts/jira_sprint_add.sh DASH-XXXX` which the
# agent's allowlist matches as a single shape.
#
# Args:
#   ISSUE_KEY                 — e.g., DASH-1234 (required)
#   [BOARD_ID=42]             — Jira Agile board id (shared by all Allmyles
#                               projects — single "Detailed Overview" board)
#   [PREFIX=<derived>]        — sprint-name prefix to filter on. When omitted,
#                               derived from ISSUE_KEY's project prefix via the
#                               lookup table below. Pass explicitly only when
#                               you need to override the derivation (rare —
#                               see INF-127 for the bug this default replaces).
#   [TIMEOUT_SECONDS=60]      — total cap across retries (default 60s)
#
# Project key prefix → sprint name prefix lookup (INF-127, expanded INF-134):
#   DASH (Mileometer)        → MEO
#   APY  (Allmylespy)        → APY
#   WHIT (WhitelabelIT)      → WHIT
#   INF  (Infrastructure)    → INF (added INF-134; INF project tickets
#                              currently land in backlog because board 42
#                              has no active INF sprint — but the helper
#                              now reports NO_ACTIVE_SPRINT instead of
#                              UNKNOWN_PREFIX, which is the right semantic
#                              and lets routing work automatically once an
#                              INF sprint is created)
#   MYST (Mylestore)         → MYST (added INF-140; MYST sprints are named
#                              MYST… e.g. MYST202627)
#   Other                    → UNKNOWN_PREFIX (no sprint match; ticket stays
#                              in backlog with a loud warning rather than
#                              silently routing to MEO — the pre-INF-127
#                              failure mode that this ticket exists to fix)
#
# Adding a new project: append a case branch in the `case "$PROJECT_KEY" in`
# block below. The script's behavior for already-mapped projects is
# unchanged.
#
# Exit:
#   0 with EXIT_REASON=OK                — issue is in the sprint, AND the
#                                          sprint's name starts with the
#                                          prefix expected for ISSUE_KEY's
#                                          project (see UNEXPECTED_SPRINT
#                                          below for what catches a mismatch)
#   1 with EXIT_REASON=NO_ACTIVE_SPRINT  — no active <PREFIX> sprint
#                                          on the board; issue stays in
#                                          backlog (not a hard failure —
#                                          callers warn but proceed)
#   1 with EXIT_REASON=UNKNOWN_PREFIX    — ISSUE_KEY's project key has no
#                                          mapping in the lookup above AND
#                                          no explicit PREFIX was passed.
#                                          The ticket stays in backlog;
#                                          add a lookup entry to enable
#                                          sprint routing for that project.
#   2 with EXIT_REASON=API_ERROR         — sprint-add API failed after
#                                          all retries
#   2 with EXIT_REASON=UNEXPECTED_SPRINT — POST returned 204 but the assigned
#                                          sprint's name does NOT start with
#                                          the prefix the script filtered on.
#                                          Should be unreachable given the
#                                          discover_sprint jq filter; emits
#                                          loudly as a safety-net assertion
#                                          rather than the pre-INF-127
#                                          silent-OK on a mis-assigned ticket.
#   1 with EXIT_REASON=TIMEOUT          — DEADLINE expired during sprint
#                                          discovery (Step A) before any
#                                          conclusive result
#   2 with EXIT_REASON=MISSING_ARGS     — no ISSUE_KEY argument
#   2 with EXIT_REASON=ERROR_BAD_KEY    — ISSUE_KEY does not match Jira shape
#   2 with EXIT_REASON=RATE_LIMIT       — HTTP 429 from sprint-add API across
#                                          all retries within the deadline
#   2 with EXIT_REASON=TIMEOUT          — DEADLINE expired during sprint POST
#                                          (Step B) without a conclusive 204
#                                          (and not while rate-limited)
#   3 with EXIT_REASON=ERROR_NO_CREDS    — JIRA_EMAIL or JIRA_API_TOKEN
#                                          unavailable (env or keychain)
#
# Logs: every API call + retry is appended to /tmp/jira-sprint-add-<KEY>.log
# so the audit trail survives the script's exit. The final stdout line
# is always EXIT_REASON=<value>; structured callers parse that.

set -u

if [ "$#" -lt 1 ]; then
  echo "usage: $0 ISSUE_KEY [BOARD_ID=42] [PREFIX=<derived from ISSUE_KEY>] [TIMEOUT_SECONDS=60]" >&2
  echo "EXIT_REASON=MISSING_ARGS"
  exit 2
fi

ISSUE_KEY="$1"
BOARD_ID="${2:-42}"
EXPLICIT_PREFIX="${3:-}"
TIMEOUT_SECONDS="${4:-60}"

# Validate TIMEOUT_SECONDS — used unquoted in arithmetic below; a malformed
# value (e.g., "60s", "-1", "abc") would either set DEADLINE to nonsense
# or trigger `set -u` failures. Clamp to [1, 600] after shape validation;
# silently fall back to default on bad input rather than aborting (the
# caller's intent was clearly "use a timeout"; help them out).
if ! printf '%s' "$TIMEOUT_SECONDS" | grep -qE '^[0-9]+$'; then
  echo "warn: TIMEOUT_SECONDS '${TIMEOUT_SECONDS}' is not a non-negative integer; falling back to 60" >&2
  TIMEOUT_SECONDS=60
fi
[ "$TIMEOUT_SECONDS" -lt 1 ] && TIMEOUT_SECONDS=1
[ "$TIMEOUT_SECONDS" -gt 600 ] && TIMEOUT_SECONDS=600

# Validate ISSUE_KEY shape (Jira key: PROJECT-NUMBER, uppercase alpha + digits).
# This is defense in depth — the agent is the only caller, but rejecting
# malformed input here prevents path traversal in the LOG path and JSON
# injection in the curl payload below if a future caller misuses the helper.
if ! printf '%s' "$ISSUE_KEY" | grep -qE '^[A-Z][A-Z0-9_]*-[0-9]+$'; then
  echo "error: ISSUE_KEY '${ISSUE_KEY}' does not match Jira key shape (e.g., DASH-1234)" >&2
  echo "EXIT_REASON=ERROR_BAD_KEY"
  exit 2
fi

LOG="/tmp/jira-sprint-add-${ISSUE_KEY}.log"
: > "$LOG"

emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }

# ── Project key prefix → sprint name prefix derivation (INF-127) ──────
# Extract PROJECT_KEY from ISSUE_KEY (everything before the first '-').
# Then resolve to a sprint-name prefix via the lookup. If the caller
# passed an explicit PREFIX (3rd positional arg), it overrides the
# lookup — preserves the escape hatch for unusual routing.
#
# Pre-INF-127 behavior: PREFIX defaulted to "MEO" unconditionally, so
# APY-XXXX / WHIT-XXXX / INF-XXXX silently landed in MEO sprints (the
# bug the ticket exists to fix). Post-INF-127: unknown prefixes exit
# loudly with EXIT_REASON=UNKNOWN_PREFIX rather than silent mis-routing.
PROJECT_KEY="${ISSUE_KEY%%-*}"
case "$PROJECT_KEY" in
  DASH) DERIVED_PREFIX="MEO" ;;
  APY)  DERIVED_PREFIX="APY" ;;
  WHIT) DERIVED_PREFIX="WHIT" ;;
  INF)  DERIVED_PREFIX="INF" ;;   # INF-134: Infrastructure project mapping
  MYST) DERIVED_PREFIX="MYST" ;;  # INF-140: Mylestore project mapping
  *)    DERIVED_PREFIX="" ;;
esac

if [ -n "$EXPLICIT_PREFIX" ]; then
  PREFIX="$EXPLICIT_PREFIX"
  emit "PREFIX_RESOLVED prefix=${PREFIX} source=explicit"
elif [ -n "$DERIVED_PREFIX" ]; then
  PREFIX="$DERIVED_PREFIX"
  emit "PREFIX_RESOLVED prefix=${PREFIX} source=derived project_key=${PROJECT_KEY}"
else
  warn "Unknown project key prefix '${PROJECT_KEY}' — no sprint-name prefix mapping. Ticket stays in backlog. Add a case branch in jira_sprint_add.sh's PROJECT_KEY lookup to enable sprint routing for this project."
  emit "EXIT_REASON=UNKNOWN_PREFIX"
  exit 1
fi

# ── Credential resolution ─────────────────────────────────────────────
# Env vars take precedence (CI / explicit overrides). Otherwise fall
# back to macOS Keychain entries (per memory `reference_jira_creds_keychain.md`).
if [ -z "${JIRA_EMAIL:-}" ]; then
  JIRA_EMAIL=$(security find-generic-password -s "JIRA_EMAIL" -w 2>/dev/null || echo "")
fi
if [ -z "${JIRA_API_TOKEN:-}" ]; then
  JIRA_API_TOKEN=$(security find-generic-password -s "JIRA_API_TOKEN" -w 2>/dev/null || echo "")
fi
if [ -z "$JIRA_EMAIL" ] || [ -z "$JIRA_API_TOKEN" ]; then
  warn "JIRA_EMAIL or JIRA_API_TOKEN unavailable (env + keychain both empty)"
  emit "EXIT_REASON=ERROR_NO_CREDS"
  exit 3
fi

DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
BACKOFF=2
ATTEMPT=0

# Per-attempt curl timeout. A single hung request must not consume the
# entire DEADLINE — curl by default has no timeout, so a TCP black hole
# would block forever and the deadline check (which only runs between
# attempts) would never fire. Cap each attempt at 1/4 of the global
# window so at least 4 attempts can fit in the budget; floor at 5s so
# very small TIMEOUT_SECONDS doesn't make every request fail.
PER_ATTEMPT_TIMEOUT=$(( TIMEOUT_SECONDS / 4 ))
[ "$PER_ATTEMPT_TIMEOUT" -lt 5 ] && PER_ATTEMPT_TIMEOUT=5

# Helper: compute the curl --max-time / --connect-timeout for THIS
# attempt as min(PER_ATTEMPT_TIMEOUT, remaining_time). Curl with
# `--max-time 0` waits forever, so floor at 1 to keep the deadline
# enforceable even when remaining_time is sub-second. The caller checks
# remaining_time > 0 before calling this; we just clamp here.
attempt_timeout() {
  local remaining="$1"
  if [ "$remaining" -lt "$PER_ATTEMPT_TIMEOUT" ]; then
    [ "$remaining" -lt 1 ] && echo 1 || echo "$remaining"
  else
    echo "$PER_ATTEMPT_TIMEOUT"
  fi
}

# Helper: cap a sleep so it cannot push past DEADLINE. Same min logic
# as attempt_timeout; floor at 0 because `sleep 0` is a no-op (vs
# `sleep -1` which is invalid on some shells). Returns the capped value.
capped_sleep() {
  local desired="$1" remaining="$2"
  if [ "$remaining" -le 0 ]; then
    echo 0
  elif [ "$desired" -lt "$remaining" ]; then
    echo "$desired"
  else
    echo "$remaining"
  fi
}

# ── Shared response scratch file (INF-187, CWE-377) ───────────────────
# mktemp + trap replaces the predictable PID-based
# "$RESP_FILE" — a pre-created symlink at a
# guessable path could redirect curl's -o write. The trap also retires
# the per-branch rm calls (cleanup happens exactly once, on any exit).
RESP_FILE=$(mktemp -t jira-sprint-add-resp-XXXXXX.json) || {
  warn "mktemp failed for response scratch file"
  emit "EXIT_REASON=API_ERROR"
  exit 2
}
trap 'rm -f "$RESP_FILE"' EXIT

# ── Step A: discover the latest active sprint matching PREFIX ─────────
# The Agile API requires `Accept: application/json` (without it, agile
# endpoints return 401 even with valid creds — REST v3 does not).
#
# INF-187: HTTP-status-aware, matching Step B's retry discipline. A
# non-429 4xx (bad creds, missing board, revoked token) is permanent —
# the previous indiscriminate retry burned the whole deadline window on
# a failure that could never succeed.
discover_sprint() {
  local timeout="$1" http_code
  http_code=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
              --connect-timeout "$timeout" \
              --max-time "$timeout" \
              -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
              -H "Accept: application/json" \
              "https://allmyles.atlassian.net/rest/agile/1.0/board/${BOARD_ID}/sprint?state=active" 2>>"$LOG")
  case "$http_code" in
    2*)
      # Pick the matching sprint with the latest startDate. Fail if none.
      jq -r --arg prefix "$PREFIX" '
        [.values[]
         | select(.name | startswith($prefix))]
        | sort_by(.startDate) | reverse
        | first
        | if . == null then "NONE" else "\(.id)\t\(.name)" end' \
        < "$RESP_FILE" 2>>"$LOG"
      ;;
    429)
      # Rate limit — transient, retry helps.
      cat "$RESP_FILE" >> "$LOG" 2>/dev/null
      return 1
      ;;
    4*)
      # Permanent (auth/permissions/unknown board) — signal the caller
      # to fail fast instead of retrying to the deadline.
      cat "$RESP_FILE" >> "$LOG" 2>/dev/null
      echo "PERMANENT:${http_code}"
      ;;
    *)
      # 5xx / 000 (network) — transient.
      cat "$RESP_FILE" >> "$LOG" 2>/dev/null
      return 1
      ;;
  esac
}

SPRINT_LINE=""
while : ; do
  REMAINING=$(( DEADLINE - $(date +%s) ))
  if [ "$REMAINING" -le 0 ]; then
    warn "sprint discovery exhausted ${TIMEOUT_SECONDS}s window before completing"
    emit "EXIT_REASON=TIMEOUT"
    exit 1
  fi
  ATTEMPT=$((ATTEMPT + 1))
  SPRINT_LINE=$(discover_sprint "$(attempt_timeout "$REMAINING")" || echo "")
  case "$SPRINT_LINE" in
    PERMANENT:*)
      # INF-187: non-429 4xx from the board endpoint — retrying cannot
      # succeed; fail fast with the same EXIT_REASON Step B uses.
      warn "sprint discovery permanent failure http=${SPRINT_LINE#PERMANENT:}"
      emit "EXIT_REASON=API_ERROR"
      exit 1
      ;;
  esac
  if [ -n "$SPRINT_LINE" ] && [ "$SPRINT_LINE" != "NONE" ]; then
    break
  fi
  if [ "$SPRINT_LINE" = "NONE" ]; then
    warn "No active '${PREFIX}' sprint on board ${BOARD_ID}"
    emit "EXIT_REASON=NO_ACTIVE_SPRINT"
    exit 1
  fi
  REMAINING=$(( DEADLINE - $(date +%s) ))
  if [ "$REMAINING" -le 0 ]; then
    warn "sprint discovery exhausted ${TIMEOUT_SECONDS}s window after attempt ${ATTEMPT}"
    emit "EXIT_REASON=TIMEOUT"
    exit 1
  fi
  ACTUAL_SLEEP=$(capped_sleep "$BACKOFF" "$REMAINING")
  warn "sprint discovery attempt ${ATTEMPT} failed; retrying in ${ACTUAL_SLEEP}s (capped from ${BACKOFF}s by remaining ${REMAINING}s)"
  sleep "$ACTUAL_SLEEP"
  BACKOFF=$((BACKOFF * 2))
  [ "$BACKOFF" -gt 16 ] && BACKOFF=16
done

SPRINT_ID=$(echo "$SPRINT_LINE" | cut -f1)
SPRINT_NAME=$(echo "$SPRINT_LINE" | cut -f2)
emit "DISCOVERED sprint_id=${SPRINT_ID} sprint_name=${SPRINT_NAME}"

# ── Step B: POST the issue to the sprint, retrying on transient errors ─
BACKOFF=2
ATTEMPT=0
while : ; do
  REMAINING=$(( DEADLINE - $(date +%s) ))
  if [ "$REMAINING" -le 0 ]; then
    warn "POST loop exhausted ${TIMEOUT_SECONDS}s window before completing"
    if [ "${RATE_LIMITED:-0}" = "1" ]; then
      emit "EXIT_REASON=RATE_LIMIT"
    else
      emit "EXIT_REASON=TIMEOUT"
    fi
    exit 2
  fi
  ATTEMPT=$((ATTEMPT + 1))
  EFFECTIVE_TIMEOUT=$(attempt_timeout "$REMAINING")
  HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
                   --connect-timeout "$EFFECTIVE_TIMEOUT" \
                   --max-time "$EFFECTIVE_TIMEOUT" \
                   -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
                   -X POST \
                   -H "Content-Type: application/json" \
                   -H "Accept: application/json" \
                   "https://allmyles.atlassian.net/rest/agile/1.0/sprint/${SPRINT_ID}/issue" \
                   -d "{\"issues\": [\"${ISSUE_KEY}\"]}" 2>>"$LOG")
  emit "POST attempt=${ATTEMPT} http=${HTTP_CODE} timeout=${EFFECTIVE_TIMEOUT}"
  case "$HTTP_CODE" in
    204)
      # Defense-in-depth (INF-127): verify the assigned sprint's name
      # actually starts with the prefix we filtered on. The
      # discover_sprint jq filter is supposed to guarantee this — but the
      # pre-INF-127 helper emitted EXIT_REASON=OK on every 204 regardless
      # of which sprint actually received the ticket, which masked the
      # silent-MEO-mis-route bug for as long as it took the operator to
      # notice in the Jira UI. This assertion is the audit-line trip-wire
      # so the same class of bug can't return silently.
      case "$SPRINT_NAME" in
        "${PREFIX}"*)
          emit "ASSIGNED ${ISSUE_KEY} -> ${SPRINT_NAME} (${SPRINT_ID})"
          emit "EXIT_REASON=OK"
          exit 0
          ;;
        *)
          warn "POST returned 204 but sprint name '${SPRINT_NAME}' does NOT start with derived prefix '${PREFIX}' — investigate discover_sprint filter (this should be unreachable)"
          emit "ASSIGNED ${ISSUE_KEY} -> ${SPRINT_NAME} (${SPRINT_ID}) — PREFIX MISMATCH"
          emit "EXIT_REASON=UNEXPECTED_SPRINT"
          exit 2
          ;;
      esac
      ;;
    429)
      # Jira rate limit. Distinct from 4xx because retrying DOES help,
      # and distinct from generic transient (5xx/0) because the surface
      # signal "we hit the limit" is itself a useful EXIT_REASON for
      # callers that want to back off across multiple sprint-adds in a
      # batch. Retry with the same exponential backoff as the transient
      # branch, but emit EXIT_REASON=RATE_LIMIT if the deadline expires
      # before a 204.
      cat "$RESP_FILE" >> "$LOG" 2>/dev/null
      RATE_LIMITED=1
      REMAINING=$(( DEADLINE - $(date +%s) ))
      ACTUAL_SLEEP=$(capped_sleep "$BACKOFF" "$REMAINING")
      warn "rate-limited http=429; retrying in ${ACTUAL_SLEEP}s (capped from ${BACKOFF}s by remaining ${REMAINING}s)"
      sleep "$ACTUAL_SLEEP"
      BACKOFF=$((BACKOFF * 2))
      [ "$BACKOFF" -gt 16 ] && BACKOFF=16
      ;;
    4*)
      # Permanent failure (auth/permissions/bad payload). Retrying
      # won't help; fail fast so the caller surfaces the warning.
      cat "$RESP_FILE" >> "$LOG" 2>/dev/null
      warn "permanent failure http=${HTTP_CODE}"
      emit "EXIT_REASON=API_ERROR"
      exit 2
      ;;
    *)
      cat "$RESP_FILE" >> "$LOG" 2>/dev/null
      REMAINING=$(( DEADLINE - $(date +%s) ))
      ACTUAL_SLEEP=$(capped_sleep "$BACKOFF" "$REMAINING")
      warn "transient http=${HTTP_CODE}; retrying in ${ACTUAL_SLEEP}s (capped from ${BACKOFF}s by remaining ${REMAINING}s)"
      sleep "$ACTUAL_SLEEP"
      BACKOFF=$((BACKOFF * 2))
      [ "$BACKOFF" -gt 16 ] && BACKOFF=16
      ;;
  esac
done
