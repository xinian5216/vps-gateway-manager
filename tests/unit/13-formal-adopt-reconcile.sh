#!/usr/bin/env bash
# =============================================================================
# unit test :: FORMAL adoption, persistent state, status and the repair path
#
# This is the regression cover for the first formal production adoption, where
#   * six clients sharing one operator ACL name collapsed into ONE inventory row
#     (the database deduplicated by display name), and
#   * the generated conf.d file redefined the OPERATOR's destination ACL name,
#     so the next reload would union the managed destinations into the
#     operator's own allow rules,
#   * `ghproxyctl status` printed empty Squid fields (state load/write asymmetry)
#     and a stale "backend=none" firewall (no live detection).
#
# It then exercises `ghproxyctl server reconcile` on a simulated legacy install,
# including its dry-run mode and its promise of no reload/restart.
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
TLS_DIR="$GP_ROOT/etc/squid/tls"
STATE="$GP_ROOT/etc/vps-gateway-manager"
FIXTURE="$TESTS_DIR/fixtures/production-debian13"

mkdir -p "$CONF_D" "$TLS_DIR" "$GP_ROOT/var/log/squid" "$GP_ROOT/var/spool/squid" \
         "$GP_ROOT/run" "$GP_ROOT/etc/letsencrypt/live/$DOMAIN" \
         "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy" "$GP_ROOT/etc/ssl/certs" \
         "$GP_ROOT/etc/default"
sed -e "s#@@ROOT@@#$GP_ROOT#g" "$FIXTURE/squid.conf" > "$SQUID_CONF"
sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$TLS_DIR#g" \
  "$FIXTURE/conf.d/github-whitelist.conf" > "$WHITELIST"
stub_make_cert "$TLS_DIR" "$DOMAIN" >/dev/null 2>&1 || {
  printf 'openssl unavailable: cannot run this test\n'; exit 1; }
printf -- '-----BEGIN CERTIFICATE-----\nstub\n' > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"
printf 'IPV6=yes\n' > "$GP_ROOT/etc/default/ufw"
printf '#!/bin/sh\n# existing production hook\nsystemctl reload squid\n' \
  > "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh"

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

WL_SUM="$(gp_sha256 "$WHITELIST")"
CIDRS="203.0.113.11/32 203.0.113.12/32 203.0.113.13/32 2001:db8::11/128 2001:db8::12/128 2001:db8::13/128"

count_rows() { printf '%s\n' "$1" | grep -c . || true; }

# -----------------------------------------------------------------------------
# 1. Formal adoption (not a dry-run)
# -----------------------------------------------------------------------------
t_begin "formal adoption of the production-shaped host"
OUT="$(run_install server --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "adoption exits successfully"
assert_contains "$OUT" 'adoption complete' "adoption reported completion"

t_begin "all six clients survive the import"
assert_eq "6" "$(clients_db_count)" "six inventory rows"
assert_eq "6" "$(clients_db_list | awk -F'\t' '$4 == "adopted"' | wc -l | tr -d ' ')" "six adopted clients"
assert_eq "0" "$(clients_db_list | awk -F'\t' '$4 != "adopted"' | wc -l | tr -d ' ')" "none of them are managed"
for c in $CIDRS; do
  assert_eq "1" "$(clients_db_list | awk -F'\t' -v c="$c" '$2 == c' | wc -l | tr -d ' ')" "preserved: $c"
done

t_begin "names and acl_ids are unique"
assert_eq "6" "$(clients_db_list | cut -f1 | sort -u | wc -l | tr -d ' ')" "display names are unique"
assert_eq "6" "$(clients_db_list | cut -f7 | sort -u | wc -l | tr -d ' ')" "acl_ids are unique"
assert_eq "allowed_clients" "$(clients_db_list | head -n1 | cut -f1)" "the first keeps the ACL name"
assert_eq "allowed_clients-2" "$(clients_db_list | sed -n '2p' | cut -f1)" "the second is suffixed"
assert_eq "allowed_clients_2" "$(clients_db_list | sed -n '2p' | cut -f7)" "its acl_id is suffixed too"

