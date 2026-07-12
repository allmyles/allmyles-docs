#!/bin/bash
# Auto-resolve staging conflicts on a feature branch WITHOUT creating a
# merge commit — so the master-promotion PR's diff stays scoped.
#
# Background: feature branches are master-based and target staging.
# A bot auto-opens a feature→master PR the moment the staging PR
# merges; that PR auto-tracks the feature-branch tip. If a later
# `git merge origin/staging` lands on the branch (e.g. to resolve a
# fix-forward conflict with an unrelated ticket already on staging),
# the merge commit pulls staging's tail into the branch's ancestor
# set, and the master-PR diff balloons. This is the DASH-2013 →
# PR #2497 incident.
#
# This helper resolves conflicts at the FILE CONTENT LEVEL using
# `git merge-file` — a 3-way merge that writes resolved text without
# creating a commit, without involving git's merge machinery, and
# without staging becoming an ancestor of the feature branch. The
# resolved files are then committed as a NORMAL single-parent commit;
# the branch's first-parent chain stays linear from master.
#
# Usage:
#   resolve_staging_conflict.sh [--strategy STRATEGY]
#                               [--per-file-strategy FILE=STRATEGY,...]
#                               [--dry-run]
#                               [--commit-message MSG]
#                               [--no-commit]
#                               [--remote-staging-ref REF]
#                               [--help]
#
#   STRATEGY ∈ {union, ours, theirs}.
#     union  — take both sides for positional conflicts (default; matches
#              the DASH-2013 case where two tickets added methods at the
#              same line in the same test class).
#     ours   — your branch wins (use when staging has a change you want
#              to revert, e.g. urls.py dual-mount overriding a redirect).
#     theirs — staging wins (rare; usually means your fix overlaps with
#              one already done on staging).
#
#   --per-file-strategy lets you override the default per file:
#     --per-file-strategy mileometer/urls.py=ours,tests/foo.py=union
#
#   --dry-run lists conflicting files + the strategy that would apply
#   to each and makes no working-tree or git changes. Always exits 0
#   when invocation parsing succeeds (the printed file count is the
#   signal — empty means no conflicts, one-or-more means conflicts
#   exist that would be resolved on a non-dry-run invocation).
#
#   --no-commit applies the resolved content to the working tree but
#   does NOT stage or commit. Useful when you want to inspect the
#   resolution before committing.
#
#   --remote-staging-ref overrides the staging ref name (default
#   origin/staging). The script always fetches it before reading.
#
# Exit codes:
#   0   — no conflicts found OR conflicts resolved cleanly (single-parent
#         commit created, OR --dry-run finished without conflicts, OR
#         --no-commit finished with working-tree changes applied)
#   1   — conflicts detected AND the chosen strategy still left conflict
#         markers in at least one file (manual intervention required)
#   2   — not a git repo, on master/staging itself, or git operations
#         failed (e.g. fetch, merge-base)
#   3   — invalid arguments
#
# Authority: see .claude/skills/develop/SKILL.md "Decision Tree" of
# Step 9 ("Merge conflicts"); CLAUDE.md "CRITICAL: Never mix staging
# into feature branches" lists this script as the canonical agentic
# alternative to the prohibited `git merge origin/staging`.

set -u

STRATEGY="union"
PER_FILE_STRATEGY=""
DRY_RUN=false
NO_COMMIT=false
STAGING_REF="origin/staging"
COMMIT_MESSAGE=""

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; /^set -u$/d; /^$/d'
}

# Validate that an option's value argument exists and isn't another flag.
# CR round 1.1: previously `--strategy --dry-run` would silently assign
# STRATEGY="--dry-run" via `${2:-}`, then fail in the case-match
# validation a few lines later. Catching it at parse time gives a
# clearer error and prevents value-stealing across flags.
require_value() {
  local flag="$1"
  local value="${2:-}"
  if [ -z "$value" ] || [ "${value#-}" != "$value" ]; then
    echo "ERROR: $flag requires a value (got: '${value:-<missing>}')" >&2
    exit 3
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --strategy)
      require_value "$1" "${2:-}"
      STRATEGY="$2"
      shift 2
      ;;
    --per-file-strategy)
      require_value "$1" "${2:-}"
      PER_FILE_STRATEGY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-commit)
      NO_COMMIT=true
      shift
      ;;
    --commit-message)
      require_value "$1" "${2:-}"
      COMMIT_MESSAGE="$2"
      shift 2
      ;;
    --remote-staging-ref)
      require_value "$1" "${2:-}"
      STAGING_REF="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 3
      ;;
  esac
