#!/bin/bash
# check-staging-drift.sh — DASH-2338
#
# Measures how far the default branch (master) has fallen BEHIND the PR base
# branch (staging) and classifies the result into a clean / advisory / block
# verdict. This is the shared core consumed by two callers:
#
#   1. .claude/hooks/check-staging-drift-advisory.sh   (SessionStart advisory)
#   2. .claude/skills/develop/SKILL.md  Init pre-flight gate (STOP on block)
#
# Why this exists (incident — DASH-2335, 2026-06-24):
#   A clean, CodeRabbit-approved feature PR (#2869) could not merge to staging
#   because staging had drifted 9 commits AHEAD of master — 9 features merged
#   to staging whose master-promotions had not landed. Staging branch
#   protection requires a PR be up-to-date with staging; a master-based feature
#   branch can only become up-to-date by merging staging in (forbidden — it
#   pollutes the auto-created master-promotion PR; see CLAUDE.md "Never mix
#   staging into feature branches"). The drift accumulated silently because the
#   post-deploy "sync staging with master" job did not fire after a re-run
#   master deploy, and nothing alerted on it. This script makes the drift a
#   first-class signal so new feature work refrains from piling onto an
#   already-drifted base.
#
# WHAT IS MEASURED (rewritten in INF-277)
#
# The authoritative signal is CONTENT divergence:
#   git diff --quiet origin/<default> origin/<base>
# i.e. "is there anything on staging that is not on master". Identical trees →
# VERDICT=clean, whatever the commit counts say.
#
# The original implementation used `git rev-list --count master..staging` and
# called it "unpromoted feature merges". It is not. In this two-branch flow
# master NEVER receives staging's merge commits: the promotion PR is opened
# from the FEATURE branch to master (develop skill Step 15), never from staging,
# while the post-deploy sync merges master INTO staging. So staging accumulates
# ~2 commits per ticket that master can never have, the count rises forever, and
# it says nothing about whether work is actually unpromoted.
#
# Measured 2026-08-14, all four staging-master consumers — every tree identical:
#   mileometer 128 commits | frontend 108 | allmylespy 87 | whitelabel 84
# At the old 150 threshold mileometer was ~11 tickets from blocking /develop on
# a perfectly healthy repo, with recovery advice that could not work (there were
# no pending promotion PRs, and re-running the sync ADDS a staging commit).
#
# Commit counts are still emitted, as secondary//informational only. Note that
# `--no-merges` is NOT sufficient either: whitelabel-internal showed 2 non-merge
# commits against an identical tree (content already on master by another
# route). Only the tree comparison is truthful.
#
# The gate remains fail-safe: it never mutates master or staging — it only
# reports, and (in the /develop caller) blocks the START of new work.
#
# Usage:
#   check-staging-drift.sh [--no-fetch] [--diagnose] [--threshold N]
#
#   --no-fetch     Do not `git fetch`; compare existing remote-tracking refs.
#                  Used by the SessionStart hook to stay fast.
#   --diagnose     Best-effort `gh` enrichment: recent master-deploy failures
#                  (AC3 greppable alert), skipped-sync detection (AC2), and the
#                  list of pending promotion PRs (recovery targets). Requires
#                  the `gh` CLI; degrades to UNKNOWN lines if unavailable.
#   --threshold N  Override the block threshold (else develop-config.json
#                  `staging_drift_block_threshold`, else default 3).
#
# Output (key=value lines on stdout; callers grep these):
#   SHAPE=<staging-master|single-branch|...>
#   DRIFT_COUNT=<n>            commits master is behind staging
#   BLOCK_THRESHOLD=<n>
#   VERDICT=<clean|advisory|block|unknown|n-a>
#   FETCH=<ok|skipped|failed>
#   MESSAGE=<one-line recovery guidance>   (only when not clean)
#   # with --diagnose, additionally (best-effort):
#   MASTER_DEPLOY_ALERT=<...>  greppable "DASH-2338 master-deploy-failure ..."
#   SYNC_STATUS=<ran|skipped|unknown>
#   PENDING_PROMOTION_PRS=<#a #b ...|none|unknown>
#
# Exit codes:
#   0  computation succeeded (VERDICT is authoritative on stdout)
#   2  could not compute (not a git repo, refs missing) — VERDICT=unknown
#
# NOTE: the exit code does NOT encode the verdict. Blocking is the CALLER's
# decision based on VERDICT — keeping the policy in one place (this script) and
# the action in the caller. A block verdict still exits 0.

