#!/bin/bash
# Pre-push hook: blocks pushing a feature branch that is STACKED on
# another DASH-XXXX feature branch — the structural enforcement of
# CLAUDE.md "Never stack on another feature branch; branch only from
# master."
#
# Background (DASH-2341): feature branches must be cut from master so
# their auto-created staging→master promotion PR contains ONLY their own
# ticket's commits/migrations. When a branch is instead cut on top of
# another feature branch, it inherits that ticket's commits — including
# its migration files — and the promotion PR re-carries them, producing a
# spurious migration-duplicate that blocks clean promotion. This is the
# DASH-2333-on-DASH-2334 incident (DASH-2333's promotion PR #2867 warned
# on DASH-2334's 0393 migration because the branch was stacked).
#
# Detection: a branch cut from master carries only its own ticket's
# commits relative to master. Enumerate the commits being pushed that are
# NOT already on origin/master; for each, read its conventional-commit
# SCOPE `type(DASH-YYYY):` from the subject. If any scope's ticket differs
# from the branch's own ticket, those are another feature's not-yet-on-
# master commits → the branch is stacked → BLOCK.
#
# Only the leading `type(DASH-XXXX):` scope is inspected — NOT arbitrary
# DASH mentions in the body — so "fix(DASH-2341): align with DASH-2342"
# does not false-positive. Unscoped commits (merge commits, etc.) are
# ignored. Commits already on master are excluded (`--not origin/master`),
# so once the other ticket is promoted to master the block clears.
#
# Behaviour:
#   - Reads pushed-ref lines from stdin (git's pre-push protocol).
#   - Skips ref deletions, non-branch refs, and protected branches
#     (master/staging/main) and any branch whose name carries no
#     DASH-XXXX ticket (nothing to enforce).
#   - Exit 0 if no violation; exit 2 with a clear recovery message.
#
# Author bypass: set the env var
#   ALLOW_FEATURE_STACKING=1
# to bypass this hook for a single push (mirrors ALLOW_STAGING_MERGE on
# pre-push-block-staging-merge.sh). Per-invocation, leaves a shell-history
# audit trail. Use only for deliberate, known intentional stacking.

set -u

# Bypass switch.
if [ "${ALLOW_FEATURE_STACKING:-0}" = "1" ]; then
  echo "pre-push-block-feature-stacking.sh: bypassed via ALLOW_FEATURE_STACKING=1 — proceeding without check" >&2
  exit 0
fi

# Fetch origin/master so the ancestry check has a current ref. Fail open
# on fetch errors (hooks shouldn't break offline workflows; the local
# origin/master we already have is good enough for the structural check).
git fetch --quiet origin master 2>/dev/null || true

VIOLATION=0
FOREIGN_LIST=""
VIOLATING_BRANCH=""

# git's pre-push hook stdin: one line per ref being pushed, format:
#   <local_ref> <local_sha> <remote_ref> <remote_sha>
# Empty stdin → no refs pushed → exit 0.
while read -r local_ref local_sha remote_ref remote_sha; do
  # Skip ref deletions (local_sha == all zeros).
  if echo "$local_sha" | grep -qE '^0+$'; then
    continue
  fi

  # Only inspect branch refs.
  case "$local_ref" in
    refs/heads/*) ;;
    *) continue ;;
  esac

  branch="${local_ref#refs/heads/}"

  # Protected branches legitimately carry many tickets' commits — never
  # enforce there.
  case "$branch" in
    master | staging | main) continue ;;
  esac

  # The branch's own ticket. If the branch name carries no ticket key,
  # we can't determine ownership — skip (nothing to enforce). INF-187:
  # prefix set covers every org board (previously DASH-only, which
  # silently no-oped the anti-stacking check on APY/WHIT/INF/MYST
  # branches — including the kit's own). Keep in sync with the
  # PROJECT_KEY lookup in scripts/jira_sprint_add.sh (canonical list).
  TICKET_PREFIXES='DASH|APY|WHIT|INF|MYST'
  branch_ticket=$(printf '%s' "$branch" | grep -oE "($TICKET_PREFIXES)-[0-9]+" | head -1 || true)
  if [ -z "$branch_ticket" ]; then
    continue
  fi

  # Commits being introduced relative to master. For a new branch the
  # remote_sha is all-zeroes; --not origin/master alone is the correct
  # lower bound either way (commits already on master are excluded).
  new_commits=$(git rev-list "$local_sha" --not origin/master 2>/dev/null) || true
  [ -z "$new_commits" ] && continue

  while read -r sha; do
    [ -z "$sha" ] && continue
    subj=$(git log -1 --format='%s' "$sha" 2>/dev/null || true)
    # Extract ONLY the leading conventional-commit scope ticket
    # (`type(KEY-XXXX):` or the breaking-change `type(KEY-XXXX)!:`).
    # Empty for unscoped commits. Same INF-187 prefix set as above.
    scope_ticket=$(printf '%s' "$subj" | sed -nE "s/^[a-zA-Z]+\((($TICKET_PREFIXES)-[0-9]+)\)!?:.*/\1/p" | head -1)
    if [ -n "$scope_ticket" ] && [ "$scope_ticket" != "$branch_ticket" ]; then
      VIOLATION=1
      # Capture the first violating branch so the message below names the
      # right ref even in a multi-ref push (the loop variable `branch`
      # would otherwise hold whatever ref was iterated last).
      [ -z "$VIOLATING_BRANCH" ] && VIOLATING_BRANCH="$branch"
      FOREIGN_LIST="${FOREIGN_LIST}  ${sha:0:9}  ${subj}
"
    fi
  done <<< "$new_commits"
done

if [ "$VIOLATION" = "1" ]; then
  {
    echo "❌ pre-push blocked (DASH-2341): branch '${VIOLATING_BRANCH}' appears stacked on another feature branch."
    echo ""
    echo "It carries commits scoped to a DIFFERENT ticket that are NOT yet on master:"
    printf '%s' "$FOREIGN_LIST"
    echo ""
    echo "Feature branches must be cut from master, never stacked on another"
    echo "DASH-XXXX branch (CLAUDE.md 'Never stack on another feature branch')."
    echo "A stacked branch's promotion PR re-carries the other ticket's commits"
    echo "and migrations — the DASH-2333-on-DASH-2334 / PR #2867 incident."
    echo ""
    echo "Recovery:"
    echo "  • If the other ticket is already on master:"
    echo "      git pull --rebase origin master"
    echo "  • Otherwise rebase this branch onto master, dropping the foreign commits:"
    echo "      git rebase --onto origin/master <last-foreign-sha> ${VIOLATING_BRANCH}"
    echo "  • Deliberate, known intentional stacking (rare):"
    echo "      ALLOW_FEATURE_STACKING=1 git push"
  } >&2
  exit 2
fi

exit 0
