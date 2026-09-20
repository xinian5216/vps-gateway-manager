#!/usr/bin/env bash
# =============================================================================
# integration test :: what does THIS Squid build actually support?
#
# The gateway needs a TLS-terminating *forward* proxy: a client must be able to
# open TLS to the listener, send CONNECT, and get a tunnel. Squid offers two
# candidate directives for that:
#
#   http_port  <port> tls-cert=... tls-key=...
#   https_port <port> tls-cert=... tls-key=...
#
# This probe starts a minimal Squid for each candidate (loopback only, no
# destination restrictions) and reports, with evidence:
#   1. is the listener really TLS? (two consecutive handshakes)
#   2. does a plain GET through it work? (curl -x https://...)
#   3. does CONNECT through it work? (curl -x https://... https://host)
#   4. what does a raw CONNECT answer look like?
#
# The results are printed as a table so the finding is visible in the CI log,
# and the assertions pin down whichever directive actually works.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'integ_teardown' EXIT

integ_skip_if_offline https://api.github.com/rate_limit

CERT_DIR="$INTEG_WORK/certs"
LOG_DIR="$GP_ROOT/var/log/squid"
mkdir -p "$CERT_DIR" "$LOG_DIR" "$GP_ROOT/spool/squid" "$GP_ROOT/run"
integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway ghproxy.test 127.0.0.1 || { printf 'could not create a certificate\n'; exit 1; }
cp "$CERT_DIR/gateway.fullchain.pem" "$CERT_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$CERT_DIR/privkey.pem"
integ_fix_perms

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"

probe_listener() {
  # probe_listener <label> <directive> <port>
  local label="$1" directive="$2" port="$3"
  local conf="$GP_ROOT/etc/squid/probe-$port.conf"
  local log="$LOG_DIR/probe-$port.log"
  local access="$LOG_DIR/probe-$port-access.log"
  local pid out rc=0

  mkdir -p "$GP_ROOT/etc/squid"
  {
    printf '# capability probe: %s\n' "$label"
    printf '%s\n' "$directive"
    printf 'visible_hostname probe\n'
    printf 'pid_filename %s\n' "$GP_ROOT/run/probe-$port.pid"
    printf 'coredump_dir %s\n' "$GP_ROOT/spool/squid"
    printf 'cache_effective_user %s\n' "$(squid_effective_user)"
    printf 'cache_effective_group %s\n' "$(squid_effective_group)"
    printf 'access_log %s squid\n' "$access"
    printf 'cache_log %s\n' "$LOG_DIR/probe-$port-cache.log"
    printf 'buffered_logs off\n'
    printf 'cache deny all\n'
    printf 'http_access allow all\n'
  } > "$conf" || { printf 'RESULT %s: could not write %s\n' "$label" "$conf"; return 1; }

  printf '\n=== %s ===\n' "$label"
  out="$("$SQUID_BIN" -f "$conf" -k parse 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qE '^(FATAL|Bungled)'; then
    printf 'RESULT %s: config rejected\n' "$label"
    printf '%s\n' "$out" | grep -E 'FATAL|Bungled|ERROR' | head -n 5 | sed 's/^/    /'
    return 1
  fi

  pid="$(integ_start_squid "$conf" "$GP_ROOT/run/probe-$port.pid" "$log")"
  if ! integ_wait_port "$port" 20; then
    printf 'RESULT %s: listener did not come up\n' "$label"
    tail -n 15 "$LOG_DIR/probe-$port-cache.log" 2>/dev/null || true
    return 1
  fi

  # 1. TLS handshake, twice in a row (with a real certificate check)
  local hs1=0 hs2=0
  integ_tls_check 127.0.0.1 "$port" ghproxy.test "$CERT_DIR/ca.pem" >/dev/null 2>&1 && hs1=1
  sleep 1
  integ_tls_check 127.0.0.1 "$port" ghproxy.test "$CERT_DIR/ca.pem" >/dev/null 2>&1 && hs2=1
  printf 'TLS handshake #1: %s   #2: %s   (1 = verified certificate received)\n' "$hs1" "$hs2"

  # 2. plain GET through the TLS proxy
  local get_code
  get_code="$(integ_curl_code --proxy "https://127.0.0.1:$port" --proxy-cacert "$CERT_DIR/ca.pem" \
              http://example.com/)"
  printf 'GET via https proxy: %s (expect 200)\n' "$get_code"

  # 3. CONNECT through the TLS proxy
  local connect_code
  connect_code="$(integ_curl_code --proxy "https://127.0.0.1:$port" --proxy-cacert "$CERT_DIR/ca.pem" \
                  https://api.github.com/rate_limit)"
  printf 'CONNECT via https proxy: %s (expect 200)\n' "$connect_code"

  # 4. raw CONNECT answer
  printf 'raw CONNECT answer:\n'
  printf 'CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n' \
    | timeout 15 openssl s_client -connect "127.0.0.1:$port" -servername ghproxy.test \
        -CAfile "$CERT_DIR/ca.pem" -quiet 2>&1 | head -n 6 | sed 's/^/    /' || true

  printf 'RESULT %s: tls=%s/%s get=%s connect=%s\n' "$label" "$hs1" "$hs2" "$get_code" "$connect_code"
  # Expose the results to the caller (the probe runs in the current shell).
  PROBE_TLS1="$hs1"
  PROBE_TLS2="$hs2"
  PROBE_GET="$get_code"
  PROBE_CONNECT="$connect_code"
  kill "$pid" 2>/dev/null || true
  sleep 1
  return 0
}