done

case "$STRATEGY" in
  union|ours|theirs) ;;
  *)
    echo "ERROR: --strategy must be one of: union, ours, theirs (got: $STRATEGY)" >&2
    exit 3
    ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not inside a git working tree" >&2
  exit 2
fi

BRANCH=$(git branch --show-current)
case "$BRANCH" in
  master|main|staging)
    echo "ERROR: refusing to run on '$BRANCH' — this script is for feature branches" >&2
    exit 2
    ;;
  "")
    echo "ERROR: detached HEAD — checkout a feature branch first" >&2
    exit 2
    ;;
esac

REMOTE="${STAGING_REF%%/*}"
REF_NAME="${STAGING_REF#*/}"
# CR round 1.3: preserve git's stderr so the user sees the underlying
# failure reason (auth, network, ref not found, etc.) — pre-1.3 the
# 2>/dev/null swallowed it and the bare "could not fetch" was useless.
FETCH_ERR=$(git fetch --quiet "$REMOTE" "$REF_NAME" 2>&1)
if [ $? -ne 0 ]; then
  echo "ERROR: could not fetch $STAGING_REF" >&2
  [ -n "$FETCH_ERR" ] && echo "$FETCH_ERR" >&2
  exit 2
fi

BASE=$(git merge-base HEAD "$STAGING_REF" 2>/dev/null)
if [ -z "$BASE" ]; then
  echo "ERROR: could not compute merge-base of HEAD and $STAGING_REF" >&2
  exit 2
fi

# Use git merge-tree to discover which files would conflict — without
# performing any merge. `--write-tree` produces a tree-ish hash on
# line 1; if conflicts exist (exit 1), additional lines describe the
# conflicted entries.
#
# Output format on conflict (text mode, no -z):
#   <merged-tree-hash>
#   <blank line>
#   <mode> <object> <stage>\t<path>     ← repeated per stage (1,2,3)
#   <mode> <object> <stage>\t<path>
#   ...
#   <free-text "Auto-merging" / "CONFLICT (..)" messages from merge>
#
# git's "Auto-merging X" / "CONFLICT" messages may go to stdout or
# stderr depending on git version — we redirect stderr separately so
# the parsing below only sees the structured records.
MERGE_TREE_OUT=$(git merge-tree --write-tree --merge-base "$BASE" HEAD "$STAGING_REF" 2>/dev/null)
MT_EXIT=$?

# A clean merge exits 0 and prints just the merged tree's hash. A
# conflict exits 1 and prints the tree hash + conflict info. Anything
# else is a real error.
if [ "$MT_EXIT" != 0 ] && [ "$MT_EXIT" != 1 ]; then
  echo "ERROR: git merge-tree failed ($MT_EXIT):" >&2
  echo "$MERGE_TREE_OUT" >&2
  exit 2
fi

if [ "$MT_EXIT" = 0 ]; then
  echo "✅ No conflicts with $STAGING_REF — nothing to do."
  exit 0
fi

# Conflicts exist. Parse the structured entries — lines matching
#   <octal-mode> SP <sha> SP <stage> TAB <path>
# Then take unique paths (sorted) so we get one entry per conflicted
# file (regardless of which stages it appears in).
CONFLICTED_FILES=$(
  printf '%s\n' "$MERGE_TREE_OUT" \
    | awk -F'\t' '/^[0-9]+ [0-9a-f]+ [1-3]\t/ { print $2 }' \
    | sort -u
)

if [ -z "$CONFLICTED_FILES" ]; then
  echo "ERROR: merge-tree reported conflicts but no conflicted paths could be parsed." >&2
  echo "Raw output:" >&2
  echo "$MERGE_TREE_OUT" >&2
  exit 2
fi

# Build per-file strategy map from --per-file-strategy CSV.
get_strategy() {
  local f="$1"
  if [ -n "$PER_FILE_STRATEGY" ]; then
    local entry
    while IFS= read -r entry; do
      local k="${entry%%=*}"
      local v="${entry#*=}"
      if [ "$k" = "$f" ]; then
        echo "$v"
        return
      fi
    done < <(printf '%s' "$PER_FILE_STRATEGY" | tr ',' '\n')
  fi
  echo "$STRATEGY"
}

FILE_COUNT=$(printf '%s\n' "$CONFLICTED_FILES" | grep -c .)
echo "📝 Found $FILE_COUNT conflicted file(s) vs $STAGING_REF:"
while IFS= read -r f; do
  s=$(get_strategy "$f")
  echo "  - $f  [strategy: $s]"
