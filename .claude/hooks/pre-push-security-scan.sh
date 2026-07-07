#!/bin/bash
# Pre-push hook: Scans modified files for common security vulnerabilities.
# Checks for OWASP top 10 patterns: hardcoded secrets, SQL injection,
# XSS, command injection, and sensitive file exposure.
#
# Exit codes:
#   0 = no security issues found
#   2 = critical security issues found, push blocked

# Self-no-op: detect the repo's default branch (master OR main) so the scan
# works for consumers regardless of branch convention. If neither exists, the
# diff comparison can't run — exit 0 silently (the security scan is opt-in
# via having a default branch to compare against).
# (DASH-2122: kit consumers use different default-branch names.)
DEFAULT_BRANCH=""
if git rev-parse --verify origin/master >/dev/null 2>&1; then
    DEFAULT_BRANCH="master"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
    DEFAULT_BRANCH="main"
else
    exit 0
fi

echo "Running security scan on modified files (diff against origin/${DEFAULT_BRANCH})..."

# Get files modified compared to the default branch
CHANGED_FILES=$(git diff "origin/${DEFAULT_BRANCH}...HEAD" --name-only 2>/dev/null)

if [ -z "$CHANGED_FILES" ]; then
    echo "No changed files to scan."
    exit 0
fi

CRITICAL_ISSUES=""
WARNINGS=""

for FILE in $CHANGED_FILES; do
    # Skip non-existent files (deleted)
    [ ! -f "$FILE" ] && continue
    # Skip test files (they may intentionally have test credentials)
    echo "$FILE" | grep -qE "(test_|_test\.py|tests/|\.test\.)" && continue
    # Skip migration files
    echo "$FILE" | grep -qE "migrations/" && continue

    CONTENT=$(cat "$FILE" 2>/dev/null)

    # --- CRITICAL: Hardcoded secrets ---
    # API keys, passwords, tokens (common patterns)
    if echo "$CONTENT" | grep -nE "(api_key|apikey|secret_key|password|token|auth_token)\s*=\s*['\"][^'\"]{8,}['\"]" | grep -ivE "(test|example|dummy|placeholder|xxx|fake|mock)" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE "(api_key|apikey|secret_key|password|token|auth_token)\s*=\s*['\"][^'\"]{8,}['\"]" | grep -ivE "(test|example|dummy|placeholder|xxx|fake|mock)")
        CRITICAL_ISSUES="${CRITICAL_ISSUES}HARDCODED SECRET in ${FILE}:\n${MATCHES}\n\n"
    fi

    # AWS keys
    if echo "$CONTENT" | grep -nE "AKIA[0-9A-Z]{16}" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE "AKIA[0-9A-Z]{16}")
        CRITICAL_ISSUES="${CRITICAL_ISSUES}AWS ACCESS KEY in ${FILE}:\n${MATCHES}\n\n"
    fi

    # Private keys
    if echo "$CONTENT" | grep -nE "BEGIN (RSA |DSA |EC )?PRIVATE KEY" > /dev/null 2>&1; then
        CRITICAL_ISSUES="${CRITICAL_ISSUES}PRIVATE KEY in ${FILE}\n\n"
    fi

    # --- CRITICAL: SQL Injection ---
    # Raw SQL with string formatting
    if echo "$CONTENT" | grep -nE "(execute|raw)\(.*(%s|%d|\{|f\"|format)" | grep -ivE "(%s.*,|\[)" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE "(execute|raw)\(.*(%s|%d|\{|f\"|format)" | grep -ivE "(%s.*,|\[)")
        if [ -n "$MATCHES" ]; then
            WARNINGS="${WARNINGS}POSSIBLE SQL INJECTION in ${FILE}:\n${MATCHES}\nUse parameterized queries instead.\n\n"
        fi
    fi

    # f-string in SQL
    if echo "$CONTENT" | grep -nE "(SELECT|INSERT|UPDATE|DELETE|DROP).*f['\"]" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE "(SELECT|INSERT|UPDATE|DELETE|DROP).*f['\"]")
        CRITICAL_ISSUES="${CRITICAL_ISSUES}SQL INJECTION (f-string) in ${FILE}:\n${MATCHES}\n\n"
    fi

    # --- CRITICAL: Command Injection ---
    if echo "$CONTENT" | grep -nE "os\.(system|popen)\(.*(\+|format|f['\"]|%)" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE "os\.(system|popen)\(.*(\+|format|f['\"]|%)")
        CRITICAL_ISSUES="${CRITICAL_ISSUES}COMMAND INJECTION in ${FILE}:\n${MATCHES}\n\n"
    fi

    # subprocess with shell=True and variables
    if echo "$CONTENT" | grep -nE "subprocess\.(run|call|Popen)\(.*shell\s*=\s*True" > /dev/null 2>&1; then
        MATCHES=$(echo "$CONTENT" | grep -nE "subprocess\.(run|call|Popen)\(.*shell\s*=\s*True")
        WARNINGS="${WARNINGS}SHELL=TRUE in subprocess in ${FILE}:\n${MATCHES}\nAvoid shell=True with user input.\n\n"
    fi

    # --- WARNING: XSS patterns ---
    # Django template |safe filter
    if echo "$FILE" | grep -qE "\.(html|htm)$"; then
        if echo "$CONTENT" | grep -nE "\|\s*safe" > /dev/null 2>&1; then
            MATCHES=$(echo "$CONTENT" | grep -nE "\|\s*safe")
            WARNINGS="${WARNINGS}XSS RISK (|safe filter) in ${FILE}:\n${MATCHES}\n\n"
        fi
    fi

    # innerHTML in JS
    if echo "$FILE" | grep -qE "\.(js|jsx|ts|tsx)$"; then
        if echo "$CONTENT" | grep -nE "innerHTML\s*=" > /dev/null 2>&1; then
            MATCHES=$(echo "$CONTENT" | grep -nE "innerHTML\s*=")
            WARNINGS="${WARNINGS}XSS RISK (innerHTML) in ${FILE}:\n${MATCHES}\nUse textContent instead.\n\n"
        fi
    fi

    # --- CRITICAL: Sensitive files ---
    if echo "$FILE" | grep -qE "\.(env|pem|key|p12|pfx|credentials)$"; then
        CRITICAL_ISSUES="${CRITICAL_ISSUES}SENSITIVE FILE being committed: ${FILE}\nThis file should be in .gitignore.\n\n"
    fi
done

# Report results
if [ -n "$CRITICAL_ISSUES" ]; then
    echo "BLOCKED: Critical security issues found." >&2
    echo "" >&2
    echo -e "$CRITICAL_ISSUES" >&2
    if [ -n "$WARNINGS" ]; then
        echo "Additional warnings:" >&2
        echo -e "$WARNINGS" >&2
    fi
    exit 2
fi

if [ -n "$WARNINGS" ]; then
    echo "Security scan passed with warnings:"
    echo -e "$WARNINGS"
    echo "No critical issues. Push allowed."
    exit 0
fi

echo "Security scan passed. No issues found."
exit 0
