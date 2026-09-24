#!/usr/bin/env bash
# =============================================================================
# vps-gateway-manager :: tests/check.sh
#
# Static analysis gate. Runs everywhere (Linux CI, macOS, Git Bash):
#   * bash -n on every shell file in the repository
#   * shellcheck (when installed) with the project's rules
#   * a policy grep that blocks destructive firewall commands and other
#     forbidden patterns from ever entering the code base
#
# Usage: bash tests/check.sh [--quiet]
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
FAILED=0
CHECKED=0

say()  { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

# ---------------------------------------------------------------------------
# 1. Collect shell files
# ---------------------------------------------------------------------------
shell_files() {
  find . -type f \( -name '*.sh' -o -name 'ghproxyctl' -o -name 'install.sh' \) \
    -not -path './.git/*' -not -path './tests/.work/*' | sort
  # files that are shell but have no extension
  printf '%s\n' ./bin/ghproxyctl
  printf '%s\n' ./bin/vgm-bootstrap
}

say "== bash -n =="
while IFS= read -r f; do
  [ -f "$f" ] || continue
  CHECKED=$((CHECKED+1))
  if ! err="$(bash -n "$f" 2>&1)"; then
    fail "syntax error in $f: $err"
  fi
done < <(shell_files)
say "   parsed $CHECKED shell files"

# ---------------------------------------------------------------------------
# 2. shellcheck
# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  say "== shellcheck =="
  # shellcheck disable=SC2046
  if ! out="$(shellcheck -x -s bash -S warning $(shell_files) 2>&1)"; then
    printf '%s\n' "$out" | grep -v '^$' | head -n 80 >&2
    fail "shellcheck reported issues"
  else
    say "   shellcheck clean"
  fi
else
  say "== shellcheck: not installed, skipped =="
fi

# ---------------------------------------------------------------------------
# 3. Policy greps
# ---------------------------------------------------------------------------
say "== policy =="

# Only the *policy guard list* itself may contain these strings.
policy_hits="$(grep -rnE 'ufw[[:space:]]+(--force[[:space:]]+)?(reset|flush)|iptables[[:space:]]+-F|nft[[:space:]]+flush[[:space:]]+ruleset' \
  --include='*.sh' --include='ghproxyctl' . 2>/dev/null \
  | grep -v './tests/check.sh' | grep -v 'lib/firewall.sh' | grep -v './.git/' \
  | grep -v './tests/' || true)"   # tests assert that these strings never reach ufw
if [ -n "$policy_hits" ]; then
  printf '%s\n' "$policy_hits" >&2
  fail "destructive firewall command found in the code base"
fi

# Never allow an insecure TLS/curl pattern.
insecure_hits="$(grep -rnE 'curl[[:space:]].*(-k|--insecure)|sslflags=DONT_VERIFY_PEER|tls-default-ca=off|verify=False|ssl_verify=False' \
  --include='*.sh' --include='ghproxyctl' . 2>/dev/null \
  | grep -v './tests/check.sh' | grep -v './lib/firewall.sh' | grep -v './.git/' || true)"
if [ -n "$insecure_hits" ]; then
  printf '%s\n' "$insecure_hits" >&2
  fail "TLS verification bypass found in the code base"
fi

# 0.0.0.0/0 or ::/0 must never appear as an ACL/rule we create.
wildcard_hits="$(grep -rnE '(^|[^0-9.])(0\.0\.0\.0/0|::/0)([^0-9]|$)' \
  --include='*.sh' --include='ghproxyctl' --include='*.conf' --include='*.txt' . 2>/dev/null \
  | grep -v './tests/' | grep -v './.git/' | grep -v 'SECURITY.md' | grep -v 'policy-exempt' || true)"
if [ -n "$wildcard_hits" ]; then
  printf '%s\n' "$wildcard_hits" >&2
  fail "blanket 0.0.0.0/0 or ::/0 grant found in the code base"
fi
say "   policy greps done"

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
  printf 'check.sh: all static checks passed\n'
  exit 0
fi
printf 'check.sh: %d check(s) failed\n' "$FAILED" >&2
exit 1
