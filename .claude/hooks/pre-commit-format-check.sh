#!/bin/bash
# Pre-commit hook: Checks that staged and modified files pass all formatters
# configured in the CI deployment pipeline.
#
# Formatter list is dynamically read from the CI pipeline via get-ci-formatters.sh
# so that local checks always stay in sync with CI.
#
# Exit codes:
#   0 = all formatting checks pass
#   2 = formatting errors found, commit blocked

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GET_FORMATTERS="$REPO_ROOT/scripts/get-ci-formatters.sh"

# INF-164: bound the Docker-routed calls in the INF-138 tree-wide pass so a
# hung/unresponsive Docker daemon cannot stall `git commit` indefinitely.
# GNU `timeout` is absent on stock macOS — fall back to coreutils' `gtimeout`,
# and if neither exists run unbounded (no worse than pre-INF-164).
# Usage: _bounded <seconds> <command...>
_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        "$@"
    fi
}

if [ ! -x "$GET_FORMATTERS" ]; then
    echo "WARNING: get-ci-formatters.sh not found or not executable. Falling back to hardcoded checks." >&2
    GET_FORMATTERS=""
fi

# The loops below split each formatter's check_cmd into argv with `read -ra`,
# which is a bare whitespace tokenizer and cannot handle quoted arguments,
# env-var prefixes, or shell metacharacters. Enforce the restriction loudly:
# if a formatter entry needs something richer, the parser here must be
# upgraded first (or the formatters' serialization format must change).
validate_check_cmd() {
    local cmd="$1"
    local name="$2"
    # ``:`` is allowed in the character class so npm scripts like
    # ``npm run format:check`` (DASH-2160) parse cleanly. Without it,
    # the validator wrongly blocks every valid JS formatter entry.
    if [[ ! "$cmd" =~ ^[A-Za-z0-9./_:\ -]+$ ]]; then
        echo "BLOCKED: formatter '$name' has an unsupported check_cmd: $cmd" >&2
        echo "Only bare tokens of [A-Za-z0-9./_-] separated by single spaces are" >&2
        echo "supported. Quoted args, env-var prefixes, and shell metacharacters" >&2
        echo "would be silently misparsed by 'read -ra' — update the hook parser" >&2
        echo "before using a richer command shape." >&2
        exit 2
    fi
}

ERRORS=""

# Get staged and modified Python files (deduplicated) into an array so filenames
# with spaces or shell metacharacters cannot be interpreted as code.
# Use a portable while-read loop instead of `readarray` — macOS ships Bash 3.2
# by default, where the `readarray` builtin is unavailable.
PYTHON_FILES=()
while IFS= read -r file; do
    [ -n "$file" ] && PYTHON_FILES+=("$file")
done < <( (git diff --cached --name-only --diff-filter=ACM -- '*.py' 2>/dev/null; git diff --name-only --diff-filter=ACM -- '*.py' 2>/dev/null) | sort -u )

