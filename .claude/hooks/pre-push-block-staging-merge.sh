#!/bin/bash
# Pre-push hook: blocks any push whose new commits have origin/staging
# as an unreachable-from-master ancestor — the structural enforcement
# of CLAUDE.md "Never reference origin/staging in git commands on a
# feature branch."
#
# Background: the bot-created master-promotion PR auto-tracks the
# feature-branch tip. If `git merge origin/staging` (or any equivalent
# rebase/pull-from-staging) lands a commit whose ancestor set includes
# staging-only commits, the master PR's diff balloons. This is the
# DASH-2013 → PR #2497 incident.
#
# This hook is the structural guard: any push that would put such
# pollution on the remote feature branch is refused. The agentic
# alternative for resolving staging conflicts is
# `.claude/scripts/resolve_staging_conflict.sh`, which applies
# `git merge-file` per file and commits as a single-parent commit.
#
# Behaviour:
#   - Reads pushed-ref lines from stdin (git's pre-push protocol).
#   - For each (local_ref, local_sha, remote_ref, remote_sha) line:
#     - Skip if local_sha is the all-zeroes delete sentinel.
#     - Skip if pushing master, staging, or main (the protected
#       branches that LEGITIMATELY have such commits in their history).
#     - Enumerate commits being pushed:
#         git rev-list --no-walk <local_sha> --not <remote_sha if non-zero>
#                                                 <origin/master>
#     - For each pushed commit, inspect its parents:
#       - 1 parent → harmless, skip.
#       - 2+ parents → for each parent beyond the first, check whether
#         it is reachable from origin/staging AND NOT reachable from
#         origin/master. If yes → the commit pulled staging history
#         that's not yet on master. BLOCK.
#   - Exit 0 if no violation; exit 2 with a clear message otherwise.
#
# Author bypass: developers can set the env var
#   ALLOW_STAGING_MERGE=1
# to bypass this hook for a single push. This is intentionally an env
# var, not a settings.json flag, so the bypass is per-invocation and
# leaves an audit trail in the shell history. Use only when you know
# why you're crossing this rule.
#
# Performance: the worst-case path is N commits × M parents × one
# `git merge-base --is-ancestor` per parent. For typical pushes this
# is <5 commits with 1 parent each, so <1s overhead. Larger pushes are
# also bounded because we only inspect commits NOT already on the
# remote.

set -u

# Bypass switch.
if [ "${ALLOW_STAGING_MERGE:-0}" = "1" ]; then
  echo "pre-push-block-staging-merge.sh: bypassed via ALLOW_STAGING_MERGE=1 — proceeding without check" >&2
  exit 0
fi

# PID-namespaced sentinel — the `while ... | while ... read` pipeline
# below runs the inner loop in a subshell, so we use a temp file to
# pass the violation signal back to the outer shell. Including $$ in
# the path scopes the sentinel to this hook invocation; concurrent
# pushes from a different shell get a different filename and don't
# collide. The trap removes the file on exit so a kill mid-run
# doesn't leave a stale signal lying around.
VIOLATION_SENTINEL=$(mktemp -t pre-push-block-XXXXXX)
trap 'rm -f "$VIOLATION_SENTINEL"' EXIT

# Fetch origin/master + origin/staging so the ancestry checks below
# have current refs. Fail open on fetch errors (hooks shouldn't break
# offline workflows entirely; the staging-tip we already have locally
# is good enough for the structural check).
git fetch --quiet origin master staging 2>/dev/null || true

