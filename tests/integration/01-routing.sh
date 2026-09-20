#!/usr/bin/env bash
# =============================================================================
# integration test :: routing, TLS and ACL behaviour against a REAL Squid
#
# This is the test that proves the design instead of assuming it:
#
#   * the configurations rendered from templates/ really parse and run
#   * a TLS forward proxy terminates TLS and speaks CONNECT to clients
#   * GitHub destinations reach the parent proxy (access-log hierarchy proof)
#   * every other destination goes DIRECT
#   * an unauthorised source address is refused, an authorised one is served
#   * a parent certificate that does not verify is refused (no silent bypass)
#
# Two Squid instances are started on loopback-only, high ports:
#   parent ("gateway")   TLS 18443, plain 13128
#   child  ("client")    plain 13129  (routes GitHub to the parent over TLS)
#   child with a bad CA  plain 13130  (must fail to reach GitHub)
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
TLS_PORT=18443
PLAIN_PORT=13128
CLIENT_PORT=13129
BADCA_PORT=13130
CERT_DIR="$INTEG_WORK/certs"
STATE_DIR="$GP_ROOT/etc/vps-gateway-manager"
CONF_D="$GP_ROOT/etc/squid/conf.d"
LOG_DIR="$GP_ROOT/var/log/squid"
mkdir -p "$CERT_DIR" "$STATE_DIR" "$CONF_D" "$LOG_DIR" "$GP_ROOT/spool/squid" "$GP_ROOT/run"
integ_fix_perms

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"
printf 'work dir: %s\n' "$INTEG_WORK"

# -----------------------------------------------------------------------------
# Certificates: a test CA, the gateway certificate, and an unrelated CA
# -----------------------------------------------------------------------------
integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway "$DOMAIN" 127.0.0.1 || { printf 'could not create the gateway certificate\n'; exit 1; }
cp "$CERT_DIR/gateway.fullchain.pem" "$CERT_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$CERT_DIR/privkey.pem"
mkdir -p "$CERT_DIR/otherca"
integ_make_ca "$CERT_DIR/otherca" >/dev/null 2>&1

# -----------------------------------------------------------------------------
# Parent ("gateway") configuration, rendered from the real template
# -----------------------------------------------------------------------------
t_begin "render + parse the gateway configuration"
SERVER_DOMAIN="$DOMAIN"
SERVER_TLS_PORT="$TLS_PORT"
SERVER_LOOPBACK_PORT="$PLAIN_PORT"
SERVER_MODE="fresh"
SERVER_SERVICE="squid"
SERVER_TLS_DIR="$CERT_DIR"
SERVER_PID_FILE="$GP_ROOT/run/gateway.pid"
SERVER_SPOOL_DIR="$GP_ROOT/spool/squid"
SERVER_CLIENT_ACL_FILE="$CONF_D/00-vps-gateway-manager-clients.conf"
SERVER_DOMAIN_ACL_NAME="gsp_github"
SERVER_ADMIN_CONTACT="root@localhost"
domains_seed_from_template

# One authorised client (a loopback alias) and one that stays unauthorised.
clients_db_add "allowed-node" "127.0.0.2/32" ghproxyctl "$SERVER_CLIENT_ACL_FILE" "integration test"
GW_CONF="$GP_ROOT/etc/squid/squid.conf"
server_render_main_config > "$GW_CONF"
server_render_clients_file 0 > "$SERVER_CLIENT_ACL_FILE"

assert_ok "generated gateway config parses (squid -k parse)" squid_parse "$GW_CONF"
assert_file_contains "$GW_CONF" "http_port $TLS_PORT tls-cert=" "TLS listener present in the rendered config"
assert_file_contains "$SERVER_CLIENT_ACL_FILE" 'acl gsp_c_allowed_node src 127\.0\.0\.2/32' "client ACL rendered"

t_begin "start the gateway (real squid, real TLS)"
GW_PID="$(integ_start_squid "$GW_CONF" "$GP_ROOT/run/gateway.pid" "$GP_ROOT/gateway.log")"
assert_ok "plain listener is up on $PLAIN_PORT" integ_wait_port "$PLAIN_PORT" 20
assert_ok "TLS listener is up on $TLS_PORT" integ_wait_port "$TLS_PORT" 20
GW_LOG="$LOG_DIR/access.log"

if ! integ_wait_port "$PLAIN_PORT" 5; then
  printf '\n--- gateway cache.log ---\n' >&2
  tail -n 40 "$LOG_DIR/cache.log" 2>/dev/null >&2 || true
  printf '\n--- gateway stdout ---\n' >&2
  tail -n 20 "$GP_ROOT/gateway.log" >&2 || true
fi

# -----------------------------------------------------------------------------
t_begin "TLS endpoint verifies with the test CA"
OUT="$(timeout 20 openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername "$DOMAIN" \
       -verify_return_error -verify_hostname "$DOMAIN" -CAfile "$CERT_DIR/ca.pem" </dev/null 2>&1)"
assert_contains "$OUT" 'Verify return code: 0 (ok)' "certificate verifies against the CA"

t_begin "authorised source: GitHub is allowed through the plain listener"
CODE="$(integ_curl_code --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "loopback client reaches GitHub (HTTP $CODE)"

t_begin "authorised source: GitHub is allowed through the TLS listener"
CODE="$(integ_curl_code --proxy "https://127.0.0.1:$TLS_PORT" --proxy-cacert "$CERT_DIR/ca.pem" \
        https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "CONNECT over TLS works end to end (HTTP $CODE)"

