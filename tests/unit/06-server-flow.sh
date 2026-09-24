#!/usr/bin/env bash
# =============================================================================
# unit test :: fresh server install + client ACL lifecycle
#
# Drives install.sh and ghproxyctl end to end inside the sandbox:
#   dry-run  -> real install -> verify -> client add/list/remove -> idempotency
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

DOMAIN="ghproxy.smartproxy.test"
PORT=8443
CERTDIR="$SANDBOX/certs"
stub_make_cert "$CERTDIR" "$DOMAIN" || { printf 'openssl unavailable: cannot run this test\n'; exit 1; }
stub_register_unit squid 0
mkdir -p "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"
mkdir -p "$GP_ROOT/etc/squid/conf.d"
mkdir -p "$GP_ROOT/var/log/squid"

MAIN_CONF="$GP_ROOT/etc/squid/squid.conf"
CLIENT_CONF="$GP_ROOT/etc/squid/conf.d/00-vps-gateway-manager-clients.conf"
STATE="$GP_ROOT/etc/vps-gateway-manager"

# -----------------------------------------------------------------------------
t_begin "dry-run changes nothing"
OUT="$(run_install server --domain "$DOMAIN" --port "$PORT" --cert-source "$CERTDIR" \
        --no-obtain-cert --dry-run --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "dry-run exits successfully"
assert_file_absent "$MAIN_CONF" "no squid.conf written by dry-run"
assert_file_absent "$CLIENT_CONF" "no client ACL file written by dry-run"
assert_file_absent "$STATE/role" "no role file written by dry-run"
assert_contains "$OUT" '[dry-run]' "dry-run output is explicit"

# -----------------------------------------------------------------------------
t_begin "fresh install"
OUT="$(run_install server --domain "$DOMAIN" --port "$PORT" --cert-source "$CERTDIR" \
        --no-obtain-cert --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "install exits successfully"
assert_contains "$OUT" 'server install complete' "install reported completion"
assert_file_exists "$MAIN_CONF" "squid.conf created"
assert_file_exists "$CLIENT_CONF" "client ACL file created"
assert_file_exists "$STATE/role" "role recorded"
assert_eq "server" "$(cat "$STATE/role" 2>/dev/null | tr -d '[:space:]')" "role is server"

t_begin "generated state"
assert_eq "$DOMAIN" "$(conf_get "$STATE/server.conf" domain)" "domain recorded"
assert_eq "$PORT" "$(conf_get "$STATE/server.conf" tls_port)" "port recorded"
assert_eq "fresh" "$(conf_get "$STATE/server.conf" mode)" "mode recorded"
assert_eq "squid.service" "$(conf_get "$STATE/server.conf" service_name)" "service recorded"
assert_file_contains "$STATE/github-domains.txt" '^\.github\.com$' "destination list present"
assert_file_mode_linux "$STATE/server.conf" 600 "server state is root-only"
assert_file_mode_linux "$STATE" 700 "state directory is root-only"

t_begin "TLS material"
assert_file_exists "$GP_ROOT/etc/squid/tls/fullchain.pem" "certificate copied into the squid TLS directory"
assert_file_exists "$GP_ROOT/etc/squid/tls/privkey.pem" "private key copied into the squid TLS directory"
assert_file_contains "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh" "$DOMAIN" \
  "certbot deploy hook generated for the domain"
assert_file_contains "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh" 'squid -k parse' \
  "deploy hook validates the configuration before reloading"

t_begin "service actions"
assert_contains "$(stub_systemd_actions)" 'started squid' "squid was started"
assert_not_contains "$(stub_systemd_actions)" 'restarted xray' "xray was never touched"
assert_contains "$(stub_squid_calls)" 'parse' "the configuration was validated with squid -k parse"

# -----------------------------------------------------------------------------
t_begin "client add"
OUT="$(run_ctl client add 203.0.113.10 cn-bj-01 --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client add exits successfully"
assert_contains "$OUT" 'Client added' "onboarding instructions printed"
assert_contains "$OUT" "--upstream https://$DOMAIN:$PORT" "onboarding command contains the upstream"
assert_contains "$OUT" 'curl --proxy https://'"$DOMAIN"':'"$PORT"'' "onboarding download goes through the proxy"
assert_file_contains "$CLIENT_CONF" "acl gsp_managed_clients src \"$(gp_managed_clients_acl)\"" "file-backed source ACL written"
assert_file_contains "$CLIENT_CONF" 'http_access allow gsp_managed_clients' "single stable allow rule written"
assert_file_contains "$(gp_managed_clients_acl)" '^203\.0\.113\.10/32$' "exact /32 in the ACL file"
assert_contains "$(stub_ufw_rules)" '8443|203.0.113.10/32|gsp:cn_bj_01' "exact firewall rule added with our marker"
assert_contains "$(stub_systemd_actions)" 'reloaded squid' "squid reloaded (not restarted)"

t_begin "client add with IPv6"
OUT="$(run_ctl client add 2001:db8::1234 jp-v6-01 --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "IPv6 client accepted"
assert_file_contains "$(gp_managed_clients_acl)" '^2001:db8::1234/128$' "exact /128 in the ACL file"

