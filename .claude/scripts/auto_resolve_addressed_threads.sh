#!/usr/bin/env bash
# Close any unresolved CodeRabbit review threads on a PR whose findings
# the just-pushed commit demonstrably addressed. Designed to be invoked
# from /develop Step 9b after every push during the merge-readiness
# loop, so the agent never has to fall back to manual `gh api graphql
# resolveReviewThread` calls for "fixed but not auto-closed" threads
# (the failure mode that blocked merge on DASH-1897).
#
# Algorithm:
#   1. List unresolved review threads on the PR (GraphQL). Pulls comment
#      body + path + line range together (DASH-1948).
#   2. For each thread, run TWO independent match heuristics — either
#      one is sufficient to consider the thread addressed:
#        H1 (anchor-line): take the first comment's path + originalLine
#           (pre-fix) and line (current) as the anchored line range,
#           diff the just-pushed commit, check whether any hunks for
#           that file overlap that range.
#        H2 (body-mention) (DASH-1948): extract any project-relative
#           file paths from the comment body (e.g. `mileometer/foo.py`,
#           `.claude/skills/develop/SKILL.md`) via a conservative
#           literal-only regex. If the commit's diff touched ANY
#           extracted path, the thread is considered addressed.
#      Both heuristics OR together. H1 catches the "comment posted
#      inline on the line that was fixed" case. H2 catches the
#      outside-diff case CodeRabbit uses when a finding references a
#      file that's NOT in the PR diff — the comment is anchored to
#      whatever file IS in the diff (so H1's anchor-file check fails),
#      but the body explicitly names the real target. This was the
#      DASH-1947 failure mode (anchored to scheduled_task_engine.py,
#      body referenced admin.py).
#   3. If either heuristic matched, post a one-line reply
#      "Addressed in commit <short_sha>" and call resolveReviewThread.
#   4. Otherwise leave the thread alone — the regular DEFERRED-WITH-
#      TICKET / REJECTED-WITH-RATIONALE protocols still apply for
#      those.
#
# Self-test: run with --self-test to exercise the H2 path-extraction
# regex on a synthetic comment body (no GitHub API calls). Used by the
# /develop CR-loop tests so the heuristic doesn't silently drift.
#
# Args: PR_NUMBER COMMIT_SHA   (or --self-test)
# Exit:
#   0 — normal (counts in the log: ADDRESSED, SKIPPED, ERRORS)
#   2 — ERROR_GH_REPO (gh CLI unauthenticated or not a GH repo)

set -u

# Conservative regex for project-relative paths CodeRabbit cites in
# outside-diff bodies. Matches:
#   - mileometer/...
#   - .claude/...
#   - tests/... (less common, but valid)
# Path tail must end with a recognisable extension or directory marker
# so we don't pick up arbitrary slashes from prose. Keep this list in
# sync with the project layout — adding a new top-level dir for shipped
# code means adding it here too.
extract_paths_from_body() {
  local body="$1"
  # Use grep -oE for the regex match; printf to bash because some
  # comment bodies have CRLF that grep doesn't strip. The trailing
  # tr -d '\r' guards against that.
  printf '%s' "$body" | tr -d '\r' \
    | grep -oE '(mileometer|\.claude|tests)/[A-Za-z0-9_./-]+\.(py|sh|md|yml|yaml|json|html|js|ts|tsx|jsx|css)' \
    | sort -u
}

