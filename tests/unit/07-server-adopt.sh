#!/usr/bin/env bash
# =============================================================================
# unit test :: adopting an existing production proxy (--adopt-existing)
#
# This is the highest-risk operation in the project, so the guarantees are
# pinned down explicitly:
#   * dry-run writes nothing and performs no service action
#   * the operator's squid.conf and whitelist file are byte-identical afterwards
#   * existing clients are imported into the inventory as "adopted"
#   * a too-broad source range and a broad CDN destination are reported, not
#     imported
#   * the additive conf.d file contains no deny rule and no client ACLs
#   * adoption performs no reload and no restart
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

DOMAIN="gh.smartproxy.test"
CONF_D="$GP_ROOT/etc/squid/conf.d"
SQUID_CONF="$GP_ROOT/etc/squid/squid.conf"
WHITELIST="$CONF_D/github-whitelist.conf"
OURS="$CONF_D/00-vps-gateway-manager-clients.conf"
DOMAINS="$CONF_D/github-domains.txt"

# -----------------------------------------------------------------------------
# Build the fake production host
# -----------------------------------------------------------------------------
mkdir -p "$CONF_D" "$GP_ROOT/etc/squid/tls" "$GP_ROOT/var/log/squid" \
         "$GP_ROOT/var/spool/squid" "$GP_ROOT/run" \
         "$GP_ROOT/etc/letsencrypt/live/$DOMAIN" \
         "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"

sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$GP_ROOT/etc/squid/tls#g" \
  "$TESTS_DIR/fixtures/production/squid.conf" > "$SQUID_CONF"
sed "s#@@ROOT@@#$GP_ROOT#g" "$TESTS_DIR/fixtures/production/github-whitelist.conf" > "$WHITELIST"
cp "$TESTS_DIR/fixtures/production/github-domains.txt" "$DOMAINS"

stub_make_cert "$GP_ROOT/etc/letsencrypt/live/$DOMAIN" "$DOMAIN" >/dev/null 2>&1 || {
  printf 'openssl unavailable: cannot run this test\n'; exit 1; }
cp "$GP_ROOT/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$GP_ROOT/etc/squid/tls/fullchain.pem"
cp "$GP_ROOT/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$GP_ROOT/etc/squid/tls/privkey.pem"
printf '#!/bin/sh\n# existing production hook\nsystemctl reload squid\n' > "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh"
chmod 0755 "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh"

cat > "$STUB_STATE/systemd/squid.cat" <<EOF
# $SQUID_CONF
[Unit]
Description=Squid Web Proxy Server
[Service]
ExecStart=/usr/sbin/squid -f $SQUID_CONF -YC
[Install]
WantedBy=multi-user.target
EOF
stub_register_unit squid 1 "$STUB_STATE/systemd/squid.cat"
stub_add_port "127.0.0.1:3128"
stub_add_port "127.0.0.1:8443"
printf 'existing-rule\n' >> "$STUB_STATE/ufw/rules"

SUID_SUM="$(gp_sha256 "$SQUID_CONF")"
WL_SUM="$(gp_sha256 "$WHITELIST")"
DOM_SUM="$(gp_sha256 "$DOMAINS")"
HOOK_SUM="$(gp_sha256 "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh")"

# -----------------------------------------------------------------------------
t_begin "adoption dry-run is read-only"
OUT="$(run_install server --adopt-existing --dry-run --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "dry-run exits successfully"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/role" "no state written"
assert_file_absent "$OURS" "no conf.d file written"
assert_eq "$SUID_SUM" "$(gp_sha256 "$SQUID_CONF")" "squid.conf untouched"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist untouched"
assert_eq "" "$(stub_systemd_actions)" "no service action during dry-run"
assert_contains "$OUT" 'adoption plan' "adoption plan printed"
assert_contains "$OUT" '== squid ==' "squid section printed"
assert_contains "$OUT" 'version: ' "squid version printed"
assert_contains "$OUT" 'main config: ' "main configuration printed"
assert_contains "$OUT" 'included files (in load order):' "include files listed"
assert_contains "$OUT" 'configured listeners:' "configured listeners listed"
assert_contains "$OUT" 'TLS listener' "TLS listener reported"
assert_contains "$OUT" 'source acl file: ' "source ACL reported"
assert_contains "$OUT" 'destination acl declarations' "destination declarations listed"
assert_contains "$OUT" 'firewall' "firewall backend reported"
assert_contains "$OUT" 'files this project WILL create' "will-create list printed"
assert_contains "$OUT" 'destination entries imported into the managed list: 3' "safe destinations imported"
assert_contains "$OUT" 'tencent-bj-01' "dry-run report lists the imported client"
assert_contains "$OUT" 'v6-node' "dry-run report lists the IPv6 client"
assert_contains "$OUT" 'will NOT touch' "dry-run lists the files that stay untouched"
assert_contains "$OUT" 'legacy-subnet-too-broad' "too-broad source range is reported"
assert_contains "$OUT" 'cloudfront.net' "broad CDN destination is reported"
assert_contains "$OUT" 'no reload and no restart' "risk note is printed"

# -----------------------------------------------------------------------------
t_begin "adoption of the existing proxy"
OUT="$(run_install server --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "adoption exits successfully"
assert_contains "$OUT" 'adoption complete' "adoption reported completion"

t_begin "the existing configuration is byte-identical"
assert_eq "$SUID_SUM" "$(gp_sha256 "$SQUID_CONF")" "squid.conf unchanged"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "client whitelist unchanged"
assert_eq "$DOM_SUM" "$(gp_sha256 "$DOMAINS")" "operator destination list unchanged"
assert_eq "$HOOK_SUM" "$(gp_sha256 "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh")" \
  "existing certbot hook unchanged"