done <<EOF
$CONFLICTED_FILES
EOF

if [ "$DRY_RUN" = true ]; then
  echo "ℹ️  --dry-run: no working-tree changes made"
  exit 0
fi

# Apply per-file 3-way merge. `git merge-file` reads three files and
# writes the merged content to the first (--ours/--theirs/--union are
# strategy flags; -p writes to stdout). Use stdout redirection so the
# original working-tree file isn't touched until we know the merge
# succeeded.
TMPDIR=$(mktemp -d -t resolve-staging-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

UNRESOLVED_COUNT=0
RESOLVED_FILES=()
ADDED_FILES=()        # files present on staging but absent on HEAD (rename/add-add)
DELETED_FILES=()      # files deleted on HEAD but modified on staging (modify/delete)

while IFS= read -r path; do
  [ -z "$path" ] && continue
  strategy=$(get_strategy "$path")
  case "$strategy" in
    union|ours|theirs) ;;
    *)
      echo "ERROR: invalid per-file strategy '$strategy' for $path" >&2
      exit 3
      ;;
  esac

  base_file="$TMPDIR/base"
  ours_file="$TMPDIR/ours"
  theirs_file="$TMPDIR/theirs"

  # Pull each side. A missing side (file added on one branch only)
  # makes `git show` return non-zero — handle as "treat absent side
  # as empty" so the 3-way merge still produces something useful.
  if git show "$BASE:$path" > "$base_file" 2>/dev/null; then :; else : > "$base_file"; fi
  HAVE_OURS=true
  HAVE_THEIRS=true
  if git show "HEAD:$path" > "$ours_file" 2>/dev/null; then :; else
    HAVE_OURS=false
    : > "$ours_file"
  fi
  if git show "$STAGING_REF:$path" > "$theirs_file" 2>/dev/null; then :; else
    HAVE_THEIRS=false
    : > "$theirs_file"
  fi

  # Add/add or rename: if one side lacks the file, the chosen strategy
  # dictates behaviour: ours = keep our absence (do nothing); theirs =
  # take staging's content (write the file). union for add/add is the
  # same as theirs unless we have both sides.
  if [ "$HAVE_OURS" = false ] && [ "$HAVE_THEIRS" = true ]; then
    if [ "$strategy" = "ours" ]; then
      # Keep our absence — file stays absent.
      continue
    fi
    # theirs / union for an add-only-on-theirs file: write the staging
    # copy. Staging is gated on NO_COMMIT — under --no-commit we leave
    # the working tree changed but don't touch the index, so the user
    # can inspect cleanly. CR round 1.1.
    mkdir -p "$(dirname "$path")"
    cp "$theirs_file" "$path"
    if [ "$NO_COMMIT" = false ]; then
      git add -- "$path" >/dev/null 2>&1 || true
    fi
    ADDED_FILES+=("$path")
    RESOLVED_FILES+=("$path")
    continue
  fi
  if [ "$HAVE_OURS" = true ] && [ "$HAVE_THEIRS" = false ]; then
    # Modify/delete: file deleted on staging but modified on HEAD,
    # or vice versa. ours = keep ours; theirs/union = remove (taking
    # the deletion). We default to "keep ours" because the agent
    # explicitly opted into this branch's content for the changed
    # file; if the agent wants to follow staging's deletion they
    # should pass --per-file-strategy <file>=theirs.
    if [ "$strategy" = "theirs" ]; then
      # Under --no-commit, still apply the deletion to the working
      # tree (with rm) but skip `git rm` so the index stays clean.
      # CR round 1.1.
      if [ "$NO_COMMIT" = false ]; then
        git rm -f -- "$path" >/dev/null 2>&1 || rm -f -- "$path"
      else
        rm -f -- "$path"
      fi
      DELETED_FILES+=("$path")
      RESOLVED_FILES+=("$path")
    else
      # ours/union: keep our version (no file-system change needed —
      # already in index). Still record the resolution so the final
      # "Resolved N file(s)" count and the auto-generated commit
      # message reflect the file (CR round 1.3 — pre-1.3 these were
      # silently skipped from RESOLVED_FILES, under-counting).
      echo "  ↳ Keeping ours for modify/delete: $path"
      RESOLVED_FILES+=("$path")
    fi
    continue
  fi

  # Both sides present — actual 3-way text merge.
  resolved_file="$TMPDIR/resolved"
  case "$strategy" in
    union)
      if git merge-file --union -p "$ours_file" "$base_file" "$theirs_file" > "$resolved_file" 2>/dev/null; then
        :
      else
        # --union shouldn't leave conflicts; non-zero here is an error.
        echo "WARNING: --union returned non-zero for $path; proceeding with raw output" >&2
      fi
      ;;
    ours)
      cp "$ours_file" "$resolved_file"
      ;;
    theirs)
      cp "$theirs_file" "$resolved_file"
      ;;
  esac

  # Check for remaining conflict markers.
  if grep -qE '^(<{7}|={7}|>{7})( |$)' "$resolved_file"; then
    echo "⚠️  Conflict markers remain in $path after strategy=$strategy"
    UNRESOLVED_COUNT=$((UNRESOLVED_COUNT + 1))
    # Still apply the marked content so the agent can inspect it.
    cp "$resolved_file" "$path"
    RESOLVED_FILES+=("$path")
  else
    cp "$resolved_file" "$path"
    # Skip staging under --no-commit so the index stays unmodified
    # and the user can inspect the working-tree changes cleanly.
    # CR round 1.1.
    if [ "$NO_COMMIT" = false ]; then
      git add -- "$path" >/dev/null 2>&1 || true
    fi
    RESOLVED_FILES+=("$path")
  fi
