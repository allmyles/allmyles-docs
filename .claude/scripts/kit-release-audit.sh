#!/usr/bin/env bash
# kit-release-audit.sh (INF-202) — per-consumer release-reach audit.
#
# The kit repo's real "done" is not "merged to kit master" — it is "the
# release reached every consumers.yaml master". This script formalizes the
# audit that was session-improvised on every release since 0.4.13:
#
#   1. Resolve the EXPECTED SHA (kit master HEAD, or --expected-sha).
#   2. Find the kit_release_fanout run for it, wait (bounded) for it to
#      finish, and collect its FANOUT_RESULT lines (best effort — the
#      audit's authority is the PINS, not the fan-out log).
#   3. Poll every consumers.yaml repo's master .claude/claude-kit-pin.json
#      until kitSha == EXPECTED or the deadline passes.
#   4. For stragglers, list open kit-upgrade/* and master-promotion PRs
#      with the known-remedy hint (auto-approve guard gaps: APY-1431 /
#      MYST-32 class). The audit NAMES manual unsticks; it never performs
#      them — approvals stay operator-authorized.
#   5. (INF-255) For every REACHED consumer, resolve its master-DEPLOY
#      conclusion (from develop-config kit_auto_close.master_deploy_workflow_name)
#      and poll — within the same deadline — while any is still building.
#      "Reached" is MERGED; "done" additionally requires DEPLOYED. A failed
#      deploy is surfaced loudly; an in-progress one keeps the verdict PARTIAL
#      so the release is never reported live mid-deploy. Consumers with no
#      kit-tracked master deploy (static sites, Cloudflare-external) are
#      "external" and never block; a .claude-only path-ignore-skipped delivery
#      reads as "no-run" and never blocks.
#
# Output: human table on stdout plus machine-parsable lines:
#   AUDIT_CONSUMER repo=<r> pin=<8sha|none> status=<reached|pending>
#   AUDIT_DEPLOY repo=<r> deploy=<deployed|in_progress|failed|no-run|external|lookupfail>
#   AUDIT_RESULT=<ALL_REACHED|PARTIAL|INFRA_ERROR> reached=<n> pending=<n> expected=<8sha> self=<..> deploy_failed=<n> deploy_inprogress=<n> deploy_unresolved=<n>
# Exit: 0 all reached AND all deploys concluded (no fail/in_progress), 1 partial
# (pin-pending OR deploy failed/in_progress), 2 infra error (not a kit checkout,
# gh missing, expected SHA unresolvable).
#
# Usage: kit-release-audit.sh [--expected-sha SHA] [--timeout SECS] [--no-wait]
# Env (tests): KIT_AUDIT_GH (gh bin), KIT_AUDIT_CONSUMERS_YAML,
#              KIT_AUDIT_POLL_INTERVAL (default 30)

set -uo pipefail

GH="${KIT_AUDIT_GH:-gh}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONSUMERS_YAML="${KIT_AUDIT_CONSUMERS_YAML:-}"
EXPECTED=""
TIMEOUT=900
POLL_INTERVAL="${KIT_AUDIT_POLL_INTERVAL:-30}"
WAIT_FANOUT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --expected-sha) EXPECTED="${2:?--expected-sha needs a value}"; shift 2 ;;
        --timeout)      TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
        --no-wait)      WAIT_FANOUT=0; shift ;;
        *) echo "unknown argument: $1" >&2; echo "AUDIT_RESULT=INFRA_ERROR reached=0 pending=0 expected=none"; exit 2 ;;
    esac
done

command -v "$GH" >/dev/null 2>&1 || {
    echo "gh CLI not available — cannot audit" >&2
    echo "AUDIT_RESULT=INFRA_ERROR reached=0 pending=0 expected=none"; exit 2
}

# ── Locate consumers.yaml (kit checkout root; script may run from the
#    kit's own .claude/scripts copy) ─────────────────────────────────────
if [ -z "$CONSUMERS_YAML" ]; then
    for cand in "${SCRIPT_DIR}/../../../consumers.yaml" "${SCRIPT_DIR}/../../consumers.yaml" "$PWD/consumers.yaml"; do
        [ -f "$cand" ] && { CONSUMERS_YAML="$cand"; break; }
    done
fi
if [ -z "$CONSUMERS_YAML" ] || [ ! -f "$CONSUMERS_YAML" ]; then
    echo "consumers.yaml not found — this audit only runs from a claude-kit checkout" >&2
    echo "AUDIT_RESULT=INFRA_ERROR reached=0 pending=0 expected=none"; exit 2
