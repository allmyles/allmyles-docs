#!/bin/bash
# Pre-push hook: Checks that all development gates are complete before allowing push.
# Verifies test marker freshness (actual test execution happens in /test and CI).
#
# Exit codes:
#   0 = all gates present and tests verified, allow push (also fires when
#       /develop is not in use in this repo — see the self-no-op guard below)
#   2 = missing gates or stale test marker, block push (Claude sees stderr)

# Anchor gate/marker paths to the project root so the hook is CWD-independent.
# CLAUDE_PROJECT_DIR is set by Claude Code; fall back to git rev-parse for
# manual invocations (developer running `git push` from a subdirectory).
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$PROJECT_ROOT" ]; then
    # No git repo / no CLAUDE_PROJECT_DIR — silent no-op rather than block,
    # since this hook can only validate workflow state when those exist.
    exit 0
fi

# Self-no-op: this hook enforces /develop's gate-file + branch-naming
# convention. Consumers that don't enable /develop (or that aren't on a
# Jira-driven workflow) shouldn't be blocked. Skip if neither the gates
# directory nor a DASH-XXXX branch prefix is present — both are needed for
# the gate enforcement to make sense.
# (DASH-2122: kit consumers opt in to /develop via their CLAUDE.md overlay.)
BRANCH=$(git branch --show-current)
if [ ! -d "$PROJECT_ROOT/.gates" ] && ! [[ "$BRANCH" =~ ^DASH-[0-9]+ ]]; then
    exit 0
fi

# Validate branch name follows Jira naming convention (now that we know the
# repo IS using /develop's workflow — gates dir exists OR branch is DASH-*).
if [[ ! "$BRANCH" =~ ^DASH-[0-9]+ ]]; then
    echo "BLOCKED: Branch name '$BRANCH' must start with a JIRA issue key (e.g. DASH-1234-description)" >&2
    exit 2
fi

GATES_DIR="$PROJECT_ROOT/.gates"
REQUIRED_GATES=(
    "db-synced"
    "jira-parsed"
    "design-complete"
    "implementation-complete"
    "tests-passed"
    "qa-passed"
    "security-scanned"
)

# Check if gates directory exists
if [ ! -d "$GATES_DIR" ]; then
    echo "BLOCKED: No gates directory found. Run /develop to complete all workflow steps." >&2
    echo "" >&2
    echo "Missing steps:" >&2
    for gate in "${REQUIRED_GATES[@]}"; do
        echo "  - $gate" >&2
    done
    echo "" >&2
    echo "If this is a docs/config-only change, create gates manually:" >&2
    echo "  mkdir -p $GATES_DIR && touch $GATES_DIR/{db-synced,jira-parsed,design-complete,implementation-complete,tests-passed,qa-passed,security-scanned}" >&2
    exit 2
fi

# Check each required gate
MISSING_GATES=()
for gate in "${REQUIRED_GATES[@]}"; do
    if [ ! -f "$GATES_DIR/$gate" ]; then
        MISSING_GATES+=("$gate")
    fi
done

# If any gates are missing, block the push
if [ ${#MISSING_GATES[@]} -gt 0 ]; then
    echo "BLOCKED: Development workflow incomplete. Missing gates:" >&2
    echo "" >&2
    for gate in "${MISSING_GATES[@]}"; do
        case "$gate" in
            "db-synced")
                echo "  - db-synced (Init: DB-Sync Pre-Flight not completed — see .claude/skills/migration-policy/SKILL.md § Local Pre-Flight Sync)" >&2
                ;;
            "jira-parsed")
                echo "  - jira-parsed (Step 1: Parse Jira issue not completed)" >&2
                ;;
            "design-complete")
                echo "  - design-complete (Step 2: Implementation design not completed)" >&2
                ;;
            "implementation-complete")
                echo "  - implementation-complete (Step 3: Feature implementation not completed)" >&2
                ;;
            "tests-passed")
                echo "  - tests-passed (Step 4: Tests not written or not passing)" >&2
                ;;
            "qa-passed")
                echo "  - qa-passed (Step 5: QA checks not completed)" >&2
                ;;
            "security-scanned")
                echo "  - security-scanned (Step 6: Security scan not completed)" >&2
                ;;
        esac
    done
    echo "" >&2
    echo "Complete the missing steps before pushing." >&2
    echo "" >&2
    echo "If this is a docs/config-only change, create missing gates:" >&2
    echo "  touch $GATES_DIR/{$(IFS=,; echo "${MISSING_GATES[*]}")}" >&2
    exit 2
fi

echo "All development gates present. Checking test marker..."

# Verify test marker freshness (CI runs the full suite — no need to re-run locally)
MARKER_FILE="$PROJECT_ROOT/.test-passed"
MAX_AGE_MINUTES=30

if [ ! -f "$MARKER_FILE" ]; then
    echo "BLOCKED: No test results found. Run /test before pushing." >&2
    echo "Tests must pass before any push is allowed." >&2
    exit 2
fi

# Check if marker is fresh (modified within MAX_AGE_MINUTES)
if [[ "$OSTYPE" == "darwin"* ]]; then
    MARKER_MOD=$(stat -f %m "$MARKER_FILE")
else
    MARKER_MOD=$(stat -c %Y "$MARKER_FILE")
fi

NOW=$(date +%s)
AGE_SECONDS=$((NOW - MARKER_MOD))
AGE_MINUTES=$((AGE_SECONDS / 60))

if [ "$AGE_MINUTES" -gt "$MAX_AGE_MINUTES" ]; then
    echo "BLOCKED: Test results are stale (${AGE_MINUTES}min old, max ${MAX_AGE_MINUTES}min)." >&2
    echo "Run /test again before pushing." >&2
    exit 2
fi

# All checks passed
echo "Tests passed ${AGE_MINUTES}min ago. All gates present. Push allowed."
exit 0
