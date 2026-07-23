#!/usr/bin/env bash
# check-ground-truth-before-branch.sh (INF-212) — PreToolUse hook that
# BLOCKS branch-creation until repo/branch/ticket state has been
# machine-verified by establish-ground-truth.sh.
#
# This is the enforcement half of the anti-speculation gate: hooks intercept
# tool CALLS, not model prose, so this cannot stop the agent from *saying* a
# speculative sentence — but it makes speculation unable to DRIVE a
# state-changing action. No feature branch is cut on unverified ground.
#
# Registered (settings.template.json) under PreToolUse matchers
# Bash(git checkout:*), Bash(git switch:*), Bash(git branch:*). Those matchers
# also fire on NON-creating uses (git checkout master, git branch -r
# --contains, git switch <existing>) — including the very commands
# establish-ground-truth.sh itself runs — so this hook self-filters via
# is_branch_creating() and only enforces on the CREATING forms.
#
# Enforcement scope: only when a /develop run is active, signaled by the
# presence of the .gates/ directory (Init creates it). Outside a ceremony
# (no .gates/) ad-hoc branch creation is not the target and is allowed —
# mirrors the self-no-op convention of pre-commit-test-gate.sh.
#
# Contract:
#   stdin  — Claude Code PreToolUse JSON; .tool_input.command is the shell line.
#   exit 0 — allow (non-creating form, no active ceremony, or gate satisfied)
#   exit 2 — block (creating form, ceremony active, gate absent/stale/wrong-repo)
#
# Bypass: ALLOW_UNVERIFIED_GROUND=1 (env, logged to stderr) — mirrors
# ALLOW_STAGING_MERGE on pre-push-block-staging-merge.sh. Per-invocation, leaves
# a shell-history audit trail. Use only when you are deliberately crossing this.

set -u

STALE_SECONDS="${KIT_GT_STALE_SECONDS:-3600}"   # 60 min default

# ── Read the tool command from stdin JSON (fall back to raw stdin) ──
INPUT="$(cat 2>/dev/null || true)"
CMD=""
if [ -n "$INPUT" ]; then
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -z "$CMD" ] && CMD="$INPUT"   # tests may pipe the bare command
fi
[ -z "$CMD" ] && exit 0            # nothing to inspect → allow

# ── is_branch_creating: does CMD create a new branch? ──
# Handles: git checkout -b/-B <name>; git switch -c/-C/--create <name>;
# git branch <name> (a bare non-flag arg AND no read-only/delete/move flag).
# Read-only forms — git checkout <existing>, git switch <existing>,
# git branch (list) / -r / -a / -v / --contains / --merged / -d / -m — are
# NOT creating and pass through.
is_branch_creating() {
    local c="$1"
    # checkout -b / -B
    if printf '%s' "$c" | grep -qE '(^|[^[:alnum:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+checkout([[:space:]]|.)*[[:space:]]-[bB]([[:space:]]|$)'; then
        return 0
    fi
    # switch -c / -C / --create
    if printf '%s' "$c" | grep -qE '(^|[^[:alnum:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+switch([[:space:]]|.)*[[:space:]](-[cC]|--create)([[:space:]]|=|$)'; then
        return 0
    fi
    # git branch — creates/resets a branch pointer. CR round 1.1: it is
    # NOT enough to check only the FIRST token — `git branch -f <name>`,
    # `--force`, `-t/--track <name> <start>` all take a flag FIRST yet still
    # create/reset a branch. Classify:
    if printf '%s' "$c" | grep -qE '(^|[^[:alnum:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+branch([[:space:]]|$)'; then
        local after
        after="$(printf '%s' "$c" | sed -E 's/.*[[:space:]]branch[[:space:]]+//')"
        # (a) Pure non-creating operations (delete / move / copy / list /
        #     read-only inspection, incl. the arg-taking read-only flags
        #     -u/--set-upstream-to/--points-at/--sort which operate on an
        #     EXISTING branch) → not creating.
        if printf '%s' "$after" | grep -qE '(^|[[:space:]])(-r|-a|-v|-vv|-l|--list|--contains|--no-contains|--merged|--no-merged|--sort|--points-at|-d|-D|--delete|-m|-M|--move|-c|-C|--copy|--edit-description|-u|--set-upstream-to|--unset-upstream|--show-current)([[:space:]]|=|$)'; then
            return 1
        fi
        # (b) Force / track flags create or reset a branch pointer → creating.
        if printf '%s' "$after" | grep -qE '(^|[[:space:]])(-f|--force|-t|--track|--no-track)([[:space:]]|=|$)'; then
            return 0
        fi
        # (c) Any bare (non-flag) token anywhere is a new branch name →
        #     creating (not just the first token).
        local tok
        for tok in $after; do
            case "$tok" in
                -*) : ;;          # a flag → keep scanning
                "") : ;;
                *)  return 0 ;;   # a bare branch name → creating
            esac
        done
    fi
    return 1
}

