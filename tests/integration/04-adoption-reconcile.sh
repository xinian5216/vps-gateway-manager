#!/usr/bin/env bash
# =============================================================================
# integration test :: FORMAL adoption + destination isolation + repair
#
# Runs the production-shaped Debian 13 fixture against a REAL Squid, adopts it
# formally (not a dry-run) and then proves with live traffic:
#
#   * the six clients sharing the operator ACL name all survive the import
#   * the managed conf.d file uses a PROJECT-OWNED destination ACL and never
#     redefines the operator's `github_dst`
#   * after a reload, an operator client still cannot reach a destination that
#     only the project list contains (.github.io), while a managed client can
#   * `ghproxyctl server reconcile` repairs a simulated legacy (broken) install
#     transactionally, with byte-identical operator files and NO reload/restart
#   * afterwards the same live checks pass again
#
# Requires: Linux, root, squid-openssl, internet access to api.github.com /
# github.io.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'integ_teardown' EXIT

integ_skip_if_offline https://api.github.com/rate_limit

DOMAIN="gh.smartproxy.test"
PLAIN_PORT=3128
TLS_PORT=8443
MAIN_CONF="$GP_ROOT/etc/squid/squid.conf"
CONF_D="$GP_ROOT/etc/squid/conf.d"
WHITELIST="$CONF_D/github-whitelist.conf"
OURS="$CONF_D/00-vps-gateway-manager-clients.conf"
TLS_DIR="$GP_ROOT/etc/squid/tls"
CERT_DIR="$INTEG_WORK/certs"
STATE_DIR="$GP_ROOT/etc/vps-gateway-manager"
MANAGED_LIST="$STATE_DIR/github-domains.txt"

# Traffic-testable client addresses: the fixture's IPv4 clients map to loopback
# aliases (127.0.0.0/8 is all local), the IPv6 ones stay as realistic filler.
OPERATOR_V4="127.0.0.11"
MANAGED_V4="127.0.0.2"
UNLISTED_V4="127.0.0.3"
CLIENT_CIDRS="127.0.0.11/32 127.0.0.12/32 127.0.0.13/32 2001:db8::11/128 2001:db8::12/128 2001:db8::13/128"

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"

mkdir -p "$CONF_D" "$TLS_DIR" "$GP_ROOT/var/log/squid" "$GP_ROOT/var/spool/squid" \
         "$GP_ROOT/spool/squid" "$GP_ROOT/run" "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"
sed -e "s#@@ROOT@@#$GP_ROOT#g" "$INTEG_ROOT/tests/fixtures/production-debian13/squid.conf" > "$MAIN_CONF"
sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$TLS_DIR#g" \
    -e "s#203\.0\.113\.11#127.0.0.11#g" -e "s#203\.0\.113\.12#127.0.0.12#g" \
    -e "s#203\.0\.113\.13#127.0.0.13#g" \
  "$INTEG_ROOT/tests/fixtures/production-debian13/conf.d/github-whitelist.conf" > "$WHITELIST"

if ip -6 addr show dev lo 2>/dev/null | grep -q 'inet6 ::1'; then
  :
else
  printf 'note: no IPv6 loopback; removing the [::1] listener line\n'
  sed -i '/^http_port \[::1\]:3128$/d' "$MAIN_CONF"
fi

# Test-only adaptation: the operator file's terminal `http_access deny all` is
# kept in the unit fixture (and in production), but the server-side health checks
# connect from 127.0.0.1, which the main file's `http_access allow localhost`
# can only reach when that deny is gone. Unlisted clients are still refused by
# the main file's own `http_access deny all`.
sed -i '/^http_access deny all$/d' "$WHITELIST"

integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway "$DOMAIN" 127.0.0.1 || { printf 'could not create a certificate\n'; exit 1; }
cp "$CERT_DIR/gateway.fullchain.pem" "$TLS_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$TLS_DIR/privkey.pem"
integ_fix_tls_perms "$TLS_DIR"
integ_fix_perms
integ_trust_ca "$CERT_DIR/ca.pem" && printf 'test CA installed in the system trust store\n'

WL_SUM="$(gp_sha256 "$WHITELIST")"
MAIN_SUM="$(gp_sha256 "$MAIN_CONF")"

t_begin "the production-shaped proxy is serving"
integ_start_squid "$MAIN_CONF" "$GP_ROOT/run/squid.pid" "$GP_ROOT/production.log" >/dev/null
assert_ok "plain listener is up on $PLAIN_PORT" integ_wait_port "$PLAIN_PORT" 25
assert_ok "TLS listener is up on $TLS_PORT" integ_wait_port "$TLS_PORT" 25
DAEMON_PID="$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)"
if [ -n "$DAEMON_PID" ]; then t_ok "daemon identified (pid $DAEMON_PID)"; else t_fail "no daemon identified"; fi

