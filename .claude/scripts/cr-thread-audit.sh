#!/usr/bin/env bash
# cr-thread-audit.sh — answer "is this CodeRabbit round actually addressed?"
# with a NUMBER the agent did not choose (INF-280).
#
# Why this exists
# ---------------
# The agent reports a round as addressed while findings remain unresolved,
# because it reads the review BODY — often through grep — instead of
# enumerating the review THREADS. The body's "Actionable comments posted: N"
# header does not count the outside-diff, duplicate, or nitpick buckets, so a
# round can look complete and not be.
#
# Evidence (mileometer-frontend PR #263, MYST-67): after five reported-complete
# rounds the PR carried 11 CodeRabbit threads with 2 unresolved — an entity
# decode-order bug in resolvers.ts and a doc-comment split in schema.ts. Thread
# enumeration found both in one query. The next round stood at 13 threads, 3
# unresolved, one of them MAJOR. The operator caught it; the workflow did not.
#
# The kit already documents the answer twice — Step 9b a2's four-bucket rule and
# Step 9b h's pre-round-complete audit, both from DASH-1948, both loaded in that
# session, neither run. That is the INF-212 shape: correct guidance, violated
# anyway, so the fix is enforcement rather than another paragraph.
#
# What it does
# ------------
#   1. Paginates the PR's reviewThreads connection (ASSERTIVE reviews on large
#      PRs exceed a single 100-node page — the same reason
#      auto_resolve_addressed_threads.sh paginates).
#      Every page is VALIDATED before accumulation: `gh api graphql` exits 0 on
#      an application-level error, so an errored or truncated page would
#      otherwise fold in as nothing and produce a false clean.
#   2. Keeps threads whose FIRST comment was authored by coderabbitai and whose
#      isResolved is false.
#   3. Prints UNRESOLVED=<n>, then one line per unresolved thread:
#      path:line — first 200 chars of the comment, newlines collapsed.
#   4. Exits non-zero when n > 0.
#
# Exit codes (distinct on purpose — the caller must tell "found open findings"
# apart from "could not look"):
#   0 — UNRESOLVED=0. The round is genuinely clean.
#   1 — UNRESOLVED>0. Findings are open; the listing is on stdout.
#   2 — infrastructure failure (no gh repo, GraphQL error, mktemp). NOT a
#       verdict about the threads. A caller must never read this as clean.
#
# Args:
#   PR_NUMBER                 audit this PR in the current gh repo
#   --fixture <file>          read the thread-node JSON array from a file
#                             instead of calling GraphQL. Test hook: it lets
#                             test_cr_thread_audit.sh prove the check
#                             discriminates in BOTH directions without network.
#   --self-test               run the built-in fixture pair and report.
#
# Output is tee'd to /tmp/cr-thread-audit-<PR>.log.

set -u

BODY_EXCERPT_CHARS=200

usage() {
  echo "usage: $0 PR_NUMBER" >&2
  echo "       $0 --fixture <threads.json> [PR_NUMBER]" >&2
  echo "       $0 --self-test" >&2
}

