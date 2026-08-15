#!/usr/bin/env bash
# kit-graphql-page-guard.sh — one validator for paginated GraphQL responses.
#
# SOURCE this file; it defines validate_graphql_page() and nothing else. It is
# not meant to be executed (running it directly just self-tests).
#
# Why it is shared rather than copied (INF-280 CR round 1.2)
# ---------------------------------------------------------
# cr-thread-audit.sh and auto_resolve_addressed_threads.sh both page through the
# same `reviewThreads` connection, so they need the same guard. The first
# attempt pasted a shortened version into the second helper and it was
# immediately weaker than the original — it missed unparseable JSON, a
# non-boolean hasNextPage, and a missing cursor, and it exited 0 on the failures
# it did catch. That is the drift CLAUDE.md's shared-logic rule exists to
# prevent, so the validator lives here once and both callers source it.
#
# What it guards against
# ----------------------
# Note on `errors`: its SHAPE is validated before its length is read. jq's `//`
# treats `false` as absent, and `{}` / `""` / `0` all have length 0, so the
# obvious `(.errors // []) | length > 0` test passes every malformed shape as a
# clean page. That was CR round 1.3 on this very PR.
# `gh api graphql` exits 0 on an application-level error: the HTTP request
# succeeded, the query did not. A caller that trusts the process exit status
# will fold an errored or truncated page in as nothing, stop paginating, and
# report a confident result about data it never received. For a thread audit
# that is a false "all clear"; for the auto-resolver it is silently skipping
# threads it should have closed.
#
# Usage:
#   . "$SCRIPT_DIR/kit-graphql-page-guard.sh"
#   if ! validate_graphql_page "$PAGE_JSON" '.data.repository.pullRequest.reviewThreads'; then
#       # $GRAPHQL_PAGE_INVALID_REASON says why; treat as infrastructure
#       # failure — never as an empty-but-valid result.
#   fi
#
# Args: PAGE_JSON  CONNECTION_JQ_PATH (e.g. '.data.repository.pullRequest.reviewThreads')
# Sets: GRAPHQL_PAGE_INVALID_REASON on failure.
# Returns: 0 valid, 1 invalid.

validate_graphql_page() {
  local page_json="$1" conn="$2" reason

  GRAPHQL_PAGE_INVALID_REASON=""

  # Unparseable payload first — every later jq would silently yield empty and
  # look indistinguishable from a clean page.
  if ! jq -e . >/dev/null 2>&1 <<< "$page_json"; then
    GRAPHQL_PAGE_INVALID_REASON="unparseable_json"
    return 1
  fi

  reason=$(jq -r --arg conn "$conn" '
    def connection: getpath($conn | ltrimstr(".") | split("."));
    # `errors` must be VALIDATED for shape before its length is read. jq'"'"'s `//`
    # treats `false` as absent, and `{}` / `""` both have length 0, so
    # `(.errors // []) | length` reads every one of those malformed shapes as a
    # clean page (CR round 1.3). A response that malformed is not evidence of
    # anything and must be rejected, not counted.
    if (type != "object") then
      "payload_not_object"
    elif (has("errors") and ((.errors | type) != "array")) then
      "errors_not_array (got " + (.errors | type) + ")"
    elif ((.errors // []) | length) > 0 then
      "graphql_errors: " + ([.errors[] | (.message // "<no message>")] | join("; "))
    elif (connection == null) then
      "connection_missing (unknown PR, or no read permission)"
    elif ((connection.nodes | type) != "array") then
      "nodes_not_array"
    elif ((connection.pageInfo.hasNextPage | type) != "boolean") then
      "hasNextPage_not_boolean"
    elif (connection.pageInfo.hasNextPage
          and ((connection.pageInfo.endCursor // "") == "")) then
      "cursor_missing_while_more_pages"
    else
      ""
    end' <<< "$page_json" 2>/dev/null)

  # A jq failure here is itself a reason to reject: we could not establish that
  # the page is valid, and "could not check" must never pass as "checked, fine".
  if [ $? -ne 0 ]; then
    GRAPHQL_PAGE_INVALID_REASON="validator_jq_failed"
    return 1
  fi

  if [ -n "$reason" ] && [ "$reason" != "null" ]; then
    GRAPHQL_PAGE_INVALID_REASON="$reason"
    return 1
  fi
  return 0
}

# Executed directly → self-test the validator against every shape it must
# reject. Kept here so the guard is verifiable on its own, independent of
# either caller's test file.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CONN='.data.repository.pullRequest.reviewThreads'
  FAILURES=0
  _expect_valid() {
    if ! validate_graphql_page "$1" "$CONN"; then
      echo "FAIL: valid page rejected ($2): $GRAPHQL_PAGE_INVALID_REASON" >&2
      FAILURES=$((FAILURES + 1))
    fi
  }
  _expect_invalid() {
    if validate_graphql_page "$1" "$CONN"; then
      echo "FAIL: invalid page ACCEPTED ($2) — would produce a false clean" >&2
      FAILURES=$((FAILURES + 1))
    fi
  }

  _expect_valid   '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' 'empty-but-valid'
  _expect_valid   '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29y"},"nodes":[{"id":"t1"}]}}}}}' 'more-pages-with-cursor'
  _expect_invalid 'not json at all' 'unparseable'
  _expect_invalid '{"errors":[{"message":"Could not resolve to a PullRequest"}],"data":{"repository":{"pullRequest":null}}}' 'graphql errors'
  # Malformed `errors` shapes: each one has length 0 (or is falsy, which jq's
  # `//` treats as absent), so a naive length check reads them as clean.
  _expect_invalid '{"errors":{},"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' 'errors object'
  _expect_invalid '{"errors":false,"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' 'errors boolean'
  _expect_invalid '{"errors":"","data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' 'errors string'
  _expect_invalid '{"errors":0,"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' 'errors number'
  _expect_invalid '[{"not":"an object"}]' 'top-level array'
  # An errors array WITHOUT a message field must still be rejected, and must not
  # crash the message join.
  _expect_invalid '{"errors":[{"path":["x"]}],"data":{"repository":{"pullRequest":null}}}' 'errors array without message'
  # `errors: []` is what a SUCCESSFUL response legitimately looks like when the
  # field is present but empty — it must still pass, or every clean page fails.
  _expect_valid   '{"errors":[],"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' 'errors empty array'
  _expect_invalid '{"data":{"repository":{"pullRequest":{"reviewThreads":null}}}}' 'connection null'
  _expect_invalid '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":null}}}}}' 'nodes not array'
  _expect_invalid '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":"yes"},"nodes":[]}}}}}' 'hasNextPage not boolean'
  _expect_invalid '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null},"nodes":[]}}}}}' 'hasNextPage null'
  _expect_invalid '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":""},"nodes":[]}}}}}' 'cursor missing while more pages'
  _expect_invalid '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}}' 'cursor absent while more pages'

  if [ "$FAILURES" -eq 0 ]; then
    echo "GUARD_SELF_TEST=OK (rejects unparseable, malformed-or-non-empty errors, null-connection, non-array nodes, non-boolean/null hasNextPage, missing cursor)"
    exit 0
  fi
  echo "GUARD_SELF_TEST=FAILED failures=${FAILURES}" >&2
  exit 1
fi
