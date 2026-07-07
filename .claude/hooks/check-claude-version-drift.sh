#!/bin/bash
# SessionStart hook: warns when the running Claude Code version disagrees
# with the version recorded in .claude/allowlist-meta.json's
# `allowlistValidatedAgainst.claudeCodeVersion` field (sidecar — NOT
# settings.json; see the comment at the META_FILE assignment below for why).
#
# DASH-2063: detects allowlist-drift exposure after Claude Code is
# updated. The first run after an update is the failure mode the
# Pillar-1 autonomy posture is most exposed to (tool-name churn,
# bypass-mode scope changes, matcher-semantics tightening — see
# .claude/skills/develop/SKILL.md § "Permission Allowlist Categorization"
# for the threat model). The companion script
# `.claude/scripts/setup-after-claude-update.sh` (DASH-2062) consumes the
# version pin and proposes allowlist deltas. This hook is the structural
# signal that the companion script needs to run.
#
# Behavior:
#   - Silent on version match (no output, exit 0).
#   - On mismatch: prints a one-line advisory to stderr telling the
#     operator to run the companion script.
#   - Idempotent within a session via /tmp/claude-version-drift-<sid>.flag.
#   - Exits 0 unconditionally — advisory only, never blocks session start.
#     Any parse failure / missing `jq` / `claude --version` failure
#     degrades to "no warning" rather than "blocked session".

set +e  # belt-and-braces: never fail the hook on a parse error

# Read hook stdin JSON; Claude Code includes session_id in the payload.
INPUT="$(cat || true)"

# Extract session_id robustly. Falls back to the shell's PPID
# (bash builtin — passed as argv[1] because `PPID` is NOT exported to
# child processes, so `os.environ.get('PPID')` returns None inside the
# python3 subprocess). The fallback is a deterministic per-shell value
# so the marker still de-duplicates within the same child process even
# if Claude Code's payload format changes.
# Whitelist the session_id to [A-Za-z0-9_-]+ before using it as a path
# component — Claude Code controls the stdin, but path-traversal hardening
# costs nothing and avoids any future misuse if the field shape changes.
SESSION_ID="$(echo "$INPUT" | python3 -c "
import sys, json, re
ppid = sys.argv[1] if len(sys.argv) > 1 else '0'
try:
    data = json.load(sys.stdin)
    sid = data.get('session_id') or data.get('sessionId') or ''
    if not sid:
        sid = ppid
    # Whitelist filesystem-safe chars only.
    sid = re.sub(r'[^A-Za-z0-9_-]', '_', str(sid))[:64]
    print(sid if sid else '0')
except Exception:
    print(re.sub(r'[^0-9]', '', str(ppid)) or '0')
" "$PPID" 2>/dev/null || echo "0")"

MARKER_FILE="/tmp/claude-version-drift-${SESSION_ID}.flag"

# Already warned this session → silent.
if [ -e "$MARKER_FILE" ]; then
    exit 0
fi

# Locate the sidecar metadata file relative to the script. Use
# $CLAUDE_PROJECT_DIR when present (set by Claude Code for hooks); otherwise
# resolve via the script's own location. The pin lives in a sidecar JSON —
# NOT in .claude/settings.json — because Claude Code's settings.json schema
# validator rejects unknown top-level fields (DASH-2063 discovery during
# implementation; the original intent of "pin into settings.json" failed
# validation, so we pivoted to a sidecar).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
META_FILE="${PROJECT_DIR}/.claude/allowlist-meta.json"

if [ ! -r "$META_FILE" ]; then
    # Sidecar missing — fresh checkout that hasn't pulled DASH-2063 yet,
    # or local edits. Silent.
    exit 0
fi

# Read the pinned version. `jq -r` returns "null" literal if the path is
# missing; normalize to empty string to make the comparison clean.
PINNED_VERSION="$(jq -r '.allowlistValidatedAgainst.claudeCodeVersion // ""' "$META_FILE" 2>/dev/null || echo "")"

# If the pin is absent / blank / literal "null", silent — the field
# hasn't been seeded yet (e.g. on a fresh checkout before DASH-2063
# lands, or after manual edits). The companion script seeds it.
if [ -z "$PINNED_VERSION" ] || [ "$PINNED_VERSION" = "null" ]; then
    exit 0
fi

# Get the running version. `claude --version` prints "X.Y.Z (Claude Code)";
# the leading token is the semver.
CURRENT_VERSION="$(claude --version 2>/dev/null | awk '{print $1}' || echo "")"

# If we can't read the running version, silent — don't false-alarm when
# the binary isn't on PATH for some reason.
if [ -z "$CURRENT_VERSION" ]; then
    exit 0
fi

# Match → silent.
if [ "$CURRENT_VERSION" = "$PINNED_VERSION" ]; then
    exit 0
fi

# Mismatch → write the marker and emit the advisory. Hooks print to
# stderr to surface in the Claude Code UI; the agent sees this on
# session start.
touch "$MARKER_FILE" 2>/dev/null || true

printf '%s\n' "⚠️ Claude Code version drift detected — allowlist last validated against v${PINNED_VERSION}, currently running v${CURRENT_VERSION}; run \`.claude/scripts/setup-after-claude-update.sh\` (DASH-2062) to verify allowlist coverage before the next /develop run." >&2

exit 0