fi
# INF-203/INF-205: the kit's own self-entry (consumers.yaml records
# allmyles/claude-kit for self-adoption, INF-179) is excluded from PIN
# polling — the fan-out never delivers to the kit repo, so its pin can
# never equal a fresh release SHA (first live run, 0.4.20, reported
# PARTIAL forever). INF-205 upgrades the bare skip to a real SELF check
# (kit master CI + committed-copies parity at the expected SHA) — see
# the self-audit block after the consumer sweep.
ALL_ENTRIES="$(awk '$1=="-" && $2=="repo:" {print $3}' "$CONSUMERS_YAML")"
SELF_PRESENT=0
if printf '%s\n' "$ALL_ENTRIES" | grep -qx "allmyles/claude-kit"; then
    SELF_PRESENT=1
fi
CONSUMERS="$(printf '%s\n' "$ALL_ENTRIES" | grep -vx "allmyles/claude-kit" || true)"
[ -n "$CONSUMERS" ] || {
    echo "no repos parsed from ${CONSUMERS_YAML}" >&2
    echo "AUDIT_RESULT=INFRA_ERROR reached=0 pending=0 expected=none"; exit 2
}

# ── Expected SHA ────────────────────────────────────────────────────────
if [ -z "$EXPECTED" ]; then
    EXPECTED="$("$GH" api /repos/allmyles/claude-kit/commits/master --jq .sha 2>/dev/null)"
fi
if [ -z "$EXPECTED" ]; then
    echo "could not resolve the expected kit SHA (gh api failed and no --expected-sha)" >&2
    echo "AUDIT_RESULT=INFRA_ERROR reached=0 pending=0 expected=none"; exit 2
fi
echo "Release-reach audit — expected kit SHA: ${EXPECTED:0:8}"

# ONE deadline for the WHOLE audit (CR round 1.1: separate per-phase
# deadlines let --timeout 900 run Step 15 for ~30 min).
AUDIT_DEADLINE=$((SECONDS + TIMEOUT))

# ── Phase 1: fan-out run (best effort; pins are the authority) ─────────
if [ "$WAIT_FANOUT" = "1" ]; then
    # CR round 1.1: select the run FOR THIS SHA (--commit) — the newest
    # run may belong to a different release and would produce unrelated
    # diagnostics.
    RUN_ID="$("$GH" run list -R allmyles/claude-kit --workflow kit_release_fanout.yaml --commit "$EXPECTED" -L 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    if [ -n "$RUN_ID" ]; then
        while [ "$SECONDS" -lt "$AUDIT_DEADLINE" ]; do
            ST="$("$GH" run view "$RUN_ID" -R allmyles/claude-kit --json status --jq .status 2>/dev/null)"
            [ "$ST" = "completed" ] && break
            sleep "$POLL_INTERVAL"
        done
        echo "── fan-out run ${RUN_ID}:"
        "$GH" run view "$RUN_ID" -R allmyles/claude-kit --log 2>/dev/null \
            | grep -oE 'FANOUT_RESULT=[A-Z_]+ repo=[^ ]+( pr=[^ ]+)?( automerge=[a-z-]+)?( companion=[a-z]+)?' \
            | sed 's/^/   /' || echo "   (log unavailable)"
    else
        echo "── fan-out run not found for ${EXPECTED:0:8} (workflow may not have fired) — auditing pins directly"
    fi
fi

# ── Phase 2: pin polling ───────────────────────────────────────────────
# pin_of echoes "<rc> <sha>" — rc is the gh api call's status, sha is
# empty when the repo genuinely has no pin. The rc travels IN the output
# because `PIN=$(pin_of …)` runs the function in a subshell, where a
# global assignment would die (the kit_fanout_consumer/kit-doctor
# subshell-variable bug class, INF-187). CR round 1.1: a FAILED lookup
# (auth, network, rate limit) must not masquerade as a merely-pending
# consumer — during polling it retries like pending; in the FINAL sweep
# it flips the audit to INFRA_ERROR.
# INF-211: read the pin from an EXPLICIT ref when given. The bug: a
# ref-less Contents API call returns the repo's DEFAULT branch, so a
# staging-master consumer whose master carries the expected SHA (fan-out
# committed to default=master, or a prior promotion) reported `reached`
# while its staging branch — the branch the delivery PR actually targets —
# still lagged (whitelabel-internal PR #603). `pin_of` keeps the ref-less
# default-branch read for single-branch consumers; the staging-aware path
# passes the base branch explicitly.
pin_at_ref() {  # $1=repo [$2=ref] → stdout "<rc> <sha-or-empty>"
    local url raw rc
    url="repos/$1/contents/.claude/claude-kit-pin.json"
    [ -n "${2:-}" ] && url="${url}?ref=$2"
    raw="$("$GH" api "$url" --jq '.content' 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "$rc "
        return
    fi
    echo "0 $(printf '%s' "$raw" | base64 -d 2>/dev/null | jq -r '.kitSha // ""' 2>/dev/null)"
}
pin_of() { pin_at_ref "$1"; }  # back-compat: default-branch read

