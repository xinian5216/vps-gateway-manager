#!/usr/bin/env bash
# =============================================================================
# vps-gateway-manager :: tests/run.sh
#
#   bash tests/run.sh                # unit tests (any platform)
#   bash tests/run.sh unit           # same
#   bash tests/run.sh integration    # real squid, Linux + root required
#   bash tests/run.sh all
#   bash tests/run.sh unit 03        # only files matching "03"
#
# Integration tests are skipped automatically when squid is unavailable.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

MODE="${1:-unit}"
FILTER="${2:-}"
FAILED_FILES=""
PASS_FILES=0
RAN=0

run_dir() {
  local dir="$1" label="$2" f rc=0
  [ -d "$dir" ] || { printf 'no %s tests found\n' "$label"; return 0; }
  for f in "$dir"/*.sh; do
    [ -e "$f" ] || continue
    if [ -n "$FILTER" ] && ! printf '%s' "$(basename "$f")" | grep -q "$FILTER"; then
      continue
    fi
    RAN=$((RAN+1))
    printf '\n============================================================\n'
    printf '== %s :: %s\n' "$label" "$(basename "$f")"
    printf '============================================================\n'
    if bash "$f"; then
      PASS_FILES=$((PASS_FILES+1))
    else
      rc=1
      FAILED_FILES="$FAILED_FILES
  * $f"
    fi
  done
  return "$rc"
}

case "$MODE" in
  unit)        run_dir "$REPO_ROOT/tests/unit" "unit" ;;
  integration) run_dir "$REPO_ROOT/tests/integration" "integration" ;;
  all)
    run_dir "$REPO_ROOT/tests/unit" "unit"
    run_dir "$REPO_ROOT/tests/integration" "integration"
    ;;
  *) printf 'usage: run.sh [unit|integration|all] [filter]\n' >&2; exit 2 ;;
esac

printf '\n============================================================\n'
if [ "$RAN" -eq 0 ]; then
  printf 'runner: no test files matched\n'
  exit 1
fi
if [ -n "$FAILED_FILES" ]; then
  printf 'runner: %s/%s test files passed; failures:%s\n' "$PASS_FILES" "$RAN" "$FAILED_FILES"
  exit 1
fi
printf 'runner: all %s test file(s) passed\n' "$RAN"
exit 0
