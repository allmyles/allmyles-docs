#!/usr/bin/env bash
# kit-gate.sh (INF-260) — /develop gate operations, backed by the per-repo
# SCRATCH dir (kit-scratch-dir.sh) instead of a `.gates/` directory inside the
# repo. Encapsulating gate I/O behind this helper keeps the agent's permission
# allowlist PROJECT-RELATIVE (`Bash(.claude/scripts/kit-gate.sh:*)`) rather than
# an uncommittable absolute path under $HOME (the DASH-1934 lesson), while the
# gate files themselves land outside the repo tree (zero-footprint, INF-259).
#
# Subcommands:
#   kit-gate.sh dir              → print the gates dir (creating it)
#   kit-gate.sh reset            → clear ALL gates (Init) and recreate the dir
#   kit-gate.sh set <name>       → create gate <name>
#   kit-gate.sh has <name>       → exit 0 if gate <name> exists, 1 otherwise
#   kit-gate.sh list             → list gate names, one per line
#   kit-gate.sh path <name>      → print the absolute path of gate <name>
#
# <name> is validated to a safe slug (letters, digits, dash, underscore, dot)
# so a caller can never escape the gates dir via `../` or an absolute path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The resolver is a sibling in the same scripts dir (plugin tree AND the
# .claude/scripts/ copy both keep them together).
SCRATCH_RESOLVER="${SCRIPT_DIR}/kit-scratch-dir.sh"

_resolve_scratch() {
    if [ -x "$SCRATCH_RESOLVER" ]; then
        "$SCRATCH_RESOLVER"
    elif [ -f "$SCRATCH_RESOLVER" ]; then
        bash "$SCRATCH_RESOLVER"
    fi
}

# Resolve the gates dir ONCE, up front, with a HARD guard: an empty or
# root-relative scratch path must NEVER become a gates dir — otherwise
# `reset` (rm -rf) or `set` could target `/gates` at the filesystem root
# (CR round 1.1, Major). Fail closed instead.
_SCRATCH="$(_resolve_scratch 2>/dev/null)"
if [ -z "$_SCRATCH" ]; then
    echo "kit-gate.sh: scratch resolver produced no path (resolver: $SCRATCH_RESOLVER) — refusing to operate on a root-relative gates dir." >&2
    exit 3
fi
case "$_SCRATCH" in
    /) echo "kit-gate.sh: scratch path is the filesystem root '/' — refusing." >&2; exit 3 ;;
    /*) : ;;  # absolute (and not exactly root), as required
    *)  echo "kit-gate.sh: scratch path '$_SCRATCH' is not absolute — refusing." >&2; exit 3 ;;
esac
_SCRATCH_TRIMMED="${_SCRATCH%/}"
# Belt-and-suspenders: a value like `//` trims to empty → would rebuild `/gates`.
if [ -z "$_SCRATCH_TRIMMED" ]; then
    echo "kit-gate.sh: scratch path '$_SCRATCH' resolves to root after trimming — refusing." >&2; exit 3
fi
GATES_DIR="${_SCRATCH_TRIMMED}/gates"

_valid_name() {
    # Reject empty, path separators, and `..` — the gate name must be a bare slug.
    case "$1" in
        ""|*/*|*..*) return 1 ;;
        *) case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac; return 0 ;;
    esac
}

CMD="${1:-}"; shift || true

case "$CMD" in
    dir)
        ( umask 077; mkdir -p "$GATES_DIR" ) 2>/dev/null || true
        printf '%s\n' "$GATES_DIR" ;;
    reset)
        rm -rf "$GATES_DIR" 2>/dev/null || true
        ( umask 077; mkdir -p "$GATES_DIR" ) 2>/dev/null || true
        printf '%s\n' "$GATES_DIR" ;;
    set)
        name="${1:-}"
        _valid_name "$name" || { echo "kit-gate.sh: invalid gate name '$name'" >&2; exit 2; }
        ( umask 077; mkdir -p "$GATES_DIR" ) 2>/dev/null || true
        : > "${GATES_DIR}/${name}" ;;
    has)
        name="${1:-}"
        _valid_name "$name" || { echo "kit-gate.sh: invalid gate name '$name'" >&2; exit 2; }
        [ -e "${GATES_DIR}/${name}" ] ;;
    path)
        name="${1:-}"
        _valid_name "$name" || { echo "kit-gate.sh: invalid gate name '$name'" >&2; exit 2; }
        printf '%s\n' "${GATES_DIR}/${name}" ;;
    list)
        [ -d "$GATES_DIR" ] && ls -1 "$GATES_DIR" 2>/dev/null || true ;;
    *)
        echo "kit-gate.sh: unknown subcommand '${CMD}' (want: dir|reset|set|has|list|path)" >&2
        exit 2 ;;
esac
