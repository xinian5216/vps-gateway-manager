#!/usr/bin/env bash
# =============================================================================
# unit test :: policy audit and the dry-run service-manager allowlist
#
# Pins three findings from the second real production dry-run:
#   * "http_access deny all" was reported as a blanket "allow all" (open proxy)
#     because the check matched both verbs - a dangerous false positive on every
#     production configuration
#   * systemctl list-timers was suppressed under --dry-run, so a real host with
#     certbot.timer showed an empty "renewal timer" section
#   * the discovery report must not print its temporary file path
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

WORK="$SANDBOX/audit"
mkdir -p "$WORK"

audit() {
  # audit <config-file> [more files...] -> sets AUDIT_RC and prints the output
  AUDIT_OUT="$(GP_VERBOSE=1 squid_policy_audit "$@" 2>&1)"; AUDIT_RC=$?
  printf '%s\n' "$AUDIT_OUT"
}

# -----------------------------------------------------------------------------
# squid_policy_audit: only a literal "http_access allow all" is dangerous
# -----------------------------------------------------------------------------
t_begin "http_access allow all is rejected as an open proxy"
printf 'http_access allow all\n' > "$WORK/allow-all.conf"
audit "$WORK/allow-all.conf" >/dev/null
assert_eq "1" "$AUDIT_RC" "the audit fails"
assert_contains "$AUDIT_OUT" 'blanket' "the open-proxy finding is reported"
assert_contains "$AUDIT_OUT" 'open proxy' "the open-proxy finding is explicit"

t_begin "http_access deny all is the safe terminator"
printf 'http_access deny all\n' > "$WORK/deny-all.conf"
audit "$WORK/deny-all.conf" >/dev/null
assert_eq "0" "$AUDIT_RC" "the audit passes"
assert_not_contains "$AUDIT_OUT" 'open proxy' "no open-proxy finding for deny all"
assert_not_contains "$AUDIT_OUT" 'not a deny' "the final-rule check accepts it"

t_begin "a normal login-like config is not reported"
printf 'http_access allow localhost\nhttp_access deny all\n' > "$WORK/localhost.conf"
audit "$WORK/localhost.conf" >/dev/null
assert_eq "0" "$AUDIT_RC" "allow localhost + deny all passes"
assert_not_contains "$AUDIT_OUT" 'open proxy' "no false positive on allow localhost"

t_begin "an explicit client list is not reported"
printf 'http_access allow allowed_clients CONNECT SSL_ports github_dst\nhttp_access deny allowed_clients\nhttp_access deny all\n' \
  > "$WORK/clients.conf"
audit "$WORK/clients.conf" >/dev/null
assert_eq "0" "$AUDIT_RC" "the client-list shape passes"
assert_not_contains "$AUDIT_OUT" 'open proxy' "no false positive on an ACL list"

t_begin "two deny-all rules (production shape) produce no finding"
printf 'http_access deny all\nhttp_access deny all\n' > "$WORK/two-denies.conf"
audit "$WORK/two-denies.conf" >/dev/null
assert_eq "0" "$AUDIT_RC" "the audit passes"
assert_not_contains "$AUDIT_OUT" 'open proxy' "repeated deny all is normal"
assert_contains "$AUDIT_OUT" 'final http_access rule is a deny' "the final rule is named as a deny"

t_begin "allow all is still caught next to a deny all"
printf 'http_access allow all\nhttp_access deny all\n' > "$WORK/allow-then-deny.conf"
audit "$WORK/allow-then-deny.conf" >/dev/null
assert_eq "1" "$AUDIT_RC" "the open proxy is detected"
assert_contains "$AUDIT_OUT" 'open proxy' "the finding is reported even with a final deny"

t_begin "a config whose final rule is not a deny still fails"
printf 'http_access allow localhost\n' > "$WORK/allow-last.conf"
audit "$WORK/allow-last.conf" >/dev/null
assert_eq "1" "$AUDIT_RC" "the audit fails"
assert_contains "$AUDIT_OUT" 'not a deny' "the missing terminator is reported"

t_begin "squid_rule_allows_all classifies rules token by token"
check_rule() {
  local rule="$1" want="$2" got=0
  squid_rule_allows_all "$rule" || got=1
  assert_eq "$want" "$got" "$rule"
}
check_rule 'http_access allow all' 0
check_rule 'http_access allow all !localhost' 0
check_rule 'http_access deny all' 1
check_rule 'http_access allow !all' 1
check_rule 'http_access allow localhost' 1
check_rule 'http_access allow allowed_clients CONNECT SSL_ports github_dst' 1
check_rule 'http_access deny all' 1