set -u

# DASH-2350: recalibrated 3 → 150 for the one-by-one promotion model. Master
# legitimately runs many commits behind staging (each un-promoted staging merge
# = +1 drift); observed healthy drift has been 56–64. A threshold of 3 fired on
# essentially every run, making the ALLOW_STAGING_DRIFT override routine. 150
# gives ~2.3× headroom over the observed steady state so normal per-feature lag
# never blocks, while still tripping on a genuinely pathological runaway (e.g.
# the post-deploy staging-sync broken for an extended period). The raw commit
# count is a weak proxy for the real hazard (a feature branch structurally
# un-mergeable against staging = a FILE-level conflict); a conflict-based signal
# is the accurate long-term refinement — see DASH-2350 (option 2).
DEFAULT_THRESHOLD=150

NO_FETCH=false
DIAGNOSE=false
THRESHOLD_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) NO_FETCH=true ;;
    --diagnose) DIAGNOSE=true ;;
    --threshold)
      shift
      THRESHOLD_OVERRIDE="${1:-}"
      ;;
    --threshold=*) THRESHOLD_OVERRIDE="${1#*=}" ;;
    -h|--help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "check-staging-drift: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
  shift
done

# Resolve project dir: CLAUDE_PROJECT_DIR when invoked as a hook / by the
# develop gate; otherwise the git worktree root (robust regardless of whether
# this script lives at .claude/scripts/ in a consumer or plugins/claude-kit/
# scripts/ in the kit). Final fallback: two levels up from the script.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/../.." && pwd))}"
CFG="${PROJECT_DIR}/.claude/develop-config.json"

# --- Read repo shape + branch names + threshold from develop-config.json ---
# Mirror the loader semantics documented in develop/SKILL.md: absent file or
# field → the mileometer staging-master defaults.
read_cfg() {
  # $1 = jq path expression, $2 = default
  local val
  if [ -r "$CFG" ] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r "$1 // \"\"" "$CFG" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then
      printf '%s' "$val"
      return
    fi
  fi
  printf '%s' "$2"
}

SHAPE=$(read_cfg '.shape' 'staging-master')
DEFAULT_BRANCH=$(read_cfg '.default_branch' 'master')
PR_BASE_BRANCH=$(read_cfg '.pr_base_branch' 'staging')

if [ -n "$THRESHOLD_OVERRIDE" ]; then
  BLOCK_THRESHOLD="$THRESHOLD_OVERRIDE"
else
  BLOCK_THRESHOLD=$(read_cfg '.staging_drift_block_threshold' "$DEFAULT_THRESHOLD")
fi
# Validate threshold is a positive integer; fall back to the default otherwise.
case "$BLOCK_THRESHOLD" in
  ''|*[!0-9]*) BLOCK_THRESHOLD="$DEFAULT_THRESHOLD" ;;
esac
[ "$BLOCK_THRESHOLD" -lt 1 ] 2>/dev/null && BLOCK_THRESHOLD="$DEFAULT_THRESHOLD"

echo "SHAPE=${SHAPE}"
echo "BLOCK_THRESHOLD=${BLOCK_THRESHOLD}"

# Single-branch (or any non-staging-master) shape has no staging branch to
# drift from — the whole gate is not applicable.
if [ "$SHAPE" != "staging-master" ]; then
  echo "DRIFT_COUNT=0"
  echo "VERDICT=n-a"
  echo "FETCH=skipped"
  exit 0
fi

# Must be inside a git work tree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "DRIFT_COUNT=0"
  echo "VERDICT=unknown"
  echo "FETCH=skipped"
  echo "MESSAGE=not inside a git work tree — cannot measure staging drift"
  exit 2
fi

# --- Refresh remote-tracking refs (unless --no-fetch) ---
FETCH_STATUS="skipped"
if [ "$NO_FETCH" = false ]; then
  if git fetch --quiet --no-tags origin "$DEFAULT_BRANCH" "$PR_BASE_BRANCH" >/dev/null 2>&1; then
    FETCH_STATUS="ok"
  else
    FETCH_STATUS="failed"
  fi