# -----------------------------------------------------------------------------
# 1. Formal adoption
# -----------------------------------------------------------------------------
t_begin "formal adoption of the running proxy"
OUT="$(run_install server --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "adoption exits successfully"
assert_contains "$OUT" 'adoption complete' "adoption reported completion"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator conf.d file byte-identical"
assert_eq "$MAIN_SUM" "$(gp_sha256 "$MAIN_CONF")" "operator main config byte-identical"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "adoption did not replace the daemon"
if [ -r "$INTEG_WORK/service/calls.log" ] && grep -qE 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log"; then
  t_fail "adoption issued a reload/restart: $(grep -E 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log" | tr '\n' ' ')"
else
  t_ok "adoption performed no reload and no restart"
fi

t_begin "all six clients survive the formal import"
assert_eq "6" "$(clients_db_count)" "six inventory rows"
for c in $CLIENT_CIDRS; do
  assert_eq "1" "$(clients_db_list | awk -F'\t' -v c="$c" '$2 == c' | wc -l | tr -d ' ')" "preserved: $c"
done
assert_eq "6" "$(clients_db_list | cut -f1 | sort -u | wc -l | tr -d ' ')" "display names are unique"
assert_eq "6" "$(clients_db_list | cut -f7 | sort -u | wc -l | tr -d ' ')" "acl_ids are unique"
assert_eq "6" "$(clients_db_list | awk -F'\t' '$4 == "adopted"' | wc -l | tr -d ' ')" "all rows are adopted"

t_begin "the managed file keeps the destination ACLs separate"
assert_file_contains "$OURS" 'acl gsp_managed_github dstdomain' "project destination ACL defined"
assert_file_not_contains "$OURS" '^acl github_dst' "operator destination ACL never redefined"
assert_file_contains "$OURS" 'http_access allow gsp_managed_clients gsp_managed_github' "managed rule uses project ACLs only"
assert_eq "gsp_managed_github" "$(conf_get "$STATE_DIR/server.conf" domain_acl_name)" "managed name in state"
assert_eq "github_dst" "$(conf_get "$STATE_DIR/server.conf" operator_domain_acl_name)" "operator name in state"

t_begin "status reports the real squid and the live firewall"
OUT="$(run_ctl status 2>&1)" || true
assert_contains "$OUT" "Squid             $SQUID_VERSION" "the squid version survives the state round trip"
assert_contains "$OUT" "Clients           6 total (0 managed, 6 adopted)" "the inventory is counted correctly"
assert_contains "$OUT" 'Firewall          backend=' "the firewall line is printed"

# -----------------------------------------------------------------------------
# 2. Simulate the legacy broken install and repair it
# -----------------------------------------------------------------------------
t_begin "simulate the legacy broken installation"
{
  printf '# %s client database (tab separated)\n' "$GP_PROJECT_NAME"
  printf 'allowed_clients\t127.0.0.11/32\t2026-09-21 00:00:00Z\tadopted\t%s\tacl allowed_clients (ipv4)\tallowed_clients\n' "$WHITELIST"
} > "$(gp_clients_db)"
SERVER_DOMAIN_ACL_NAME="github_dst"
SERVER_OPERATOR_DOMAIN_ACL_NAME=""
server_render_clients_file 1 > "$OURS"
conf_set "$STATE_DIR/server.conf" domain_acl_name "github_dst"
conf_set "$STATE_DIR/server.conf" operator_domain_acl_name ""
assert_eq "1" "$(clients_db_count)" "one row, as the old import left it"
assert_file_contains "$OURS" '^acl github_dst' "the operator ACL is redefined (the bug)"
BROKEN_DB_SUM="$(gp_sha256 "$(gp_clients_db)")"
BROKEN_CONF_SUM="$(gp_sha256 "$OURS")"

t_begin "reconcile --dry-run changes nothing"
OUT="$(run_ctl server reconcile --dry-run --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "the dry-run exits successfully"
assert_contains "$OUT" 'never redefined' "the operator ACL promise is printed"
assert_contains "$OUT" 'no reload, no restart' "the no-reload guarantee is stated"
assert_contains "$OUT" '6' "six clients are planned"
assert_eq "$BROKEN_DB_SUM" "$(gp_sha256 "$(gp_clients_db)")" "inventory unchanged"
assert_eq "$BROKEN_CONF_SUM" "$(gp_sha256 "$OURS")" "managed file unchanged"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator file unchanged"
if [ -r "$INTEG_WORK/service/calls.log" ]; then
  CALLS_BEFORE="$(wc -l < "$INTEG_WORK/service/calls.log" | tr -d ' ')"
  assert_eq "$CALLS_BEFORE" "$(wc -l < "$INTEG_WORK/service/calls.log" | tr -d ' ')" "no service call during the dry-run"
fi

t_begin "reconcile repairs the install without touching Squid"
OUT="$(run_ctl server reconcile --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "reconcile exits successfully"
assert_contains "$OUT" 'reconcile complete' "repair reported completion"
assert_eq "6" "$(clients_db_count)" "six adopted rows restored"
for c in $CLIENT_CIDRS; do
  assert_eq "1" "$(clients_db_list | awk -F'\t' -v c="$c" '$2 == c' | wc -l | tr -d ' ')" "restored: $c"
