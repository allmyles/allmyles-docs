#!/bin/bash
# DASH-2160: Import-graph targeted-test discovery.
#
# Replaces the filename-substring mapping the /develop skill used to
# document in Step 4 (e.g., views/booking.py → tests/*/test_*booking*).
# That mapping missed any test file whose name didn't carry the source
# filename as a substring — the DASH-2158 incident shape: an edit to
# mileometer/scheduled_task_engine.py was matched by
# tests/test_scheduled_task_engine.py (passed) but missed
# tests/test_scheduled_task_admin_reference.py (which imports
# SCHEDULED_TASK_SPECS via build_per_booking_type_matrix — failed in CI).
#
# This script does an import-graph match instead: for each changed
# source file, compute its module path, then `grep -l` for every test
# file that imports that path (either as ``from <module> import X`` or
# ``import <module>``). Both the canonical fully-qualified form
# (``from mileometer.scheduled_task_engine import``) and the relative
# host-mount form (``from scheduled_task_engine import`` — what tests
# actually use; see test_todo_list_view.py:34) are matched.
#
# Usage:
#   .claude/scripts/discover-targeted-tests.sh <changed_file> [<changed_file> ...]
#
# Reads file paths from stdin too:
#   git diff --name-only master...HEAD -- '*.py' | \
#     .claude/scripts/discover-targeted-tests.sh
#
# Output:
#   One test file path per line, relative to the repo root. Empty if no
#   tests match (no Python files changed, or no test imports the
#   changed modules — the caller should handle the empty case gracefully).
#
# Exit codes:
#   0 = success (output may be empty)
#   1 = configuration error (test tree not found, etc.)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The host's mileometer/ maps to /opt/code in the container; the test
# tree lives in mileometer/tests/. Module paths inside tests strip
# the leading "mileometer/" prefix (because Django adds /opt/code to
# sys.path), so an edit to mileometer/views/todo.py is imported in
# tests as either:
#   from views.todo import ...   (most common — see existing tests)
#   import views.todo            (rare)
#   from mileometer.views.todo import ...  (also accepted, fully-qualified)
# All three patterns are matched below.
TEST_ROOT="$REPO_ROOT/mileometer/tests"

if [ ! -d "$TEST_ROOT" ]; then
    echo "ERROR: test root not found at $TEST_ROOT" >&2
    exit 1
fi

# Collect changed files from args + stdin (if any).
# Portable indexed array — macOS ships Bash 3.2 where associative
# arrays (declare -A) are unavailable. Deduplication happens at the
# emission step via `sort -u`.
CHANGED_FILES=()
if [ "$#" -gt 0 ]; then
    CHANGED_FILES=("$@")