# INF-211: a consumer's repo shape decides which branch's pin proves reach.
# Read the consumer's committed .claude/develop-config.json (default branch).
# Absent/unreadable → treat as single-branch (config-less consumers — static
# sites, docs, sandbox — keep the pure default-branch check; this preserves
# the pre-INF-211 behavior for them). Echoes "<shape> <pr_base_branch>".
# CR round 1.1 (finding 1): distinguish a CONFIRMED-absent config (HTTP
# 404 → the consumer genuinely has no develop-config, so single-branch)
# from any OTHER gh failure (transient / auth / rate-limit → indeterminate,
# NOT single-branch). Collapsing every failure to single-branch would skip
# the staging-pin check and re-open the same false-`reached` this ticket
# closes. `gh api` exits 1 for both 404 and 5xx, so the HTTP status is only
# in stderr — grep it. Shape ∈ staging-master | single-branch | unreadable.
shape_of() {  # $1=repo → stdout "<shape> <pr_base_branch>"
    local raw rc errf cfg shape base
    errf="$(mktemp -t kra-shape-XXXXXX 2>/dev/null)" || errf=""
    if [ -n "$errf" ]; then
        raw="$("$GH" api "repos/$1/contents/.claude/develop-config.json" --jq '.content' 2>"$errf")"
    else
        raw="$("$GH" api "repos/$1/contents/.claude/develop-config.json" --jq '.content' 2>/dev/null)"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # 404 (or empty stderr — mktemp failed, can't classify) → treat as
        # config-absent single-branch; any identifiable non-404 error →
        # unreadable so reach_of degrades to pending rather than skipping
        # the staging check.
        if [ -z "$errf" ] || grep -qiE 'HTTP 404|Not Found' "$errf" 2>/dev/null; then
            [ -n "$errf" ] && rm -f "$errf"
            echo "single-branch "
            return
        fi
        rm -f "$errf"
        echo "unreadable "
        return
    fi
    [ -n "$errf" ] && rm -f "$errf"
    if [ -z "$raw" ]; then
        echo "single-branch "
        return
    fi
    cfg="$(printf '%s' "$raw" | base64 -d 2>/dev/null)"
    shape="$(printf '%s' "$cfg" | jq -r '.shape // "single-branch"' 2>/dev/null)"
    base="$(printf '%s' "$cfg" | jq -r '.pr_base_branch // "staging"' 2>/dev/null)"
    [ -z "$shape" ] && shape="single-branch"
    echo "$shape $base"
}

# INF-211: an open kit-upgrade/* delivery PR to the staging base means the
# staging-side delivery has not fully landed, regardless of what the pins
# read. CR round 1.1 (finding 2): propagate the gh exit code IN the output
# (the pin_at_ref pattern) so a lookup FAILURE is not swallowed as
# "confirmed no PR" — that was another path back to a false `reached`.
# Echoes "<rc> <pr-number-or-empty>".
has_open_kit_delivery_pr() {  # $1=repo $2=base → "<rc> <pr-number-or-empty>"
    local out rc
    out="$("$GH" pr list -R "$1" --state open --base "$2" --json number,headRefName \
        --jq '[.[] | select(.headRefName | startswith("kit-upgrade/"))][0].number // empty' 2>/dev/null)"
    rc=$?
    echo "$rc $out"
}

# INF-211: single reach predicate shared by the poll loop AND the final
# sweep (so the two can never diverge). CR round 1.1 (nitpick 1, bash-3.2
# safe): shape/base are precomputed once per repo and passed in — no
# per-poll-tick develop-config re-fetch. Echoes:
#   "<status>|<master_sha>|<staging_sha>|<delivery_pr>|<reason>"
#   status ∈ reached | pending | lookupfail
reach_of() {  # $1=repo $2=shape $3=base
    local repo="$1" shp="$2" base="$3" mo mrc msha so src ssha dpo dprc dp
    mo="$(pin_at_ref "$repo")"; mrc="${mo%% *}"; msha="${mo#* }"
    if [ "$mrc" != "0" ]; then
        # Default-branch lookup failure is the infra canary (unchanged).
        echo "lookupfail||||master-lookup"
        return
    fi
    if [ "$shp" = "unreadable" ]; then
        # Could not read the consumer's shape → cannot know which branch
        # proves reach; pending, never a silent single-branch downgrade.
        echo "pending|${msha}|||shape-unreadable"
        return
    fi
    if [ "$shp" = "staging-master" ] && [ -n "$base" ]; then
        so="$(pin_at_ref "$repo" "$base")"; src="${so%% *}"; ssha="${so#* }"
        if [ "$src" != "0" ]; then
            # Staging unreadable (missing branch/file, transient) → cannot
            # confirm reach; pending, never infra (the master read already
            # covers true outages, so a staging hiccup must not flip the
            # whole audit to INFRA_ERROR).
            echo "pending|${msha}|||staging-unreadable"
            return
        fi
        dpo="$(has_open_kit_delivery_pr "$repo" "$base")"; dprc="${dpo%% *}"; dp="${dpo#* }"
        if [ "$dprc" != "0" ]; then
            # PR-list lookup failed → indeterminate, not "confirmed no PR".
            echo "pending|${msha}|${ssha}||delivery-lookup-failed"
            return
        fi
        if [ "$msha" = "$EXPECTED" ] && [ "$ssha" = "$EXPECTED" ] && [ -z "$dp" ]; then
            echo "reached|${msha}|${ssha}||"
        else
            local reason=""
            [ "$msha" != "$EXPECTED" ] && reason="master-lag"
            [ "$ssha" != "$EXPECTED" ] && reason="${reason:+$reason,}staging-lag"
            [ -n "$dp" ] && reason="${reason:+$reason,}delivery-open#${dp}"
            echo "pending|${msha}|${ssha}|${dp}|${reason}"
        fi
    else
        if [ "$msha" = "$EXPECTED" ]; then
            echo "reached|${msha}|||"
        else
            echo "pending|${msha}|||master-lag"
        fi
    fi
}

