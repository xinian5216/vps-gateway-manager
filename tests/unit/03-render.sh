#!/usr/bin/env bash
# =============================================================================
# unit test :: configuration rendering
#
# The generated client ACL file and the main Squid configuration are the
# security boundary of the server. These tests pin down:
#   * exact /32 and /128 ACL entries, one per client
#   * allow rules that reference a GitHub-only destination ACL
#   * the *absence* of any deny rule in the additive conf.d file (a deny there
#     would shadow a pre-existing whitelist on an adopted server)
#   * the presence of a final "deny all" in the fresh main config
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

server_set_defaults
SERVER_DOMAIN="gh.test.invalid"
SERVER_MODE="fresh"
SERVER_DOMAIN_ACL_NAME="gsp_github"
domains_seed_from_template

# -----------------------------------------------------------------------------
t_begin "client ACL file (fresh mode)"
clients_db_add cn-bj-01 203.0.113.10/32 ghproxyctl "$SERVER_CLIENT_ACL_FILE" ""
clients_db_add jp-v6-01 2001:db8::10/128 ghproxyctl "$SERVER_CLIENT_ACL_FILE" ""
clients_db_add edge-01 198.51.100.7/32 ghproxyctl "$SERVER_CLIENT_ACL_FILE" ""
OUT="$(server_render_clients_file 0)"
assert_contains "$OUT" 'acl gsp_c_cn_bj_01 src 203.0.113.10/32' "IPv4 client ACL is exact"
assert_contains "$OUT" 'acl gsp_c_jp_v6_01 src 2001:db8::10/128' "IPv6 client ACL is exact"
assert_contains "$OUT" 'http_access allow gsp_c_cn_bj_01' "allow rule references the client ACL"
assert_contains "$OUT" 'gsp_github' "allow rule references the GitHub destination ACL"
assert_not_contains "$OUT" 'http_access deny' "no deny rule in the additive conf.d file"
assert_not_contains "$OUT" '0.0.0.0/0' "no blanket source grant"
assert_not_contains "$OUT" '::/0' "no blanket IPv6 source grant"
assert_not_contains "$OUT" 'dstdomain .*github.com.*amazonaws' "no CDN destinations"
assert_contains "$OUT" 'DO NOT EDIT' "file declares itself managed"

t_begin "client ACL file (adopted mode defines its own destination ACL)"
OUT2="$(server_render_clients_file 1)"
assert_contains "$OUT2" "acl gsp_github dstdomain \"$(gp_domains_file)\"" "destination ACL defined for adopted servers"
assert_not_contains "$OUT2" 'http_access deny' "still no deny rule"

t_begin "empty client list is valid and inert"
: > "$(gp_clients_db)"
OUT3="$(server_render_clients_file 1)"
assert_contains "$OUT3" 'no clients are authorised yet' "placeholder comment for an empty list"
assert_not_contains "$OUT3" 'http_access allow' "no allow rules without clients"
assert_not_contains "$OUT3" 'http_access deny' "no deny rules without clients"

t_begin "rendering is deterministic (idempotent writes)"
clients_db_add cn-bj-01 203.0.113.10/32 ghproxyctl "$SERVER_CLIENT_ACL_FILE" ""
A="$(server_render_clients_file 0 | grep -v '^#')"
B="$(server_render_clients_file 0 | grep -v '^#')"
assert_eq "$A" "$B" "same state produces the same ACL body"

t_begin "large client lists are chunked"
i=1
while [ "$i" -le 40 ]; do
  clients_db_add "node-$(printf '%02d' "$i")" "203.0.113.$i/32" ghproxyctl "$SERVER_CLIENT_ACL_FILE" "" >/dev/null 2>&1
  i=$((i+1))
done
OUT4="$(server_render_clients_file 0)"
MAXLEN="$(printf '%s\n' "$OUT4" | awk '/^http_access allow/{ if (length($0) > m) m = length($0) } END { print m+0 }')"
if [ "$MAXLEN" -lt 600 ]; then t_ok "no single allow line exceeds 600 characters (max: $MAXLEN)"; else t_fail "allow line too long: $MAXLEN"; fi
assert_eq "41" "$(clients_db_count)" "all clients recorded"