fi
if [ ! -t 0 ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && CHANGED_FILES+=("$line")
    done
fi

if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
    # No changed files. Output nothing; exit 0. This is a valid state —
    # e.g., a docs-only PR where the caller still invoked the script
    # defensively. Caller can detect empty output and skip pytest.
    exit 0
fi

# Discovered test files accumulate as one-per-line into this temp file;
# de-duplication happens at the emission step via `sort -u`. Avoids
# bash-4 associative arrays so the script runs on macOS's default
# Bash 3.2.
DISCOVERED_TMP=$(mktemp -t dash2160-discovered-XXXXXX)
trap 'rm -f "$DISCOVERED_TMP"' EXIT

for src in "${CHANGED_FILES[@]}"; do
    # Skip blank lines.
    [ -z "$src" ] && continue
    # Skip __pycache__.
    [[ "$src" == *__pycache__* ]] && continue
    # Skip non-Python.
    [[ "$src" != *.py ]] && continue

    # If the changed file IS a test file, include it directly. Tests
    # live under mileometer/tests/.
    if [[ "$src" == mileometer/tests/* ]] || [[ "$src" == tests/* ]]; then
        # Normalise to the canonical mileometer/tests/ form.
        case "$src" in
            mileometer/tests/*) echo "$src" >> "$DISCOVERED_TMP" ;;
            tests/*) echo "mileometer/$src" >> "$DISCOVERED_TMP" ;;
        esac
        continue
    fi

    # Compute the importable module path. Two candidate forms:
    #   - Strip the leading "mileometer/" prefix → ``views/todo.py`` →
    #     ``views.todo``. This matches the most common import shape in
    #     this codebase (the docker container adds /opt/code to sys.path
    #     and /opt/code IS the mounted mileometer/ directory).
    #   - Keep the prefix → ``mileometer.views.todo``. Some tests use
    #     this fully-qualified form.
    rel="${src#mileometer/}"            # views/todo.py | scheduled_task_engine.py
    rel="${rel#./}"                     # strip leading ./ if any
    module="${rel%.py}"                 # views/todo | scheduled_task_engine
    module="${module//\//.}"            # views.todo | scheduled_task_engine

    # Build a regex that matches the import statement forms Python uses
    # for the changed module. Three forms are covered (CR round 1.3):
    #
    #   1. ``from views.todo import X`` / ``import views.todo``
    #      — short form, module exposed at top level
    #   2. ``from mileometer.views.todo import X``
    #      — mileometer-prefixed form (some tests use it)
    #   3. ``from views import todo``
    #      — split import: package on the left, module name on the right.
    #      Pre-CR-1.3 this third form was missed, so an edit to
    #      ``views/todo.py`` would NOT pull in a test that imported via
    #      ``from views import todo`` — the same class of miss DASH-2158
    #      caught after the fact for ``scheduled_task_admin_reference.py``.
    #
    # Word boundary on the right side: ``\s|\.|$`` so a partial-prefix
    # match (``from views.todo_helper``) doesn't match ``views.todo``.
    # For the split form (#3) we use the same right-anchor on the leaf
    # name to keep ``from views import todo_helper`` from matching.
    #
    # The module path "views.todo" splits into package="views" + leaf="todo"
    # for the third form. Modules without a dot (top-level edit like
    # ``scheduled_task_engine.py``) skip the split-form regex — there's
    # no package to attribute it to.
    short_re="(from|import)[[:space:]]+${module}([[:space:]]|\\.|$)"
    long_re="(from|import)[[:space:]]+mileometer\\.${module}([[:space:]]|\\.|$)"
    if [[ "$module" == *.* ]]; then
        pkg="${module%.*}"
        leaf="${module##*.}"
        # Match ``from <pkg> import ... <leaf> ...`` — leaf can be one of
        # several comma-separated names. Use word-class boundaries so a
        # leaf "todo" doesn't match an import of "todo_helper".
        split_re="from[[:space:]]+${pkg}[[:space:]]+import[[:space:]]+[^#]*([^A-Za-z0-9_]|^)${leaf}([^A-Za-z0-9_]|$)"
        # Mileometer-prefixed split form: ``from mileometer.<pkg> import <leaf>``
        split_long_re="from[[:space:]]+mileometer\\.${pkg}[[:space:]]+import[[:space:]]+[^#]*([^A-Za-z0-9_]|^)${leaf}([^A-Za-z0-9_]|$)"
        grep_pattern="$short_re|$long_re|$split_re|$split_long_re"
    else
        grep_pattern="$short_re|$long_re"
    fi

    # grep -lE -r — list files containing any matching line. --include
    # restricts to .py files. -E for extended regex (we use {})
    while IFS= read -r found; do
        # found is an absolute path; convert to repo-relative. Quote
        # ``$REPO_ROOT`` inside the parameter expansion so a path that
        # happens to contain shell glob metacharacters (``*``, ``?``,
        # ``[``) doesn't trigger pattern expansion inside the prefix
        # removal — shellcheck-style safety. Today the project's repo
        # path doesn't have those, but future operator setups might.
        rel_found="${found#"$REPO_ROOT"/}"
        echo "$rel_found" >> "$DISCOVERED_TMP"
    done < <(grep -lE --include='*.py' -r "$grep_pattern" "$TEST_ROOT" 2>/dev/null)
done

# Emit the discovered set, sorted + deduplicated.
sort -u "$DISCOVERED_TMP"