fi
echo "FETCH=${FETCH_STATUS}"

# --- Compute drift: commits on staging not yet on master ---
RANGE="origin/${DEFAULT_BRANCH}..origin/${PR_BASE_BRANCH}"
if ! DRIFT_COUNT=$(git rev-list --count "$RANGE" 2>/dev/null); then
  echo "DRIFT_COUNT=0"
  echo "VERDICT=unknown"
  echo "MESSAGE=could not compare ${RANGE} (missing remote-tracking refs?) — run 'git fetch origin ${DEFAULT_BRANCH} ${PR_BASE_BRANCH}'"
  exit 2
fi
echo "DRIFT_COUNT=${DRIFT_COUNT}"

# --- INF-277: content divergence is the authoritative signal ---
# DRIFT_COUNT above counts merge topology and rises forever; it is retained for
# continuity and diagnosis but no longer decides the verdict.
UNPROMOTED_COMMITS=$(git rev-list --count --no-merges "$RANGE" 2>/dev/null || echo 0)
echo "UNPROMOTED_COMMITS=${UNPROMOTED_COMMITS}"

# `git diff A B` is SYMMETRIC — it reports differences in both directions, so it
# cannot on its own tell "staging has unpromoted work" from "master has a hotfix
# staging has not received yet". Those need opposite advice, and recommending
# promotion for a master-only change would be actively wrong (CR round 1.1).
# Attribute each side against the merge base.
MERGE_BASE=$(git merge-base "origin/${DEFAULT_BRANCH}" "origin/${PR_BASE_BRANCH}" 2>/dev/null || echo "")
# The set of paths that ACTUALLY differ between the two branch tips right now.
DIVERGED_LIST=$(git diff --name-only "origin/${DEFAULT_BRANCH}" "origin/${PR_BASE_BRANCH}" 2>/dev/null)

if [ -n "$MERGE_BASE" ]; then
  STAGING_SIDE_RAW=$(git diff --name-only "$MERGE_BASE" "origin/${PR_BASE_BRANCH}" 2>/dev/null)
  MASTER_SIDE_RAW=$(git diff --name-only "$MERGE_BASE" "origin/${DEFAULT_BRANCH}" 2>/dev/null)
else
  STAGING_SIDE_RAW=""; MASTER_SIDE_RAW=""
fi

# A path CHANGED since the merge base is not necessarily a path that still
# DIVERGES: if both branches made the same edit to a.txt, a.txt appears on both
# side-lists yet the trees agree on it (CR round 1.2). Counting it would report
# direction "both" — and possibly unpromoted work — for a repo where only the
# other branch's file actually differs. This is the same convergent-content case
# test 2 pins down at the whole-tree level, one level finer. So intersect each
# side-list with the paths that genuinely differ now, and count only those.
_intersect_with_diverged() {  # stdin: candidate paths → stdout: those still diverging
  if [ -z "$DIVERGED_LIST" ]; then cat >/dev/null; return 0; fi
  grep -Fx -f <(printf '%s\n' "$DIVERGED_LIST") 2>/dev/null || true
}
STAGING_SIDE=$(printf '%s\n' "$STAGING_SIDE_RAW" | grep -v '^$' | _intersect_with_diverged)
MASTER_SIDE=$(printf '%s\n' "$MASTER_SIDE_RAW"  | grep -v '^$' | _intersect_with_diverged)

UNPROMOTED_FILES=$(printf '%s' "$STAGING_SIDE" | grep -c . || true)
BEHIND_FILES=$(printf '%s' "$MASTER_SIDE" | grep -c . || true)

if git diff --quiet "origin/${DEFAULT_BRANCH}" "origin/${PR_BASE_BRANCH}" 2>/dev/null; then
  CONTENT_DIVERGED=no
  DIVERGED_FILES=0
  DIVERGED_PATHS=""
  DIVERGE_DIRECTION=none
