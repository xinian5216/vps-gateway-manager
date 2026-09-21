#!/usr/bin/env bash
# =============================================================================
# integration test :: adopting a RUNNING production proxy
#
# Proves the production path with a real Squid that is already serving clients:
#
#   1. --dry-run changes nothing and reports the findings
#   2. adoption is additive: the operator's squid.conf, whitelist, destination
#      list and certbot hook stay byte-identical, and the daemon is untouched
#   3. one managed client is authorised and served
#   4. a SECOND managed client is authorised and BOTH are served
#      (regression: several source ACL names must never be combined in one
#       http_access rule - Squid ANDs them, so nobody would be allowed)
#   5. removing one managed client refuses that client and keeps the other
#   6. an operator file that ends with "http_access deny all" cannot shadow the
#      managed clients (the 00- file is evaluated first)
#   7. a reload keeps the same daemon process (adopted servers are never
#      restarted silently)
#   8. a failed health check rolls back with the daemon, the files and the
#      process table in agreement
#
# Requires: Linux, root, squid-openssl, internet access to api.github.com.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'integ_teardown' EXIT

integ_skip_if_offline https://api.github.com/rate_limit

DOMAIN="ghproxy.test"
TLS_PORT=8443
PLAIN_PORT=3128
CERT_DIR="$INTEG_WORK/certs"
SQUID_DIR="$GP_ROOT/etc/squid"
CONF_D="$SQUID_DIR/conf.d"
LOG_DIR="$GP_ROOT/var/log/squid"
STATE_DIR="$GP_ROOT/etc/vps-gateway-manager"
LE_DIR="$GP_ROOT/etc/letsencrypt/live/$DOMAIN"
HOOK_DIR="$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"
MAIN_CONF="$SQUID_DIR/squid.conf"
WHITELIST="$CONF_D/github-whitelist.conf"
OURS="$CONF_D/00-vps-gateway-manager-clients.conf"
ACL_FILE="$STATE_DIR/managed-clients.acl"
DOMAINS="$CONF_D/github-domains.txt"
OPERATOR_HOOK="$HOOK_DIR/reload-squid-tls.sh"

# The health checks connect by hostname (as on a real host); make it resolvable.
integ_add_host_alias "$DOMAIN"

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"

# -----------------------------------------------------------------------------
# Build a production-looking installation
# -----------------------------------------------------------------------------
mkdir -p "$CERT_DIR" "$CONF_D" "$LOG_DIR" "$LE_DIR" "$HOOK_DIR" "$GP_ROOT/spool/squid" \
         "$GP_ROOT/run" "$GP_ROOT/var/spool/squid"
integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway "$DOMAIN" 127.0.0.1 || { printf 'could not create a certificate\n'; exit 1; }
# The health checks verify against the system trust store (Let's Encrypt in
# production), so the test CA is installed there for the duration of the run.
integ_trust_ca "$CERT_DIR/ca.pem" && printf 'test CA installed in the system trust store\n'
cp "$CERT_DIR/gateway.fullchain.pem" "$CERT_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$CERT_DIR/privkey.pem"
cp "$CERT_DIR/gateway.fullchain.pem" "$LE_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$LE_DIR/privkey.pem"
printf '#!/bin/sh\n# the operator existing certbot hook\nsystemctl reload squid\n' > "$OPERATOR_HOOK"
chmod 0755 "$OPERATOR_HOOK"

# The operator's main configuration (Debian-style, conf.d included).
# A working production TLS forward proxy uses https_port: with
# "http_port ... tls-cert=" Squid keeps the listener plaintext (see
# tests/integration/00-squid-capabilities.sh).
sed -e "s#@@ROOT@@#$GP_ROOT#g" \
    -e "s#@@CERT@@#$CERT_DIR#g" \
    -e "s#^http_port 8443 tls-cert=#https_port 8443 tls-cert=#" \
    "$TESTS_DIR/fixtures/production/squid.conf" > "$MAIN_CONF"
sed -e "s#@@ROOT@@#$GP_ROOT#g" "$TESTS_DIR/integration/fixtures/production-whitelist.conf" > "$WHITELIST"
printf '.github.com\n.githubusercontent.com\n.githubassets.com\n.cloudfront.net\n' > "$DOMAINS"