t_begin "http_port with TLS options (documented as NOT terminating TLS)"
probe_listener "http_port tls-cert" \
  "http_port 18501 tls-cert=$CERT_DIR/fullchain.pem tls-key=$CERT_DIR/privkey.pem" 18501
assert_eq "0" "$PROBE_TLS1" "http_port + tls-cert does not terminate TLS on this build"

t_begin "https_port with TLS options (the directive this project uses)"
probe_listener "https_port tls-cert" \
  "https_port 18502 tls-cert=$CERT_DIR/fullchain.pem tls-key=$CERT_DIR/privkey.pem" 18502
assert_eq "1" "$PROBE_TLS1" "https_port terminates TLS (verified certificate)"
assert_eq "1" "$PROBE_TLS2" "https_port keeps terminating TLS on a second connection"
assert_eq "200" "$PROBE_GET" "a plain GET works through the TLS forward proxy"
assert_eq "200" "$PROBE_CONNECT" "CONNECT works through the TLS forward proxy"

t_begin "the rendered gateway template uses https_port"
SERVER_DOMAIN="ghproxy.test"
SERVER_TLS_PORT=8443
SERVER_LOOPBACK_PORT=3128
SERVER_TLS_DIR="$CERT_DIR"
SERVER_PID_FILE="$GP_ROOT/run/tpl.pid"
SERVER_SPOOL_DIR="$GP_ROOT/spool/squid"
SERVER_CLIENT_ACL_FILE="$GP_ROOT/etc/squid/conf.d/00-clients.conf"
SERVER_DOMAIN_ACL_NAME="gsp_github"
SERVER_ADMIN_CONTACT="root@localhost"
domains_seed_from_template
TPL="$(server_render_main_config)"
assert_contains "$TPL" 'https_port 8443 tls-cert=' "the gateway renders a TLS listener with https_port"
assert_not_contains "$TPL" 'http_port 8443 tls-cert=' "the gateway never renders a plain listener with TLS options"

t_begin "http_port with TLS options and ssl-bump (interception only, not used)"
probe_listener "http_port tls-cert ssl-bump" \
  "http_port 18503 tls-cert=$CERT_DIR/fullchain.pem tls-key=$CERT_DIR/privkey.pem ssl-bump" 18503

printf '\n--- gateway-style cache log (http_port variant) ---\n'
grep -E 'Accepting|TLS|error|FATAL' "$LOG_DIR/probe-18501-cache.log" 2>/dev/null | tail -n 12 || true

t_begin "reload semantics: does 'squid -k reconfigure' keep the daemon alive?"
RELOAD_CONF="$GP_ROOT/etc/squid/reload-probe.conf"
mkdir -p "$GP_ROOT/etc/squid"
{
  printf 'https_port 18504 tls-cert=%s/fullchain.pem tls-key=%s/privkey.pem\n' "$CERT_DIR" "$CERT_DIR"
  printf 'visible_hostname probe\n'
  printf 'pid_filename %s/run/reload-probe.pid\n' "$GP_ROOT"
  printf 'coredump_dir %s/spool/squid\n' "$GP_ROOT"
  printf 'cache_effective_user %s\n' "$(squid_effective_user)"
  printf 'cache_effective_group %s\n' "$(squid_effective_group)"
  printf 'access_log %s/probe-reload-access.log squid\n' "$LOG_DIR"
  printf 'cache_log %s/probe-reload-cache.log\n' "$LOG_DIR"
  printf 'buffered_logs off\n'
  printf 'cache deny all\n'
  printf 'http_access allow all\n'
} > "$RELOAD_CONF"
RELOAD_PID="$(integ_start_squid "$RELOAD_CONF" "$GP_ROOT/run/reload-probe.pid" "$GP_ROOT/reload-probe.log")"
if integ_wait_port 18504 20; then
  t_ok "probe listener is up"
  RRC=0
  "$SQUID_BIN" -f "$RELOAD_CONF" -k reconfigure >/dev/null 2>&1 || RRC=$?
  sleep 2
  assert_eq "0" "$RRC" "squid -k reconfigure exits successfully"
  if integ_squid_alive "$RELOAD_PID"; then
    t_ok "the daemon survives the reload"
  else
    t_fail "the daemon died during the reload"
  fi
  if integ_wait_port 18504 5; then t_ok "the listener is still up"; else t_fail "the listener disappeared"; fi
