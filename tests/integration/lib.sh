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
  # squid drops privileges to cache_effective_user (proxy), so the work tree
  # must be traversable and the log/spool/run directories writable by it.
  chmod 0755 "$INTEG_WORK"
  load_project_libs
  GSP_VERSION="$(gp_load_version)"
  squid_detect || { printf 'integration: squid not usable\n'; exit 0; }
  squid_check_min_version || exit 0
  integ_fix_perms
  return 0
}

# integ_fix_perms : (re)apply ownership/permissions for the squid effective user
integ_fix_perms() {
  local user grp
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  mkdir -p "$INTEG_WORK/var/log" "$INTEG_WORK/spool" "$INTEG_WORK/run" "$INTEG_WORK/certs"
  chmod 0755 "$INTEG_WORK" 2>/dev/null || true
  chown -R "$user:$grp" \
    "$INTEG_WORK/var" "$INTEG_WORK/spool" "$INTEG_WORK/run" "$INTEG_WORK/certs" 2>/dev/null || true
  chmod -R u+rwX,g+rwX "$INTEG_WORK/var" "$INTEG_WORK/spool" "$INTEG_WORK/run" "$INTEG_WORK/certs" 2>/dev/null || true
  return 0
}

# integ_add_host_alias <name> [ip]
# Makes a test domain resolvable the way DNS would be on a real host, so the
# health checks (which connect by name) can run. Restored by integ_teardown.
integ_add_host_alias() {
  local name="$1" ip="${2:-127.0.0.1}"
  if grep -qE "^[^#]*[[:space:]]${name}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    return 0
  fi
  if [ ! -r "$INTEG_WORK/hosts.backup" ]; then
    cp -f /etc/hosts "$INTEG_WORK/hosts.backup" 2>/dev/null || true
  fi
  printf '%s %s # vps-gateway-manager integration test\n' "$ip" "$name" >> /etc/hosts
  INTEG_HOSTS_ADDED=1
  return 0
}

integ_remove_host_alias() {
  [ "${INTEG_HOSTS_ADDED:-0}" = "1" ] || return 0
  if [ -r "$INTEG_WORK/hosts.backup" ]; then
    cp -f "$INTEG_WORK/hosts.backup" /etc/hosts 2>/dev/null || true
  fi
  INTEG_HOSTS_ADDED=0
  return 0
}

integ_teardown() {
  local pid
  integ_remove_host_alias
  # PIDs are also recorded in a file: the start helper is usually called inside
  # a command substitution, so array appends would only happen in a subshell.
  if [ -r "$INTEG_WORK/pids" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] && INTEG_PIDS+=("$pid")
    done < "$INTEG_WORK/pids"
  fi
  for pid in "${INTEG_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${INTEG_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  integ_kill_stray_squid
  [ -n "$INTEG_WORK" ] && rm -rf "$INTEG_WORK" 2>/dev/null || true
  return 0
}

# integ_stray_squid_pids -> pids of squid processes belonging to this sandbox
# (matched on their command line, so nothing outside the test can be hit)
integ_stray_squid_pids() {
  local p cmdline
  [ -n "$INTEG_WORK" ] || return 0
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    cmdline="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
    case "$cmdline" in
      *squid*"$INTEG_WORK"*) printf '%s\n' "${p#/proc/}" ;;
    esac
  done
  return 0
}

# integ_kill_stray_squid - make sure no Squid of this test survives
integ_kill_stray_squid() {
  local pid pids
  pids="$(integ_stray_squid_pids)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(integ_stray_squid_pids); do
    kill -9 "$pid" 2>/dev/null || true
  done
  return 0
}

# integ_assert_sandbox_squid_count <expected> <description>
# Counts Squid processes whose command line belongs to this sandbox. Used to
# prove that nothing (adoption, reload, rollback) started an extra instance.
integ_assert_sandbox_squid_count() {
  local expected="$1" desc="${2:-sandbox Squid process count}" actual pids
  pids="$(integ_stray_squid_pids)"
  actual="$(printf '%s' "$pids" | grep -c . || true)"
  if [ "$actual" = "$expected" ]; then
    t_ok "$desc ($actual)"
  else
    t_fail "$desc (expected $expected, found $actual: $(printf '%s' "$pids" | tr '\n' ' '))"
  fi
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

# integ_fix_tls_perms <dir>
# Squid reads the certificate as its effective user, so the TLS directory must
# be traversable and the private key readable by it (production layout:
# root:proxy 0750 for the directory, 0640 for the key).
integ_fix_tls_perms() {
  local dir="$1" user grp
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  [ -d "$dir" ] || return 0
  chown -R "$user:$grp" "$dir" 2>/dev/null || true
  chmod 0750 "$dir" 2>/dev/null || true
  chmod 0644 "$dir/fullchain.pem" 2>/dev/null || true
  chmod 0640 "$dir/privkey.pem" 2>/dev/null || true
  return 0
}

# integ_trust_ca <ca.pem>
# Installs a test CA into the system trust store. On a real host the gateway
# certificate is issued by Let's Encrypt and is trusted for exactly this reason;
# the health checks verify against the system store, so the test CA has to play
# the same role.
integ_trust_ca() {
  local ca="$1"
  [ -r "$ca" ] || return 1
  if have update-ca-certificates; then
    cp "$ca" /usr/local/share/ca-certificates/vgm-integ-test-ca.crt 2>/dev/null || return 1
    update-ca-certificates >/dev/null 2>&1 || true
    return 0
  fi
  if have trust; then
    cp "$ca" /etc/pki/ca-trust/source/anchors/vgm-integ-test-ca.crt 2>/dev/null || return 1
    trust extract-compat >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

# integ_start_squid <conf> <pidfile> <logfile> -> prints the pid
integ_start_squid() {
  local conf="$1" pidfile="$2" logfile="$3" pid
  "$SQUID_BIN" -f "$conf" -N -d1 >"$logfile" 2>&1 &
  pid=$!
  INTEG_PIDS+=("$pid")
  # Also persist it: this helper is normally called in a command substitution,
  # so the array append above only happens inside a subshell.
  printf '%s\n' "$pid" >> "$INTEG_WORK/pids"
  printf '%s\n' "$pid"
  return 0
}

# integ_squid_alive <pid>
integ_squid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

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
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 "$@" 2>/dev/null)" || true
  [ -n "$code" ] || code=000
  printf '%s\n' "$code"
  return 0
}