# git's pre-push hook stdin: one line per ref being pushed, format:
#   <local_ref> <local_sha> <remote_ref> <remote_sha>
# Empty stdin → no refs pushed → exit 0.
while read -r local_ref local_sha remote_ref remote_sha; do
  # Skip ref deletions (local_sha == all zeros).
  if echo "$local_sha" | grep -qE '^0+$'; then
    continue
  fi

  # Only inspect branch refs. Tags (refs/tags/...), notes (refs/notes/...),
  # and any other ref types are NOT feature branches; running branch-only
  # ancestry checks on them would either misclassify or waste work.
  # CR round 1.1.
  case "$local_ref" in
    refs/heads/*) ;;
    *)
      continue
      ;;
  esac

  # Determine branch name from local_ref (refs/heads/<name>).
  branch="${local_ref#refs/heads/}"

  # Skip protected branches — master, staging, and main legitimately
  # contain merge commits with staging history.
  case "$branch" in
    master|main|staging)
      continue
      ;;
  esac

  # Enumerate the commits being pushed. If remote_sha is non-zero
  # (existing remote branch), it's the lower bound. If it's all zeros
  # (new branch push), use origin/master as the lower bound so we
  # don't inspect every commit since the dawn of time.
  if echo "$remote_sha" | grep -qE '^0+$'; then
    lower_bound="origin/master"
  else
    lower_bound="$remote_sha"
  fi

  # Note: `git rev-list X --not Y` includes commits reachable from X
  # but not from Y. We further exclude origin/master in all cases so
  # we never re-inspect commits already integrated into master.
  pushed_commits=$(git rev-list "$local_sha" --not "$lower_bound" origin/master 2>/dev/null) || true

  if [ -z "$pushed_commits" ]; then
    continue
  fi

  # Check each pushed commit for a parent in staging that's not in master.
  echo "$pushed_commits" | while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    parents=$(git log -1 --format='%P' "$sha" 2>/dev/null)
    # First parent is the commit's "main line" parent — fine.
    # Second-and-later parents are the merged-in branches.
    set -- $parents
    if [ "$#" -lt 2 ]; then
      continue
    fi
    shift  # drop first parent
    for extra_parent in "$@"; do
      # Is extra_parent reachable from origin/staging?
      if git merge-base --is-ancestor "$extra_parent" origin/staging 2>/dev/null; then
        # Is it ALSO reachable from origin/master? If yes, it's fine
        # (the staging tail has already landed on master).
        if ! git merge-base --is-ancestor "$extra_parent" origin/master 2>/dev/null; then
          # Hit. Emit a diagnostic and signal violation.
          echo "❌ pre-push-block-staging-merge.sh: BLOCKED" >&2
          echo "" >&2
          echo "Commit ${sha:0:8} on branch '$branch' has parent ${extra_parent:0:8}" >&2
          echo "which is reachable from origin/staging but NOT from origin/master." >&2
          echo "" >&2
          echo "Commit subject: $(git log -1 --format='%s' "$sha" 2>/dev/null)" >&2
          echo "" >&2
          echo "This means the branch contains a merge of origin/staging — staging's tail" >&2
          echo "will pollute the auto-created feature→master promotion PR's diff. See" >&2
          echo "CLAUDE.md 'CRITICAL: Never mix staging into feature branches' for the rule" >&2
          echo "and the DASH-2013 → PR #2497 incident for what this prevents." >&2
          echo "" >&2
          echo "Recovery:" >&2
          echo "  1. To resolve a staging conflict without a merge commit, run:" >&2
          echo "       .claude/scripts/resolve_staging_conflict.sh" >&2
          echo "     This uses git merge-file to apply per-file 3-way merges as" >&2
          echo "     single-parent commits — no staging ancestor, no pollution." >&2
          echo "" >&2
          echo "  2. If you've already created a merge commit, rebuild the branch:" >&2
          echo "       git checkout master && git pull --rebase origin master" >&2
          echo "       git checkout -b <branch>-clean origin/master" >&2
          echo "       git cherry-pick <your DASH-XXXX commits>" >&2
          echo "       # then push the new branch and close the polluted PR" >&2
          echo "" >&2
          echo "  3. Single-push bypass (use only with explicit justification):" >&2
          echo "       ALLOW_STAGING_MERGE=1 git push" >&2
          echo "" >&2
          # Signal the violation back to the outer shell via the
          # PID-namespaced sentinel (the inner while-read runs in a
          # subshell because of the upstream pipe).
          echo "1" > "$VIOLATION_SENTINEL"
        fi
      fi
    done
  done
done

if [ -s "$VIOLATION_SENTINEL" ]; then
  exit 2
fi
exit 0