# --- self-test mode ----------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
      printf 'PASS: %s\n' "$label"
    else
      printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$label" "$expected" "$actual"
      fail=1
    fi
  }

  body1="The spec now shows cruise/tourop at 50/40, but mileometer/mileometer/admin.py:238-245 still advertises 45/30."
  got1=$(extract_paths_from_body "$body1" | tr '\n' ' ' | sed 's/ $//')
  check "H2 single mileometer path" "mileometer/mileometer/admin.py" "$got1"

  body2="Update the scheduled task engine doc — see .claude/skills/develop/SKILL.md and tests/unit_tests/test_scheduled_task_engine.py."
  got2=$(extract_paths_from_body "$body2" | tr '\n' ' ' | sed 's/ $//')
  check "H2 .claude + tests path" ".claude/skills/develop/SKILL.md tests/unit_tests/test_scheduled_task_engine.py" "$got2"

  body3="Plain English with no paths in it."
  got3=$(extract_paths_from_body "$body3" | tr '\n' ' ' | sed 's/ $//')
  check "H2 no paths"             ""                              "$got3"

  body4="The src/ directory is fine; tests/integration_tests/test_foo.py needs an assertion."
  got4=$(extract_paths_from_body "$body4" | tr '\n' ' ' | sed 's/ $//')
  check "H2 ignores bare 'src/'"  "tests/integration_tests/test_foo.py" "$got4"

  body5="Multi-line:\nFirst paragraph mentions mileometer/views/todo.py:42.\nSecond paragraph mentions mileometer/views/todo.py:99 again — should dedupe."
  got5=$(printf '%b' "$body5" | { read -r line; while read -r line; do printf '%s ' "$line"; done; } > /dev/null; \
    extract_paths_from_body "$(printf '%b' "$body5")" | tr '\n' ' ' | sed 's/ $//')
  check "H2 dedupes repeated"     "mileometer/views/todo.py"      "$got5"

  if [ $fail -eq 0 ]; then
    echo "All H2 self-tests passed."
    exit 0
  else
    echo "H2 self-tests FAILED."
    exit 1
  fi
fi
# --- /self-test mode ---------------------------------------------------

if [ "$#" -lt 2 ]; then
  echo "usage: $0 PR_NUMBER COMMIT_SHA   (or $0 --self-test)" >&2
  exit 2
fi

PR_NUMBER="$1"
COMMIT_SHA="$2"
SHORT_SHA="${COMMIT_SHA:0:8}"
LOG="/tmp/auto-resolve-${PR_NUMBER}.log"
: > "$LOG"

emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }

OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$OWNER_REPO" ]; then
  warn "gh repo view returned empty nameWithOwner — not in a GitHub repo, or gh CLI unauthenticated"
  emit "EXIT_REASON=ERROR_GH_REPO"
  exit 2
fi
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

# Files touched by the just-pushed commit. Used by both H1 (the
# in-loop sed/awk hunk parser still anchors per-thread, this list is
# only for the cheap H2 set-membership check) and H2 (body-mention).
TOUCHED_FILES=$(git diff --name-only "${COMMIT_SHA}^..${COMMIT_SHA}" 2>/dev/null | sort -u)

# 1. Fetch unresolved threads. We only need the first comment per thread
#    for the file/line anchor and a comment id we can reply to via REST.
#
# A single-page query (`first: 100`) was sufficient for the PRs that
# motivated this helper (DASH-1897, DASH-1915), but ASSERTIVE-mode
# CodeRabbit reviews on big PRs can produce well over 100 threads —
# DASH-1915 round 6 flagged this. Page through the connection until
# `pageInfo.hasNextPage == false`, accumulating nodes into one combined
# JSON array under the same shape the rest of the script consumes.
ALL_NODES_FILE=$(mktemp -t auto-resolve-threads-XXXXXX) || {
  warn "mktemp failed"
  emit "EXIT_REASON=MKTEMP_FAILED"
  exit 0
}
trap 'rm -f "$ALL_NODES_FILE"' EXIT
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
          isOutdated
          comments(first: 1) {
            nodes {
              databaseId
              path
              line
              originalLine
              body
              author { login }
            }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" 2>>"$LOG") || {
      warn "GraphQL reviewThreads query failed (page $PAGE, no cursor)"
      emit "EXIT_REASON=GRAPHQL_FAILED"
      exit 0
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
          isOutdated
          comments(first: 1) {
            nodes {
              databaseId
              path
              line
              originalLine
              body
              author { login }
            }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" -f after="$CURSOR" 2>>"$LOG") || {
      warn "GraphQL reviewThreads query failed (page $PAGE, cursor $CURSOR)"
      emit "EXIT_REASON=GRAPHQL_FAILED"
      exit 0
    }
  fi

  # Append this page's nodes to the accumulator file.
  jq --argjson prev "$(cat "$ALL_NODES_FILE")" \
     '$prev + .data.repository.pullRequest.reviewThreads.nodes' \
     <<< "$PAGE_JSON" > "${ALL_NODES_FILE}.next"
  mv "${ALL_NODES_FILE}.next" "$ALL_NODES_FILE"

  HAS_NEXT=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<< "$PAGE_JSON")
  CURSOR=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' <<< "$PAGE_JSON")
  if [ "$HAS_NEXT" != "true" ] || [ -z "$CURSOR" ]; then
    break
  fi