# ── INF-255: per-consumer master-DEPLOY status ─────────────────────────
# "Reached" (pin == EXPECTED) means the release MERGED to the consumer's
# master — NOT that it DEPLOYED. A consumer whose master-deploy pipeline is
# still building, or has FAILED, is not done; reporting ALL_REACHED then
# overclaims (the operator observation on the 0.4.52 fan-out: reached 4/8 by
# pin while four master deploys were still in_progress). These two helpers
# resolve each consumer's master-deploy workflow + its conclusion.

# deploy_workflow_of: the consumer's master-deploy workflow DISPLAY NAME, read
# from its committed develop-config kit_auto_close.master_deploy_workflow_name
# (the same field the auto-close-on-master-deploy workflow watches). Empty →
# the consumer declares no kit-tracked master deploy (static site, Cloudflare-
# external, no ORM) → the caller classifies it "external" (non-blocking).
deploy_workflow_of() {  # $1=repo → stdout "<name>" | "" (404/none) | "__lookupfail__"
    # CR round 1.1 (Major): mirror shape_of's 404-vs-other-error handling. A
    # genuine 404 (config absent) → "" (→ external, non-blocking). ANY OTHER
    # failure (auth / rate-limit / network) → the __lookupfail__ sentinel so
    # deploy_status_of reports lookupfail rather than silently collapsing a
    # transient error into the PERMANENT "external" classification (which would
    # hide an unchecked deploy and could let ALL_REACHED pass).
    local raw cfg errf rc
    errf="$(mktemp -t kra-deploywf-err-XXXXXX 2>/dev/null)" || errf=""
    if [ -n "$errf" ]; then
        raw="$("$GH" api "repos/$1/contents/.claude/develop-config.json" --jq '.content' 2>"$errf")"
    else
        raw="$("$GH" api "repos/$1/contents/.claude/develop-config.json" --jq '.content' 2>/dev/null)"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -n "$errf" ] && ! grep -qiE 'HTTP 404|Not Found' "$errf" 2>/dev/null; then
            rm -f "$errf"; echo "__lookupfail__"; return
        fi
        [ -n "$errf" ] && rm -f "$errf"
        echo ""; return   # 404 (or unclassifiable — mktemp failed) → config absent
    fi
    [ -n "$errf" ] && rm -f "$errf"
    [ -z "$raw" ] && { echo ""; return; }
    cfg="$(printf '%s' "$raw" | base64 -d 2>/dev/null)"
    printf '%s' "$cfg" | jq -r '.kit_auto_close.master_deploy_workflow_name // ""' 2>/dev/null
}

