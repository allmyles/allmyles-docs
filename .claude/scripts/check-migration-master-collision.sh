#!/bin/bash
# check-migration-master-collision.sh (DASH-2342)
#
# ADVISORY check: compares a feature branch's NEW migration files against
# origin/master to surface a migration-number collision *at feature-PR time*,
# instead of only at staging→master promotion time (the late
# staging_to_master_pr.yaml warning that bit DASH-2333/2334).
#
# Why advisory, not blocking: the feature IS correctly numbered for staging
# (the blocking `migration-collision-check` gate already enforces that). master
# legitimately lags staging in the per-feature promotion model, so a
# master-relative collision must NOT block staging integration ("a staging
# deploy must never block parallel feature development"). This surfaces the
# collision early so it can be addressed before promotion. Exit 0 ALWAYS.
#
# Same-blob exclusion (the DASH-2341 stacking case): if master already has the
# SAME migration filename and it is byte-identical, that is an
# inherited/already-promoted identical file, NOT a real collision — classified
# INFO, not WARN. Only a different-content same-file, or a different-file
# same-number, is a WARN.
#
# Output: one `FINDING <WARN|INFO> <kind> <basename> (<detail>)` line per
# flagged file, then a `SUMMARY warn=N info=M checked=K master_latest=L` line.
#
# Usage:
#   check-migration-master-collision.sh [--migration-dir DIR] [--base REF] [FILE...]
#     --migration-dir DIR  migrations dir (default mileometer/mileometer/migrations)
#     --base REF           ref to compare against (default origin/master)
#     FILE...              explicit migration file paths to check. When omitted,
#                          the new/modified migration files are computed via
#                          `git diff --diff-filter=AM <base>...HEAD`.

set -uo pipefail

MIGRATION_DIR="mileometer/mileometer/migrations"
BASE_REF="origin/master"
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --migration-dir) MIGRATION_DIR="$2"; shift 2 ;;
    --base) BASE_REF="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    *) FILES+=("$1"); shift ;;
  esac
done

# Best-effort fetch so the comparison is current. No-op (fail open) when the
# base is a purely local ref, e.g. in tests.
git fetch --quiet origin "${BASE_REF#origin/}" 2>/dev/null || true

# Resolve the set of new/modified migration files when not given explicitly.
if [ "${#FILES[@]}" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < <(git diff --name-only --diff-filter=AM "${BASE_REF}...HEAD" -- "$MIGRATION_DIR" 2>/dev/null \
            | grep -E "/[0-9]{4}_[^/]*\.py$" || true)
fi

# master's migration basenames + latest number (base-10 guard; DASH-2287).
MASTER_FILES=$(git ls-tree "$BASE_REF" --name-only "$MIGRATION_DIR/" 2>/dev/null | sed 's|.*/||' | grep -E '^[0-9]{4}_' || true)
LATEST_MASTER_FILE=$(printf '%s\n' "$MASTER_FILES" | sort | tail -1)
LATEST_MASTER_NUM=$(printf '%s' "$LATEST_MASTER_FILE" | grep -oE '^[0-9]+' || echo "0")
LATEST_MASTER_NUM=$((10#${LATEST_MASTER_NUM:-0}))

WARN_COUNT=0
INFO_COUNT=0
CHECKED=0

if [ "${#FILES[@]}" -gt 0 ]; then
  for file in "${FILES[@]}"; do
    [ -z "$file" ] && continue
    base=$(basename "$file")
    bnum=$(printf '%s' "$base" | grep -oE '^[0-9]+' || true)
    [ -z "$bnum" ] && continue
    CHECKED=$((CHECKED + 1))

    # Same filename already on master?
    if printf '%s\n' "$MASTER_FILES" | grep -qx "$base"; then
      feat_blob=$(git rev-parse "HEAD:${MIGRATION_DIR}/${base}" 2>/dev/null || echo "")
      master_blob=$(git rev-parse "${BASE_REF}:${MIGRATION_DIR}/${base}" 2>/dev/null || echo "")
      if [ -n "$feat_blob" ] && [ "$feat_blob" = "$master_blob" ]; then
        echo "FINDING INFO same-file-identical ${base} (already on master, byte-identical — inherited/promoted, not a collision; see DASH-2341)"
        INFO_COUNT=$((INFO_COUNT + 1))
      else
        echo "FINDING WARN same-file-different ${base} (same filename on master with DIFFERENT content — will collide on promotion)"
        WARN_COUNT=$((WARN_COUNT + 1))
      fi
      continue
    fi

    # Different filename, same 4-digit number already taken on master?
    master_same_num=$(printf '%s\n' "$MASTER_FILES" | grep -E "^${bnum}_" | head -1 || true)
    if [ -n "$master_same_num" ]; then
      suggested=$((LATEST_MASTER_NUM + 1))
      echo "FINDING WARN number-collision ${base} (number ${bnum} already taken on master by ${master_same_num} — will collide on promotion; renumber toward ${suggested} when promoting)"
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  done
fi

echo "SUMMARY warn=${WARN_COUNT} info=${INFO_COUNT} checked=${CHECKED} master_latest=${LATEST_MASTER_NUM}"
exit 0
