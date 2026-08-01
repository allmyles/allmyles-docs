#!/usr/bin/env bash
# kit-config.sh (INF-261) — resolve the EFFECTIVE develop-config JSON for the
# current repo. This is what /develop's Repo Shape Configuration loader uses
# instead of reading .claude/develop-config.json directly, so a repo WITHOUT a
# committed config still gets correct shape config — detected and cached
# kit-side, outside the repo (zero-footprint, epic INF-259).
#
# Precedence:
#   1. A committed .claude/develop-config.json (valid JSON) WINS — team-mode
#      repos and the kit itself are unchanged (no-regression, AC5).
#   2. Else the kit-side per-repo cache (persists across runs).
#   3. Else DETECT shape (shared kit-detect-shape.sh) + write the cache.
#
# Output modes:
#   (default)     print the effective JSON to stdout.
#   --emit-file   write the effective JSON to a stable kit-side path and print
#                 THAT PATH (so the /develop loader can point `CFG` at it and
#                 keep every `jq ... "$CFG"` call unchanged).
#   --refresh     force re-detection, ignoring the cache (a committed config
#                 still wins). Combinable with --emit-file.
#
# ALWAYS succeeds with valid output: if the kit-side cache cannot be
# resolved/written (unusable scratch path), it still detects + prints (default
# mode) or falls back to the committed path (--emit-file). Only a bad CLI arg
# exits non-zero.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REFRESH=false
EMIT_FILE=false
for arg in "$@"; do
    case "$arg" in
        --refresh)   REFRESH=true ;;
        --emit-file) EMIT_FILE=true ;;
        *) echo "kit-config.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$PWD"
# Detection (step 3) runs git in the CWD, so it MUST be the repo root. Track
# whether the cd succeeded; if it failed we REFUSE to detect from the wrong
# directory (CR round 1.1) — committed/cache use absolute paths and are
# unaffected, so they still resolve correctly.
CD_OK=true
cd "$PROJECT_ROOT" 2>/dev/null || CD_OK=false

COMMITTED="${PROJECT_ROOT}/.claude/develop-config.json"

# Resolve the kit-side scratch dir once (per-repo, outside the repo). Guard an
# empty / root / non-absolute path — in those cases there is simply no cache and
# no --emit-file target, and we degrade gracefully (never operate on root).
_SCRATCH=""
if [ -f "${SCRIPT_DIR}/kit-scratch-dir.sh" ]; then
    _SCRATCH="$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "${SCRIPT_DIR}/kit-scratch-dir.sh" 2>/dev/null)"
fi
CONFIG_DIR=""
case "$_SCRATCH" in
    ""|/) : ;;
    /*)   CONFIG_DIR="${_SCRATCH%/}/config" ;;
    *)    : ;;
esac
CACHE="${CONFIG_DIR:+${CONFIG_DIR}/develop-config.json}"

# ── Resolve EFFECTIVE_JSON per the precedence, and whether it came from a
#    committed file (for the --emit-file fast path). ──────────────────────────
EFFECTIVE_JSON=""
FROM_COMMITTED=false

# Validity check is `type == "object"` (not bare `jq -e .`): a config file whose
# top-level is null/false/array is not usable config, and bare `jq -e .` also
# returns non-zero for a valid `null`/`false` document (CR round 1.1) — an
# object test is the precise contract.
if [ -f "$COMMITTED" ] && jq -e 'type == "object"' "$COMMITTED" >/dev/null 2>&1; then
    EFFECTIVE_JSON="$(cat "$COMMITTED")"
    FROM_COMMITTED=true
elif [ "$REFRESH" != true ] && [ -n "$CACHE" ] && [ -f "$CACHE" ] && jq -e 'type == "object"' "$CACHE" >/dev/null 2>&1; then
    EFFECTIVE_JSON="$(cat "$CACHE")"
elif [ "$CD_OK" != true ]; then
    # Could not enter the repo root — detecting here would read the WRONG
    # directory. Emit an empty object so /develop's loader falls back to its
    # own documented field defaults rather than a mis-detected shape.
    echo "kit-config.sh: could not enter '$PROJECT_ROOT' — emitting empty config (loader defaults apply)." >&2
    EFFECTIVE_JSON='{}'
else
    # Detect shape (shared lib) + build valid JSON with jq (branch names are
    # escaped; the "null" sentinels become real JSON null). Only the DETECTED
    # fields are emitted — /develop's loader fills every other field from its
    # own documented defaults via `// default`.
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/kit-detect-shape.sh"
    _compute_shape
    EFFECTIVE_JSON="$(jq -n \
        --arg shape "$SHAPE" \
        --arg default_branch "$DEFAULT_BRANCH" \
        --arg pr_base_branch "$PR_BASE_BRANCH" \
        --arg required_check "$REQUIRED_CHECK" \
        --arg migration_tool "$MIGRATION_TOOL" \
        '{
           shape: $shape,
           default_branch: $default_branch,
           pr_base_branch: $pr_base_branch,
           required_check_name: (if $required_check == "null" then null else $required_check end),
           migration_tool: (if $migration_tool == "null" then null else $migration_tool end)
         }')"
    # Persist to the cache (best-effort, atomic temp+rename beside the target so
    # it is a real rename). A write failure never blocks the output.
    if [ -n "$CACHE" ] && ( umask 077; mkdir -p "$CONFIG_DIR" ) 2>/dev/null; then
        _tmp="$(mktemp "${CONFIG_DIR}/.develop-config.XXXXXX" 2>/dev/null || true)"
        if [ -n "$_tmp" ] && printf '%s\n' "$EFFECTIVE_JSON" > "$_tmp" 2>/dev/null; then
            mv "$_tmp" "$CACHE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
        fi
    fi
fi

# ── Output ─────────────────────────────────────────────────────────────────
if [ "$EMIT_FILE" = true ]; then
    # A committed config is already an on-disk file — point at it directly.
    if [ "$FROM_COMMITTED" = true ]; then
        printf '%s\n' "$COMMITTED"; exit 0
    fi
    # Otherwise write the effective JSON to a stable kit-side path.
    if [ -n "$CONFIG_DIR" ] && ( umask 077; mkdir -p "$CONFIG_DIR" ) 2>/dev/null; then
        EFFECTIVE="${CONFIG_DIR}/develop-config.effective.json"
        _etmp="$(mktemp "${CONFIG_DIR}/.effective.XXXXXX" 2>/dev/null || true)"
        if [ -n "$_etmp" ] && printf '%s\n' "$EFFECTIVE_JSON" > "$_etmp" 2>/dev/null && mv "$_etmp" "$EFFECTIVE" 2>/dev/null; then
            printf '%s\n' "$EFFECTIVE"; exit 0
        fi
        rm -f "$_etmp" 2>/dev/null || true
    fi
    # Could not write kit-side — fall back to the committed path ONLY if it is
    # valid config (an object). An invalid committed file must NEVER be returned
    # as the config path (CR round 1.1); emitting nothing lets the loader use its
    # own defaults.
    if [ -f "$COMMITTED" ] && jq -e 'type == "object"' "$COMMITTED" >/dev/null 2>&1; then
        printf '%s\n' "$COMMITTED"
    fi
    exit 0
fi

printf '%s\n' "$EFFECTIVE_JSON"
exit 0