integ_fix_perms

MAIN_SUM="$(gp_sha256 "$MAIN_CONF")"
WL_SUM="$(gp_sha256 "$WHITELIST")"
DOM_SUM="$(gp_sha256 "$DOMAINS")"
HOOK_SUM="$(gp_sha256 "$OPERATOR_HOOK")"

t_begin "the existing production proxy is serving clients"
PROD_PID="$(integ_start_squid "$MAIN_CONF" "$GP_ROOT/run/squid.pid" "$GP_ROOT/production.log")"
assert_ok "plain listener is up on $PLAIN_PORT" integ_wait_port "$PLAIN_PORT" 25
assert_ok "TLS listener is up on $TLS_PORT" integ_wait_port "$TLS_PORT" 25
GW_LOG="$LOG_DIR/access.log"
DAEMON_PID="$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)"
if [ -n "$DAEMON_PID" ]; then
  t_ok "the daemon is identified through its pid file (pid $DAEMON_PID)"
else
  t_fail "no live squid daemon could be identified from $MAIN_CONF"
fi
if integ_pid_ignores_sighup "$PROD_PID"; then
  t_fail "the daemon ignores SIGHUP (the harness must start it with default signal dispositions)"
else
  t_ok "the daemon can be reconfigured by SIGHUP, like a service-managed daemon"
fi

t_begin "the running proxy does not disturb the operator's baselines"
CODE="$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the operator's existing client is served (HTTP $CODE)"
# A denied CONNECT reports 000 (no tunnel), so source ACLs are probed with
# http:// where Squid's own 403 is visible.
CODE="$(integ_curl_code --interface 127.0.0.5 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "an unlisted source is refused (HTTP $CODE)"

# -----------------------------------------------------------------------------
t_begin "adoption dry-run is read-only"
OUT="$(run_install server --adopt-existing --dry-run --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "dry-run exits successfully"
assert_contains "$OUT" 'existing-node' "the operator's client is reported"
assert_contains "$OUT" 'legacy-subnet-too-broad' "the /64 range is reported"
assert_contains "$OUT" 'cloudfront.net' "the broad CDN destination is reported"
assert_contains "$OUT" 'will NOT touch' "the untouched files are listed"
assert_eq "$MAIN_SUM" "$(gp_sha256 "$MAIN_CONF")" "squid.conf untouched by dry-run"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist untouched by dry-run"
assert_file_absent "$OURS" "no managed file written by dry-run"
assert_file_absent "$STATE_DIR/role" "no state written by dry-run"

t_begin "adoption of the running proxy"
OUT="$(run_install server --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "adoption exits successfully"
assert_eq "$MAIN_SUM" "$(gp_sha256 "$MAIN_CONF")" "squid.conf byte-identical"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist byte-identical"
assert_eq "$DOM_SUM" "$(gp_sha256 "$DOMAINS")" "destination list byte-identical"
assert_eq "$HOOK_SUM" "$(gp_sha256 "$OPERATOR_HOOK")" "certbot hook byte-identical"
assert_file_exists "$OURS" "managed conf.d file created"
assert_file_exists "$ACL_FILE" "the client ACL file created"
assert_file_not_contains "$OURS" 'http_access deny' "managed file contains no deny rule"
assert_eq "adopted" "$(conf_get "$STATE_DIR/server.conf" mode)" "mode recorded as adopted"
assert_eq "$WHITELIST" "$(conf_get "$STATE_DIR/server.conf" source_acl_file)" "source ACL file recorded"
assert_eq "8443" "$(conf_get "$STATE_DIR/server.conf" tls_port)" "TLS port detected"
assert_eq "3128" "$(conf_get "$STATE_DIR/server.conf" loopback_port)" "loopback port detected"
assert_eq "github_domains" "$(conf_get "$STATE_DIR/server.conf" domain_acl_name)" "existing destination ACL reused"