else
  CONTENT_DIVERGED=yes
  DIVERGED_PATHS=$(git diff --name-only "origin/${DEFAULT_BRANCH}" "origin/${PR_BASE_BRANCH}" 2>/dev/null | head -20 | paste -sd, - )
  DIVERGED_FILES=$(git diff --name-only "origin/${DEFAULT_BRANCH}" "origin/${PR_BASE_BRANCH}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$UNPROMOTED_FILES" -gt 0 ] && [ "$BEHIND_FILES" -gt 0 ]; then
    DIVERGE_DIRECTION=both
  elif [ "$UNPROMOTED_FILES" -gt 0 ]; then
    DIVERGE_DIRECTION=staging-ahead
  elif [ "$BEHIND_FILES" -gt 0 ]; then
    DIVERGE_DIRECTION=master-ahead
  else
    # Trees differ but neither side changed relative to the merge base — only
    # reachable if the merge base could not be resolved. Say so rather than
    # guessing a direction.
    DIVERGE_DIRECTION=unknown
  fi
fi
echo "CONTENT_DIVERGED=${CONTENT_DIVERGED}"
echo "DIVERGE_DIRECTION=${DIVERGE_DIRECTION}"
echo "DIVERGED_FILES=${DIVERGED_FILES}"
echo "UNPROMOTED_FILES=${UNPROMOTED_FILES}"
echo "BEHIND_FILES=${BEHIND_FILES}"
[ -n "$DIVERGED_PATHS" ] && echo "DIVERGED_PATHS=${DIVERGED_PATHS}"

# A threshold inherited from the commit-counting era (e.g. 150) is meaningless
# against the new measure and would silently disable the gate. Say so rather
# than letting it pass unnoticed — a gate that cannot fire should never look
# like a gate that is passing.
if [ "$BLOCK_THRESHOLD" -ge 50 ] 2>/dev/null; then
  echo "THRESHOLD_NOTICE=staging_drift_block_threshold=${BLOCK_THRESHOLD} looks like a commit-counting-era value (INF-277 changed the measure to unpromoted files). Consider lowering it in .claude/develop-config.json."
fi

# --- Classify ---
# Recovery advice must name an action that actually reduces the measured
# quantity. The pre-INF-277 text told the operator to re-run the staging sync,
# which ADDS a staging commit — advice that made the number worse.
# Recovery advice is DIRECTION-SPECIFIC. The pre-INF-277 text always pointed at
# the staging sync, which for unpromoted work adds a staging commit and makes
# things worse — but for a master-ahead hotfix the sync is exactly right. Naming
# the wrong one is worse than naming none, so each direction gets its own.
PROMOTE_ADVICE="Promote the outstanding work to ${DEFAULT_BRANCH} (merge its ${PR_BASE_BRANCH}→${DEFAULT_BRANCH} promotion PR, or open one for the paths above), then re-run."
SYNC_ADVICE="Bring ${PR_BASE_BRANCH} up to date with ${DEFAULT_BRANCH} (the post-deploy 'sync staging with master' job, master_deploy_pipeline.yaml :: sync-staging-branch), then re-run."
BYPASS="Bypass for one run with ALLOW_STAGING_DRIFT=1."

case "$DIVERGE_DIRECTION" in
  staging-ahead) RECOVERY="$PROMOTE_ADVICE $BYPASS" ;;
  master-ahead)  RECOVERY="$SYNC_ADVICE $BYPASS" ;;
  both)          RECOVERY="Both branches carry changes the other lacks. $PROMOTE_ADVICE Then: $SYNC_ADVICE $BYPASS" ;;
  *)             RECOVERY="Inspect the diverging paths above before starting new work. $BYPASS" ;;
esac

if [ "$CONTENT_DIVERGED" = "no" ]; then
  # Identical trees: nothing is unpromoted, regardless of DRIFT_COUNT.
  echo "VERDICT=clean"
elif [ "$DIVERGE_DIRECTION" = "master-ahead" ]; then
  # Nothing is unpromoted — staging is simply behind. That is the sync job's
  # normal window and never a reason to block the start of new work.
  echo "VERDICT=advisory"
  echo "MESSAGE=${PR_BASE_BRANCH} is behind ${DEFAULT_BRANCH} by ${BEHIND_FILES} file(s) [${DIVERGED_PATHS}]. Nothing is unpromoted. ${RECOVERY}"
elif [ "$UNPROMOTED_FILES" -lt "$BLOCK_THRESHOLD" ]; then
  echo "VERDICT=advisory"
  echo "MESSAGE=${PR_BASE_BRANCH} has ${UNPROMOTED_FILES} file(s) not on ${DEFAULT_BRANCH} [${DIVERGED_PATHS}]. Normal while a promotion is in flight. ${RECOVERY}"
