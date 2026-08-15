#!/bin/bash
# SessionStart hook: warns when the LOCAL default branch is behind origin
# (INF-281).
#
# Why this exists
# ---------------
# The agent answered "is X in the repo?" / "has this shipped?" from a local
# checkout that was three merges behind the remote, and stated the answer as
# fact. Nothing in the session said the checkout was stale, so the wrong answer
# had exactly the confidence of a right one. The operator caught it by opening a
# GitHub Actions page.
#
# INF-212's ground-truth gate already hard-BLOCKS branch creation until repo
# state is machine-verified — the right shape, but it only fires there.
# Mid-session questions ("is this file present", "is that PR merged") are
# answered from whatever the working tree happens to be. This hook does not fix
# that; it makes the precondition VISIBLE once per session, so a stale checkout
# is surfaced rather than discovered by being wrong.
#
# Structural clone of check-kit-drift.sh (DASH-2179) and
# check-staging-drift-advisory.sh (DASH-2338): single stderr advisory on
# mismatch, silent on match, idempotent per session via a /tmp marker, exits 0
# unconditionally (advisory only — NEVER blocks session start).
#
# Behavior:
#   - Local default branch up to date with origin  → silent.
#   - Behind origin                                → one advisory naming the
#     count and the fix.
#   - Not a git repo / no origin / fetch fails / detached HEAD → silent.
#     Degrading to "no warning" is correct here: this hook's job is to add a
#     signal, never to manufacture one it could not verify. (An advisory that
#     fired on its own failure would be the very bug INF-281 is about.)
#   - Uses `git fetch --dry-run`-equivalent cheap refs: it fetches ONLY the
#     default branch ref with a short timeout, so session start stays fast.

set +e  # belt-and-braces: never fail the hook on an error

INPUT="$(cat || true)"

SESSION_ID="$(echo "$INPUT" | python3 -c "
import sys, json, re
ppid = sys.argv[1] if len(sys.argv) > 1 else '0'
try:
    data = json.load(sys.stdin)
    sid = data.get('session_id') or data.get('sessionId') or ''
    if not sid:
        sid = ppid
    sid = re.sub(r'[^A-Za-z0-9_-]', '_', str(sid))[:64]
    print(sid if sid else '0')
except Exception:
    print(re.sub(r'[^0-9]', '', str(ppid)) or '0')
" "$PPID" 2>/dev/null || echo "0")"

MARKER_FILE="/tmp/local-branch-staleness-${SESSION_ID}.flag"
[ -e "$MARKER_FILE" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0

# Detached HEAD → silent, per this hook's documented contract (CR round 1.1
# caught the code and the header disagreeing: a detached checkout still resolves
# refs/heads/<default> and would have emitted the advisory).
#
# Silence is also the right call on the merits. The advisory's claim is "the tree
# you are reading may be out of date", and its remedy names the local default
# branch — but a detached HEAD is deliberately parked at some other commit
# (bisect, inspecting history), so the staleness of refs/heads/<default> is not
# what the operator is looking at. Reporting the branch's lag while they read a
# different commit would be a confidently-worded near-miss, which is the class of
# thing this whole ticket is about.
git symbolic-ref --quiet HEAD >/dev/null 2>&1 || exit 0

# Resolve the default branch. Prefer the repo's declared config (the kit's own
# develop-config), then origin/HEAD, then the conventional names. Never guess
# past that — a wrong branch would produce a wrong advisory.
DEFAULT_BRANCH=""
if [ -r ".claude/develop-config.json" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_BRANCH="$(jq -r '.default_branch // empty' .claude/develop-config.json 2>/dev/null)"
fi
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
fi
if [ -z "$DEFAULT_BRANCH" ]; then
  for candidate in master main; do
    if git show-ref --verify --quiet "refs/remotes/origin/${candidate}"; then
      DEFAULT_BRANCH="$candidate"
      break
    fi
  done
fi
[ -z "$DEFAULT_BRANCH" ] && exit 0

# Fetch just that one ref so the comparison is against the REMOTE, not against
# a remote-tracking ref that may itself be stale — the whole point is that local
# state is not evidence of remote state.
#
# Do NOT hard-depend on `timeout`: macOS does not ship it (GNU coreutils
# installs it as `gtimeout`), so a bare `timeout 10 git fetch … || exit 0` fails
# with command-not-found on every Mac and the hook silently never fires. That is
# precisely the ERROR-AS-ABSENCE bug this ticket is about, and it was in this
# hook's first draft — caught by tracing the hook rather than assuming it worked.
# Fall back to a plain fetch; the hooks.json `timeout` field is the real backstop
# against a hung network call.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 10"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 10"
fi
# shellcheck disable=SC2086  # intentional word-split: TIMEOUT_CMD is a kit-set literal or empty
$TIMEOUT_CMD git fetch --quiet origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || exit 0

LOCAL_SHA="$(git rev-parse --quiet --verify "refs/heads/${DEFAULT_BRANCH}" 2>/dev/null)"
REMOTE_SHA="$(git rev-parse --quiet --verify FETCH_HEAD 2>/dev/null)"
[ -z "$LOCAL_SHA" ] || [ -z "$REMOTE_SHA" ] && exit 0
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] && exit 0

BEHIND="$(git rev-list --count "${LOCAL_SHA}..${REMOTE_SHA}" 2>/dev/null)"
case "$BEHIND" in
  ''|*[!0-9]*) exit 0 ;;   # could not count → say nothing rather than guess
  0) exit 0 ;;
esac

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
touch "$MARKER_FILE" 2>/dev/null || true

printf '%s\n' "⚠️ Local ${DEFAULT_BRANCH} is ${BEHIND} commit(s) behind origin/${DEFAULT_BRANCH} (INF-281). Anything you read from this working tree — files present, what shipped, what a script contains — may be out of date. For REMOTE state use \`gh api\` or fetch first; to refresh: git checkout ${DEFAULT_BRANCH} && git pull --rebase origin ${DEFAULT_BRANCH}. (currently on: ${CURRENT_BRANCH})" >&2

exit 0
