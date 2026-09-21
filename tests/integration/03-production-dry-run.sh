#!/usr/bin/env bash
# =============================================================================
# integration test :: read-only adoption dry-run, production-shaped Debian 13
#
# Uses tests/fixtures/production-debian13/ with a REAL Squid daemon serving:
#
#   * the TLS listener, the client ACLs and the INLINE destination ACLs live in
#     an included conf.d file, not in the main squid.conf
#   * the operator's file ends with "http_access deny all"
#
# Then it runs `install.sh server --adopt-existing --dry-run --verbose` and
# asserts, behaviourally:
#
#   * the full discovery report is printed (never just the title)
#   * the TLS listener is discovered through the include tree
#   * all six exact clients and all inline destinations are discovered
#   * nothing was written, the daemon PID did not change, no reload/restart was
#     issued, exactly one Squid is running and it still serves
#
# Requires: Linux, root, squid-openssl, no internet access needed.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'integ_teardown' EXIT

DOMAIN="gh.smartproxy.test"
PLAIN_PORT=3128
TLS_PORT=8443
MAIN_CONF="$GP_ROOT/etc/squid/squid.conf"
CONF_D="$GP_ROOT/etc/squid/conf.d"
WHITELIST="$CONF_D/github-whitelist.conf"
TLS_DIR="$GP_ROOT/etc/squid/tls"
CERT_DIR="$INTEG_WORK/certs"
STATE_DIR="$GP_ROOT/etc/vps-gateway-manager"
OURS="$CONF_D/00-vps-gateway-manager-clients.conf"

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"

# -----------------------------------------------------------------------------
# A production-shaped installation with the TLS listener in the include file
# -----------------------------------------------------------------------------
mkdir -p "$CONF_D" "$TLS_DIR" "$GP_ROOT/var/log/squid" "$GP_ROOT/var/spool/squid" \
         "$GP_ROOT/spool/squid" "$GP_ROOT/run" "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"
sed -e "s#@@ROOT@@#$GP_ROOT#g" "$INTEG_ROOT/tests/fixtures/production-debian13/squid.conf" > "$MAIN_CONF"
sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$TLS_DIR#g" \
  "$INTEG_ROOT/tests/fixtures/production-debian13/conf.d/github-whitelist.conf" > "$WHITELIST"

# The production host listens on both loopback families. Containers that have no
# IPv6 loopback cannot bind [::1]; drop that one line there (and say so) instead
# of failing the whole suite for an environment limitation.
if ip -6 addr show dev lo 2>/dev/null | grep -q 'inet6 ::1'; then
  printf 'IPv6 loopback available: the [::1] listener line is used as-is\n'
else
  printf 'note: no IPv6 loopback in this environment; removing the [::1] listener line\n'
  sed -i '/^http_port \[::1\]:3128$/d' "$MAIN_CONF"
fi

integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway "$DOMAIN" 127.0.0.1 || { printf 'could not create a certificate\n'; exit 1; }
cp "$CERT_DIR/gateway.fullchain.pem" "$TLS_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$TLS_DIR/privkey.pem"
integ_fix_tls_perms "$TLS_DIR"
integ_fix_perms

# The host really runs certbot.timer. `systemctl list-timers` is a read-only
# query, so the dry-run must actually execute it and show the timer.
printf 'NEXT  LEFT  LAST  PASSED  UNIT  ACTIVATES\nTue 2026-09-22 00:00 UTC  1h  certbot.timer  certbot.service\n' \
  > "$INTEG_WORK/service/timers"

MAIN_SUM="$(gp_sha256 "$MAIN_CONF")"
WL_SUM="$(gp_sha256 "$WHITELIST")"
CERT_SUM="$(gp_sha256 "$TLS_DIR/fullchain.pem")"
KEY_SUM="$(gp_sha256 "$TLS_DIR/privkey.pem")"

t_begin "the production-shaped proxy is serving before the dry-run"
PROD_PID="$(integ_start_squid "$MAIN_CONF" "$GP_ROOT/run/squid.pid" "$GP_ROOT/production.log")"
assert_ok "plain loopback listener is up on $PLAIN_PORT" integ_wait_port "$PLAIN_PORT" 25
assert_ok "TLS listener is up on $TLS_PORT" integ_wait_port "$TLS_PORT" 25
DAEMON_PID="$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)"
if [ -n "$DAEMON_PID" ]; then
  t_ok "the daemon is identified through its pid file (pid $DAEMON_PID)"