else
  t_fail "the reload probe listener did not come up"
fi
integ_dump_logs "reload probe cache.log" "$LOG_DIR/probe-reload-cache.log" 15
kill "$RELOAD_PID" 2>/dev/null || true

t_begin "does a direct SIGHUP make a running squid re-read its configuration?"
SIGHUP_CONF="$GP_ROOT/etc/squid/sighup-probe.conf"
SIGHUP_DENY="acl gsp_probe src 127.0.0.2/32
http_access allow gsp_probe
http_access deny all"
mkdir -p "$GP_ROOT/etc/squid"
{
  printf 'http_port 18505\n'
  printf 'visible_hostname probe\n'
  printf 'pid_filename %s/run/sighup-probe.pid\n' "$GP_ROOT"
  printf 'coredump_dir %s/spool/squid\n' "$GP_ROOT"
  printf 'cache_effective_user %s\n' "$(squid_effective_user)"
  printf 'cache_effective_group %s\n' "$(squid_effective_group)"
  printf 'access_log %s/probe-sighup-access.log squid\n' "$LOG_DIR"
  printf 'cache_log %s/probe-sighup-cache.log\n' "$LOG_DIR"
  printf 'buffered_logs off\n'
  printf 'cache deny all\n'
  printf '%s\n' "$SIGHUP_DENY"
} > "$SIGHUP_CONF"
SIGHUP_PID="$(integ_start_squid "$SIGHUP_CONF" "$GP_ROOT/run/sighup-probe.pid" "$GP_ROOT/sighup-probe.log")"
if integ_wait_port 18505 20; then
  t_ok "probe listener is up on 18505"
  SIG_MASK="$(sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$SIGHUP_PID/status" 2>/dev/null)"
  SIG_BLK="$(sed -n 's/^SigBlk:[[:space:]]*//p' "/proc/$SIGHUP_PID/status" 2>/dev/null)"
  printf 'SigIgn=%s SigBlk=%s\n' "${SIG_MASK:-?}" "${SIG_BLK:-?}"
  printf 'process: %s\n' "$(ps -o pid,ppid,pgid,sid,stat,args -p "$SIGHUP_PID" 2>/dev/null | tail -n 1)"
  CODE="$(integ_curl_code --interface 127.0.0.2 --proxy http://127.0.0.1:18505 http://example.com/)"
  printf 'before reload: 127.0.0.2 -> %s (expect 200)\n' "$CODE"
  # flip the rule and signal the daemon
  {
    printf 'http_port 18505\n'
    printf 'visible_hostname probe\n'
    printf 'pid_filename %s/run/sighup-probe.pid\n' "$GP_ROOT"
    printf 'coredump_dir %s/spool/squid\n' "$GP_ROOT"
    printf 'cache_effective_user %s\n' "$(squid_effective_user)"
    printf 'cache_effective_group %s\n' "$(squid_effective_group)"
    printf 'access_log %s/probe-sighup-access.log squid\n' "$LOG_DIR"
    printf 'cache_log %s/probe-sighup-cache.log\n' "$LOG_DIR"
    printf 'buffered_logs off\n'
    printf 'cache deny all\n'
    printf '%s\n' "${SIGHUP_DENY/gsp_probe/gsp_probe2}"
  } > "$SIGHUP_CONF"
  kill -HUP "$SIGHUP_PID" 2>/dev/null || true
  sleep 3
  LIVE="$(curl -sS --max-time 5 --proxy http://127.0.0.1:18505 http://127.0.0.1/squid-internal-mgr/config 2>/dev/null | grep -c 'gsp_probe2' || true)"
  printf 'after reload: running config mentions gsp_probe2: %s\n' "$LIVE"
  printf 'daemon alive after reload: %s\n' "$(integ_squid_alive "$SIGHUP_PID" && printf yes || printf no)"
  printf 'cache log tail:\n'
  tail -n 6 "$LOG_DIR/probe-sighup-cache.log" 2>/dev/null | sed 's/^/    /' || true
else
  t_fail "the SIGHUP probe listener did not come up"
fi
kill "$SIGHUP_PID" 2>/dev/null || true

integ_dump_logs "probe-18502 cache.log (https_port)" "$LOG_DIR/probe-18502-cache.log" 12

integ_teardown
trap - EXIT
t_summary
