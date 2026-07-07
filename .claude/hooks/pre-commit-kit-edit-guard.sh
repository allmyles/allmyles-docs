#!/bin/bash
# PreToolUse (Bash git commit) guard: flags a commit that stages a local edit
# to a kit-managed file (.claude/{skills,scripts,hooks}/…) so the change gets
# routed to claude-kit instead of silently diverging in the consumer.
#
# INF-152 (epic INF-150). The prevent half of bidirectional kit-drift
# protection; pairs with INF-151's SessionStart detector. Where INF-151 warns
# once per session that drift already exists, this fires at the moment drift
# would be committed — the earliest, cheapest place to stop it.
#
# A staged file is "kit-managed" when the same relative path exists under the
# installed plugin (${CLAUDE_PLUGIN_ROOT}/<rest>) AND the staged/working copy
# differs from it (an actual local edit — an identical copy is harmless). The
# "exists in plugin" test means genuinely-local files (settings.local.json,
# develop-config.json, plans/, gates, the pin file) are never flagged: they
# have no plugin counterpart.
#
# Modes:
#   default (warn)          → exit 0, single stderr advisory. Non-blocking so a
#                             deliberate in-flight edit (e.g. a dual-touch skill
#                             migration) isn't obstructed.
#   KIT_EDIT_GUARD=block    → exit 2 (blocks the commit; Claude sees stderr).
#   ALLOW_LOCAL_KIT_EDIT=1  → exit 0 silently (single-commit bypass; mirrors
#                             ALLOW_STAGING_MERGE / ALLOW_FEATURE_STACKING).
#
# Self-no-op: silent exit 0 when not a plugin consumer (CLAUDE_PLUGIN_ROOT
# unset) or not in a git repo. Never fails the commit on an internal error.
#
# Exit codes:  0 = allow (also warn mode & bypass)   2 = block (strict mode)

set +e

# Single-commit bypass.
if [ "${ALLOW_LOCAL_KIT_EDIT:-}" = "1" ]; then
    exit 0
fi

# Only meaningful for a plugin consumer.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && exit 0

# Staged changes with status (relative to repo root). Nothing staged → nothing
# to guard. We use --name-status (not --name-only) so staged deletions can be
# skipped, and we compare the INDEX blob (what is actually being committed) —
# not the working tree, which can differ from what's staged.
STAGED="$(git -C "$PROJECT_ROOT" diff --cached --name-status 2>/dev/null)"
[ -z "$STAGED" ] && exit 0

FLAGGED=""
while IFS=$'\t' read -r status path newpath; do
    [ -n "$path" ] || continue
    case "$status" in
        D*) continue ;;                    # staged deletion → not a local edit
        R*|C*) [ -n "$newpath" ] && path="$newpath" ;;  # rename/copy: the staged
                                           # content lives at the NEW path (the
                                           # 3rd --name-status field), not the old
    esac
    case "$path" in
        .claude/skills/*|.claude/scripts/*|.claude/hooks/*) ;;
        *) continue ;;
    esac
    rel="${path#.claude/}"                       # scripts/foo.sh, skills/develop/SKILL.md, …
    plugin_file="${PLUGIN_ROOT}/${rel}"
    [ -f "$plugin_file" ] || continue            # no plugin twin → genuinely local, not guarded
    # Compare the STAGED blob (":$path" = the index version) against the kit
    # copy — this is exactly what the commit will contain, regardless of any
    # later un-staged working-tree change.
    if ! git -C "$PROJECT_ROOT" show ":$path" 2>/dev/null | cmp -s - "$plugin_file"; then
        FLAGGED="${FLAGGED}${FLAGGED:+, }${path}"
    fi
done <<< "$STAGED"

[ -z "$FLAGGED" ] && exit 0

MSG="⚠️ kit-managed file(s) edited locally: ${FLAGGED}. These are owned by allmyles/claude-kit — make the change there (INF PR) and re-pull via \`setup-project.sh\`, don't diverge the local copy. Deliberate local override: prefix the commit with ALLOW_LOCAL_KIT_EDIT=1."

if [ "${KIT_EDIT_GUARD:-warn}" = "block" ]; then
    printf 'BLOCKED: %s\n' "$MSG" >&2
    exit 2
fi

printf '%s\n' "$MSG" >&2
exit 0
