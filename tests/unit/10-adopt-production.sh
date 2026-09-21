#!/usr/bin/env bash
# =============================================================================
# unit test :: adoption dry-run against a production-shaped Debian 13 host
#
# Regression cover for the first real dry-run, which printed only
#
#   == vps-gateway-manager :: adopting the existing proxy ==
#
# and returned to the shell because
#   * the discovery report was never collected,
#   * the TLS listener was looked up in the main file only (it lives in a
#     conf.d include), and the resulting certificate lookup aborted the script
#     silently under `set -e`,
#   * inline dstdomain ACLs were mistaken for file paths.
#
# The report must always be complete, and the dry-run must stay read-only.
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
TLS_DIR="$GP_ROOT/etc/squid/tls"
OURS="$CONF_D/00-vps-gateway-manager-clients.conf"
FIXTURE="$TESTS_DIR/fixtures/production-debian13"

mkdir -p "$CONF_D" "$TLS_DIR" "$GP_ROOT/var/log/squid" "$GP_ROOT/var/spool/squid" \
         "$GP_ROOT/run" "$GP_ROOT/etc/letsencrypt/live/$DOMAIN" \
         "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"

sed -e "s#@@ROOT@@#$GP_ROOT#g" "$FIXTURE/squid.conf" > "$SQUID_CONF"
sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$TLS_DIR#g" \
  "$FIXTURE/conf.d/github-whitelist.conf" > "$WHITELIST"
stub_make_cert "$TLS_DIR" "$DOMAIN" >/dev/null 2>&1 || {
  printf 'openssl unavailable: cannot run this test\n'; exit 1; }
printf '#!/bin/sh\n# existing production hook\nsystemctl reload squid\n' \
  > "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy/reload-squid-tls.sh"
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
# The host really runs certbot.timer; `systemctl list-timers` is a read-only
# query and must be answered during the dry-run.
printf 'NEXT  LEFT  LAST  PASSED  UNIT  ACTIVATES\nTue 2026-09-22 00:00 UTC  1h  certbot.timer  certbot.service\n' \
  > "$STUB_STATE/systemd/timers"

BEFORE_SQUID="$(gp_sha256 "$SQUID_CONF")"
BEFORE_WL="$(gp_sha256 "$WHITELIST")"

# -----------------------------------------------------------------------------
# Parser level: the effective configuration includes conf.d
# -----------------------------------------------------------------------------
t_begin "the include tree is walked"
INCLUDES="$(squid_conf_includes "$SQUID_CONF")"
assert_contains "$INCLUDES" 'github-whitelist.conf' "conf.d file is part of the effective configuration"
LISTENERS="$(squid_config_listeners "$SQUID_CONF")"
assert_contains "$LISTENERS" 'http_port 127.0.0.1:3128' "loopback listener found in the main file"
assert_contains "$LISTENERS" 'https_port 8443 tls-cert=' "TLS listener found in the INCLUDED file"

t_begin "destination ACLs are typed (inline vs file vs regex)"
EFFECTIVE_FILES=("$SQUID_CONF")
while IFS= read -r _f; do [ -n "$_f" ] && EFFECTIVE_FILES+=("$_f"); done < <(squid_conf_includes "$SQUID_CONF")
DST="$(squid_dst_acls "${EFFECTIVE_FILES[@]}")"
assert_eq "github_dst" "$(squid_dst_acl_used "${EFFECTIVE_FILES[@]}")" "the destination ACL used by http_access is identified"
assert_eq "0" "$(printf '%s\n' "$DST" | awk -F'\t' '$2 == "file"' | wc -l | tr -d ' ')" "inline definitions are not reported as files"
assert_eq "5" "$(printf '%s\n' "$DST" | grep . | cut -f3 | sort -u | wc -l | tr -d ' ')" "all five distinct inline destinations are found"
assert_contains "$(printf '%s\n' "$DST" | cut -f3 | sort -u)" 'ghcr.io' "a bare domain is an inline destination"
assert_contains "$(printf '%s\n' "$DST" | cut -f3 | sort -u)" '.cloudfront.net' "the broad CDN entry is discovered (and later refused)"
TMP_CONF="$(mktemp)"
printf 'acl files dstdomain "/tmp/list.txt"\nacl re dstdom_regex ^foo\\.example\\.com\n' > "$TMP_CONF"
DST2="$(squid_acl_dst_entries "$TMP_CONF")"
assert_eq "file" "$(printf '%s\n' "$DST2" | awk -F'\t' '$1 == "files"' | cut -f2)" "a quoted path is a file-backed ACL"
assert_eq "regex" "$(printf '%s\n' "$DST2" | awk -F'\t' '$1 == "re"' | cut -f2)" "a dstdom_regex pattern is flagged as a regex"
rm -f "$TMP_CONF"

