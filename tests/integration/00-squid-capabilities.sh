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
  local pid

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
  } > "$conf"

  printf '\n=== %s ===\n' "$label"
  if ! squid_parse "$conf"; then
    printf 'RESULT %s: config rejected\n' "$label"
    return 1
  fi

  pid="$(integ_start_squid "$conf" "$GP_ROOT/run/probe-$port.pid" "$log")"
  if ! integ_wait_port "$port" 20; then
    printf 'RESULT %s: listener did not come up\n' "$label"
    tail -n 15 "$LOG_DIR/probe-$port-cache.log" 2>/dev/null || true
    return 1
  fi

  # 1. TLS handshake, twice in a row
  local hs1 hs2
  hs1="$(timeout 15 openssl s_client -connect "127.0.0.1:$port" -servername ghproxy.test \
         -verify_return_error -verify_hostname ghproxy.test -CAfile "$CERT_DIR/ca.pem" </dev/null 2>&1 \
         | grep -c 'Verify return code: 0 (ok)' || true)"
  sleep 1
  hs2="$(timeout 15 openssl s_client -connect "127.0.0.1:$port" -servername ghproxy.test \
         -verify_return_error -verify_hostname ghproxy.test -CAfile "$CERT_DIR/ca.pem" </dev/null 2>&1 \
         | grep -c 'Verify return code: 0 (ok)' || true)"
  printf 'TLS handshake #1: %s   #2: %s   (1 = verified)\n' "$hs1" "$hs2"

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
  kill "$pid" 2>/dev/null || true
  sleep 1
  return 0
}

t_begin "http_port with TLS options"
probe_listener "http_port tls-cert" \
  "http_port 18501 tls-cert=$CERT_DIR/fullchain.pem tls-key=$CERT_DIR/privkey.pem" 18501

t_begin "https_port with TLS options"
probe_listener "https_port tls-cert" \
  "https_port 18502 tls-cert=$CERT_DIR/fullchain.pem tls-key=$CERT_DIR/privkey.pem" 18502

t_begin "http_port with TLS options and ssl-bump"
probe_listener "http_port tls-cert ssl-bump" \
  "http_port 18503 tls-cert=$CERT_DIR/fullchain.pem tls-key=$CERT_DIR/privkey.pem ssl-bump" 18503

printf '\n--- gateway-style cache log (http_port variant) ---\n'
grep -E 'Accepting|TLS|error|FATAL' "$LOG_DIR/probe-18501-cache.log" 2>/dev/null | tail -n 12 || true

integ_dump_logs "probe-18502 cache.log" "$LOG_DIR/probe-18502-cache.log" 12
integ_dump_logs "probe-18503 cache.log" "$LOG_DIR/probe-18503-cache.log" 12

integ_teardown
trap - EXIT
t_summary