t_begin "rejected inputs"
OUT="$(run_ctl client add 2001:db8::/64 bad-prefix --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "a /64 source range is refused"
assert_contains "$OUT" 'must be exact hosts' "the refusal explains the policy"
OUT="$(run_ctl client add 0.0.0.0/0 bad-all --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "0.0.0.0/0 is refused"
OUT="$(run_ctl client add 203.0.113.10 duplicate --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "adding an already-authorised address is a no-op"
assert_contains "$OUT" 'already authorised' "duplicate is explained"
assert_eq "1" "$(grep -c '203\.0\.113\.10/32' "$(gp_managed_clients_acl)")" "no duplicate address lines"
OUT="$(run_ctl client add 10.20.30.40 private-node --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "private addresses are refused without --allow-private"
OUT="$(run_ctl client add 10.20.30.40 private-node --allow-private --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "private addresses accepted with the explicit flag"

t_begin "client list"
OUT="$(run_ctl client list 2>&1)"; RC=$?
assert_eq "0" "$RC" "client list works"
assert_contains "$OUT" 'cn-bj-01' "managed client listed"
assert_contains "$OUT" 'jp-v6-01' "IPv6 client listed"
assert_contains "$OUT" '203.0.113.10/32' "address shown"

t_begin "dry-run client add changes nothing"
BEFORE="$(cat "$CLIENT_CONF")"
OUT="$(run_ctl client add 198.51.100.5 dry-node --dry-run --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "dry-run client add exits successfully"
assert_eq "$BEFORE" "$(cat "$CLIENT_CONF")" "ACL file untouched by dry-run"
assert_not_contains "$(stub_ufw_rules)" '198.51.100.5' "no firewall rule added by dry-run"
assert_not_contains "$(run_ctl client list 2>&1)" 'dry-node' "client not recorded by dry-run"

t_begin "client remove"
OUT="$(run_ctl client remove cn-bj-01 --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "remove exits successfully"
assert_file_not_contains "$CLIENT_CONF" '203\.0\.113\.10/32' "ACL removed"
# Diagnostic only: if the rule is still present, dump the stub state before
# the assertion fails. The assertion itself is unchanged.
UFW_RULES="$(stub_ufw_rules)"
if printf '%s\n' "$UFW_RULES" | grep -q '203.0.113.10/32'; then
  printf 'DIAG firewall rule removed: stub still contains the CIDR\n' >&2
  printf 'DIAG sandbox: %s\n' "${SANDBOX:-unset}" >&2
  printf 'DIAG STUB_STATE: %s\n' "${STUB_STATE:-unset}" >&2
  printf 'DIAG cidr being removed: 203.0.113.10/32 (client cn-bj-01)\n' >&2
  printf 'DIAG stub_ufw_rules:\n%s\n' "$UFW_RULES" >&2
  printf 'DIAG ufw calls:\n%s\n' "$(stub_ufw_calls)" >&2
fi
assert_not_contains "$UFW_RULES" '203.0.113.10/32' "firewall rule removed"
assert_not_contains "$(run_ctl client list 2>&1)" 'cn-bj-01' "client no longer listed"
assert_contains "$(stub_ufw_rules)" '2001:db8::1234/128' "the other client's rule is untouched"
OUT="$(run_ctl client remove does-not-exist --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "removing an unknown client fails cleanly"

# -----------------------------------------------------------------------------
t_begin "install is idempotent"
BEFORE_MAIN="$(cat "$MAIN_CONF")"
BEFORE_CLIENTS="$(cat "$CLIENT_CONF")"
stub_add_port "127.0.0.1:3128"
stub_add_port "127.0.0.1:8443"
OUT="$(run_install server --domain "$DOMAIN" --port "$PORT" --cert-source "$CERTDIR" \
        --no-obtain-cert --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "second install exits successfully"
assert_eq "$BEFORE_MAIN" "$(cat "$MAIN_CONF")" "main configuration unchanged"
assert_eq "$BEFORE_CLIENTS" "$(cat "$CLIENT_CONF")" "client ACL file unchanged"
assert_eq "1" "$(grep -c '^include .*vps-gateway-manager-clients.conf' "$MAIN_CONF")" "include line not duplicated"
assert_eq "1" "$(grep -cE '^2001:db8::1234/128$' "$(gp_managed_clients_acl)")" "client address not duplicated"

t_begin "status output"
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "status exits successfully"
assert_contains "$OUT" 'Role              server' "status shows the role"
assert_contains "$OUT" 'TLS listener      8443' "status shows the TLS port"
assert_contains "$OUT" 'Clients           2 total' "status counts clients"
assert_contains "$OUT" 'PASS' "status reports passing checks"

t_begin "unknown source is refused (stub)"
OUT="$(run_ctl test 2>&1)"
assert_contains "$OUT" 'Unknown source refused' "the unauthorised-source check runs"

# -----------------------------------------------------------------------------
t_begin "destination policy through the CLI (--force boundary)"
OUT="$(run_ctl domains add github-cloud.s3.amazonaws.com --force --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "an exact CDN resource host is added with the explicit --force override"
assert_file_contains "$(gp_domains_file)" 'github-cloud\.s3\.amazonaws\.com' "the exact host is in the list"

OUT="$(run_ctl domains add .amazonaws.com --force --yes 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "--force can never add a shared platform suffix"
assert_file_not_contains "$(gp_domains_file)" '^\.amazonaws\.com$' "the platform suffix is not in the list"

OUT="$(run_ctl domains add .cloudfront.net --force --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "--force can never add .cloudfront.net either"

OUT="$(run_ctl domains add s3.amazonaws.com --force --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "--force can never add the shared s3 service endpoint"

OUT="$(run_ctl domains add d111111abcdef8.cloudfront.net --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "an exact distribution is refused without --force"

OUT="$(run_ctl domains remove github-cloud.s3.amazonaws.com --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "the exact host can be removed again"

sandbox_teardown
t_summary