t_begin "the generated configuration uses one file-backed source ACL"
assert_file_contains "$OURS" 'http_access allow gsp_managed_clients github_domains' "single allow rule"
assert_file_contains "$OURS" "acl gsp_managed_clients src \"$ACL_FILE\"" "rule uses the file-backed ACL"
assert_file_not_contains "$OURS" '^acl gsp_c_' "no per-client src ACLs are generated"
# Regression guard: Squid ANDs ACL names on one http_access line, so two source
# ACL names in one rule can never match.
assert_file_not_contains "$OURS" 'http_access allow[^#]*gsp_c_[^ ]*[[:space:]]+gsp_c_' "no two source ACL names in one rule"

t_begin "adoption did not disturb the running daemon"
assert_ok "the daemon is still the same process (pid $DAEMON_PID)" integ_squid_alive "$DAEMON_PID"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the pid file still points at it"
assert_ok "the plain listener still accepts connections" integ_wait_port "$PLAIN_PORT" 10
CODE="$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the operator's client is still served (HTTP $CODE)"
integ_assert_sandbox_squid_count 1 "no second Squid instance was started by adoption"

t_begin "existing clients are imported as adopted"
OUT="$(run_ctl client list 2>&1)"
assert_contains "$OUT" 'existing-node' "client imported with its comment name"
assert_contains "$OUT" '127.0.0.4/32' "exact address imported"
assert_contains "$OUT" 'adopted' "marked as adopted"
assert_eq "" "$(clients_db_find_by_cidr '2001:db8::/64')" "the /64 was not imported"
assert_file_not_contains "$ACL_FILE" '^127\.0\.0\.4/32$' "adopted clients are not duplicated into the ACL file"

# -----------------------------------------------------------------------------
t_begin "authorising the first managed client"
OUT="$(run_ctl client add 127.0.0.2 managed-node --allow-private --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client add exits successfully"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "the operator's whitelist is still untouched"
assert_file_contains "$ACL_FILE" '^127\.0\.0\.2/32$' "the client is in the ACL file"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the reload kept the same daemon process"
integ_wait_http_code 200 "the first managed client is served" \
  --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit

t_begin "authorising a second managed client (regression: ACL names are ANDed)"
OUT="$(run_ctl client add 127.0.0.6 strict-node --allow-private --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the second client add exits successfully"
assert_file_contains "$ACL_FILE" '^127\.0\.0\.2/32$' "the first client is still in the ACL file"
assert_file_contains "$ACL_FILE" '^127\.0\.0\.6/32$' "the second client is in the ACL file"
# Both clients must be served, and adding the second must not break the first.
integ_wait_http_code 200 "the first managed client is still served" \
  --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 200 "the second managed client is served" \
  --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
assert_eq "1" "$(printf '%s\n' "$(cat "$OURS")" | grep -c '^http_access allow')" "still exactly one allow rule"
integ_wait_http_code 403 "an unlisted source is still refused" \
  --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit

t_begin "a reload keeps the daemon process (adopted servers are not restarted)"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the pid is unchanged after two client adds"
assert_ok "the TLS listener still accepts connections" integ_wait_port "$TLS_PORT" 10
integ_assert_sandbox_squid_count 1 "exactly one Squid instance"

# -----------------------------------------------------------------------------
t_begin "removing one managed client leaves the other working"
OUT="$(run_ctl client remove managed-node --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client remove exits successfully"
assert_file_not_contains "$ACL_FILE" '^127\.0\.0\.2/32$' "the removed client is gone from the ACL file"
assert_file_contains "$ACL_FILE" '^127\.0\.0\.6/32$' "the other client is still in the ACL file"
integ_wait_http_code 403 "the removed client is refused again" \
  --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit
integ_wait_http_code 200 "the remaining client is still served" \
  --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "the operator's whitelist untouched throughout"

# -----------------------------------------------------------------------------
t_begin "a strict operator file cannot shadow the managed clients"
# The operator hardens their own file: nothing but explicit entries is allowed.
printf '\nhttp_access deny all\n' >> "$WHITELIST"
WL_SUM="$(gp_sha256 "$WHITELIST")"   # the append above is intentional
# Apply it the way an operator would: reload the daemon and confirm the cycle.
OP_OFFSET="$(squid_cache_log_lines "$MAIN_CONF")"
kill -HUP "$DAEMON_PID" 2>/dev/null || true
assert_ok "the operator's reload was applied" \
  squid_wait_reconfigure_complete "$MAIN_CONF" "$OP_OFFSET" 20 "$DAEMON_PID"