# integ_wait_http_code <expected> <description> <curl args...>
# Retries a *behavioural* assertion for a short while: right after a Squid reload
# there is a brief window where new connections are accepted but not served yet.
# The expectation itself stays strict - it must reach <expected>, otherwise the
# assertion fails.
integ_wait_http_code() {
  local expected="$1" desc="$2"
  shift 2
  local attempt=1 code=""
  while [ "$attempt" -le 6 ]; do
    code="$(integ_curl_code "$@")"
    if [ "$code" = "$expected" ]; then
      t_ok "$desc (HTTP $code${attempt:+ after attempt $attempt})"
      return 0
    fi
    sleep 3
    attempt=$((attempt+1))
  done
  t_fail "$desc (expected HTTP $expected, last seen $code)"
  return 1
}

# integ_direct_code <url> -> status without a proxy (internet reachability probe)
integ_direct_code() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null)" || true
  [ -n "$code" ] || code=000
  printf '%s\n' "$code"
  return 0
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

# integ_status_of <logfile> <host> <skip-lines> -> "TCP_MISS/200"
integ_status_of() {
  local line
  line="$(integ_access_log_line "$1" "$2" "$3")" || { printf 'none\n'; return 0; }
  printf '%s\n' "$(printf '%s' "$line" | awk '{print $4}')"
  return 0
}

# integ_tls_check <host> <port> <sni> <cafile>
# Returns 0 only when a TLS handshake completed AND a certificate was received
# AND it verified. (openssl prints "Verify return code: 0 (ok)" even when the
# handshake failed, so the certificate presence must be checked explicitly.)
integ_tls_check() {
  local host="$1" port="$2" sni="$3" cafile="$4" out
  out="$(timeout 20 openssl s_client -connect "$host:$port" -servername "$sni" \
        -verify_return_error -verify_hostname "$sni" -CAfile "$cafile" </dev/null 2>&1)" || true
  if printf '%s' "$out" | grep -q 'no peer certificate available'; then
    printf 'no certificate presented (listener is not TLS?)\n'
    return 1
  fi
  if ! printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
    printf 'certificate did not verify\n'
    printf '%s\n' "$out" | grep -iE 'verify|error' | head -n 3
    return 1
  fi
  if ! printf '%s' "$out" | grep -qE '^subject='; then
    printf 'handshake produced no peer certificate\n'
    return 1
  fi
  return 0
}

# integ_dump_logs <label> <file> [lines] - diagnostics that survive in the CI log
integ_dump_logs() {
  local label="$1" file="$2" lines="${3:-20}"
  [ -r "$file" ] || return 0
  printf '\n--- %s: %s ---\n' "$label" "$file"
  tail -n "$lines" "$file" 2>/dev/null || true
  return 0
}

# integ_debug_curl <curl args...> - verbose curl output for a failing request
integ_debug_curl() {
  printf '\n--- curl -v diagnostics ---\n'
  curl -v -o /dev/null --max-time 25 "$@" 2>&1 | tail -n 25 || true
  return 0
}

# integ_debug_connect <host> <port> <target> [sni] [cafile]
# Sends a raw CONNECT and prints Squid's response, including X-Squid-Error which
# names the ACL that denied the request.
integ_debug_connect() {
  local host="$1" port="$2" target="$3" sni="${4:-}" cafile="${5:-}"
  local -a args=(-connect "$host:$port" -quiet)
  [ -n "$sni" ] && args+=(-servername "$sni")
  [ -n "$cafile" ] && [ -r "$cafile" ] && args+=(-CAfile "$cafile")
  printf '\n--- raw CONNECT %s via %s:%s ---\n' "$target" "$host" "$port"
  printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' "$target" "$target" \
    | timeout 15 openssl s_client "${args[@]}" 2>&1 | head -n 20 || true
  return 0
}
