#!/bin/bash
# Pre-push hook: CodeRabbit-style review scan.
# Catches the patterns CodeRabbit commonly flags — input hardening, missing
# test assertions, variable shadowing, and unguarded external data access —
# so they are fixed BEFORE code reaches CI.
#
# This is a heuristic scan (grep-based). All findings block the push to
# ensure fixes before the PR. The agent reviews and fixes flagged issues.
#
# Exit codes:
#   0 = no issues found
#   2 = issues found (critical or warnings), push blocked to ensure fixes before PR

# Self-no-op: detect the repo's default branch (master OR main). If neither
# exists, the diff comparison can't run — exit 0 silently.
# (DASH-2122: kit consumers use different default-branch names.)
DEFAULT_BRANCH=""
if git rev-parse --verify origin/master >/dev/null 2>&1; then
    DEFAULT_BRANCH="master"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
    DEFAULT_BRANCH="main"
else
    exit 0
fi

echo "Running CodeRabbit-style review on modified files (diff against origin/${DEFAULT_BRANCH})..."

# Get the diff against the default branch
DIFF=$(git diff "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null)

if [ -z "$DIFF" ]; then
    echo "No changes to review."
    exit 0
fi

# Get changed files (excluding deleted)
CHANGED_FILES=$(git diff "origin/${DEFAULT_BRANCH}...HEAD" --name-only --diff-filter=d 2>/dev/null)

# Extract only added/modified lines from the diff for a given file.
# This prevents legacy patterns in untouched lines from blocking pushes.
get_added_lines_for_file() {
    local file="$1"
    git diff --unified=0 origin/master...HEAD -- "$file" 2>/dev/null \
      | grep '^+' \
      | grep -v '^\+\+\+' \
      | sed 's/^+//'
}

# TODO: Promote findings to CRITICAL_ISSUES for checks that should hard-block
# (e.g., leaked secrets, license violations). Currently all findings are warnings.
CRITICAL_ISSUES=""
WARNINGS=""

# ============================================================
# 1. INPUT HARDENING — unguarded dict/list access on external data
# ============================================================
while IFS= read -r FILE; do
    [ ! -f "$FILE" ] && continue
    echo "$FILE" | grep -qE "migrations/" && continue
    echo "$FILE" | grep -qE "\.(py)$" || continue

    CONTENT=$(get_added_lines_for_file "$FILE")
    [ -z "$CONTENT" ] && continue

    # Detect response.json()[key] or data[key] without prior isinstance/get/if checks
    # Look for direct index access on json() results: .json()["key"] or .json()[0]
    if echo "$CONTENT" | grep -nE '\.json\(\)\s*\[' > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE '\.json\(\)\s*\[')
        WARNINGS="${WARNINGS}UNGUARDED JSON ACCESS in ${FILE}:\n${MATCHES}\nValidate response shape before indexing .json() result.\n\n"
    fi

    # Detect chained dict access like data["key1"]["key2"] (2+ levels deep)
    if echo "$CONTENT" | grep -nE '\[["\x27][a-zA-Z_]+["\x27]\]\s*\[["\x27]' > /dev/null 2>&1; then
        # Exclude lines that have .get( or isinstance on them (already guarded)
        MATCHES=$(echo "$CONTENT" | grep -nE '\[["\x27][a-zA-Z_]+["\x27]\]\s*\[["\x27]' | grep -ivE "(\.get\(|isinstance|if .* in )")
        if [ -n "$MATCHES" ]; then
            WARNINGS="${WARNINGS}DEEP DICT ACCESS without guard in ${FILE}:\n${MATCHES}\nConsider using .get() or validating keys exist.\n\n"
        fi
    fi

    # Skip test files for index-access checks (tests often index known fixtures)
    echo "$FILE" | grep -qE "(test_|_test\.py|tests/)" && continue

    # Detect list[0] or list[-1] without length/empty check (heuristic — may
    # have false positives; tuple unpacking `first, *rest = items` is a safer
    # alternative that doesn't need guards)
    if echo "$CONTENT" | grep -nE '[a-z_]+\[0\]' | grep -ivE "(range|enumerate|sys\.argv|args\[0\]|__)" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE '[a-z_]+\[0\]' | grep -ivE "(range|enumerate|sys\.argv|args\[0\]|__|\.split|\.items|\.values|\.keys)")
        if [ -n "$MATCHES" ]; then
            WARNINGS="${WARNINGS}UNGUARDED INDEX [0] in ${FILE}:\n${MATCHES}\nVerify list is non-empty before indexing.\n\n"
        fi
    fi
done <<< "$CHANGED_FILES"

