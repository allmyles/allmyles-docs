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
# The drift measured is `git rev-list --count origin/<default>..origin/<base>`
# = commits on the PR base branch (staging) NOT yet on the default branch
# (master) = unpromoted feature merges. The gate is fail-safe: it never mutates
# master or staging — it only reports, and (in the /develop caller) blocks the
# START of new work.
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

# --- Classify ---
RECOVERY="Resolve before starting new feature work: merge the pending ${PR_BASE_BRANCH}→${DEFAULT_BRANCH} promotion PRs (gh pr list --base ${DEFAULT_BRANCH} --state open), or re-run the post-deploy 'sync staging with master' job (master_deploy_pipeline.yaml :: sync-staging-branch). Bypass for one run with ALLOW_STAGING_DRIFT=1."

if [ "$DRIFT_COUNT" -eq 0 ]; then
  echo "VERDICT=clean"
elif [ "$DRIFT_COUNT" -lt "$BLOCK_THRESHOLD" ]; then
  echo "VERDICT=advisory"
  echo "MESSAGE=${DEFAULT_BRANCH} is ${DRIFT_COUNT} commit(s) behind ${PR_BASE_BRANCH} (below block threshold ${BLOCK_THRESHOLD}). Normal mid-promotion lag, but watch it: ${RECOVERY}"
else
  echo "VERDICT=block"
  echo "MESSAGE=${DEFAULT_BRANCH} is ${DRIFT_COUNT} commit(s) behind ${PR_BASE_BRANCH} (>= block threshold ${BLOCK_THRESHOLD}). The post-deploy staging-sync has not reconciled them; new feature PRs may be structurally un-mergeable against staging. ${RECOVERY}"
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
