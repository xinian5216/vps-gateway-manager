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
# This suite tests raw Squid behaviour, so the service-manager shim is disabled:
# the direct reload path (pid validation + SIGHUP) is what gets exercised here.
INTEG_SERVICE_SHIM=0
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
  printf 'signal masks before: SigCgt=%s SigIgn=%s SigBlk=%s\n' \
    "$(sed -n 's/^SigCgt:[[:space:]]*//p' "/proc/$SIGHUP_PID/status" 2>/dev/null)" \
    "$(sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$SIGHUP_PID/status" 2>/dev/null)" \
    "$(sed -n 's/^SigBlk:[[:space:]]*//p' "/proc/$SIGHUP_PID/status" 2>/dev/null)"
  printf 'live config before (http_access lines):\n'
  curl -sS --max-time 5 --proxy http://127.0.0.1:18505 "http://127.0.0.1/squid-internal-mgr/config" 2>/dev/null \
    | grep -E '^http_access|^acl gsp_probe' | head -n 6 | sed 's/^/    /' || true
  # Write a COMPLETE new configuration (atomically) that denies 127.0.0.2 and
  # uses a new ACL name, then signal the daemon.
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
    printf 'acl gsp_probe_flipped src 127.0.0.9/32\n'
    printf 'http_access allow gsp_probe_flipped\n'
    printf 'http_access deny all\n'
  } > "$SIGHUP_CONF.new" && mv "$SIGHUP_CONF.new" "$SIGHUP_CONF"
  kill -HUP "$SIGHUP_PID" 2>/dev/null || true
  sleep 3
  printf 'after reload: 127.0.0.2 -> %s (expect 403 if the reload took effect)\n' \
    "$(integ_curl_code --interface 127.0.0.2 --proxy http://127.0.0.1:18505 http://example.com/)"
  printf 'live config after (http_access lines):\n'
  curl -sS --max-time 5 --proxy http://127.0.0.1:18505 "http://127.0.0.1/squid-internal-mgr/config" 2>/dev/null \
    | grep -E '^http_access|^acl gsp_probe' | head -n 6 | sed 's/^/    /' || true
  printf 'daemon alive after reload: %s\n' "$(integ_squid_alive "$SIGHUP_PID" && printf yes || printf no)"
  printf 'cache log tail:\n'
  tail -n 8 "$LOG_DIR/probe-sighup-cache.log" 2>/dev/null | sed 's/^/    /' || true
else
  t_fail "the SIGHUP probe listener did not come up"
fi
kill "$SIGHUP_PID" 2>/dev/null || true