# -----------------------------------------------------------------------------
t_begin "fresh main configuration"
squid() { :; }   # keep shellcheck quiet about the stub path
CONF="$(server_render_main_config)"
assert_contains "$CONF" "http_port 8443 tls-cert=" "public TLS listener present"
assert_contains "$CONF" "http_port 127.0.0.1:3128" "plain port bound to loopback only"
assert_contains "$CONF" 'http_access deny all' "final deny rule present"
assert_contains "$CONF" 'http_access deny !gsp_safe_ports' "port hygiene enforced"
assert_contains "$CONF" "include $SERVER_CLIENT_ACL_FILE" "client ACL file included"
assert_contains "$CONF" 'cache deny all' "caching disabled for source control traffic"
assert_not_contains "$CONF" 'http_access allow all' "no blanket allow"
assert_contains "$CONF" 'managed by vps-gateway-manager' "config declares itself managed"
# The include of the client file must appear before the final deny.
INCLUDE_LINE="$(printf '%s\n' "$CONF" | grep -n "^include " | head -n1 | cut -d: -f1)"
DENY_LINE="$(printf '%s\n' "$CONF" | grep -n '^http_access deny all' | head -n1 | cut -d: -f1)"
if [ -n "$INCLUDE_LINE" ] && [ -n "$DENY_LINE" ] && [ "$INCLUDE_LINE" -lt "$DENY_LINE" ]; then
  t_ok "client include is evaluated before the final deny all"
else
  t_fail "client include must come before the final deny all (include=$INCLUDE_LINE deny=$DENY_LINE)"
fi

t_begin "client configuration"
SERVER_UPSTREAM_HOST="gh.test.invalid"
CLIENT_UPSTREAM="https://gh.test.invalid:8443"
CLIENT_UPSTREAM_HOST="gh.test.invalid"
CLIENT_UPSTREAM_PORT="8443"
CLIENT_UPSTREAM_SCHEME="https"
CLIENT_UPSTREAM_CA="/etc/ssl/certs/ca-certificates.crt"
CLIENT_LOCAL_PORT="3129"
CLIENT_TAG="test"
CLIENT_RUNTIME_DIR="$GP_ROOT/run/vps-gateway-manager"
CLIENT_LOG_DIR="$GP_ROOT/var/log/vps-gateway-manager"
CLIENT_SPOOL_DIR="$GP_ROOT/var/spool/vps-gateway-manager"
CLIENT_ACCESS_LOG="$CLIENT_LOG_DIR/access.log"
CCONF="$(client_render_squid_conf)"
assert_contains "$CCONF" 'http_port 127.0.0.1:3129' "local listener on loopback"
assert_contains "$CCONF" 'cache_peer gh.test.invalid parent 8443' "upstream configured as a parent"
assert_contains "$CCONF" 'tls tls-cafile=/etc/ssl/certs/ca-certificates.crt' "TLS to the upstream with CA verification"
assert_not_contains "$CCONF" 'DONT_VERIFY' "no certificate verification bypass"
assert_contains "$CCONF" 'never_direct allow gsp_github' "GitHub must use the parent"
assert_contains "$CCONF" 'cache_peer_access gsp_upstream deny all' "no other destination may use the parent"
assert_contains "$CCONF" 'http_access deny all' "loopback-only access control"
assert_contains "$CCONF" 'never_direct allow gsp_github' "GitHub never goes direct"

t_begin "unit file rendering"
CSVC="$(client_render_unit)"
assert_contains "$CSVC" 'ExecStart=' "unit has an ExecStart"
assert_contains "$CSVC" '-f /etc/vps-gateway-manager/client-squid.conf' "unit uses the dedicated config file"
assert_contains "$CSVC" 'vps-gateway-manager' "unit is identifiable"
assert_not_contains "$CSVC" '^Conflicts=' "unit must not stop an unrelated squid"
assert_contains "$CSVC" 'Restart=on-failure' "unit restarts on failure"
assert_contains "$CSVC" 'WantedBy=multi-user.target' "unit is enabled normally"

sandbox_teardown
t_summary