t_begin "source ACLs: several definitions and several values per line"
SRC="$(squid_acl_src_entries "$WHITELIST")"
assert_eq "6" "$(printf '%s\n' "$SRC" | grep -c .)" "all six exact clients found"
assert_eq "1" "$(printf '%s\n' "$SRC" | grep . | cut -f2 | sort -u | wc -l | tr -d ' ')" "they share one ACL name (Squid ORs the values)"

# -----------------------------------------------------------------------------
# The dry-run report itself
# -----------------------------------------------------------------------------
t_begin "adoption dry-run against a Debian 13 production host"
OUT="$(run_install server --adopt-existing --dry-run --verbose --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "dry-run exits successfully"

t_begin "the report contains every required section"
assert_contains "$OUT" 'adoption plan' "adoption plan"
assert_contains "$OUT" '== squid ==' "squid section"
assert_contains "$OUT" 'version: ' "squid version"
assert_contains "$OUT" 'main config: ' "main configuration (discovery)"
assert_contains "$OUT" 'main configuration' "main configuration (plan)"
assert_contains "$OUT" 'included files (in load order):' "include file list"
assert_contains "$OUT" 'github-whitelist.conf' "the included production file"
assert_contains "$OUT" 'configured listeners:' "listener list"
assert_contains "$OUT" 'https_port 8443 tls-cert=' "TLS listener from the include"
assert_contains "$OUT" 'TLS listener' "TLS listener (plan)"
assert_contains "$OUT" '8443' "TLS port value"
assert_contains "$OUT" 'source acl file: ' "source ACL (discovery)"
assert_contains "$OUT" 'client ACL file (yours)' "source ACL (plan)"
assert_contains "$OUT" 'destination acl declarations' "destination declarations (discovery)"
assert_contains "$OUT" 'inline' "inline destination type"
assert_contains "$OUT" 'ghcr.io' "inline destination value"
assert_contains "$OUT" 'firewall' "firewall"
assert_contains "$OUT" 'renewal timer:' "certbot timer section"
assert_contains "$OUT" 'certbot.timer' "the timer is discovered (list-timers runs in dry-run)"
assert_contains "$OUT" 'final http_access rule is a deny' "the policy audit names the deny terminator"
assert_not_contains "$OUT" 'open proxy' "deny all is not misreported as an open proxy"
assert_not_contains "$OUT" 'policy audit produced warnings' "the production configuration produces no policy finding"
if printf '%s\n' "$OUT" | grep -qE '^/tmp/tmp\.[A-Za-z0-9]+$'; then
  t_fail "the discovery temporary path leaked into the report"
else
  t_ok "no temporary path is printed"
fi
assert_contains "$OUT" 'files this project WILL create' "will create"
assert_contains "$OUT" 'files this project will NOT touch during adoption' "will NOT touch"
assert_contains "$OUT" 'read-only adoption analysis' "read-only closing note"
TLS_PLAN_LINE="$(printf '%s\n' "$OUT" | grep -m1 '^TLS listener' || true)"
assert_contains "$TLS_PLAN_LINE" '8443' "TLS listener port (plan)"
assert_contains "$TLS_PLAN_LINE" "$TLS_DIR/fullchain.pem" "certificate path reported"
assert_contains "$TLS_PLAN_LINE" "$TLS_DIR/privkey.pem" "key path reported"
DEST_PLAN_LINE="$(printf '%s\n' "$OUT" | grep -m1 '^destination ACL' || true)"
assert_contains "$DEST_PLAN_LINE" 'github_dst' "destination ACL name (plan)"
assert_contains "$DEST_PLAN_LINE" '(inline domains in' "the inline destination ACL is described as inline"
assert_contains "$DEST_PLAN_LINE" 'github-whitelist.conf' "the declaring file is reported"