else
  echo "VERDICT=block"
  echo "MESSAGE=${PR_BASE_BRANCH} has ${UNPROMOTED_FILES} file(s) not on ${DEFAULT_BRANCH} (>= threshold ${BLOCK_THRESHOLD}) [${DIVERGED_PATHS}]. New feature PRs may be structurally un-mergeable against ${PR_BASE_BRANCH}. ${RECOVERY}"
fi

# --- Optional gh-backed diagnosis (best-effort; never fails the script) ---
if [ "$DIAGNOSE" = true ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "SYNC_STATUS=unknown"
    echo "PENDING_PROMOTION_PRS=unknown"
    echo "MASTER_DEPLOY_ALERT=unknown (gh CLI not available)"
  else
    # AC3 — master-deploy failure alert. Scan recent master-branch runs of the
    # master-deploy workflow. Emit a greppable alert when the most recent run
    # concluded failure and no later run for the same head SHA succeeded.
    MASTER_RUNS=$(gh run list --workflow "master_deploy_pipeline.yaml" --branch "$DEFAULT_BRANCH" \
                    -L 12 --json databaseId,headSha,conclusion,status,createdAt 2>/dev/null || echo "")
    if [ -n "$MASTER_RUNS" ] && command -v jq >/dev/null 2>&1; then
      # For each headSha keep its latest conclusion; alert on any SHA whose
      # latest concluded run is a failure (i.e. not later rescued by a success).
      ALERT=$(printf '%s' "$MASTER_RUNS" | jq -r '
        [ .[] | select(.status == "completed") ]
        | group_by(.headSha)
        | map(max_by(.createdAt))
        | map(select(.conclusion == "failure"))
        | sort_by(.createdAt) | reverse | .[0]
        | if . == null then empty
          else "DASH-2338 master-deploy-failure run=\(.databaseId) sha=\(.headSha[0:8]) at=\(.createdAt)"
          end' 2>/dev/null)
      if [ -n "$ALERT" ]; then
        echo "MASTER_DEPLOY_ALERT=${ALERT}"
      else
        echo "MASTER_DEPLOY_ALERT=none (no unrescued master-deploy failure in last 12 runs)"
      fi
    else
      echo "MASTER_DEPLOY_ALERT=unknown (could not query master-deploy runs)"
    fi

    # AC2 — skipped-sync detection. After a successful master deploy the
    # sync-staging-branch job opens a master→staging sync PR ("chore... sync
    # staging with master ..."). If drift > 0 AND no such sync PR is open or
    # recently merged, the sync likely did not fire (the re-run skip case).
    SYNC_PRS=$(gh pr list --head "$DEFAULT_BRANCH" --base "$PR_BASE_BRANCH" --state all -L 5 \
                 --json number,title,state,createdAt 2>/dev/null || echo "")
    if [ -n "$SYNC_PRS" ] && command -v jq >/dev/null 2>&1; then
      RECENT_SYNC=$(printf '%s' "$SYNC_PRS" | jq -r '
        [ .[] | select(.title | test("sync staging with master")) ]
        | sort_by(.createdAt) | reverse | .[0]
        | if . == null then "" else "#\(.number) (\(.state))" end' 2>/dev/null)
      if [ "$DRIFT_COUNT" -gt 0 ] && [ -z "$RECENT_SYNC" ]; then
        echo "SYNC_STATUS=skipped"
      elif [ -n "$RECENT_SYNC" ]; then
        echo "SYNC_STATUS=ran (latest sync PR ${RECENT_SYNC})"
      else
        echo "SYNC_STATUS=ran"
      fi
    else
      echo "SYNC_STATUS=unknown"
    fi

    # Recovery targets — open promotion PRs the operator can merge to catch
    # master up. These are feature→master / staging→master PRs (base=master).
    PROMO=$(gh pr list --base "$DEFAULT_BRANCH" --state open -L 30 --json number \
              --jq '[.[].number] | map("#" + (.|tostring)) | join(" ")' 2>/dev/null || echo "")
    if [ -n "$PROMO" ]; then
      echo "PENDING_PROMOTION_PRS=${PROMO}"
    else
      echo "PENDING_PROMOTION_PRS=none"
    fi
  fi
fi

exit 0