t_begin "the managed file never redefines an operator ACL"
assert_file_contains "$OURS" 'acl gsp_managed_github dstdomain' "project destination ACL is defined"
assert_file_not_contains "$OURS" '^acl github_dst' "operator destination ACL is not redefined"
assert_file_contains "$OURS" 'http_access allow gsp_managed_clients gsp_managed_github' "the managed rule uses only project ACLs"
assert_file_contains "$OURS" 'Operator destination ACL' "the operator ACL is documented in the file"
assert_file_contains "$OURS" 'github_dst' "the operator ACL name is named in the doc line"

t_begin "the operator's own configuration is untouched"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator conf.d file byte-identical"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator file still byte-identical (second read)"

t_begin "adoption performs no service action and no firewall change"
assert_eq "" "$(stub_systemd_actions)" "no reload and no restart"
assert_not_contains "$(stub_squid_calls)" '-k reconfigure' "squid was never asked to reconfigure"
assert_eq "existing-rule" "$(cat "$STUB_STATE/ufw/rules")" "no firewall rule was added or removed"

t_begin "state records the operator and managed ACL names separately"
assert_eq "gsp_managed_github" "$(conf_get "$STATE/server.conf" domain_acl_name)" "managed name in state"
assert_eq "github_dst" "$(conf_get "$STATE/server.conf" operator_domain_acl_name)" "operator name in state"
assert_eq "adopted" "$(conf_get "$STATE/server.conf" mode)" "mode is adopted"
assert_eq "5" "$(domains_current_list | wc -l | tr -d ' ')" "the managed destination list has the five default entries"

# -----------------------------------------------------------------------------
# 2. State round trip (why status used to print empty fields)
# -----------------------------------------------------------------------------
t_begin "server state survives a write/load round trip"
server_state_load                             # exactly what adoption left behind
SQUID_BIN="/usr/sbin/squid"
SQUID_VERSION="6.13"
SQUID_FLAVOR="openssl"
SQUID_VENDOR_PKG="squid-openssl"
server_state_write
SQUID_BIN=""; SQUID_VERSION=""; SQUID_FLAVOR=""; SQUID_VENDOR_PKG=""
SERVER_MODE=""; SERVER_OPERATOR_DOMAIN_ACL_NAME=""; SERVER_DOMAIN_ACL_NAME=""
server_state_load
assert_eq "/usr/sbin/squid" "$SQUID_BIN" "squid binary survives"
assert_eq "6.13" "$SQUID_VERSION" "squid version survives"
assert_eq "openssl" "$SQUID_FLAVOR" "squid flavor survives"
assert_eq "squid-openssl" "$SQUID_VENDOR_PKG" "package name survives"
assert_eq "adopted" "$SERVER_MODE" "mode survives"
assert_eq "gsp_managed_github" "$SERVER_DOMAIN_ACL_NAME" "managed ACL name survives"
assert_eq "github_dst" "$SERVER_OPERATOR_DOMAIN_ACL_NAME" "operator ACL name survives"

t_begin "status reports live squid and firewall data"
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "status exits successfully"
assert_contains "$OUT" 'Squid             6.13 (openssl)' "the state values are shown, not empty fields"
assert_contains "$OUT" 'backend=ufw active=1 ipv6=1' "the live firewall state is detected"
assert_contains "$OUT" '(managed=1)' "firewall management is reported separately"
assert_contains "$OUT" 'Clients           6 total (0 managed, 6 adopted)' "the inventory is counted correctly"

