#!/usr/bin/env bash
# kit-check.sh — make ABSENCE provable (INF-281).
#
# The problem
# -----------
# The agent reports confident negatives that are not findings but failures. A
# command errors, a `|| echo "(none)"` fallback fires, and the fallback text is
# relayed as a fact. `cmd 2>/dev/null` has the same shape: the error vanishes
# and an empty result takes its place.
#
# Evidence (this session, minutes apart):
#
#   claim:  "no cr-thread-audit.sh on master"
#   basis:  gh api repos/.../contents/.claude/scripts?ref=master --jq ... \
#             || echo "no ..."
#           the unquoted ? was glob-expanded by the shell; the command NEVER RAN
#   truth:  cr-thread-audit.sh IS on master
#
# The failure and the finding were byte-identical on the way out, so the wrong
# statement read exactly like a right one. The operator caught it by opening a
# GitHub page.
#
# What this does
# --------------
# Runs a command and reports the OUTCOME, not just the output:
#
#   exit 0, output     → RESULT_COUNT=<n> then the lines
#   exit 0, no output  → RESULT_COUNT=0 + CHECK_EMPTY  (a genuine empty result)
#   non-zero exit      → CHECK_FAILED with the command, exit code, and stderr
#
# A caller can never confuse the last two, because the failure carries its own
# distinguishable marker and its own exit status. That is the whole point: the
# tooling stops manufacturing confident negatives.
#
# Usage:
#   kit-check.sh [--label <name>] -- <command> [args...]
#   kit-check.sh --self-test
#
# Exit codes:
#   0 — the command ran and produced output (RESULT_COUNT>0)
#   1 — the command ran and produced NOTHING (CHECK_EMPTY) — a real negative
#   2 — the command FAILED (CHECK_FAILED) — not a negative, an unknown
#
# Callers that only care "did it find anything" test exit 0; callers that must
# not mistake a failure for an absence test for exit 2 explicitly. Never write
# `kit-check.sh ... || echo none` — that reintroduces the very bug.

set -u

LABEL=""

usage() {
  echo "usage: $0 [--label <name>] -- <command> [args...]" >&2
  echo "       $0 --self-test" >&2
}

run_check() {
  local label="$1"; shift
  local out_file err_file status out_lines

  out_file=$(mktemp -t kit-check-out-XXXXXX) || { echo "CHECK_FAILED label=${label} reason=mktemp_failed"; return 2; }
  err_file=$(mktemp -t kit-check-err-XXXXXX) || { rm -f "$out_file"; echo "CHECK_FAILED label=${label} reason=mktemp_failed"; return 2; }

  "$@" >"$out_file" 2>"$err_file"
  status=$?

  # Strip trailing blank lines so a command that emits only a newline is not
  # counted as a result — that would be an empty finding wearing a result's
  # clothes, the same confusion in miniature.
  out_lines=$(sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$out_file" | grep -c . || true)

  if [ "$status" -ne 0 ]; then
    printf 'CHECK_FAILED label=%s exit=%s\n' "${label:-<none>}" "$status"
    printf 'CHECK_FAILED_CMD: %s\n' "$*"
    if [ -s "$err_file" ]; then
      sed 's/^/CHECK_FAILED_STDERR: /' "$err_file"
    else
      printf 'CHECK_FAILED_STDERR: <empty — the command failed without writing to stderr>\n'
    fi
    printf 'NOTE: this is NOT an empty result. The check could not establish the answer; do not report absence.\n'
    rm -f "$out_file" "$err_file"
    return 2
  fi

  printf 'RESULT_COUNT=%s\n' "$out_lines"
  if [ "$out_lines" -eq 0 ]; then
    printf 'CHECK_EMPTY label=%s — the command RAN and found nothing (a real negative)\n' "${label:-<none>}"
    rm -f "$out_file" "$err_file"
    return 1
  fi

  cat "$out_file"
  rm -f "$out_file" "$err_file"
  return 0
}

# ── Self-test: prove the three outcomes are distinguishable ────────────────
if [ "${1:-}" = "--self-test" ]; then
  FAILURES=0
  _expect() { # expected_status, expected_marker, description, command...
    local want_status="$1" want_marker="$2" desc="$3"; shift 3
    local out got
    out=$(run_check "selftest" "$@" 2>&1); got=$?
    if [ "$got" -ne "$want_status" ]; then
      echo "SELF_TEST FAIL: ${desc} — exit ${got}, expected ${want_status}" >&2
      FAILURES=$((FAILURES + 1))
      return
    fi
    if ! printf '%s' "$out" | grep -q "$want_marker"; then
      echo "SELF_TEST FAIL: ${desc} — output missing '${want_marker}'" >&2
      FAILURES=$((FAILURES + 1))
    fi
  }

  _expect 0 "RESULT_COUNT=1"  "found something"        printf 'a\n'
  _expect 1 "CHECK_EMPTY"     "ran, found nothing"     true
  _expect 2 "CHECK_FAILED"    "command failed"         false
  _expect 2 "CHECK_FAILED"    "command does not exist" /nonexistent/command-that-cannot-run

  # The case that motivated the ticket: a command that fails must NOT look like
  # a command that found nothing.
  EMPTY_OUT=$(run_check "x" true 2>&1); EMPTY_ST=$?
  FAIL_OUT=$(run_check "x" false 2>&1); FAIL_ST=$?
  if [ "$EMPTY_OUT" = "$FAIL_OUT" ] || [ "$EMPTY_ST" = "$FAIL_ST" ]; then
    echo "SELF_TEST FAIL: empty and failed outcomes are indistinguishable" >&2
    FAILURES=$((FAILURES + 1))
  fi

  if [ "$FAILURES" -eq 0 ]; then
    echo "SELF_TEST=OK (found / empty / failed are three distinct outcomes, by output AND exit code)"
    exit 0
  fi
  echo "SELF_TEST=FAILED failures=${FAILURES}" >&2
  exit 2
fi

# ── Argument parsing ───────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    --)      shift; break ;;
    -h|--help) usage; exit 0 ;;
    *)       usage; exit 2 ;;
  esac
done

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

run_check "$LABEL" "$@"