integ_wait_http_code 200 "managed client is served although the operator file denies" \
  --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 200 "the operator's own client is still served" \
  --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 403 "an unlisted source is refused by the operator's deny" \
  --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the operator's reload kept the daemon"
integ_assert_sandbox_squid_count 1 "no second Squid instance was started"
# Undo the hardening so the remaining scenarios behave normally.
sed -i '/^http_access deny all$/d' "$WHITELIST"
WL_SUM="$(gp_sha256 "$WHITELIST")"
OP_OFFSET="$(squid_cache_log_lines "$MAIN_CONF")"
kill -HUP "$DAEMON_PID" 2>/dev/null || true
assert_ok "the revert was applied" \
  squid_wait_reconfigure_complete "$MAIN_CONF" "$OP_OFFSET" 20 "$DAEMON_PID"

# -----------------------------------------------------------------------------
t_begin "a failed health check rolls the change back on a real daemon"
# Make the TLS check fail deterministically by removing the test CA from the
# trust store (the certificate then no longer verifies, exactly like an expired
# or mis-issued certificate would).
CA_ANCHOR=/usr/local/share/ca-certificates/vgm-integ-test-ca.crt
if [ -f "$CA_ANCHOR" ]; then
  BEFORE_ACL="$(cat "$ACL_FILE")"
  rm -f "$CA_ANCHOR"
  update-ca-certificates >/dev/null 2>&1 || true
  OUT="$(run_ctl client add 127.0.0.7 rollback-node --allow-private --yes 2>&1)"; RC=$?
  if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
  assert_ne "0" "$RC" "client add fails when the health check fails"
  assert_contains "$OUT" 'health check failed' "the failure is reported"
  assert_contains "$OUT" 'rolling back' "the change is rolled back"
  assert_eq "$BEFORE_ACL" "$(cat "$ACL_FILE")" "the ACL file is restored byte for byte"
  assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "the operator's whitelist is untouched"
  assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" \
    "the daemon is still the same process after the rollback"
  assert_ok "the listener survived the rollback" integ_wait_port "$PLAIN_PORT" 10
  integ_wait_http_code 200 "the remaining client is still served after the rollback" \
    --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
  integ_wait_http_code 403 "the rolled-back client is refused" \
    --interface 127.0.0.7 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit
  integ_assert_sandbox_squid_count 1 "the rollback did not leave a second Squid behind"
  cp "$CERT_DIR/ca.pem" "$CA_ANCHOR"
  update-ca-certificates >/dev/null 2>&1 || true
else
  t_skip "test CA anchor not present; rollback scenario skipped"
fi

# -----------------------------------------------------------------------------
t_begin "an adopted client cannot be removed by this tool"
OUT="$(run_ctl client remove existing-node --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "removal of an adopted client is refused"
assert_contains "$OUT" 'will not rewrite a file it does not own' "the refusal explains the policy"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist untouched after the refusal"

t_begin "final state"
assert_ok "the gateway daemon is still serving" integ_squid_alive "$DAEMON_PID"
assert_ok "the TLS listener still accepts connections" integ_wait_port "$TLS_PORT" 10
assert_ok "the plain listener still accepts connections" integ_wait_port "$PLAIN_PORT" 10
integ_assert_sandbox_squid_count 1 "exactly one Squid for the gateway is running"
integ_wait_http_code 200 "the operator's client is still served" \
  --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit

printf '\n--- production squid status ---\n'
printf 'pid file: %s  service pid: %s  active marker: %s\n' \
  "$(cat "$GP_ROOT/run/squid.pid" 2>/dev/null || printf 'none')" \
  "$(cat "$INTEG_WORK/service/pid" 2>/dev/null || printf 'none')" \
  "$([ -f "$INTEG_WORK/service/active" ] && printf yes || printf no)"
printf 'service-manager calls:\n'; sed 's/^/  /' "$INTEG_WORK/service/calls.log" 2>/dev/null || true
integ_dump_logs "managed ACL file" "$ACL_FILE" 12
integ_dump_logs "production cache.log" "$LOG_DIR/cache.log" 15
integ_dump_logs "production access.log" "$GW_LOG" 8

integ_teardown
trap - EXIT
t_summary