if ! is_branch_creating "$CMD"; then
    exit 0
fi

# ── Enforcement only inside an active /develop ceremony (.gates/ present) ──
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && exit 0
if [ ! -d "$PROJECT_ROOT/.gates" ]; then
    exit 0   # not mid-ceremony → not this hook's business
fi

# ── Bypass ──
if [ "${ALLOW_UNVERIFIED_GROUND:-0}" = "1" ]; then
    echo "check-ground-truth-before-branch.sh: bypassed via ALLOW_UNVERIFIED_GROUND=1 — branch creation allowed without a fresh ground-truth gate." >&2
    exit 0
fi

GATE="$PROJECT_ROOT/.gates/ground-truth-verified"
REMEDY="Run: .claude/scripts/establish-ground-truth.sh \"$PROJECT_ROOT\" [<ticket-key>]  — relay its GROUND_TRUTH output, then retry. Deliberate override: ALLOW_UNVERIFIED_GROUND=1."

if [ ! -f "$GATE" ]; then
    echo "BLOCKED (INF-212): branch creation before ground truth is established." >&2
    echo "No .gates/ground-truth-verified in $PROJECT_ROOT — repo/branch/ticket state has not been machine-verified this run." >&2
    echo "$REMEDY" >&2
    exit 2
fi

# Gate must name THIS repo (a stale marker from another checkout must not
# satisfy it) and be fresh. Compare SYMLINK-RESOLVED paths on both sides: the
# gate stores establish-ground-truth.sh's `pwd` (resolved), while
# CLAUDE_PROJECT_DIR may be unresolved (e.g. a /tmp→/private/var symlink on
# macOS) — comparing raw strings would false-block.
GATE_REPO="$(sed -n 's/.*repo=\([^ ]*\).*/\1/p' "$GATE" 2>/dev/null | head -1)"
# CR round 1.1: an empty/unparsable gate (no repo= field — e.g. a partial or
# corrupt write) must FAIL CLOSED, not be treated as valid just because the
# file exists and is fresh. A gate that carries no verifiable repo fact
# proves nothing.
if [ -z "$GATE_REPO" ]; then
    echo "BLOCKED (INF-212): ground-truth gate is present but carries no repo= field (partial/corrupt write) — failing closed." >&2
    echo "$REMEDY" >&2
    exit 2
fi
PROJECT_ROOT_RESOLVED="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd)"; PROJECT_ROOT_RESOLVED="${PROJECT_ROOT_RESOLVED:-$PROJECT_ROOT}"
GATE_REPO_RESOLVED="$(cd "$GATE_REPO" 2>/dev/null && pwd)"; GATE_REPO_RESOLVED="${GATE_REPO_RESOLVED:-$GATE_REPO}"
if [ "$GATE_REPO_RESOLVED" != "$PROJECT_ROOT_RESOLVED" ]; then
    echo "BLOCKED (INF-212): ground-truth gate names a different repo ($GATE_REPO), not $PROJECT_ROOT." >&2
    echo "$REMEDY" >&2
    exit 2
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    GATE_MTIME="$(stat -f %m "$GATE" 2>/dev/null || echo 0)"
else
    GATE_MTIME="$(stat -c %Y "$GATE" 2>/dev/null || echo 0)"
fi
NOW="$(date +%s)"
AGE=$(( NOW - GATE_MTIME ))
if [ "$AGE" -gt "$STALE_SECONDS" ]; then
    echo "BLOCKED (INF-212): ground-truth gate is stale (${AGE}s old, max ${STALE_SECONDS}s)." >&2
    echo "Re-establish it so the facts reflect current state. $REMEDY" >&2
    exit 2
fi

exit 0