t_begin "the production Debian 13 fixture audits clean"
FIXTURE="$TESTS_DIR/fixtures/production-debian13"
FIX_MAIN="$WORK/squid.conf"
FIX_WL="$WORK/github-whitelist.conf"
sed -e "s#@@ROOT@@#$SANDBOX#g" "$FIXTURE/squid.conf" > "$FIX_MAIN"
sed -e "s#@@ROOT@@#$SANDBOX#g" -e "s#@@CERT@@#$SANDBOX/etc/squid/tls#g" \
  "$FIXTURE/conf.d/github-whitelist.conf" > "$FIX_WL"
audit "$FIX_MAIN" "$FIX_WL" >/dev/null
assert_eq "0" "$AUDIT_RC" "the effective configuration is judged safe"
assert_not_contains "$AUDIT_OUT" 'open proxy' "the two deny-all rules are not an open proxy"
assert_not_contains "$AUDIT_OUT" 'not a deny' "the final rule is a deny"
assert_contains "$AUDIT_OUT" 'final http_access rule is a deny' "the final rule is reported as enforce"

# -----------------------------------------------------------------------------
# systemctl_cmd: read-only verbs run under --dry-run, mutating verbs never do
# -----------------------------------------------------------------------------
t_begin "systemctl_cmd runs list-timers for real under --dry-run"
stub_register_unit squid 1
printf 'NEXT  LEFT  LAST  PASSED  UNIT  ACTIVATES\nTue 2026-09-22 00:00 UTC  1h  certbot.timer  certbot.service\n' \
  > "$STUB_STATE/systemd/timers"
export GP_DRY_RUN=1
OUT_SYS="$(systemctl_cmd list-timers certbot.timer --no-pager 2>&1)"
assert_contains "$OUT_SYS" 'certbot.timer' "the timer table is returned"
assert_not_contains "$OUT_SYS" 'would systemctl' "the query is not suppressed as a dry-run action"
OUT_SYS="$(systemctl_cmd list-unit-files squid 2>&1)"
assert_contains "$OUT_SYS" 'squid' "list-unit-files is still allowed"

t_begin "systemctl_cmd does not execute mutating verbs under --dry-run"
for verb in reload restart start stop enable disable; do
  systemctl_cmd "$verb" squid >/dev/null 2>&1 || true
done
assert_eq "" "$(stub_systemd_actions)" "no mutating verb reached the service manager"
unset GP_DRY_RUN

t_begin "mutating verbs still work outside a dry-run"
GP_DRY_RUN=0 systemctl_cmd start squid >/dev/null 2>&1 || true
assert_contains "$(stub_systemd_actions)" 'started squid' "the allowlist did not break normal operation"

# -----------------------------------------------------------------------------
# discovery collection: no temporary path in the output, no leaked temp file
# -----------------------------------------------------------------------------
t_begin "the discovery collector prints no temporary path and cleans up"
COLLECT_LOG="$(mktemp)"
server_discovery_collect > "$COLLECT_LOG" 2>&1; COLLECT_RC=$?
assert_eq "0" "$COLLECT_RC" "the collector succeeds"
assert_eq "" "$(cat "$COLLECT_LOG")" "nothing is printed on stdout (the report is read back separately)"
FIRST_REPORT="${SERVER_DISCOVERY:-}"
assert_file_exists "$FIRST_REPORT" "the report file was created"
COLLECTED_REPORT="$(server_discovery_print)"
assert_contains "$COLLECTED_REPORT" '== squid ==' "the report contains the discovery sections"
server_discovery_collect >/dev/null 2>&1
SECOND_REPORT="${SERVER_DISCOVERY:-}"
assert_ne "$FIRST_REPORT" "$SECOND_REPORT" "a fresh report file is used"
if [ -n "$FIRST_REPORT" ] && [ -f "$FIRST_REPORT" ]; then
  t_fail "the previous report file was not removed on re-collection"
else
  t_ok "the previous report file was removed on re-collection"
fi
server_discovery_cleanup
assert_file_absent "$SECOND_REPORT" "the report file is removed by the cleanup"

sandbox_teardown 2>/dev/null || true
t_summary