t_begin "every client and every safe destination is discovered"
assert_contains "$OUT" '203.0.113.11/32'
assert_contains "$OUT" '203.0.113.12/32'
assert_contains "$OUT" '203.0.113.13/32'
assert_contains "$OUT" '2001:db8::11/128'
assert_contains "$OUT" '2001:db8::12/128'
assert_contains "$OUT" '2001:db8::13/128'
assert_contains "$OUT" 'clients found in your ACL file: 6' "all six clients in the plan"
assert_contains "$OUT" 'destination entries imported into the managed list: 4' "four safe destinations imported, duplicates collapsed"
assert_contains "$OUT" '.githubassets.com'
assert_contains "$OUT" 'ghcr.io'
IMPORTED_SECTION="$(printf '%s\n' "$OUT" | sed -n '/destination entries imported into the managed list/,/files this project WILL create/p')"
assert_not_contains "$IMPORTED_SECTION" 'cloudfront' "the broad CDN entry is not imported"
assert_contains "$OUT" 'NOT imported into the managed list' "the refusal is explained"

t_begin "the dry-run changed nothing"
assert_eq "$BEFORE_SQUID" "$(gp_sha256 "$SQUID_CONF")" "squid.conf byte-identical"
assert_eq "$BEFORE_WL" "$(gp_sha256 "$WHITELIST")" "operator conf.d file byte-identical"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/role" "no state written"
assert_file_absent "$OURS" "no managed conf.d file written"
assert_file_absent "$(gp_managed_clients_acl)" "no managed client ACL written"
assert_eq "" "$(stub_systemd_actions)" "no reload and no restart"
assert_not_contains "$(stub_squid_calls)" '-k reconfigure' "squid was never reconfigured"
if printf '%s\n' "$(stub_ufw_calls)" | grep -qE 'allow|delete|--force|enable|disable|reset|flush'; then
  t_fail "the dry-run issued a mutating ufw command: $(stub_ufw_calls | tr '\n' ' ')"
else
  t_ok "ufw was only queried, never changed"
fi

# -----------------------------------------------------------------------------
# Regression: the old code aborted silently when the certificate path could not
# be resolved (the TLS listener lived in an include). Without a TLS listener the
# report must still be complete and the run must explain itself.
# -----------------------------------------------------------------------------
t_begin "a missing TLS listener cannot abort the report"
grep -v '^https_port' "$WHITELIST" > "$WHITELIST.tmp" && mv "$WHITELIST.tmp" "$WHITELIST"
OUT2="$(run_install server --adopt-existing --dry-run --verbose --yes 2>&1)"; RC2=$?
if [ "$RC2" != "0" ]; then printf '%s\n' "$OUT2" >&2; fi
TLS_PLAN_LINE2="$(printf '%s\n' "$OUT2" | grep -m1 '^TLS listener' || true)"
assert_contains "$OUT2" 'adoption plan' "the report is still printed"
assert_contains "$OUT2" 'no TLS listener' "the missing TLS listener is reported"
assert_contains "$TLS_PLAN_LINE2" '<none>' "the plan shows that no TLS listener was found"
assert_contains "$OUT2" 'read-only adoption analysis' "the run still completes read-only"
assert_file_absent "$OURS" "still nothing written"
# Restore the fixture for the fatal-failure scenario below.
sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$TLS_DIR#g" \
  "$FIXTURE/conf.d/github-whitelist.conf" > "$WHITELIST"

t_begin "a fatal analysis failure is loud and returns non-zero"
cat > "$STUB_STATE/systemd/squid.cat" <<EOF
# missing configuration
[Unit]
Description=Squid Web Proxy Server
[Service]
ExecStart=/usr/sbin/squid -f $GP_ROOT/etc/squid/does-not-exist.conf -YC
[Install]
WantedBy=multi-user.target
EOF
stub_register_unit squid 1 "$STUB_STATE/systemd/squid.cat"
OUT3="$(run_install server --adopt-existing --dry-run --yes 2>&1)"; RC3=$?
assert_ne "0" "$RC3" "the dry-run does not pretend to have succeeded"
assert_contains "$OUT3" 'adoption analysis failed' "the analysis failure is reported"
assert_contains "$OUT3" 'not readable' "the unreadable configuration is named"
assert_contains "$OUT3" 'nothing was changed' "the operator is reassured that nothing changed"

sandbox_teardown 2>/dev/null || true
t_summary