# -----------------------------------------------------------------------------
# 3. Repair path: reconcile a legacy (broken) installation
# -----------------------------------------------------------------------------
t_begin "simulate the legacy broken installation"
# Exactly what the old import produced: one row and a managed file that
# redefines the operator ACL.
{
  printf '# %s client database (tab separated)\n' "$GP_PROJECT_NAME"
  printf 'allowed_clients\t203.0.113.11/32\t2026-09-21 00:00:00Z\tadopted\t%s\tacl allowed_clients (ipv4)\tallowed_clients\n' "$WHITELIST"
} > "$(gp_clients_db)"
SERVER_DOMAIN_ACL_NAME="github_dst"
SERVER_OPERATOR_DOMAIN_ACL_NAME=""
{
  server_render_clients_file 1
} > "$OURS"
conf_set "$STATE/server.conf" domain_acl_name "github_dst"
conf_set "$STATE/server.conf" operator_domain_acl_name ""
LEGACY_DB_SUM="$(gp_sha256 "$(gp_clients_db)")"
LEGACY_CONF_SUM="$(gp_sha256 "$OURS")"
assert_eq "1" "$(clients_db_count)" "the broken state has one row"
assert_file_contains "$OURS" '^acl github_dst' "the broken state redefines the operator ACL"

t_begin "reconcile --dry-run is a read-only plan"
OUT="$(run_ctl server reconcile --dry-run --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the dry-run exits successfully"
assert_contains "$OUT" 'reconcile' "the plan is announced"
assert_contains "$OUT" '6' "six adopted clients are planned"
assert_contains "$OUT" 'gsp_managed_github' "the project destination ACL is planned"
assert_contains "$OUT" 'never redefined' "the operator ACL promise is repeated"
assert_contains "$OUT" 'no reload, no restart' "the no-reload guarantee is stated"
assert_contains "$OUT" 'read-only reconcile plan' "the dry-run is explicit"
assert_eq "$LEGACY_DB_SUM" "$(gp_sha256 "$(gp_clients_db)")" "inventory unchanged by dry-run"
assert_eq "$LEGACY_CONF_SUM" "$(gp_sha256 "$OURS")" "managed file unchanged by dry-run"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator file unchanged by dry-run"
assert_eq "" "$(stub_systemd_actions)" "dry-run performed no service action"

t_begin "reconcile repairs the installation without touching Squid"
OUT="$(run_ctl server reconcile --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "reconcile exits successfully"
assert_contains "$OUT" 'reconcile complete' "repair reported completion"
assert_eq "6" "$(clients_db_count)" "six adopted rows restored"
for c in $CIDRS; do
  assert_eq "1" "$(clients_db_list | awk -F'\t' -v c="$c" '$2 == c' | wc -l | tr -d ' ')" "restored: $c"
done
assert_eq "6" "$(clients_db_list | cut -f1 | sort -u | wc -l | tr -d ' ')" "names are unique"
assert_file_contains "$OURS" 'acl gsp_managed_github dstdomain' "the managed file uses the project ACL"
assert_file_not_contains "$OURS" '^acl github_dst' "the operator ACL is no longer redefined"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator file byte-identical after repair"
assert_eq "gsp_managed_github" "$(conf_get "$STATE/server.conf" domain_acl_name)" "state: managed name"
assert_eq "github_dst" "$(conf_get "$STATE/server.conf" operator_domain_acl_name)" "state: operator name"
assert_eq "" "$(stub_systemd_actions)" "no reload and no restart during the repair"
assert_not_contains "$(stub_squid_calls)" '-k reconfigure' "squid was never asked to reconfigure during the repair"
assert_eq "existing-rule" "$(cat "$STUB_STATE/ufw/rules")" "the firewall was not touched"

t_begin "reconcile is idempotent"
DB_SUM="$(gp_sha256 "$(gp_clients_db)")"
CONF_SUM="$(gp_sha256 "$OURS")"
OUT="$(run_ctl server reconcile --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "the second run succeeds"
assert_contains "$OUT" 'already consistent' "nothing left to repair"
assert_eq "$DB_SUM" "$(gp_sha256 "$(gp_clients_db)")" "inventory unchanged"
assert_eq "$CONF_SUM" "$(gp_sha256 "$OURS")" "managed file unchanged"
assert_eq "" "$(stub_systemd_actions)" "still no service action"

sandbox_teardown 2>/dev/null || true
t_summary