if [ ${#PYTHON_FILES[@]} -gt 0 ]; then
    # Get Python formatters from CI pipeline (or fall back to hardcoded).
    # DASH-2160: the get-ci-formatters.sh output now has 5 fields
    # (name|check_cmd|fix_cmd|lang|cwd); pre-commit ignores the 5th
    # (cwd) because it operates on per-file lists rather than running
    # the formatter on a whole directory like CI does. The hardcoded
    # fallback is retained for graceful degradation when the helper
    # script is missing, but its commands now match CI's invocation
    # shape (no more .venv/bin/black — DASH-2160 removed the .venv
    # drift path; see plan).
    if [ -n "$GET_FORMATTERS" ]; then
        PYTHON_FORMATTERS=$("$GET_FORMATTERS" --python)
    else
        PYTHON_FORMATTERS="black|black --check --config pyproject.toml|black --config pyproject.toml|python|.
flake8|flake8|flake8|python|."
    fi

    while IFS='|' read -r name check_cmd fix_cmd lang _cwd; do
        [ -z "$name" ] && continue
        validate_check_cmd "$check_cmd" "$name"
        # Split check_cmd into an argv array, then exec directly with the file
        # list. This avoids `eval`, which would execute shell metacharacters
        # embedded in filenames.
        read -ra CHECK_CMD_ARR <<< "$check_cmd"
        if ! OUTPUT=$("${CHECK_CMD_ARR[@]}" "${PYTHON_FILES[@]}" 2>&1); then
            ERRORS="${ERRORS}$(echo "$name" | tr '[:lower:]' '[:upper:]') CHECK FAILED:\n"
            ERRORS="${ERRORS}${OUTPUT}\n"
            ERRORS="${ERRORS}Fix: $fix_cmd $(printf '%q ' "${PYTHON_FILES[@]}")\n\n"
        fi
    done <<< "$PYTHON_FORMATTERS"
fi

# Get staged and modified JS/JSON files (deduplicated) into an array.
# Portable while-read loop (see note on PYTHON_FILES above).
JS_FILES=()
while IFS= read -r file; do
    [ -n "$file" ] && JS_FILES+=("$file")
done < <( (git diff --cached --name-only --diff-filter=ACM -- '*.js' '*.jsx' '*.ts' '*.tsx' '*.json' 2>/dev/null; git diff --name-only --diff-filter=ACM -- '*.js' '*.jsx' '*.ts' '*.tsx' '*.json' 2>/dev/null) | sort -u )

if [ ${#JS_FILES[@]} -gt 0 ]; then
    # Get JS formatters from CI pipeline (or fall back to hardcoded).
    # DASH-2160: CI uses ``npm run format:check`` / ``npm run lint`` (which
    # resolve via package.json), so the file list passed positionally
    # doesn't work — those npm scripts already encode the scope. The
    # pre-commit hook handles JS files differently from CI: it invokes
    # the underlying binary (prettier/eslint) directly with the file
    # list, so the check_cmd here is still the binary form. The hardcoded
    # fallback path keeps that binary form for compatibility; the
    # primary path (via get-ci-formatters.sh) emits the npm-script form
    # for CI parity. When the primary path is in use and the command
    # starts with ``npm ``, we skip the positional file append and let
    # the script's own scope-discovery apply.
    if [ -n "$GET_FORMATTERS" ]; then
        JS_FORMATTERS=$("$GET_FORMATTERS" --js)
    else
        JS_FORMATTERS="prettier|npx prettier --check|npx prettier --write|js|."
    fi

    while IFS='|' read -r name check_cmd fix_cmd lang _cwd; do
        [ -z "$name" ] && continue
        validate_check_cmd "$check_cmd" "$name"
        read -ra CHECK_CMD_ARR <<< "$check_cmd"
        TOOL_BIN="${CHECK_CMD_ARR[0]}"
        # Skip npx- and npm-based formatters when Node.js / npm is not installed
        if [ "$TOOL_BIN" = "npx" ] || [ "$TOOL_BIN" = "npm" ]; then
            if ! command -v "$TOOL_BIN" &> /dev/null; then
                continue
            fi
        fi
        # When the command is an npm script (`npm run X`), the script's
        # own definition in package.json encodes the file scope; we
        # invoke it with no per-file args. ``cd`` into the formatter's
        # ``_cwd`` field (DASH-2160 — feature_pipeline.yaml runs the
        # frontend-lint job from ``./mileometer``); a subshell scopes
        # the directory change so the rest of the loop keeps its
        # original CWD. Without this, ``npm run format:check`` fires
        # from the repo root where there is no package.json and exits
        # with a confusing "ENOENT" rather than the expected formatter
        # diagnostic.
        if [ "$TOOL_BIN" = "npm" ]; then
            if [ -n "${_cwd:-}" ] && [ "$_cwd" != "." ]; then
                # INF-187: _cwd is interpolated into a bash -c string —
                # constrain it to a safe repo-relative shape first so a
                # malformed formatter entry (quote, `..`, leading dash,
                # absolute path) can't inject shell syntax or escape the
                # repo. Dot-prefixed relative paths (`./packages`) are
                # legitimate (CR round 1.1); `..` is rejected as a PATH
                # COMPONENT, not a substring, so a literal `a..b`
                # directory name stays usable.
                if ! printf '%s' "$_cwd" | grep -qE '^(\./)?[A-Za-z0-9_][A-Za-z0-9_./-]*$' \
                   || printf '%s' "$_cwd" | grep -qE '(^|/)\.\.(/|$)'; then
                    echo "WARN: skipping formatter '$name' — unsafe cwd '$_cwd' (INF-187 guard)" >&2
                    continue
                fi
                NPM_RUN=( bash -c "cd '$_cwd' && exec ${CHECK_CMD_ARR[*]}" )
            else
                NPM_RUN=( "${CHECK_CMD_ARR[@]}" )
            fi
            if ! OUTPUT=$("${NPM_RUN[@]}" 2>&1); then
                ERRORS="${ERRORS}$(echo "$name" | tr '[:lower:]' '[:upper:]') CHECK FAILED:\n"
                ERRORS="${ERRORS}$(echo "$OUTPUT" | grep -v "^$")\n"
                ERRORS="${ERRORS}Fix: $fix_cmd\n\n"
            fi
        else
            if ! OUTPUT=$("${CHECK_CMD_ARR[@]}" "${JS_FILES[@]}" 2>&1); then
                ERRORS="${ERRORS}$(echo "$name" | tr '[:lower:]' '[:upper:]') CHECK FAILED:\n"
                ERRORS="${ERRORS}$(echo "$OUTPUT" | grep -v "^$")\n"
                ERRORS="${ERRORS}Fix: $fix_cmd $(printf '%q ' "${JS_FILES[@]}")\n\n"
            fi
        fi
    done <<< "$JS_FORMATTERS"
fi

# INF-174: actionlint pass for GitHub Actions workflow files.
#
# CI validates YAML syntax but NOT GitHub Actions semantics. A workflow
# file can be valid YAML yet invalid to Actions — e.g. an empty ${{ }}
# expression (even inside a run-block comment) invalidates the WHOLE file
# at parse time, so it fails as a startup_failure with no job ever running.
# DASH-2368 incident: PR #2965 passed PyYAML + Prettier + the full
# CodeRabbit pipeline yet broke BOTH deploy pipelines on staging AND master
# for ~35 min. actionlint (https://github.com/rhysd/actionlint) catches
# invalid expressions, unknown keys, and type errors in workflow files.
#
# Runner resolution is portable and best-effort: prefer an `actionlint` on
# PATH; else run the pinned Docker image; else emit a WARNING and skip. We
# do NOT block a commit when the tool genuinely cannot be obtained — this
# is local reinforcement of the CI check, not a hard dependency every
# consumer must install. When the tool IS available and finds an error,
# the finding lands in ERRORS and the existing exit-2 path blocks the
# commit.
WORKFLOW_FILES=()
while IFS= read -r file; do
    [ -n "$file" ] && WORKFLOW_FILES+=("$file")
done < <( (git diff --cached --name-only --diff-filter=ACM -- '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>/dev/null; git diff --name-only --diff-filter=ACM -- '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>/dev/null) | sort -u )

if [ ${#WORKFLOW_FILES[@]} -gt 0 ]; then
    # The hook's REPO_ROOT points at the plugin/.claude dir, not the git
    # repo root; resolve the actual repo root for the Docker bind mount.
    GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    ACTIONLINT_RUNNER=""
    if command -v actionlint >/dev/null 2>&1; then
        ACTIONLINT_RUNNER="path"
    elif docker ps >/dev/null 2>&1; then
        ACTIONLINT_RUNNER="docker"
    fi

    if [ -z "$ACTIONLINT_RUNNER" ]; then
        echo "WARNING: actionlint not on PATH and Docker not running — skipping" >&2
        echo "         GitHub Actions workflow validation for: ${WORKFLOW_FILES[*]}" >&2
        echo "         Install actionlint (https://github.com/rhysd/actionlint)" >&2
        echo "         or start Docker to enable the INF-174 workflow-semantics check." >&2
    else
        if [ "$ACTIONLINT_RUNNER" = "path" ]; then
            AL_OUTPUT=$(actionlint -no-color "${WORKFLOW_FILES[@]}" 2>&1)
            AL_RC=$?
        else
            # Pinned image for reproducibility; repo mounted read-only at
            # /repo (actionlint only reads), workflow paths are repo-root-
            # relative so they resolve against `-w /repo`. _bounded (INF-164)
            # so a hung/unresponsive Docker daemon cannot stall `git commit`.
            AL_OUTPUT=$(_bounded 60 docker run --rm -v "$GIT_ROOT":/repo:ro -w /repo \
                rhysd/actionlint:1.7.7 -no-color "${WORKFLOW_FILES[@]}" 2>&1)
            AL_RC=$?
            # CR round 1: Docker-LAYER failures are NOT actionlint verdicts.
            # `docker run` returns 125 (daemon error / image-pull failure),
            # 126 (entrypoint not executable), or 127 (entrypoint not found)
            # before the container process ever runs; _bounded's timeout
            # returns 124. actionlint's own finding exit code is 1. Treating
            # 124-127 as a "workflow is broken" verdict would block commits on
            # an image-pull miss or daemon flap. Reclassify them as the same
            # best-effort skip as an unobtainable tool (never block).
            if [ "$AL_RC" -ge 124 ] && [ "$AL_RC" -le 127 ]; then
                echo "WARNING: actionlint Docker run failed (exit $AL_RC — image" >&2
                echo "         pull / daemon / timeout, not a workflow error) —" >&2
                echo "         skipping the INF-174 check for: ${WORKFLOW_FILES[*]}" >&2
                AL_RC=0
                AL_OUTPUT=""
            fi
        fi
        if [ "$AL_RC" -ne 0 ]; then
            ERRORS="${ERRORS}ACTIONLINT CHECK FAILED (INF-174 — GitHub Actions workflow semantics):\n"
            ERRORS="${ERRORS}${AL_OUTPUT}\n"
            ERRORS="${ERRORS}Fix: correct the workflow error above (e.g. an empty \${{ }} expression invalidates the whole file). See https://github.com/rhysd/actionlint.\n\n"
        fi
    fi
fi

# INF-138: tree-wide CI-parity check via run-all-formatters.sh.
#
# The per-file Black + flake8 above runs on the host's PATH (fast, ~1s)
# which may diverge from CI's requirements-dev.txt-pinned Docker versions.
# DASH-2160 established run-all-formatters.sh as the CI-parity gate that
# routes through the meo_dashboard container; this hook now invokes it
# as an authoritative second-pass check after the fast per-file pass.
#
# Two-tier rationale (option (a) per INF-138):
#   - Per-file step (~1s, host PATH): catches obvious staged-file
#     Black/flake8 drift fast; runs without Docker dependency.
#   - Tree-wide step (~5s, Docker-routed): catches cross-file Black
#     reflow, F541/F811 from versioned flake8, and anything the per-file
#     step missed due to host-vs-CI version drift. The DASH-2211 case
#     (PR #2611's two consecutive CI lint failures) is exactly this:
#     F541 in a file the per-file flake8 either didn't see or saw with
#     a different version.
#
# Behavior:
#   - run-all-formatters.sh missing → skip with warning. Consumer hasn't
#     run setup-project.sh yet; per-file remains the baseline guard.
#   - Docker not running → skip with warning. Don't block commits when
#     Docker is down; per-file already ran and caught what it could.
#   - Docker running + formatter failure (exit 2) → block. Append to
#     ERRORS; the existing exit-2 path handles the rest.
#   - Any other non-zero exit (1 = the script's own infra checks: docker
#     flap, wrong dir, missing service; 124/125 = _bounded timeout;
#     126/127 = exec failure) → warn + skip. INF-164: classification is
#     by run-all-formatters.sh's documented EXIT CODE contract (1 =
#     infrastructure, 2 = formatter failure), not by string-matching its
#     stdout — a wording change there must never silently reclassify a
#     real formatter failure as a benign skip.
#
# Why not replace per-file with tree-wide? The ticket explicitly chose
# option (a) over (b) — keep the fast-path for the common case. If
# commit latency becomes a complaint, the per-file step can be retired
# in a follow-up; for now both run.

RUN_ALL_FORMATTERS="$REPO_ROOT/scripts/run-all-formatters.sh"
if [ -x "$RUN_ALL_FORMATTERS" ]; then
    if _bounded 10 docker ps > /dev/null 2>&1; then
        TREE_OUTPUT=$(_bounded 180 "$RUN_ALL_FORMATTERS" --check 2>&1)
        TREE_RC=$?
        if [ "$TREE_RC" -eq 2 ]; then
            # Exit 2 is run-all-formatters.sh's formatter-failure contract.
            ERRORS="${ERRORS}TREE-WIDE FORMATTER CHECK FAILED (run-all-formatters.sh --check):\n"
            ERRORS="${ERRORS}${TREE_OUTPUT}\n"
            ERRORS="${ERRORS}Fix: .claude/scripts/run-all-formatters.sh --fix && re-stage changed files, then commit again.\n\n"
        elif [ "$TREE_RC" -ne 0 ]; then
            # Exit 1 = the script's own infrastructure guards (Docker
            # stopped mid-check, wrong dir, missing compose service);
            # 124/125 = timeout; 126/127 = not runnable. None of these is
            # a formatter verdict — warn and fall back to the per-file
            # pass that already ran, instead of blocking the commit.
            echo "WARNING: tree-wide formatter pass skipped (run-all-formatters.sh exit ${TREE_RC} — infrastructure, not a formatter failure). Per-file checks above still apply." >&2
        fi
    else
        echo "WARNING: Docker not running — skipping tree-wide CI-parity formatter check (INF-138). Per-file Black/flake8 above ran on host PATH only; may diverge from CI." >&2
    fi
else
    echo "WARNING: $RUN_ALL_FORMATTERS not found or not executable — skipping tree-wide CI-parity check (INF-138). Run setup-project.sh to install kit helpers." >&2
fi

if [ -n "$ERRORS" ]; then
    echo "BLOCKED: Code formatting checks failed." >&2
    echo "" >&2
    echo -e "$ERRORS" >&2
    echo "Run formatters on the listed files, then try committing again." >&2
    exit 2
fi

echo "Formatting checks passed."
exit 0