done

# Synthesize the same JSON shape downstream code consumed before
# pagination was added.
THREADS_JSON=$(jq --slurpfile nodes "$ALL_NODES_FILE" \
  -n '{ data: { repository: { pullRequest: { reviewThreads: { nodes: $nodes[0] } } } } }')

# Extract the unresolved thread set as JSON-per-line (jq -c). Each line
# is a self-contained compact JSON object the loop below decodes via
# `jq -r` field-by-field. DASH-1948 added `body` to the record set so
# the H2 (body-mention) heuristic can scan it for project-relative
# file paths without bash IFS-splitting on multi-line content.
#
# IMPORTANT: only consider threads whose first comment was authored by
# the CodeRabbit bot. Without this filter the script would happily
# auto-resolve a human reviewer's open thread on the same line range,
# which would be an unsolicited "fix" of someone else's review and
# could close a discussion the human still wants to have. The bot's
# GitHub login is "coderabbitai" (no [bot] suffix on `author.login`).
ROWS=$(echo "$THREADS_JSON" | jq -c '
  .data.repository.pullRequest.reviewThreads.nodes
  | map(select(.isResolved == false))
  | map(select(.comments.nodes[0].author.login == "coderabbitai"))
  | .[]
  | {
      thread_id: .id,
      comment_id: ((.comments.nodes[0].databaseId // "") | tostring),
      path: (.comments.nodes[0].path // ""),
      line_low: (.comments.nodes[0].originalLine // .comments.nodes[0].line // 0),
      line_high: (.comments.nodes[0].line // .comments.nodes[0].originalLine // 0),
      body: (.comments.nodes[0].body // "")
    }')

ADDRESSED=0
SKIPPED=0
TOTAL=0

# Iterate the JSON-per-line records. `jq -r` per row keeps multi-line
# bodies intact; bash never sees them as a single string we could
# IFS-split, which is exactly the brittleness DASH-1948 fixed.
while IFS= read -r record; do
  [ -z "$record" ] && continue
  TOTAL=$((TOTAL + 1))

  thread_id=$(jq -r '.thread_id' <<< "$record")
  comment_id=$(jq -r '.comment_id' <<< "$record")
  path=$(jq -r '.path' <<< "$record")
  line_low=$(jq -r '.line_low' <<< "$record")
  line_high=$(jq -r '.line_high' <<< "$record")
  body=$(jq -r '.body' <<< "$record")

  if [ -z "$path" ] || [ -z "$comment_id" ]; then
    emit "SKIP thread=$thread_id reason=missing-path-or-comment-id"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Normalise the line range so low <= high. CodeRabbit sometimes anchors
  # to a single line (line == originalLine), sometimes to a range.
  if [ "$line_low" -gt "$line_high" ]; then
    tmp="$line_low"; line_low="$line_high"; line_high="$tmp"
  fi

  # H1 — anchor-line overlap. Did the just-pushed commit touch any
  # line in $path that overlaps [line_low, line_high]?
  HUNKS=$(git diff "${COMMIT_SHA}^..${COMMIT_SHA}" -- "$path" 2>/dev/null \
    | sed -nE 's/^@@ -[0-9]+(,[0-9]+)? \+([0-9]+)(,([0-9]+))? @@.*/\2 \4/p' \
    | awk '{
        start = $1 + 0;
        # Empty length defaults to 1 (diff convention for single-line
        # context); 0 (deletion-only hunk) also defaults to 1 so the
        # surrounding context still anchors at $start without producing
        # end < start.
        len = ($2 == "" || $2 == "0" ? 1 : $2 + 0);
        print start, start + len - 1
      }')

  H1_TOUCHED=0
  while read -r hunk_start hunk_end; do
    [ -z "$hunk_start" ] && continue
    if [ "$hunk_start" -le "$line_high" ] && [ "$hunk_end" -ge "$line_low" ]; then
      H1_TOUCHED=1
      break
    fi
  done <<< "$HUNKS"

  # H2 — body-mention (DASH-1948). Extract project-relative file paths
  # from the comment body and check whether the commit touched any of
  # them. This catches the outside-diff failure mode where the thread
  # is anchored to a file CodeRabbit COULD post on (because that file
  # is in the diff) but the body references a DIFFERENT file (which
  # isn't in the diff). The DASH-1947 admin.py thread sat at this
  # exact intersection — anchored to scheduled_task_engine.py (path
  # the round-1.8 commit didn't touch in any hunk that overlapped the
  # anchor line range), body referenced admin.py (which the commit
  # DID touch). Without H2 the helper SKIPped that thread on every
  # round, leaving it open until manual resolution.
  H2_TOUCHED=0
  H2_MATCHED_PATHS=""
  if [ "$H1_TOUCHED" -eq 0 ]; then
    BODY_PATHS=$(extract_paths_from_body "$body")
    if [ -n "$BODY_PATHS" ]; then
      while IFS= read -r body_path; do
        [ -z "$body_path" ] && continue
        if printf '%s\n' "$TOUCHED_FILES" | grep -Fxq "$body_path"; then
          H2_TOUCHED=1
          H2_MATCHED_PATHS="${H2_MATCHED_PATHS:+$H2_MATCHED_PATHS,}$body_path"
        fi
      done <<< "$BODY_PATHS"
    fi
  fi

  if [ "$H1_TOUCHED" -eq 0 ] && [ "$H2_TOUCHED" -eq 0 ]; then
    emit "SKIP thread=$thread_id path=$path lines=$line_low-$line_high reason=neither-h1-nor-h2-matched"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  MATCH_REASON=$([ "$H1_TOUCHED" -eq 1 ] && echo "h1-anchor" || echo "h2-body=${H2_MATCHED_PATHS}")

  # Post a reply to the thread acknowledging the fix.
  REPLY_OK=0
  if gh api --method POST \
       "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${comment_id}/replies" \
       -f body="Addressed in commit ${SHORT_SHA}." > /dev/null 2>>"$LOG"; then
    REPLY_OK=1
  else
    warn "reply POST failed for thread=$thread_id comment=$comment_id"
  fi

  # Flip isResolved via the GraphQL mutation. The reply alone does
  # NOT close the thread in GitHub's data model.
  FLIPPED=$(gh api graphql -f query='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread { id isResolved }
      }
    }' -f threadId="$thread_id" \
    --jq '.data.resolveReviewThread.thread.isResolved' 2>>"$LOG" || echo "ERROR")

  if [ "$FLIPPED" = "true" ]; then
    emit "ADDRESS thread=$thread_id path=$path lines=$line_low-$line_high match=$MATCH_REASON reply_ok=$REPLY_OK"
    ADDRESSED=$((ADDRESSED + 1))
  else
    warn "resolveReviewThread returned '$FLIPPED' for thread=$thread_id (expected 'true')"
    emit "SKIP thread=$thread_id path=$path lines=$line_low-$line_high reason=resolve-mutation-not-true"
    SKIPPED=$((SKIPPED + 1))
  fi
done <<< "$ROWS"

emit "SUMMARY addressed=$ADDRESSED skipped=$SKIPPED total=$TOTAL commit=$SHORT_SHA"
emit "EXIT_REASON=OK"
exit 0