done <<EOF
$CONFLICTED_FILES
EOF

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  echo "❌ $UNRESOLVED_COUNT file(s) still have conflict markers — manual resolution required"
  echo "   The working tree contains the partially-resolved files; inspect, edit, and commit manually."
  exit 1
fi

if [ "$NO_COMMIT" = true ]; then
  echo "✅ ${#RESOLVED_FILES[@]} file(s) resolved into working tree — --no-commit, not committing."
  exit 0
fi

if [ "${#RESOLVED_FILES[@]}" -eq 0 ]; then
  echo "ℹ️  Nothing to commit (all conflicts were add-only on ours kept as 'absent')."
  exit 0
fi

# Build commit message if not user-supplied.
if [ -z "$COMMIT_MESSAGE" ]; then
  ticket=$(printf '%s\n' "$BRANCH" | grep -oE 'DASH-[0-9]+' | head -1)
  ticket="${ticket:-DASH-XXXX}"
  files_summary=$(printf '%s\n' "${RESOLVED_FILES[@]}" | head -3 | tr '\n' ',' | sed 's/,$//')
  if [ "${#RESOLVED_FILES[@]}" -gt 3 ]; then
    files_summary="$files_summary, +$((${#RESOLVED_FILES[@]} - 3)) more"
  fi
  COMMIT_MESSAGE=$(printf '%s\n\n%s\n\n%s' \
    "fix($ticket): Resolve staging conflict via git merge-file (strategy=$STRATEGY)" \
    "Files: $files_summary" \
    "Single-parent commit — no merge commit, no staging ancestor. See .claude/scripts/resolve_staging_conflict.sh.")
fi

# Final safety check: there should be staged changes to commit.
if git diff --staged --quiet; then
  echo "ℹ️  No staged changes — nothing to commit."
  exit 0
fi

# CR round 1.3: check git commit's exit code. Pre-1.3 the exit was
# unchecked, so a pre-commit hook failure (or a `commit --allow-empty=false`
# guard tripping) would NOT abort — the script would then call
# `git rev-parse HEAD` (which returns the PREVIOUS commit's SHA) and
# emit a misleading "✅ Resolved … committed as …" line for a commit
# that never happened. Fail loudly instead.
if ! git commit -m "$COMMIT_MESSAGE"; then
  echo "❌ git commit failed — see output above. Resolution files are still staged; investigate and commit manually, or run 'git reset' to discard." >&2
  exit 2
fi
COMMIT_SHA=$(git rev-parse HEAD)
echo "✅ Resolved ${#RESOLVED_FILES[@]} file(s); committed as ${COMMIT_SHA:0:8} (single-parent)"
echo "   Strategy: $STRATEGY"
echo "   First parent: $(git log -1 --format='%P' "$COMMIT_SHA" | awk '{print $1}' | cut -c1-8)"
SECOND_PARENT=$(git log -1 --format='%P' "$COMMIT_SHA" | awk '{print $2}')
if [ -n "$SECOND_PARENT" ]; then
  echo "❌ FATAL: commit has a second parent ($SECOND_PARENT) — this should never happen"
  exit 2
fi
exit 0
