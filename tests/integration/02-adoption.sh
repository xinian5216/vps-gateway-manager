# =============================================================================
# integration test :: adopting a RUNNING production proxy
#
# Proves the production path with a real Squid that is already serving clients:
#
#   * --dry-run changes nothing and reports the findings
#   * adoption is additive: the operator's squid.conf, whitelist, destination
#     list and certbot hook stay byte-identical
#   * existing clients keep working, an unlisted source stays refused
#   * ghproxyctl client add on an adopted server really takes effect (the
#     running Squid is reloaded and serves the new client)
#   * the managed 00- file is evaluated before a pre-existing deny rule, so
#     managed clients survive a strict operator configuration
#   * ghproxyctl client remove takes effect as well
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
DOMAINS="$CONF_D/github-domains.txt"
OPERATOR_HOOK="$HOOK_DIR/reload-squid-tls.sh"

# The health checks connect by hostname (as on a real host); make it resolvable.
integ_add_host_alias "$DOMAIN"

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"

# -----------------------------------------------------------------------------
# Build a production-looking installation
# -----------------------------------------------------------------------------
mkdir -p "$CERT_DIR" "$CONF_D" "$LOG_DIR" "$LE_DIR" "$HOOK_DIR" "$GP_ROOT/spool/squid" "$GP_ROOT/run" \
         "$GP_ROOT/var/spool/squid"
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
CODE="$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the operator's existing client is served (HTTP $CODE)"
# A denied CONNECT reports 000 (no tunnel), so source ACLs are probed with
# http:// where Squid's own 403 is visible.
CODE="$(integ_curl_code --interface 127.0.0.5 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "an unlisted source is refused (HTTP $CODE)"

if ! integ_wait_port "$PLAIN_PORT" 5; then
  printf '\n--- squid cache.log ---\n' >&2
  tail -n 40 "$LOG_DIR/cache.log" 2>/dev/null >&2 || true
  printf '\n--- squid stdout ---\n' >&2
  tail -n 20 "$GP_ROOT/production.log" >&2 || true
fi

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
assert_file_not_contains "$OURS" 'http_access deny' "managed file contains no deny rule"
assert_eq "adopted" "$(conf_get "$STATE_DIR/server.conf" mode)" "mode recorded as adopted"
assert_eq "$WHITELIST" "$(conf_get "$STATE_DIR/server.conf" source_acl_file)" "source ACL file recorded"
assert_eq "8443" "$(conf_get "$STATE_DIR/server.conf" tls_port)" "TLS port detected"
assert_eq "3128" "$(conf_get "$STATE_DIR/server.conf" loopback_port)" "loopback port detected"
assert_eq "github_domains" "$(conf_get "$STATE_DIR/server.conf" domain_acl_name)" "existing destination ACL reused"

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

# -----------------------------------------------------------------------------
t_begin "authorising a new client on the adopted server"
# --allow-private because the test uses loopback aliases as clients.
OUT="$(run_ctl client add 127.0.0.2 managed-node --allow-private --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client add exits successfully"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "the operator's whitelist is still untouched"
assert_file_contains "$OURS" 'acl gsp_c_managed_node src 127\.0\.0\.2/32' "managed ACL written"
assert_file_contains "$OURS" 'http_access allow gsp_c_managed_node' "managed allow rule written"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the reload kept the same daemon process"

t_begin "the reload really happened (new client is served)"
integ_wait_http_code 200 "the newly authorised client is served" \
  --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 200 "the operator's client still works" \
  --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 403 "an unlisted source is still refused" \
  --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit

# -----------------------------------------------------------------------------
t_begin "a failed health check rolls the change back on a real daemon"
# Make the TLS check fail deterministically by removing the test CA from the
# trust store (the certificate then no longer verifies, exactly like an expired
# or mis-issued certificate would).
CA_ANCHOR=/usr/local/share/ca-certificates/vgm-integ-test-ca.crt
if [ -f "$CA_ANCHOR" ]; then
  BEFORE_OURS="$(cat "$OURS")"
  rm -f "$CA_ANCHOR"
  update-ca-certificates >/dev/null 2>&1 || true
  OUT="$(run_ctl client add 127.0.0.7 rollback-node --allow-private --yes 2>&1)"; RC=$?
  if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
  assert_ne "0" "$RC" "client add fails when the health check fails"
  assert_contains "$OUT" 'health check failed' "the failure is reported"
  assert_contains "$OUT" 'rolling back' "the change is rolled back"
  assert_eq "$BEFORE_OURS" "$(cat "$OURS")" "the managed ACL file is restored byte for byte"
  assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "the operator's whitelist is untouched"
  assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" \
    "the daemon is still the same process after the rollback"
  assert_ok "the listener survived the rollback" integ_wait_port "$PLAIN_PORT" 10
  CODE="$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
  assert_eq "200" "$CODE" "the operator's client is still served after the rollback (HTTP $CODE)"
  CODE="$(integ_curl_code --interface 127.0.0.7 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
  assert_eq "403" "$CODE" "the rolled-back client is refused (HTTP $CODE)"
  integ_assert_sandbox_squid_count 1 "the rollback did not leave a second Squid behind"
  # restore the trust anchor for the remaining checks
  cp "$CERT_DIR/ca.pem" "$CA_ANCHOR"
  update-ca-certificates >/dev/null 2>&1 || true