# deploy_status_of: the conclusion of the newest run of workflow $2 on repo
# $1's default-branch HEAD. Match by DISPLAY NAME (not --workflow, which wants
# a file/ID) so the develop-config name resolves directly. Echoes one of:
#   deployed    — a run for HEAD concluded success
#   failed      — a run for HEAD concluded non-success (loud; blocks done)
#   in_progress — a run for HEAD is queued/in_progress (blocks done; polled)
#   no-run      — no run for HEAD (a .claude-only path-ignore-skipped delivery,
#                 or the pipeline simply never fires for this consumer) — non-
#                 blocking: nothing deployed BECAUSE nothing needed to
#   external    — $2 empty: consumer has no kit-tracked master deploy — non-blocking
#   lookupfail  — gh api failed resolving the branch/HEAD/runs — non-blocking
#                 (the pin sweep already flips true outages to INFRA_ERROR)
deploy_status_of() {  # $1=repo $2=workflow-name → stdout "<status>"
    local repo="$1" wf="$2" defbr head runs sc
    # CR round 1.1 (Major): a transient develop-config error surfaces here as
    # the __lookupfail__ sentinel — report lookupfail, do NOT treat as external.
    [ "$wf" = "__lookupfail__" ] && { echo "lookupfail"; return; }
    [ -z "$wf" ] && { echo "external"; return; }
    defbr="$("$GH" api "repos/$repo" --jq '.default_branch' 2>/dev/null)" || { echo "lookupfail"; return; }
    [ -z "$defbr" ] && { echo "lookupfail"; return; }
    head="$("$GH" api "repos/$repo/commits/$defbr" --jq '.sha' 2>/dev/null)" || { echo "lookupfail"; return; }
    [ -z "$head" ] && { echo "lookupfail"; return; }
    # Newest run whose display name AND headSha match the default-branch HEAD.
    # CR round 1.1 (Major, security): fetch RAW JSON and select with
    # `jq --arg` — NEVER interpolate the (config-sourced) workflow name into a
    # jq program string, where a crafted name could rewrite the filter and make
    # an unrelated run masquerade as the deploy result.
    runs="$("$GH" run list -R "$repo" -L 40 --json name,headSha,status,conclusion 2>/dev/null)"
    sc="$(printf '%s' "$runs" | jq -r --arg wf "$wf" --arg head "$head" \
        '[.[] | select(.name==$wf and .headSha==$head)][0]
         | if . == null then "" else .status + "/" + (.conclusion // "") end' 2>/dev/null)"
    case "$sc" in
        completed/success)                     echo "deployed" ;;
        completed/"")                          echo "in_progress" ;;  # completed but conclusion not yet populated
        completed/*)                           echo "failed" ;;       # failure/timed_out/cancelled/action_required/…
        ""|"null")                             echo "no-run" ;;       # no run for this HEAD
        */*)                                   echo "in_progress" ;;  # queued/in_progress/waiting/…
        *)                                     echo "no-run" ;;
    esac
}

# CR round 1.1 (nitpick 1): shape is static for the audit's lifetime, so
# resolve it ONCE per repo into a tab-separated memo file (bash-3.2 safe —
# no `declare -A`) that both the poll loop and the final sweep read.
SHAPE_CACHE_FILE="$(mktemp -t kra-shapes-XXXXXX 2>/dev/null || echo "")"
cached_shape() {  # $1=repo → "<shape> <base>" (recomputes if no cache file)
    if [ -n "$SHAPE_CACHE_FILE" ] && [ -f "$SHAPE_CACHE_FILE" ]; then
        local hit
        hit="$(awk -F'\t' -v r="$1" '$1==r {print $2; exit}' "$SHAPE_CACHE_FILE")"
        [ -n "$hit" ] && { printf '%s' "$hit"; return; }
    fi
    shape_of "$1"
}
if [ -n "$SHAPE_CACHE_FILE" ]; then
    for repo in $CONSUMERS; do
        printf '%s\t%s\n' "$repo" "$(shape_of "$repo")" >> "$SHAPE_CACHE_FILE"
    done
fi

# INF-255: the master-deploy workflow name is likewise static for the run —
# memoize it once per repo (same bash-3.2-safe memo-file pattern).
DEPLOY_WF_CACHE_FILE="$(mktemp -t kra-deploywf-XXXXXX 2>/dev/null || echo "")"
cached_deploy_wf() {  # $1=repo → "<workflow-name-or-empty>"
    if [ -n "$DEPLOY_WF_CACHE_FILE" ] && [ -f "$DEPLOY_WF_CACHE_FILE" ]; then
        local hit
        hit="$(awk -F'\t' -v r="$1" '$1==r {print $2; exit}' "$DEPLOY_WF_CACHE_FILE")"
        # A repo with an empty deploy name is a legitimate memo hit (external);
        # distinguish "cached empty" from "not cached" via a sentinel column.
        if awk -F'\t' -v r="$1" '$1==r {found=1} END {exit found?0:1}' "$DEPLOY_WF_CACHE_FILE"; then
            printf '%s' "$hit"; return
        fi
    fi
    deploy_workflow_of "$1"
}
# CR round 1.1 (nitpick): do NOT eagerly resolve deploy-workflow names for the
# whole fleet — deploy status is only checked for REACHED consumers (a
# consumer still pending on its pin has deployed nothing to master). The cache
# is populated for exactly the reached set just before the deploy poll below,
# so pending consumers never incur a develop-config fetch for their (unused)
# deploy name.

# Single EXIT trap that cleans every memo file (bash-3.2 safe).
trap 'rm -f "$SHAPE_CACHE_FILE" "$DEPLOY_WF_CACHE_FILE" "${DEPLOY_STATUS_FILE:-}"' EXIT