# ── Core classification, shared by the live and fixture paths ───────────────
# Takes a JSON ARRAY of reviewThread nodes; prints "UNRESOLVED=<n>" as its FIRST
# line, then one listing line per unresolved CodeRabbit thread. Returns 2 when
# the payload is not a usable array.
#
# The count is returned via stdout rather than a global on purpose: every caller
# reads this through a command substitution, which runs the function in a
# subshell, so a global assignment would never reach the caller. (It didn't —
# the first draft of this file set UNRESOLVED_COUNT here and every fixture came
# back empty.) One function is still the single source of truth for the verdict,
# which is what lets the fixture test exercise the real logic instead of a
# re-implementation of it.
audit_nodes() {
  local nodes_json="$1" count

  count=$(jq -r '
    [ .[]
      | select(.isResolved == false)
      | select((.comments.nodes[0].author.login // "") == "coderabbitai")
    ] | length' <<< "$nodes_json" 2>/dev/null)

  case "$count" in
    ''|*[!0-9]*) return 2 ;;
  esac

  printf 'UNRESOLVED=%s\n' "$count"

  if [ "$count" -gt 0 ]; then
    jq -r --argjson n "$BODY_EXCERPT_CHARS" '
      .[]
      | select(.isResolved == false)
      | select((.comments.nodes[0].author.login // "") == "coderabbitai")
      | .comments.nodes[0] as $c
      | "  - " + ($c.path // "?")
        + ":" + (($c.line // $c.originalLine // 0) | tostring)
        + " — " + (($c.body // "") | gsub("[\r\n]+"; " ") | .[0:$n])
    ' <<< "$nodes_json"
  fi

  return 0
}

# Pull the count back out of audit_nodes' output.
count_from() { printf '%s\n' "$1" | grep -E '^UNRESOLVED=' | head -1 | cut -d= -f2; }

# The GraphQL page guard is SHARED with auto_resolve_addressed_threads.sh
# (INF-280 CR round 1.2) — the first attempt pasted a shortened copy into that
# helper and it drifted weaker immediately. One implementation, both callers.
_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$_GUARD_DIR/kit-graphql-page-guard.sh" ]; then
  . "$_GUARD_DIR/kit-graphql-page-guard.sh"
else
  echo "[WARN] kit-graphql-page-guard.sh not found — refusing to audit without page validation, since an errored page would read as clean" >&2
  echo "EXIT_REASON=GUARD_MISSING" >&2
  exit 2
fi

# ── Argument parsing ───────────────────────────────────────────────────────
FIXTURE_FILE=""
SELF_TEST=false
PR_NUMBER=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixture)
      FIXTURE_FILE="${2:-}"
      [ -z "$FIXTURE_FILE" ] && { usage; exit 2; }
      shift 2
      ;;
    --self-test) SELF_TEST=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           PR_NUMBER="$1"; shift ;;
  esac
done

# ── Self-test: prove the check discriminates, both directions ──────────────
if [ "$SELF_TEST" = "true" ]; then
  CLEAN='[{"isResolved":true,"comments":{"nodes":[{"path":"a.ts","line":1,"body":"fixed","author":{"login":"coderabbitai"}}]}}]'
  DIRTY='[{"isResolved":true,"comments":{"nodes":[{"path":"a.ts","line":1,"body":"fixed","author":{"login":"coderabbitai"}}]}},
          {"isResolved":false,"comments":{"nodes":[{"path":"resolvers.ts","line":42,"body":"entity decode order: & decoded first causes double-decode","author":{"login":"coderabbitai"}}]}}]'
  HUMAN='[{"isResolved":false,"comments":{"nodes":[{"path":"a.ts","line":1,"body":"human musing","author":{"login":"someone-else"}}]}}]'
  FAILURES=0

  N=$(count_from "$(audit_nodes "$CLEAN")")
  [ "$N" = "0" ] || { echo "SELF_TEST FAIL: all-resolved fixture gave '$N'" >&2; FAILURES=$((FAILURES+1)); }

  N=$(count_from "$(audit_nodes "$DIRTY")")
  [ "$N" = "1" ] || { echo "SELF_TEST FAIL: one-unresolved fixture gave '$N'" >&2; FAILURES=$((FAILURES+1)); }

  N=$(count_from "$(audit_nodes "$HUMAN")")
  [ "$N" = "0" ] || { echo "SELF_TEST FAIL: non-coderabbit thread counted ('$N')" >&2; FAILURES=$((FAILURES+1)); }

  # Page validation is the shared guard's job; assert it is wired in and
  # rejecting, rather than re-testing its cases here (kit-graphql-page-guard.sh
  # self-tests every shape itself).
  if ! validate_graphql_page '{"errors":[{"message":"boom"}]}' '.data.repository.pullRequest.reviewThreads'; then
    :
  else
    echo "SELF_TEST FAIL: shared page guard accepted an errored page" >&2; FAILURES=$((FAILURES+1))
  fi
  if ! validate_graphql_page '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' '.data.repository.pullRequest.reviewThreads'; then
    echo "SELF_TEST FAIL: shared page guard rejected a valid page" >&2; FAILURES=$((FAILURES+1))
  fi

  if [ "$FAILURES" -eq 0 ]; then
    echo "SELF_TEST=OK (discriminates: clean=0, one-unresolved=1, non-coderabbit ignored; shared page guard wired in)"
    exit 0
  fi
  echo "SELF_TEST=FAILED failures=${FAILURES}" >&2
  exit 2
fi

LOG="/tmp/cr-thread-audit-${PR_NUMBER:-fixture}.log"
: > "$LOG" 2>/dev/null || LOG=/dev/null
emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }

# ── Fixture path (offline; used by the test) ───────────────────────────────
if [ -n "$FIXTURE_FILE" ]; then
  if [ ! -r "$FIXTURE_FILE" ]; then
    warn "fixture file not readable: $FIXTURE_FILE"
    emit "EXIT_REASON=FIXTURE_UNREADABLE"
    exit 2
  fi
  NODES=$(cat "$FIXTURE_FILE")
  AUDIT=$(audit_nodes "$NODES") || {
    warn "fixture is not a JSON array of thread nodes"
    emit "EXIT_REASON=FIXTURE_MALFORMED"
    exit 2
  }
  UNRESOLVED_COUNT=$(count_from "$AUDIT")
  printf '%s\n' "$AUDIT" | tee -a "$LOG"
  if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
    emit "EXIT_REASON=UNRESOLVED_THREADS"
    exit 1
  fi
  emit "EXIT_REASON=OK"
  exit 0
fi

# ── Live path ──────────────────────────────────────────────────────────────
if [ -z "$PR_NUMBER" ]; then
  usage
  exit 2
fi

OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$OWNER_REPO" ]; then
  warn "gh repo view returned empty nameWithOwner — not in a GitHub repo, or gh CLI unauthenticated"
  emit "EXIT_REASON=ERROR_GH_REPO"
  exit 2
fi
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

ALL_NODES_FILE=$(mktemp -t cr-thread-audit-XXXXXX) || {
  warn "mktemp failed"
  emit "EXIT_REASON=MKTEMP_FAILED"
  exit 2
}
trap 'rm -f "$ALL_NODES_FILE" "${ALL_NODES_FILE}.next"' EXIT
echo '[]' > "$ALL_NODES_FILE"

CURSOR=""
PAGE=0
while : ; do
  PAGE=$((PAGE + 1))
  if [ -z "$CURSOR" ]; then
    PAGE_JSON=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { path line originalLine body author { login } }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" 2>>"$LOG") || {
      warn "GraphQL reviewThreads query failed (page $PAGE, no cursor)"
      emit "EXIT_REASON=GRAPHQL_FAILED"
      exit 2
    }
  else
    PAGE_JSON=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { path line originalLine body author { login } }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" -f after="$CURSOR" 2>>"$LOG") || {
      warn "GraphQL reviewThreads query failed (page $PAGE, cursor $CURSOR)"
      emit "EXIT_REASON=GRAPHQL_FAILED"
      exit 2
    }
  fi

  if ! validate_graphql_page "$PAGE_JSON" '.data.repository.pullRequest.reviewThreads'; then
    warn "GraphQL page $PAGE failed validation: ${GRAPHQL_PAGE_INVALID_REASON} — refusing to report a count from a partial or errored response"
    emit "EXIT_REASON=GRAPHQL_FAILED"
    exit 2
  fi

  jq --argjson prev "$(cat "$ALL_NODES_FILE")" \
     '$prev + .data.repository.pullRequest.reviewThreads.nodes' \
     <<< "$PAGE_JSON" > "${ALL_NODES_FILE}.next" || {
       warn "jq failed accumulating page $PAGE"
       emit "EXIT_REASON=GRAPHQL_FAILED"
       exit 2
     }
  mv "${ALL_NODES_FILE}.next" "$ALL_NODES_FILE"

  HAS_NEXT=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<< "$PAGE_JSON")
  CURSOR=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' <<< "$PAGE_JSON")
  if [ "$HAS_NEXT" != "true" ] || [ -z "$CURSOR" ]; then
    break
  fi
done

TOTAL=$(jq 'length' < "$ALL_NODES_FILE")
AUDIT=$(audit_nodes "$(cat "$ALL_NODES_FILE")") || {
  warn "thread payload was not a JSON array"
  emit "EXIT_REASON=GRAPHQL_FAILED"
  exit 2
}
UNRESOLVED_COUNT=$(count_from "$AUDIT")

emit "THREADS_TOTAL=${TOTAL} pages=${PAGE}"
printf '%s\n' "$AUDIT" | tee -a "$LOG"

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  emit "EXIT_REASON=UNRESOLVED_THREADS"
  exit 1
fi
emit "EXIT_REASON=OK"
exit 0