# ============================================================
# 2. TEST ASSERTION COMPLETENESS — tests without response assertions
# ============================================================
while IFS= read -r FILE; do
    [ ! -f "$FILE" ] && continue
    echo "$FILE" | grep -qE "(test_|_test\.py|tests/)" || continue
    echo "$FILE" | grep -qE "\.py$" || continue

    CONTENT=$(get_added_lines_for_file "$FILE")
    [ -z "$CONTENT" ] && continue

    # Find test methods that call self.client (Django test client) but never assert status_code
    # Use a simple heuristic: test function with client.get/post/put/patch/delete but no assert.*status
    PYTHON_TEST_FUNCS=$(echo "$CONTENT" | grep -n "def test_")
    if [ -n "$PYTHON_TEST_FUNCS" ]; then
        # Check if file uses Django test client but has no status_code assertions
        if echo "$CONTENT" | grep -qE "self\.client\.(get|post|put|patch|delete)" 2>/dev/null; then
            if ! echo "$CONTENT" | grep -qE "(\.status_code|assert.*status|assertEqual.*20[0-9]|assertEqual.*30[0-9]|assertEqual.*40[0-9])" 2>/dev/null; then
                WARNINGS="${WARNINGS}MISSING STATUS ASSERTION in ${FILE}:\nTests use Django client but no status_code assertions found.\nEvery client call should assert the response status.\n\n"
            fi
        fi
    fi
done <<< "$CHANGED_FILES"

# ============================================================
# 3. VARIABLE SHADOWING — same name reused with different meaning
# ============================================================
while IFS= read -r FILE; do
    [ ! -f "$FILE" ] && continue
    echo "$FILE" | grep -qE "\.(py)$" || continue
    echo "$FILE" | grep -qE "(test_|_test\.py|tests/|migrations/)" && continue

    CONTENT=$(get_added_lines_for_file "$FILE")
    [ -z "$CONTENT" ] && continue

    # Detect common shadowing pattern: builtin names used as variables
    # Uses POSIX ERE (portable — grep -P is unavailable on macOS/BSD)
    for BUILTIN in "id" "type" "list" "dict" "input" "format" "map" "filter" "hash" "range" "object"; do
        if echo "$CONTENT" | grep -nE "^[[:space:]]*${BUILTIN}[[:space:]]*=[[:space:]]*($|[^=])" > /dev/null 2>&1; then
            MATCHES=$(echo "$CONTENT" | grep -nE "^[[:space:]]*${BUILTIN}[[:space:]]*=[[:space:]]*($|[^=])")
            WARNINGS="${WARNINGS}BUILTIN SHADOWING '${BUILTIN}' in ${FILE}:\n${MATCHES}\nAvoid shadowing Python builtins.\n\n"
            break  # one warning per file is enough
        fi
    done
done <<< "$CHANGED_FILES"

# ============================================================
# 4. LEAST-PRIVILEGE — Docker mounts, workflow permissions
# ============================================================
while IFS= read -r FILE; do
    [ ! -f "$FILE" ] && continue

    # Check Docker Compose files for writable mounts that should be read-only
    if echo "$FILE" | grep -qE "(docker-compose|compose).*\.ya?ml$"; then
        CONTENT=$(get_added_lines_for_file "$FILE")
        [ -z "$CONTENT" ] && continue
        # Volumes without :ro that aren't data dirs
        if echo "$CONTENT" | grep -nE "^\s+-\s+\.\/" | grep -vE "(:ro|/data|/logs|/media|/static|/tmp|/app|/code|/opt)" > /dev/null 2>&1; then
            MATCHES=$(echo "$CONTENT" | grep -nE "^\s+-\s+\.\/" | grep -vE "(:ro|/data|/logs|/media|/static|/tmp|/app|/code|/opt)")
            WARNINGS="${WARNINGS}MOUNT WITHOUT :ro in ${FILE}:\n${MATCHES}\nConsider read-only mounts where writes are unnecessary.\n\n"
        fi
    fi

    # Check GitHub Actions for missing permissions block
    if echo "$FILE" | grep -qE "\.github/workflows/.*\.ya?ml$"; then
        CONTENT=$(get_added_lines_for_file "$FILE")
        [ -z "$CONTENT" ] && continue
        if ! echo "$CONTENT" | grep -qE "^[[:space:]]*permissions:" 2>/dev/null; then
            WARNINGS="${WARNINGS}MISSING PERMISSIONS BLOCK in ${FILE}:\nGitHub Actions workflow should declare explicit least-privilege permissions.\n\n"
        fi
    fi
done <<< "$CHANGED_FILES"

# ============================================================
# Report results
# ============================================================
if [ -n "$CRITICAL_ISSUES" ]; then
    echo "BLOCKED: Critical CodeRabbit-style issues found." >&2
    echo "" >&2
    echo -e "$CRITICAL_ISSUES" >&2
    if [ -n "$WARNINGS" ]; then
        echo "Additional warnings:" >&2
        echo -e "$WARNINGS" >&2
    fi
    exit 2
fi

if [ -n "$WARNINGS" ]; then
    echo "BLOCKED: CodeRabbit-style review found issues that should be fixed before push." >&2
    echo "" >&2
    echo -e "$WARNINGS" >&2
    echo "Fix these issues to avoid CodeRabbit flagging them on the PR." >&2
    echo "If these are false positives, add a comment explaining why and re-push." >&2
    exit 2
fi

echo "CodeRabbit-style review passed. No issues found."
exit 0