t_begin "no service action during adoption"
assert_eq "" "$(stub_systemd_actions)" "squid was not reloaded or restarted"

t_begin "adopted state"
STATE="$GP_ROOT/etc/vps-gateway-manager"
assert_eq "adopted" "$(conf_get "$STATE/server.conf" mode)" "mode is adopted"
assert_eq "$WHITELIST" "$(conf_get "$STATE/server.conf" source_acl_file)" "source ACL file recorded"
assert_eq "8443" "$(conf_get "$STATE/server.conf" tls_port)" "TLS port detected"
assert_eq "3128" "$(conf_get "$STATE/server.conf" loopback_port)" "loopback port detected"
assert_eq "gsp_managed_github" "$(conf_get "$STATE/server.conf" domain_acl_name)" "the managed destination ACL is project-owned"
assert_eq "github_domains" "$(conf_get "$STATE/server.conf" operator_domain_acl_name)" "the operator destination ACL is recorded separately"
assert_eq "1" "$(conf_get "$STATE/server.conf" ufw_managed)" "firewall management enabled"
assert_file_exists "$STATE/github-domains.txt" "managed destination list created"
assert_file_exists "$OURS" "additive conf.d file created"
assert_file_contains "$OURS" 'acl gsp_managed_github dstdomain' "additive file defines the project destination ACL"
assert_file_not_contains "$OURS" '^acl github_domains' "the operator destination ACL is never redefined"
assert_file_contains "$OURS" "acl gsp_managed_clients src \"$(gp_managed_clients_acl)\"" "additive file uses the file-backed source ACL"
assert_file_not_contains "$OURS" 'http_access deny' "additive file contains no deny rule"
assert_file_exists "$(gp_managed_clients_acl)" "the client ACL file exists"
assert_file_not_contains "$(gp_managed_clients_acl)" '^[0-9]' "the client ACL file grants nothing yet"

t_begin "client inventory"
OUT="$(run_ctl client list 2>&1)"; RC=$?
assert_eq "0" "$RC" "client list works"
assert_contains "$OUT" 'tencent-bj-01' "IPv4 client imported with its comment name"
assert_contains "$OUT" 'v6-node' "IPv6 client imported"
assert_contains "$OUT" '203.0.113.10/32' "IPv4 address recorded"
assert_contains "$OUT" '2001:db8::10/128' "IPv6 address recorded"
assert_contains "$OUT" 'adopted' "clients are marked as adopted"
assert_eq "3" "$(clients_db_count)" "every exact host was imported (three entries)"
assert_eq "" "$(clients_db_find_by_cidr '198.51.100.0/24')" "the /24 range was not imported"

t_begin "managed destination list imports the safe entries only"
assert_file_contains "$STATE/github-domains.txt" '^\.github\.com$' "existing GitHub entry imported"
assert_file_contains "$STATE/github-domains.txt" '^\.githubassets\.com$' "existing asset CDN imported"
assert_file_not_contains "$STATE/github-domains.txt" 'cloudfront' "broad CDN entry not imported"

# -----------------------------------------------------------------------------
t_begin "adding a client in adopted mode keeps the operator's file intact"
OUT="$(run_ctl client add 203.0.113.55 new-node --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client add works on an adopted server"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator whitelist still unchanged"
assert_file_contains "$(gp_managed_clients_acl)" '^203\.0\.113\.55/32$' "new client written to the ACL file"
assert_file_contains "$OURS" 'http_access allow gsp_managed_clients' "the stable rule is unchanged"
assert_contains "$(stub_systemd_actions)" 'reloaded squid' "squid reloaded once for the new client"
assert_contains "$(stub_ufw_rules)" '8443|203.0.113.55/32|gsp:new_node' "exact firewall rule added"

t_begin "an address already present in the operator's file is refused"
# Simulate the operator adding a node to their own file after adoption.
printf 'acl github_nodes src 203.0.113.99/32  # added-by-hand\n' >> "$WHITELIST"
WL_SUM="$(gp_sha256 "$WHITELIST")"   # the append above is intentional; re-baseline
OUT="$(run_ctl client add 203.0.113.99 hand-added --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "an address that only exists in the operator's file is refused"
assert_contains "$OUT" 'already present in' "the refusal explains why"
assert_eq "" "$(clients_db_get hand-added)" "nothing was recorded"
assert_not_contains "$(stub_ufw_rules)" '203.0.113.99' "no firewall rule was created"

t_begin "adopted clients cannot be removed by this tool"
OUT="$(run_ctl client remove tencent-bj-01 --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "removal of an adopted client is refused"
assert_contains "$OUT" 'will not rewrite a file it does not own' "the refusal explains the policy"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist untouched after the refusal"
assert_contains "$(run_ctl client list 2>&1)" 'tencent-bj-01' "client is still listed"

t_begin "forget only drops the inventory row"
run_ctl client forget tencent-bj-01 --yes >/dev/null 2>&1
assert_eq "" "$(clients_db_get tencent-bj-01)" "row removed"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "whitelist still untouched"
run_ctl client reimport --yes >/dev/null 2>&1
assert_contains "$(run_ctl client list 2>&1)" 'tencent-bj-01' "reimport restores the inventory row"

t_begin "removing a managed client leaves adopted clients alone"
run_ctl client remove new-node --yes >/dev/null 2>&1
assert_file_not_contains "$OURS" '203\.0\.113\.55' "managed ACL removed"
assert_not_contains "$(stub_ufw_rules)" '203.0.113.55/32' "managed firewall rule removed"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator whitelist untouched throughout"

sandbox_teardown
t_summary