else
  t_skip "test CA anchor not present; rollback scenario skipped"
fi

# -----------------------------------------------------------------------------
t_begin "a strict operator file cannot shadow the managed clients"
# 1. authorise a client the normal way (health checks can still reach GitHub)
OUT="$(run_ctl client add 127.0.0.6 strict-node --allow-private --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client add succeeds before the operator hardens their file"
integ_wait_http_code 200 "the new client is served right after being added" \
  --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
# 2. the operator hardens their own file: nothing but explicit entries is allowed
printf '\nhttp_access deny all\n' >> "$WHITELIST"
WL_SUM="$(gp_sha256 "$WHITELIST")"   # the append above is intentional
kill -HUP "$DAEMON_PID" 2>/dev/null || true
assert_ok "the daemon accepts connections after the operator reload" integ_wait_port "$PLAIN_PORT" 15
# 3. the managed client must still be served: the 00- file is evaluated first
integ_wait_http_code 200 "managed client is served although the operator file denies" \
  --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 200 "the operator's own client is still served" \
  --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit
integ_wait_http_code 403 "an unlisted source is refused by the operator's deny" \
  --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit
assert_file_contains "$OURS" 'acl gsp_c_strict_node src 127\.0\.0\.6/32' "the managed ACL is on disk"
printf '\n--- diagnostics: request from 127.0.0.6 with a strict operator file ---\n'
printf 'managed file content:\n'; sed 's/^/  /' "$OURS" 2>/dev/null || true
printf 'daemon pid: %s  cmdline: %s\n' "$DAEMON_PID" "$(tr '\0' ' ' < "/proc/$DAEMON_PID/cmdline" 2>/dev/null || printf '?')"
printf 'port owners:\n'; ss -ltnp 2>/dev/null | awk '/3128|8443/ {print "  " $0}' || true
printf 'control codes: .2=%s .4=%s .6=%s\n' \
  "$(integ_curl_code --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)" \
  "$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)" \
  "$(integ_curl_code --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
printf 'after an extra explicit SIGHUP: .6=%s\n' \
  "$(kill -HUP "$DAEMON_PID" 2>/dev/null; sleep 3; integ_curl_code --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
curl -sv --max-time 10 --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" \
  https://api.github.com/rate_limit -o /dev/null 2>&1 | grep -vE '^\{|^\}|^\* (TLS|SSL|ALPN)' | tail -n 12 || true
printf 'loopback addresses:\n'
ip -o addr show dev lo 2>/dev/null | awk '{print "  " $4}' || true
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the daemon was not replaced"
integ_assert_sandbox_squid_count 1 "no second Squid instance was started"
# 4. undo the operator's hardening so the remaining scenarios behave normally
sed -i '/^http_access deny all$/d' "$WHITELIST"
WL_SUM="$(gp_sha256 "$WHITELIST")"
kill -HUP "$DAEMON_PID" 2>/dev/null || true
assert_ok "the daemon accepts connections after the revert" integ_wait_port "$PLAIN_PORT" 15

# -----------------------------------------------------------------------------
t_begin "removing a managed client takes effect"
OUT="$(run_ctl client remove managed-node --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client remove exits successfully"
assert_file_not_contains "$OURS" '127\.0\.0\.2/32' "managed ACL removed"
CODE="$(integ_curl_code --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "the removed client is refused again (HTTP $CODE)"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the daemon was not replaced by the removal"

t_begin "an adopted client cannot be removed by this tool"
OUT="$(run_ctl client remove existing-node --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "removal of an adopted client is refused"
assert_contains "$OUT" 'will not rewrite a file it does not own' "the refusal explains the policy"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist untouched after the refusal"

# -----------------------------------------------------------------------------
t_begin "final state"
assert_ok "the gateway daemon is still serving" integ_squid_alive "$DAEMON_PID"
assert_ok "the TLS listener still accepts connections" integ_wait_port "$TLS_PORT" 10
assert_ok "the plain listener still accepts connections" integ_wait_port "$PLAIN_PORT" 10
integ_assert_sandbox_squid_count 1 "exactly one Squid for the gateway is running"
assert_ok "the operator's client is still served" \
  test "$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)" = "200"

printf '\n--- production squid status ---\n'
printf 'pid file: %s\n' "$(cat "$GP_ROOT/run/squid.pid" 2>/dev/null || printf 'none')"
integ_dump_logs "production cache.log" "$LOG_DIR/cache.log" 12
integ_dump_logs "production access.log" "$GW_LOG" 8

integ_teardown
trap - EXIT
t_summary