PENDING="$CONSUMERS"
declare -a REACHED_LIST=()
while : ; do
    STILL=""
    for repo in $PENDING; do
        # INF-211: reach is shape-aware (master + staging pin + open
        # delivery PR for staging-master consumers), not a ref-less
        # default-branch pin. Lookup failures retry like pending here;
        # the final sweep is where they become INFRA_ERROR.
        read -r _shp _base <<<"$(cached_shape "$repo")"
        if [ "$(reach_of "$repo" "$_shp" "$_base" | cut -d'|' -f1)" = "reached" ]; then
            REACHED_LIST+=("$repo")
        else
            STILL="${STILL}${repo}"$'\n'
        fi
    done
    PENDING="$(printf '%s' "$STILL" | sed '/^$/d')"
    [ -z "$PENDING" ] && break
    [ "$SECONDS" -ge "$AUDIT_DEADLINE" ] && break
    sleep "$POLL_INTERVAL"
done

# ── Phase 2b (INF-255): master-DEPLOY status of the REACHED consumers ──
# For every consumer that MERGED (pin == EXPECTED), resolve its master-deploy
# conclusion and — bounded by the SAME audit deadline — poll while any is
# still in_progress, so the audit does not report "done" mid-deploy. Results
# land in a memo file (repo<TAB>status) the report + result gating both read.
# Consumers still PENDING on pins aren't checked here (nothing has deployed to
# their master yet); their pin-lag is the operative signal.
DEPLOY_STATUS_FILE="$(mktemp -t kra-deploystatus-XXXXXX 2>/dev/null || echo "")"
if [ -n "$DEPLOY_STATUS_FILE" ] && [ "${#REACHED_LIST[@]}" -gt 0 ]; then
    # Resolve each reached consumer's deploy-workflow name ONCE (static for the
    # run) into the cache, so the poll ticks below reuse it without re-fetching.
    if [ -n "$DEPLOY_WF_CACHE_FILE" ]; then
        for repo in "${REACHED_LIST[@]}"; do
            printf '%s\t%s\n' "$repo" "$(deploy_workflow_of "$repo")" >> "$DEPLOY_WF_CACHE_FILE"
        done
    fi
    while : ; do
        : > "$DEPLOY_STATUS_FILE"
        DEPLOY_INPROG=0
        for repo in "${REACHED_LIST[@]}"; do
            dwf="$(cached_deploy_wf "$repo")"
            dst="$(deploy_status_of "$repo" "$dwf")"
            printf '%s\t%s\n' "$repo" "$dst" >> "$DEPLOY_STATUS_FILE"
            [ "$dst" = "in_progress" ] && DEPLOY_INPROG=$((DEPLOY_INPROG + 1))
        done
        [ "$DEPLOY_INPROG" -eq 0 ] && break
        [ "$SECONDS" -ge "$AUDIT_DEADLINE" ] && break
        sleep "$POLL_INTERVAL"
    done
fi
deploy_status_for() {  # $1=repo → cached deploy status, or "" if unresolved
    [ -n "$DEPLOY_STATUS_FILE" ] && [ -f "$DEPLOY_STATUS_FILE" ] || { echo ""; return; }
    awk -F'\t' -v r="$1" '$1==r {print $2; exit}' "$DEPLOY_STATUS_FILE"
}

