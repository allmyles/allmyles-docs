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
#
# Output: human table on stdout plus machine-parsable lines:
#   AUDIT_CONSUMER repo=<r> pin=<8sha|none> status=<reached|pending>
#   AUDIT_RESULT=<ALL_REACHED|PARTIAL|INFRA_ERROR> reached=<n> pending=<n> expected=<8sha>
# Exit: 0 all reached, 1 partial, 2 infra error (not a kit checkout, gh
# missing, expected SHA unresolvable).
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
pin_of() {  # $1=repo → stdout "<rc> <sha-or-empty>"
    local raw rc
    raw="$("$GH" api "repos/$1/contents/.claude/claude-kit-pin.json" --jq '.content' 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "$rc "
        return
    fi
    echo "0 $(printf '%s' "$raw" | base64 -d 2>/dev/null | jq -r '.kitSha // ""' 2>/dev/null)"
}

PENDING="$CONSUMERS"
declare -a REACHED_LIST=()
while : ; do
    STILL=""
    for repo in $PENDING; do
        PIN_OUT="$(pin_of "$repo")"
        PIN="${PIN_OUT#* }"
        if [ "$PIN" = "$EXPECTED" ]; then
            REACHED_LIST+=("$repo")
        else
            # Lookup failures retry like pending here; the final sweep
            # is where they become INFRA_ERROR.
            STILL="${STILL}${repo}"$'\n'
        fi
    done
    PENDING="$(printf '%s' "$STILL" | sed '/^$/d')"
    [ -z "$PENDING" ] && break
    [ "$SECONDS" -ge "$AUDIT_DEADLINE" ] && break
    sleep "$POLL_INTERVAL"
done

# ── Report ─────────────────────────────────────────────────────────────
REACHED_COUNT=${#REACHED_LIST[@]}
PENDING_COUNT=0; [ -n "$PENDING" ] && PENDING_COUNT="$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')"
echo "── consumer masters:"
INFRA_FAIL=0
for repo in $CONSUMERS; do
    PIN_OUT="$(pin_of "$repo")"
    PIN_RC="${PIN_OUT%% *}"
    PIN="${PIN_OUT#* }"
    if [ "$PIN_RC" != "0" ]; then
        echo "   ❌ $repo: pin lookup FAILED (gh api rc=$PIN_RC)"
        echo "AUDIT_CONSUMER repo=$repo pin=lookup-failed status=pending"
        INFRA_FAIL=1
        continue
    fi
    if [ "$PIN" = "$EXPECTED" ]; then
        echo "   ✅ $repo: ${PIN:0:8}"
        echo "AUDIT_CONSUMER repo=$repo pin=${PIN:0:8} status=reached"
    else
        echo "   ⏳ $repo: ${PIN:0:8}${PIN:+ }(expected ${EXPECTED:0:8})"
        echo "AUDIT_CONSUMER repo=$repo pin=${PIN:0:8} status=pending"
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

if [ "$INFRA_FAIL" = "1" ]; then
    # CR round 1.1: a failed lookup in the final sweep is infrastructure,
    # not a pending consumer — the audit cannot honestly report reach.
    echo "AUDIT_RESULT=INFRA_ERROR reached=${REACHED_COUNT} pending=${PENDING_COUNT} expected=${EXPECTED:0:8} self=${SELF_STATUS}"
    exit 2
fi
if [ "$PENDING_COUNT" = "0" ] && [ "$SELF_STATUS" != "fail" ]; then
    echo "AUDIT_RESULT=ALL_REACHED reached=${REACHED_COUNT} pending=0 expected=${EXPECTED:0:8} self=${SELF_STATUS}"
    exit 0
fi
echo "AUDIT_RESULT=PARTIAL reached=${REACHED_COUNT} pending=${PENDING_COUNT} expected=${EXPECTED:0:8} self=${SELF_STATUS}"
exit 1