else
  t_fail "no live squid daemon could be identified from $MAIN_CONF"
fi
if integ_tls_check 127.0.0.1 "$TLS_PORT" "$DOMAIN" "$CERT_DIR/ca.pem"; then
  t_ok "the TLS listener completes a verified handshake"
else
  t_fail "the TLS listener does not complete a verified handshake"
fi
# 127.0.0.1 is not one of the operator's clients, so the final deny answers:
# receiving that 403 proves the proxy is actually serving requests.
integ_wait_http_code 403 "the proxy answers requests from loopback" \
  --proxy "http://127.0.0.1:$PLAIN_PORT" http://example.com/

# -----------------------------------------------------------------------------
t_begin "the adoption dry-run prints the full report"
OUT="$(run_install server --adopt-existing --dry-run --verbose --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "dry-run exits successfully"
assert_contains "$OUT" 'adoption plan' "adoption plan"
assert_contains "$OUT" '== squid ==' "squid section"
assert_contains "$OUT" 'version: ' "squid version"
assert_contains "$OUT" 'main config: ' "main configuration (discovery)"
assert_contains "$OUT" "main configuration      : $MAIN_CONF" "main configuration (plan)"
assert_contains "$OUT" 'included files (in load order):' "include file list"
assert_contains "$OUT" 'github-whitelist.conf' "the included production file"
assert_contains "$OUT" 'configured listeners:' "listener list"
assert_contains "$OUT" 'https_port 8443 tls-cert=' "TLS listener discovered through the include"
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
assert_contains "$TLS_PLAN_LINE" "$TLS_DIR" "TLS directory reported"
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
IMPORTED_SECTION="$(printf '%s\n' "$OUT" | sed -n '/destination entries imported into the managed list/,/files this project WILL create/p')"
assert_not_contains "$IMPORTED_SECTION" 'cloudfront' "the broad CDN entry is not imported"
assert_contains "$OUT" 'NOT imported into the managed list' "the refusal is explained"

# -----------------------------------------------------------------------------
t_begin "the dry-run did not disturb the running production proxy"
assert_eq "$MAIN_SUM" "$(gp_sha256 "$MAIN_CONF")" "squid.conf byte-identical"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator conf.d file byte-identical"
assert_eq "$CERT_SUM" "$(gp_sha256 "$TLS_DIR/fullchain.pem")" "certificate byte-identical"
assert_eq "$KEY_SUM" "$(gp_sha256 "$TLS_DIR/privkey.pem")" "private key byte-identical"
assert_file_absent "$STATE_DIR/role" "no state written"
assert_file_absent "$OURS" "no managed conf.d file written"
assert_file_absent "$STATE_DIR/managed-clients.acl" "no managed client ACL written"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "the daemon PID is unchanged"
assert_ok "the same daemon is still running" integ_squid_alive "$DAEMON_PID"
integ_assert_sandbox_squid_count 1 "exactly one Squid instance is running"
if [ -r "$INTEG_WORK/service/calls.log" ] && grep -qE 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log"; then
  t_fail "the dry-run issued a reload or restart: $(grep -E 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log" | tr '\n' ' ')"
else
  t_ok "no reload and no restart was issued"
fi
assert_ok "the plain listener is still up" integ_wait_port "$PLAIN_PORT" 10
assert_ok "the TLS listener is still up" integ_wait_port "$TLS_PORT" 10
if integ_tls_check 127.0.0.1 "$TLS_PORT" "$DOMAIN" "$CERT_DIR/ca.pem"; then
  t_ok "the TLS listener still completes a verified handshake"
else
  t_fail "the TLS listener stopped completing a verified handshake"
fi
integ_wait_http_code 403 "the proxy still answers requests" \
  --proxy "http://127.0.0.1:$PLAIN_PORT" http://example.com/

printf '\n--- adopted production cache.log (last lines) ---\n'
tail -n 10 "$GP_ROOT/var/log/squid/cache.log" 2>/dev/null | sed 's/^/  /' || true
integ_dump_logs "integration service calls" "$INTEG_WORK/service/calls.log" 10

integ_teardown
trap - EXIT
t_summary