# ── Report ─────────────────────────────────────────────────────────────
REACHED_COUNT=${#REACHED_LIST[@]}
DEPLOY_FAILED_COUNT=0
DEPLOY_INPROGRESS_COUNT=0
DEPLOY_UNRESOLVED_COUNT=0
PENDING_COUNT=0; [ -n "$PENDING" ] && PENDING_COUNT="$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')"
echo "── consumer masters:"
INFRA_FAIL=0
for repo in $CONSUMERS; do
    # INF-211: shape-aware reach. Parse reach_of's pipe-record so the human
    # + machine lines carry the staging pin + pending reason, not just the
    # default-branch pin the pre-INF-211 sweep read.
    read -r _shp _base <<<"$(cached_shape "$repo")"
    R="$(reach_of "$repo" "$_shp" "$_base")"
    R_STATUS="$(printf '%s' "$R" | cut -d'|' -f1)"
    R_MSHA="$(printf '%s' "$R" | cut -d'|' -f2)"
    R_SSHA="$(printf '%s' "$R" | cut -d'|' -f3)"
    R_REASON="$(printf '%s' "$R" | cut -d'|' -f5)"
    if [ "$R_STATUS" = "lookupfail" ]; then
        echo "   ❌ $repo: pin lookup FAILED (default-branch gh api)"
        echo "AUDIT_CONSUMER repo=$repo pin=lookup-failed status=pending"
        INFRA_FAIL=1
        continue
    fi
    if [ "$R_STATUS" = "reached" ]; then
        # INF-255: reached = merged. Append the master-DEPLOY conclusion so the
        # table distinguishes "merged" from "deployed / building / broken".
        DST="$(deploy_status_for "$repo")"
        case "$DST" in
            deployed)    DEPLOY_LABEL="deployed ✓" ;;
            in_progress) DEPLOY_LABEL="deploy in_progress ⏳"; DEPLOY_INPROGRESS_COUNT=$((DEPLOY_INPROGRESS_COUNT + 1)) ;;
            failed)      DEPLOY_LABEL="deploy FAILED ❌"; DEPLOY_FAILED_COUNT=$((DEPLOY_FAILED_COUNT + 1)) ;;
            no-run)      DEPLOY_LABEL="no deploy run (path-ignored / not fired)" ;;
            external)    DEPLOY_LABEL="deploy external (no GH-Actions pipeline)" ;;
            lookupfail)  DEPLOY_LABEL="deploy status UNVERIFIED (gh lookup failed)"; DEPLOY_UNRESOLVED_COUNT=$((DEPLOY_UNRESOLVED_COUNT + 1)) ;;
            *)           DEPLOY_LABEL="deploy status unknown"; DEPLOY_UNRESOLVED_COUNT=$((DEPLOY_UNRESOLVED_COUNT + 1)) ;;
        esac
        echo "   ✅ $repo: ${R_MSHA:0:8}${R_SSHA:+ (staging ${R_SSHA:0:8})} — merged; ${DEPLOY_LABEL}"
        echo "AUDIT_CONSUMER repo=$repo pin=${R_MSHA:0:8} status=reached${R_SSHA:+ staging=${R_SSHA:0:8}}"
        echo "AUDIT_DEPLOY repo=$repo deploy=${DST:-unknown}"
        if [ "$DST" = "failed" ]; then
            echo "      ❌ master DEPLOY FAILED on ${repo} — the release merged but did not deploy; inspect the '$(cached_deploy_wf "$repo")' run on ${repo}'s master HEAD before treating this release as live."
        fi
    else
        echo "   ⏳ $repo: ${R_MSHA:0:8}${R_MSHA:+ }(expected ${EXPECTED:0:8})${R_SSHA:+; staging ${R_SSHA:0:8}}${R_REASON:+ — ${R_REASON}}"
        echo "AUDIT_CONSUMER repo=$repo pin=${R_MSHA:0:8} status=pending${R_SSHA:+ staging=${R_SSHA:0:8}}${R_REASON:+ reason=${R_REASON}}"
        # Stalled-PR diagnosis + known-remedy hints. Named, never performed.
        "$GH" pr list -R "$repo" --state open --json number,headRefName,baseRefName \
            --jq '.[] | select(.headRefName | startswith("kit-upgrade/")) | "      open delivery PR #\(.number) (base \(.baseRefName)) — if blocked on review: auto-approve guard gap (APY-1431 / MYST-32 class), operator approve needed"' 2>/dev/null
        "$GH" pr list -R "$repo" --base master --state open --search "upgrade claude-kit in:title" --json number \
            --jq '.[] | "      open promotion PR #\(.number) — if green+unarmed: GitHub arm-then-clean disarm quirk, direct merge needed"' 2>/dev/null
    fi
done