t_begin "does a reload pick up a NEW file in an include glob?"
GLOB_DIR="$GP_ROOT/etc/squid/glob-probe.d"
GLOB_CONF="$GP_ROOT/etc/squid/glob-probe.conf"
GLOB_DENY="$GLOB_DIR/10-deny.conf"
mkdir -p "$GLOB_DIR"
printf 'http_access deny all\n' > "$GLOB_DENY"
{
  printf 'http_port 18506\n'
  printf 'visible_hostname probe\n'
  printf 'pid_filename %s/run/glob-probe.pid\n' "$GP_ROOT"
  printf 'coredump_dir %s/spool/squid\n' "$GP_ROOT"
  printf 'cache_effective_user %s\n' "$(squid_effective_user)"
  printf 'cache_effective_group %s\n' "$(squid_effective_group)"
  printf 'access_log %s/probe-glob-access.log squid\n' "$LOG_DIR"
  printf 'cache_log %s/probe-glob-cache.log\n' "$LOG_DIR"
  printf 'buffered_logs off\n'
  printf 'cache deny all\n'
  printf 'include %s/*.conf\n' "$GLOB_DIR"
} > "$GLOB_CONF"
GLOB_PID="$(integ_start_squid "$GLOB_CONF" "$GP_ROOT/run/glob-probe.pid" "$GP_ROOT/glob-probe.log")"
if integ_wait_port 18506 20; then
  printf 'before: 127.0.0.2 -> %s (expect 403, the glob denies everything)\n' \
    "$(integ_curl_code --interface 127.0.0.2 --proxy http://127.0.0.1:18506 http://example.com/)"
  # A NEW file, sorting before the existing one, that allows 127.0.0.2.
  GLOB_CACHE="$(squid_cache_log "$GLOB_CONF" 2>/dev/null || printf '')"
  GLOB_OFFSET="$(squid_cache_log_lines "$GLOB_CONF")"
  printf 'acl gsp_glob_probe src 127.0.0.2/32\nhttp_access allow gsp_glob_probe\n' > "$GLOB_DIR/00-allow.conf"
  printf 'included files now: %s\n' "$(ls -1 "$GLOB_DIR" | tr '\n' ' ')"
  kill -HUP "$GLOB_PID" 2>/dev/null || true
  # Wait for a real reconfigure cycle instead of assuming the signal was enough.
  if squid_wait_reconfigure_complete "$GLOB_CONF" "$GLOB_OFFSET" 20 "$GLOB_PID"; then
    printf 'reconfigure cycle: confirmed\n'
  else
    printf 'reconfigure cycle: NOT confirmed\n'
  fi
  AFTER_RELOAD="$(integ_curl_code --interface 127.0.0.2 --proxy http://127.0.0.1:18506 http://example.com/)"
  printf 'after SIGHUP + confirmed reconfigure: 127.0.0.2 -> %s (200 = the new file was picked up)\n' "$AFTER_RELOAD"
  printf 'cache log window after the signal:\n'
  tail -n +"$((GLOB_OFFSET+1))" "$GLOB_CACHE" 2>/dev/null | grep -iE 'reconfigur|Processing|FATAL|Bungled' | head -n 8 | sed 's/^/    /' || true
  if [ "$AFTER_RELOAD" = "200" ]; then
    t_ok "a reload DOES pick up a newly created file in an include glob (with a confirmed cycle)"
  else
    t_ok "a reload does NOT pick up a newly created file in an include glob (evidence below; not yet a documented Squid behaviour)"
    printf 'evidence for the follow-up:\n'
    printf '  squid: %s\n' "$SQUID_VERSION"
    printf '  include directive: include %s/*.conf\n' "$GLOB_DIR"
    printf '  files: %s\n' "$(ls -1 "$GLOB_DIR" | tr '\n' ' ')"
    printf '  config:\n'; sed 's/^/    /' "$GLOB_CONF"
    printf '  new file:\n'; sed 's/^/    /' "$GLOB_DIR/00-allow.conf"
    printf '  cache log (last reconfigure-related lines):\n'
    grep -iE 'reconfigur|Processing Configuration|FATAL|Bungled' "$GLOB_CACHE" 2>/dev/null | tail -n 10 | sed 's/^/    /' || true
  fi
  # And prove that a restart applies it
  kill -TERM "$GLOB_PID" 2>/dev/null || true
  sleep 2
  GLOB_PID="$(integ_start_squid "$GLOB_CONF" "$GP_ROOT/run/glob-probe.pid" "$GP_ROOT/glob-probe2.log")"
  if integ_wait_port 18506 20; then
    printf 'after restart: 127.0.0.2 -> %s (expect 200)\n' \
      "$(integ_curl_code --interface 127.0.0.2 --proxy http://127.0.0.1:18506 http://example.com/)"
  fi
else
  t_fail "the include-glob probe listener did not come up"
fi
kill "$GLOB_PID" 2>/dev/null || true

t_begin "direct reload refuses a stale pid file instead of starting a second instance"
STALE_CONF="$GP_ROOT/etc/squid/stale-probe.conf"
STALE_PIDFILE="$GP_ROOT/run/stale-probe.pid"
mkdir -p "$GP_ROOT/etc/squid" "$GP_ROOT/run"
{
  printf 'http_port 18507\n'
  printf 'visible_hostname probe\n'
  printf 'pid_filename %s\n' "$STALE_PIDFILE"
  printf 'coredump_dir %s/spool/squid\n' "$GP_ROOT"
  printf 'cache_effective_user %s\n' "$(squid_effective_user)"
  printf 'cache_effective_group %s\n' "$(squid_effective_group)"
  printf 'cache deny all\n'
  printf 'http_access allow all\n'
} > "$STALE_CONF"
# A pid file pointing at a live process that is NOT a squid for this config
# (this script itself), i.e. exactly the dangerous stale/foreign case.
printf '%s\n' "$$" > "$STALE_PIDFILE"
BEFORE_SQUID="$(pgrep -c squid 2>/dev/null || printf 0)"
STALE_RC=0
squid_reload "" "$STALE_CONF" >/dev/null 2>&1 || STALE_RC=$?
assert_ne "0" "$STALE_RC" "a foreign/stale pid file is refused"
AFTER_SQUID="$(pgrep -c squid 2>/dev/null || printf 0)"
assert_eq "$BEFORE_SQUID" "$AFTER_SQUID" "refusing did not start a second Squid instance"
# And with no pid file at all
rm -f "$STALE_PIDFILE"
STALE_RC=0
squid_reload "" "$STALE_CONF" >/dev/null 2>&1 || STALE_RC=$?
assert_ne "0" "$STALE_RC" "a missing pid file is refused"
assert_eq "$BEFORE_SQUID" "$(pgrep -c squid 2>/dev/null || printf 0)" "still no second Squid instance"

integ_dump_logs "probe-18502 cache.log (https_port)" "$LOG_DIR/probe-18502-cache.log" 12

integ_teardown
trap - EXIT
t_summary
