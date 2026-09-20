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
GW_LOG="$LOG_DIR/access.log"
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

t_begin "the reload really happened (new client is served)"
CODE="$(integ_curl_code --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the newly authorised client is served (HTTP $CODE)"
CODE="$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the operator's client still works (HTTP $CODE)"
CODE="$(integ_curl_code --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "an unlisted source is still refused (HTTP $CODE)"

# -----------------------------------------------------------------------------
t_begin "a strict operator file cannot shadow the managed clients"
# Simulate an operator whose whitelist ends with a blanket deny.
printf '\nhttp_access deny all\n' >> "$WHITELIST"
WL_SUM="$(gp_sha256 "$WHITELIST")"   # the append above is intentional
run_ctl client add 127.0.0.6 strict-node --allow-private --yes >/dev/null 2>&1
CODE="$(integ_curl_code --interface 127.0.0.6 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "managed client is served although the operator file denies (HTTP $CODE)"
CODE="$(integ_curl_code --interface 127.0.0.4 --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the operator's own client is still served (HTTP $CODE)"
CODE="$(integ_curl_code --interface 127.0.0.3 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "an unlisted source is refused by the operator's deny (HTTP $CODE)"

# -----------------------------------------------------------------------------
t_begin "removing a managed client takes effect"
OUT="$(run_ctl client remove managed-node --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client remove exits successfully"
assert_file_not_contains "$OURS" '127\.0\.0\.2/32' "managed ACL removed"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "the operator's whitelist untouched"
CODE="$(integ_curl_code --interface 127.0.0.2 --proxy "http://127.0.0.1:$PLAIN_PORT" http://api.github.com/rate_limit)"
assert_eq "403" "$CODE" "the removed client is refused again (HTTP $CODE)"

t_begin "an adopted client cannot be removed by this tool"
OUT="$(run_ctl client remove existing-node --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "removal of an adopted client is refused"
assert_contains "$OUT" 'will not rewrite a file it does not own' "the refusal explains the policy"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist untouched after the refusal"

integ_teardown
trap - EXIT
t_summary