# ── SELF check (INF-205) — the kit repo's own currency, pin-free ───────
# The operator's challenge on 0.4.22 ("you did not check your own
# claude-kit ci either"): the kit is the one consumer nothing measured.
# Verified here: (a) kit master CI (kit_tests) conclusion for the
# expected SHA, (b) committed .claude/{scripts,hooks} copies equal their
# plugins/claude-kit canonical sources AT that SHA (self-adoption rule).
SELF_STATUS="absent"
if [ "$SELF_PRESENT" = "1" ]; then
    KIT_ROOT="$(cd "$(dirname "$CONSUMERS_YAML")" && pwd)"
    SELF_CI="$("$GH" run list -R allmyles/claude-kit --workflow kit_tests.yaml --commit "$EXPECTED" -L 1 --json conclusion --jq '.[0].conclusion // "missing"' 2>/dev/null)"
    [ -z "$SELF_CI" ] && SELF_CI="missing"
    SELF_PARITY="ok"
    if git -C "$KIT_ROOT" cat-file -e "${EXPECTED}^{commit}" 2>/dev/null; then
        # CR round 1.1: BOTH directions. A .claude copy whose canonical
        # plugins/ source no longer exists at the SHA is an ORPHAN — a
        # retired helper that survived in the consumer-facing tree —
        # and counts as drift. (Canonical files absent from .claude are
        # NORMAL: the copy lists deliberately exclude test_*,
        # templates, setup-project.sh itself.)
        for d in scripts hooks; do
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                b="$(basename "$f")"
                SRC="plugins/claude-kit/$d/$b"
                if git -C "$KIT_ROOT" cat-file -e "$EXPECTED:$SRC" 2>/dev/null; then
                    A="$(git -C "$KIT_ROOT" rev-parse "$EXPECTED:$f" 2>/dev/null)"
                    B="$(git -C "$KIT_ROOT" rev-parse "$EXPECTED:$SRC" 2>/dev/null)"
                    if [ "$A" != "$B" ]; then
                        SELF_PARITY="drift:$b"
                        break 2
                    fi
                else
                    SELF_PARITY="drift:orphan:$b"
                    break 2
                fi
            done <<< "$(git -C "$KIT_ROOT" ls-tree --name-only "$EXPECTED" ".claude/$d/" 2>/dev/null)"
        done
    else
        # Expected SHA not in the local checkout (audit run before a
        # pull) — parity is unverifiable, not failed.
        SELF_PARITY="unknown"
    fi
    if [ "$SELF_CI" = "success" ] && [ "$SELF_PARITY" = "ok" ]; then
        SELF_STATUS="ok"
        echo "   ✅ allmyles/claude-kit: self ok (ci=${SELF_CI}, copies=parity)"
        echo "AUDIT_CONSUMER repo=allmyles/claude-kit pin=self status=self-ok"
    elif [ "$SELF_CI" = "success" ] && [ "$SELF_PARITY" = "unknown" ]; then
        # CR round 1.1: unverifiable is NOT failed — say so and leave the
        # verdict alone (the previous code silently collapsed this into
        # fail, contradicting the documented design).
        SELF_STATUS="unknown"
        echo "   ⚠️ allmyles/claude-kit: self UNKNOWN (ci=${SELF_CI}, copies unverifiable — expected SHA not in this checkout; fetch master and re-run for a full self verdict)"
        echo "AUDIT_CONSUMER repo=allmyles/claude-kit pin=self status=self-unknown"
    else
        SELF_STATUS="fail"
        echo "   ❌ allmyles/claude-kit: self FAIL (ci=${SELF_CI}, copies=${SELF_PARITY})"
        echo "AUDIT_CONSUMER repo=allmyles/claude-kit pin=self status=self-fail"
        echo "      remedy: CI red → inspect the kit_tests run on ${EXPECTED:0:8}; copies drift/orphan → re-run setup-project.sh in the kit checkout, remove retired copies, and commit (self-adoption rule)"
    fi
fi

DEPLOY_COUNTS="deploy_failed=${DEPLOY_FAILED_COUNT} deploy_inprogress=${DEPLOY_INPROGRESS_COUNT} deploy_unresolved=${DEPLOY_UNRESOLVED_COUNT}"
if [ "$INFRA_FAIL" = "1" ]; then
    # CR round 1.1: a failed lookup in the final sweep is infrastructure,
    # not a pending consumer — the audit cannot honestly report reach.
    echo "AUDIT_RESULT=INFRA_ERROR reached=${REACHED_COUNT} pending=${PENDING_COUNT} expected=${EXPECTED:0:8} self=${SELF_STATUS} ${DEPLOY_COUNTS}"
    exit 2
fi
# INF-255: "merged" is not "done". ALL_REACHED requires that every reached
# consumer's master DEPLOY has also concluded successfully — no failures, none
# still building, and none whose status could not be verified. A failed deploy
# is surfaced loudly; an in-progress or unverified one keeps the verdict
# PARTIAL so the caller (e.g. /develop Step 15) does not report the release
# live while a pipeline is mid-flight or its status is unknown.
if [ "$DEPLOY_FAILED_COUNT" -gt 0 ]; then
    echo "❌ ${DEPLOY_FAILED_COUNT} consumer master DEPLOY(s) FAILED — the release merged but is NOT live everywhere. See the 'deploy=failed' line(s) above."
fi
if [ "$PENDING_COUNT" = "0" ] && [ "$SELF_STATUS" != "fail" ] \
   && [ "$DEPLOY_FAILED_COUNT" -eq 0 ] && [ "$DEPLOY_INPROGRESS_COUNT" -eq 0 ] \
   && [ "$DEPLOY_UNRESOLVED_COUNT" -eq 0 ]; then
    echo "AUDIT_RESULT=ALL_REACHED reached=${REACHED_COUNT} pending=0 expected=${EXPECTED:0:8} self=${SELF_STATUS} ${DEPLOY_COUNTS}"
    exit 0
fi
echo "AUDIT_RESULT=PARTIAL reached=${REACHED_COUNT} pending=${PENDING_COUNT} expected=${EXPECTED:0:8} self=${SELF_STATUS} ${DEPLOY_COUNTS}"
exit 1
