#!/bin/bash
# Post-push hook: Verifies an open PR exists for the current branch.
# Auto-merge is handled by the staging_auto_merge.yaml GitHub Actions pipeline.
#
# This hook runs AFTER a successful push and provides informational
# output (never blocks, since push already succeeded).
# CI pipeline and merging are handled separately — this hook only
# checks for PR existence.

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)

# Skip for master/staging/main branches (no PR needed)
if echo "$CURRENT_BRANCH" | grep -qE "^(master|main|staging)$"; then
    exit 0
fi

# Skip if no branch detected
if [ -z "$CURRENT_BRANCH" ]; then
    exit 0
fi

# Detect the repo's PR target branch — repos with staging use staging,
# repos without staging fall back to main (single-branch projects like
# claude-kit, allmyles.github.io). DASH-2122: kit consumers don't all
# follow mileometer's staging→master flow.
if git rev-parse --verify origin/staging >/dev/null 2>&1; then
    PR_BASE="staging"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
    PR_BASE="main"
elif git rev-parse --verify origin/master >/dev/null 2>&1; then
    PR_BASE="master"
else
    # No identifiable default branch — silent no-op.
    exit 0
fi

# Check for open PR using gh CLI if available
if command -v gh &> /dev/null; then
    PR_NUMBER=$(gh pr list --state open --head "$CURRENT_BRANCH" --base "$PR_BASE" --json number --jq '.[0].number' 2>/dev/null)
    if [ -z "$PR_NUMBER" ]; then
        echo "WARNING: No open ${PR_BASE} PR found for branch '$CURRENT_BRANCH'."
        echo ""
        echo "MANDATORY: Create a PR targeting ${PR_BASE} now. Use:"
        echo "  gh pr create --base ${PR_BASE} --title \"DASH-XXXX: type: Description\""
    else
        echo "PR #${PR_NUMBER} exists for '$CURRENT_BRANCH' (base: ${PR_BASE})."
    fi
else
    # gh CLI not available - use GitHub MCP tool instruction
    echo "REMINDER: Verify an open PR exists for branch '$CURRENT_BRANCH' (target: ${PR_BASE})."
fi

exit 0