t_begin "non-GitHub destination is refused"
CODE="$(integ_curl_code --proxy "http://127.0.0.1:$PLAIN_PORT" https://example.com/)"
assert_eq "403" "$CODE" "example.com is refused by the destination ACL (HTTP $CODE)"

t_begin "a listed client address is served"
CODE="$(integ_curl_code --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" \
        https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "127.0.0.2 (authorised via ghproxyctl client add) is served (HTTP $CODE)"

t_begin "an unlisted source address is refused"
CODE="$(integ_curl_code --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" \
        https://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "127.0.0.3 is refused (HTTP $CODE)"
CODE="$(integ_curl_code --interface 127.0.0.3 --proxy "https://127.0.0.1:$TLS_PORT" \
        --proxy-cacert "$CERT_DIR/ca.pem" https://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "127.0.0.3 is refused on the TLS listener too (HTTP $CODE)"

# -----------------------------------------------------------------------------
# Child ("client") configuration: GitHub through the TLS parent, rest direct
# -----------------------------------------------------------------------------
t_begin "render + parse the client configuration"
CLIENT_UPSTREAM="https://$DOMAIN:$TLS_PORT"
CLIENT_UPSTREAM_HOST="127.0.0.1"
CLIENT_UPSTREAM_PORT="$TLS_PORT"
CLIENT_UPSTREAM_SCHEME="https"
CLIENT_UPSTREAM_CA="$CERT_DIR/ca.pem"
CLIENT_UPSTREAM_SSL_DOMAIN="$DOMAIN"
CLIENT_LOCAL_PORT="$CLIENT_PORT"
CLIENT_TAG="integ"
CLIENT_RUNTIME_DIR="$GP_ROOT/run"
CLIENT_LOG_DIR="$GP_ROOT/var/log/client"
CLIENT_SPOOL_DIR="$GP_ROOT/spool/client"
CLIENT_ACCESS_LOG="$CLIENT_LOG_DIR/access.log"
mkdir -p "$CLIENT_LOG_DIR" "$CLIENT_SPOOL_DIR"
integ_fix_perms
CLIENT_CONF="$GP_ROOT/etc/squid/client-squid.conf"
client_render_squid_conf > "$CLIENT_CONF"

assert_ok "generated client config parses (squid -k parse)" squid_parse "$CLIENT_CONF"
assert_file_contains "$CLIENT_CONF" 'tls tls-cafile=' "TLS parent configured"

t_begin "start the client proxy"
CL_PID="$(integ_start_squid "$CLIENT_CONF" "$CLIENT_RUNTIME_DIR/client.pid" "$GP_ROOT/client.log")"
assert_ok "client listener is up on $CLIENT_PORT" integ_wait_port "$CLIENT_PORT" 20

t_begin "GitHub goes through the parent (access-log proof)"
CLIENT_LOG="$CLIENT_LOG_DIR/access.log"
SKIP="$(integ_access_log_count "$CLIENT_LOG")"
CODE="$(integ_curl_code --proxy "http://127.0.0.1:$CLIENT_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "GitHub request succeeds through the chain (HTTP $CODE)"
sleep 1
HIER="$(integ_hierarchy_of "$CLIENT_LOG" 'api.github.com' "$SKIP")"
assert_contains "$HIER" 'PARENT' "client log shows the parent hierarchy ($HIER)"
assert_file_contains "$GW_LOG" 'api.github.com:443' "gateway log shows the GitHub CONNECT from the client"

t_begin "everything else goes DIRECT"
SKIP="$(integ_access_log_count "$CLIENT_LOG")"
CODE="$(integ_curl_code --proxy "http://127.0.0.1:$CLIENT_PORT" https://example.com/)"
assert_eq "200" "$CODE" "non-GitHub request succeeds directly (HTTP $CODE)"
sleep 1
HIER="$(integ_hierarchy_of "$CLIENT_LOG" 'example.com' "$SKIP")"
assert_contains "$HIER" 'DIRECT' "client log shows DIRECT for example.com ($HIER)"

t_begin "a non-GitHub destination is not sent to the gateway"
COUNT_BEFORE="$(grep -c 'example.com' "$GW_LOG" 2>/dev/null || printf '0')"
assert_eq "0" "$COUNT_BEFORE" "example.com never appears in the gateway log"

# -----------------------------------------------------------------------------
t_begin "a parent certificate that does not verify is refused"
CLIENT_UPSTREAM_CA="$CERT_DIR/otherca/ca.pem"
CLIENT_LOCAL_PORT="$BADCA_PORT"
CLIENT_RUNTIME_DIR="$GP_ROOT/run/badca"
CLIENT_LOG_DIR="$GP_ROOT/var/log/badca"
CLIENT_SPOOL_DIR="$GP_ROOT/spool/badca"
CLIENT_ACCESS_LOG="$CLIENT_LOG_DIR/access.log"
mkdir -p "$CLIENT_RUNTIME_DIR" "$CLIENT_LOG_DIR" "$CLIENT_SPOOL_DIR"
integ_fix_perms
BADCA_CONF="$GP_ROOT/etc/squid/badca-squid.conf"
client_render_squid_conf > "$BADCA_CONF"
integ_start_squid "$BADCA_CONF" "$CLIENT_RUNTIME_DIR/squid.pid" "$GP_ROOT/badca.log" >/dev/null
if integ_wait_port "$BADCA_PORT" 20; then
  CODE="$(integ_curl_code --proxy "http://127.0.0.1:$BADCA_PORT" https://api.github.com/rate_limit)"
  assert_ne "200" "$CODE" "a parent with an untrusted certificate is not used (HTTP $CODE)"
else
  t_fail "the bad-CA client did not start"
fi

integ_teardown
trap - EXIT
t_summary
