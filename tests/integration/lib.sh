#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: tests/integration/lib.sh
#
# Helpers for integration tests that run the REAL squid binary.
#
# Requirements: Linux, root, a Squid with TLS support (squid-openssl on
# Debian/Ubuntu). Everything runs inside a private directory with loopback-only
# listeners on high ports, so it can also be executed on a throwaway VPS.
# =============================================================================

INTEG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
. "$INTEG_ROOT/tests/lib.sh"

INTEG_WORK=""
INTEG_PIDS=()

integ_require() {
  # integ_require -> exits with a SKIP-style status when the host cannot run it
  if [ "$(uname -s)" != "Linux" ]; then
    printf 'integration: skipped (not Linux: %s)\n' "$(uname -s)"
    exit 0
  fi
  if [ "$(id -u)" != "0" ]; then
    printf 'integration: skipped (needs root)\n'
    exit 0
  fi
  if ! command -v squid >/dev/null 2>&1 && [ ! -x /usr/sbin/squid ]; then
    printf 'integration: skipped (squid is not installed)\n'
    exit 0
  fi
  return 0
}

integ_setup() {
  INTEG_WORK="$(mktemp -d /tmp/vgm-integ.XXXXXX)"
  export INTEG_WORK
  export GP_ROOT="$INTEG_WORK"
  export GP_NO_COLOR=1
  export VGM_INTEG=1
  mkdir -p "$INTEG_WORK"/{etc,var/log,run,spool,certs}
  load_project_libs
  GSP_VERSION="$(gp_load_version)"
  squid_detect || { printf 'integration: squid not usable\n'; exit 0; }
  squid_check_min_version || exit 0
  return 0
}

integ_teardown() {
  local pid
  for pid in "${INTEG_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${INTEG_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  [ -n "$INTEG_WORK" ] && rm -rf "$INTEG_WORK" 2>/dev/null || true
  return 0
}

# integ_make_ca <dir> -> dir/ca.pem, dir/ca.key
integ_make_ca() {
  local dir="$1"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/ca.key" -out "$dir/ca.pem" \
    -days 30 -subj "/CN=vps-gateway-manager test CA" \
    -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
  return $?
}

# integ_make_cert <dir> <name> <dns-san> [ip-san]
integ_make_cert() {
  local dir="$1" name="$2" dns="$3" ip="${4:-127.0.0.1}"
  openssl req -newkey rsa:2048 -nodes -keyout "$dir/$name.key" -out "$dir/$name.csr" \
    -subj "/CN=$dns" >/dev/null 2>&1 || return 1
  cat > "$dir/$name.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$dns,IP:$ip
EOF
  openssl x509 -req -in "$dir/$name.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" \
    -CAcreateserial -out "$dir/$name.crt" -days 30 -extfile "$dir/$name.ext" >/dev/null 2>&1 || return 1
  cat "$dir/$name.crt" "$dir/ca.pem" > "$dir/$name.fullchain.pem"
  return 0
}

# integ_start_squid <conf> <pidfile> <logfile> -> prints the pid
integ_start_squid() {
  local conf="$1" pidfile="$2" logfile="$3" pid
  "$SQUID_BIN" -f "$conf" -N -d1 >"$logfile" 2>&1 &
  pid=$!
  INTEG_PIDS+=("$pid")
  printf '%s\n' "$pid"
  return 0
}

# integ_wait_port <port> [seconds]
integ_wait_port() {
  local port="$1" timeout="${2:-15}" i=0
  while [ "$i" -lt "$timeout" ]; do
    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# integ_curl_code <curl args...> -> HTTP status (000 on connection failure)
integ_curl_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 25 "$@" 2>/dev/null || printf '000'
}

# integ_direct_code <url> -> status without a proxy (internet reachability probe)
integ_direct_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || printf '000'
}

# integ_skip_if_offline <url>
integ_skip_if_offline() {
  local code
  code="$(integ_direct_code "$1")"
  case "$code" in
    200|204|301|302) return 0 ;;
    *) printf 'integration: skipped (no direct internet access: %s -> %s)\n' "$1" "$code"; exit 0 ;;
  esac
}

# integ_access_log_line <logfile> <pattern> [skip-lines]
integ_access_log_line() {
  local log="$1" pattern="$2" skip="${3:-0}" found
  [ -r "$log" ] || return 1
  found="$(tail -n +"$((skip+1))" "$log" 2>/dev/null | grep -F "$pattern" | tail -n 1)"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
  return 0
}

integ_access_log_count() {
  local log="$1"
  [ -r "$log" ] && wc -l < "$log" | tr -d ' ' || printf '0'
}

# integ_hierarchy_of <logfile> <host> <skip-lines> -> the hierarchy tag
integ_hierarchy_of() {
  local line
  line="$(integ_access_log_line "$1" "$2" "$3")" || { printf 'none\n'; return 0; }
  printf '%s\n' "$(printf '%s' "$line" | awk '{print $(NF-1)}')"
  return 0
}