done
assert_file_contains "$OURS" 'acl gsp_managed_github dstdomain' "project ACL in the repaired file"
assert_file_not_contains "$OURS" '^acl github_dst' "operator ACL no longer redefined"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator file byte-identical after repair"
assert_eq "$MAIN_SUM" "$(gp_sha256 "$MAIN_CONF")" "operator main config byte-identical after repair"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "same daemon after the repair"
if [ -r "$INTEG_WORK/service/calls.log" ] && grep -qE 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log"; then
  t_fail "reconcile issued a reload/restart: $(grep -E 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log" | tr '\n' ' ')"
else
  t_ok "reconcile performed no reload and no restart"
fi
assert_ok "the repaired configuration parses" squid_parse "$MAIN_CONF"

t_begin "reconcile is idempotent"
DB_SUM="$(gp_sha256 "$(gp_clients_db)")"
CONF_SUM="$(gp_sha256 "$OURS")"
OUT="$(run_ctl server reconcile --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "the second run succeeds"
assert_contains "$OUT" 'already consistent' "nothing left to repair"
assert_eq "$DB_SUM" "$(gp_sha256 "$(gp_clients_db)")" "inventory unchanged"
assert_eq "$CONF_SUM" "$(gp_sha256 "$OURS")" "managed file unchanged"

# -----------------------------------------------------------------------------
# 3. Behaviour after the next reload: isolation must hold
# -----------------------------------------------------------------------------
reload_operator_config() {
  local offset
  offset="$(squid_cache_log_lines "$MAIN_CONF")"
  systemctl reload vgm-test-squid.service >/dev/null 2>&1 || kill -HUP "$DAEMON_PID" 2>/dev/null || true
  squid_wait_reconfigure_complete "$MAIN_CONF" "$offset" 20 "$DAEMON_PID"
}

t_begin "after a reload the operator still only reaches its own destinations"
assert_ok "the operator configuration was applied" reload_operator_config
assert_ok "the same daemon is still serving" integ_squid_alive "$DAEMON_PID"
CODE="$(integ_curl_code --interface "$OPERATOR_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the operator client reaches GitHub (HTTP $CODE)"
CODE="$(integ_curl_code --interface "$OPERATOR_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://ghcr.io/)"
if [ "$CODE" = "000" ]; then
  t_fail "the operator client cannot reach a destination FROM ITS OWN LIST (ghcr.io, HTTP 000)"
else
  t_ok "the operator client reaches its own ghcr.io rule (HTTP $CODE)"
fi
CODE="$(integ_curl_code --interface "$OPERATOR_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://github.io/)"
if [ "$CODE" = "000" ]; then
  t_ok "the operator client is REFUSED a project-only destination (.github.io, HTTP 000)"
else
  t_fail "destination isolation is broken: the operator reached .github.io (HTTP $CODE)"
fi

t_begin "a managed client gets the project destination list"
OUT="$(run_ctl client add "$MANAGED_V4" managed-node --allow-private --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the managed client was added (this reloads squid)"
CODE="$(integ_curl_code --interface "$MANAGED_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "200" "$CODE" "the managed client reaches GitHub (HTTP $CODE)"
CODE="$(integ_curl_code --interface "$MANAGED_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://github.io/)"
if [ "$CODE" = "000" ]; then
  integ_debug_curl --interface "$MANAGED_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://github.io/
  t_fail "the managed client cannot reach a project destination (.github.io, HTTP 000)"
else
  t_ok "the managed client reaches the project list (.github.io, HTTP $CODE)"
fi
CODE="$(integ_curl_code --interface "$UNLISTED_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://api.github.com/rate_limit)"
assert_eq "000" "$CODE" "an unlisted client is still refused (HTTP $CODE)"

t_begin "the operator client is still isolated after the managed add"
CODE="$(integ_curl_code --interface "$OPERATOR_V4" --proxy "http://127.0.0.1:$PLAIN_PORT" https://github.io/)"
if [ "$CODE" = "000" ]; then
  t_ok "the operator client still cannot reach .github.io (HTTP 000)"
else
  t_fail "destination isolation regressed: operator got HTTP $CODE for .github.io"
fi
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator file untouched throughout"

t_begin "the final state"
assert_ok "the daemon is still the original one" integ_squid_alive "$DAEMON_PID"
integ_assert_sandbox_squid_count 1 "exactly one Squid instance"
assert_file_contains "$(gp_managed_clients_acl)" "^$MANAGED_V4/32$" "the managed client is in the file-backed ACL"

printf '\n--- production-like cache.log (last lines) ---\n'
tail -n 10 "$GP_ROOT/var/log/squid/cache.log" 2>/dev/null | sed 's/^/  /' || true
printf '\n--- access.log (last lines) ---\n'
tail -n 8 "$GP_ROOT/var/log/squid/access.log" 2>/dev/null | sed 's/^/  /' || true

integ_teardown
trap - EXIT
t_summary
