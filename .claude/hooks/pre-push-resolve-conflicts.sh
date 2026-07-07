#!/bin/bash
# Pre-push hook: Checks for merge conflicts with the target branch (staging).
# Runs BEFORE the test suite hook to ensure the branch can merge cleanly.
#
# Strategy:
#   1. Fetch the latest target branch (staging)
#   2. Attempt a trial merge (--no-commit --no-ff) to detect conflicts
#   3. ALWAYS abort the trial merge — never commit staging into the feature branch
#   4. If conflicts exist — block push and report conflicting files
#
# Why abort instead of commit?
#   Committing the merge pollutes the feature branch with staging's history,
#   bloating the PR diff against master. CI runs on the staging PR after merge,
#   which catches integration issues — so testing against the merged result
#   here is unnecessary.
#
# Exit codes:
#   0 = no conflicts, allow push
#   2 = unresolvable merge conflicts, block push (Claude sees stderr)

BRANCH=$(git branch --show-current)

# Skip for non-feature branches (master, staging, main)
if [[ "$BRANCH" == "master" || "$BRANCH" == "staging" || "$BRANCH" == "main" ]]; then
    exit 0
fi

# Self-no-op: this hook trial-merges against origin/staging. Repos without a
# staging branch (single-branch projects like claude-kit, allmyles.github.io,
# Jekyll sandbox repos) don't participate in the staging→master flow — exit 0
# silently. (DASH-2122: not every consumer follows mileometer's branch model.)
if ! git rev-parse --verify origin/staging >/dev/null 2>&1; then
    exit 0
fi

TARGET_BRANCH="staging"

echo "Checking for merge conflicts with $TARGET_BRANCH..."

# Fetch latest target branch
git fetch origin "$TARGET_BRANCH" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "WARNING: Could not fetch origin/$TARGET_BRANCH. Skipping conflict check." >&2
    exit 0
fi

# Trial merge to detect conflicts — never committed, always aborted
git merge --no-commit --no-ff "origin/$TARGET_BRANCH" >/dev/null 2>&1
MERGE_EXIT_CODE=$?

if [ $MERGE_EXIT_CODE -eq 0 ]; then
    # No git conflicts — now check for Django migration graph forks.
    # Two migrations sharing the same dependency parent = forked graph.
    MIGRATION_DIR="mileometer/mileometer/migrations"
    if [ -d "$MIGRATION_DIR" ]; then
        # Extract dependency parent names from all migration files.
        # Each migration declares dependencies = [("mileometer", "0NNN_name")].
        # If two migrations share the same parent, the graph is forked.
        # Uses -E (POSIX extended regex) for macOS compatibility (no -P).
        FORKED_PARENTS=$(grep -hE '^\s*\("mileometer",\s*"[0-9]{4}_[^"]+"\)' "$MIGRATION_DIR"/0*.py 2>/dev/null \
            | sed 's/.*"\(0[0-9]*_[^"]*\)".*/\1/' \
            | sort | uniq -d)

        if [ -n "$FORKED_PARENTS" ]; then
            # Abort the trial merge first
            git merge --abort 2>/dev/null

            echo "BLOCKED: Django migration graph fork detected." >&2
            echo "" >&2
            echo "Multiple migrations depend on the same parent:" >&2
            echo "$FORKED_PARENTS" | while read -r parent; do
                echo "  Parent: $parent" >&2
                grep -rlE "\"$parent\"" "$MIGRATION_DIR"/0*.py 2>/dev/null | while read -r f; do
                    echo "    <- $(basename "$f")" >&2
                done
            done
            echo "" >&2
            echo "To resolve (see migration-policy/SKILL.md):" >&2
            echo "  1. Run: git fetch origin staging" >&2
            echo "  2. Find staging's latest migration number" >&2
            echo "  3. Renumber YOUR migration to staging's latest + 1" >&2
            echo "  4. Update YOUR migration's dependency to staging's latest migration name" >&2
            echo "  5. NEVER copy migration files from staging into your branch" >&2
            exit 2
        fi

        # Check for duplicate migration numbers (two files with same 4-digit prefix).
        # This catches cases where a feature branch carries a copy of a staging migration
        # alongside its own migration with the same number.
        DUPLICATE_NUMS=$(ls "$MIGRATION_DIR"/0*.py 2>/dev/null \
            | xargs -I {} basename {} .py \
            | grep -oE '^[0-9]+' \
            | sort | uniq -d)

        if [ -n "$DUPLICATE_NUMS" ]; then
            # Abort the trial merge first
            git merge --abort 2>/dev/null

            echo "BLOCKED: Duplicate migration numbers detected after trial merge." >&2
            echo "" >&2
            echo "Multiple migrations share the same number:" >&2
            echo "$DUPLICATE_NUMS" | while read -r num; do
                echo "  Number: $num" >&2
                ls "$MIGRATION_DIR"/${num}_*.py 2>/dev/null | while read -r f; do
                    echo "    - $(basename "$f")" >&2
                done
            done
            echo "" >&2
            echo "To resolve (see migration-policy/SKILL.md):" >&2
            echo "  1. Run: git fetch origin staging" >&2
            echo "  2. Find staging's latest migration number" >&2
            echo "  3. Renumber YOUR migration to staging's latest + 1" >&2
            echo "  4. Update YOUR migration's dependency to staging's latest migration name" >&2
            echo "  5. Remove any copied staging migration files from your branch" >&2
            exit 2
        fi
    fi

    # No conflicts, no migration forks, no duplicate numbers — abort to keep branch clean
    git merge --abort 2>/dev/null
    echo "No merge conflicts with $TARGET_BRANCH. Push allowed."
    exit 0
else
    # Merge had conflicts — collect conflicting file list
    CONFLICTING_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null)

    # Abort the failed merge to restore clean state
    git merge --abort 2>/dev/null

    echo "BLOCKED: Merge conflicts detected with origin/$TARGET_BRANCH." >&2
    echo "" >&2
    echo "Conflicting files:" >&2
    echo "$CONFLICTING_FILES" | while read -r file; do
        echo "  - $file" >&2
    done
    echo "" >&2
    echo "To resolve (NEVER rebase from staging — use master):" >&2
    echo "  1. Run: git rebase origin/master" >&2
    echo "  2. Resolve conflicts in each step" >&2
    echo "  3. Run: git add <resolved-files> && git rebase --continue" >&2
    echo "  4. Re-run tests: /test" >&2
    echo "  5. Push again with: git push --force-with-lease" >&2
    exit 2
fi
