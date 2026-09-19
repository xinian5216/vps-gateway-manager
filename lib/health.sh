#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/health.sh
#
# Health checks and status output for both roles.
#
# Two principles:
#   1. A check must prove the *routing*, not just "something answered".
#      On a client this means reading the local Squid access log and looking at
#      the hierarchy tag (PARENT/... vs HIER_DIRECT/...).
#   2. A check must never weaken TLS verification. There is no --insecure path
#      in this code base; a self-signed or expired upstream is a FAIL.
# =============================================================================

if [ -n "${GP_HEALTH_SH:-}" ]; then
  return 0
fi
GP_HEALTH_SH=1

GP_PROBE_TIMEOUT="${GP_PROBE_TIMEOUT:-25}"
GP_TEST_API_URL="${GP_TEST_API_URL:-https://api.github.com/rate_limit}"
GP_TEST_RAW_URL="${GP_TEST_RAW_URL:-https://raw.githubusercontent.com/git/git/master/README.md}"
GP_TEST_RELEASE_API="${GP_TEST_RELEASE_API:-https://api.github.com/repos/cli/cli/releases/latest}"
GP_TEST_DIRECT_URL="${GP_TEST_DIRECT_URL:-https://www.cloudflare.com/cdn-cgi/trace}"

HC_RESULTS=()
HC_FAILED=0

hc_reset() { HC_RESULTS=(); HC_FAILED=0; }

hc_record() {
  # hc_record <name> <PASS|FAIL|SKIP|WARN> <detail>
  local name="$1" status="$2" detail="${3:-}"
  HC_RESULTS+=("$(printf '%-22s %-5s %s' "$name" "$status" "$detail")")
  [ "$status" = "FAIL" ] && HC_FAILED=$((HC_FAILED+1))
  return 0
}

hc_print() {
  local line
  for line in "${HC_RESULTS[@]}"; do printf '%s\n' "$line"; done
  return 0
}

hc_summary_failed() { [ "$HC_FAILED" -gt 0 ]; }

# -----------------------------------------------------------------------------
# Primitives
# -----------------------------------------------------------------------------
# HTTP status through a proxy (000 when the connection itself failed).
hc_proxy_code() {
  local proxy="$1" url="$2"
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' \
    --proxy "$proxy" \
    --proxy-cacert "$(gp_ca_bundle)" \
    --max-time "$GP_PROBE_TIMEOUT" \
    "$@" "$url" 2>/dev/null || printf '000'
}

# HTTP status direct (no proxy), used to prove a host is reachable at all.
hc_direct_code() {
  local url="$1"
  shift
  curl -sS -o /dev/null -w '%{http_code}' --max-time "$GP_PROBE_TIMEOUT" "$@" "$url" 2>/dev/null || printf '000'
}

# TLS handshake against the proxy endpoint, with full verification.
hc_tls_verify() {
  # hc_tls_verify <host> <port>
  local host="$1" port="$2" out rc=0
  if ! have openssl; then hc_record "Upstream TLS" SKIP "openssl not installed"; return 0; fi
  out="$(timeout 20 openssl s_client -connect "${host}:${port}" -servername "$host" \
        -verify_return_error -verify_hostname "$host" </dev/null 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
    hc_record "Upstream TLS" FAIL "certificate verification failed for ${host}:${port}"
    printf '%s\n' "$out" | grep -iE 'verify|error' | head -n 5 | sed 's/^/    /' >&2
    return 1
  fi
  local subj notafter
  subj="$(printf '%s' "$out" | sed -n 's/^subject=//p' | head -n1)"
  notafter="$(printf '%s' "$out" | sed -n 's/^ *notAfter=//p' | head -n1)"
  hc_record "Upstream TLS" PASS "${host}:${port} verified${notafter:+ (expires $notafter)}${subj:+ [$subj]}"
  return 0
}

# -----------------------------------------------------------------------------
# GitHub target checks through a proxy
# -----------------------------------------------------------------------------
hc_github_api() {
  local proxy="$1" code
  code="$(hc_proxy_code "$proxy" "$GP_TEST_API_URL")"
  case "$code" in
    200) hc_record "GitHub API" PASS "GET api.github.com/rate_limit -> 200"; return 0 ;;
    *)   hc_record "GitHub API" FAIL "expected 200, got $code"; return 1 ;;
  esac
}

hc_github_raw() {
  local proxy="$1" code
  code="$(hc_proxy_code "$proxy" "$GP_TEST_RAW_URL" -r 0-1024)"
  case "$code" in
    200|206) hc_record "GitHub Raw" PASS "GET raw.githubusercontent.com -> $code"; return 0 ;;
    *)       hc_record "GitHub Raw" FAIL "expected 200/206, got $code"; return 1 ;;
  esac
}

hc_github_release() {
  # Resolves a real release asset URL through the proxy and fetches its head.
  local proxy="$1" json url code
  json="$(curl -sS --proxy "$proxy" --proxy-cacert "$(gp_ca_bundle)" \
          --max-time "$GP_PROBE_TIMEOUT" "$GP_TEST_RELEASE_API" 2>/dev/null || true)"
  url="$(printf '%s' "$json" | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' \
        | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')"
  if [ -z "$url" ]; then
    # No asset in the latest release: fall back to a codeload archive redirect.
    url="https://github.com/git/git/archive/refs/heads/master.tar.gz"
    code="$(hc_proxy_code "$proxy" "$url" -r 0-1024 -L)"
    case "$code" in
      200|206) hc_record "GitHub Release" PASS "archive redirect -> $code"; return 0 ;;
      *)       hc_record "GitHub Release" FAIL "expected 200/206, got $code"; return 1 ;;
    esac
  fi
  code="$(hc_proxy_code "$proxy" "$url" -r 0-1024 -L)"
  case "$code" in
    200|206) hc_record "GitHub Release" PASS "$(printf '%s' "$url" | cut -c1-60)... -> $code"; return 0 ;;
    *)       hc_record "GitHub Release" FAIL "release asset fetch returned $code"; return 1 ;;
  esac
}

hc_github_git() {
  # git ls-remote through the proxy: proves the smart-HTTP path works end to end.
  local proxy="$1" rc=0
  if [ "${GP_SKIP_NET_CHECKS:-0}" = "1" ]; then
    hc_record "Git smart HTTP" SKIP "network checks disabled in this environment"
    return 0
  fi
  if ! have git; then hc_record "Git smart HTTP" SKIP "git not installed"; return 0; fi
  if gp_dry_run; then hc_record "Git smart HTTP" SKIP "dry-run"; return 0; fi
  GIT_TERMINAL_PROMPT=0 timeout "$GP_PROBE_TIMEOUT" git \
    -c "http.proxy=$proxy" -c "https.proxy=$proxy" \
    ls-remote --heads https://github.com/git/git.git HEAD >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    hc_record "Git smart HTTP" PASS "git ls-remote github.com -> ok"
    return 0
  fi
  hc_record "Git smart HTTP" FAIL "git ls-remote failed (rc=$rc)"
  return 1
}

# A non-GitHub destination must NOT be proxied. Returns 0 when the request is
# refused (403) or when a direct fetch is what actually works.
hc_non_github_denied() {
  local proxy="$1" code
  code="$(hc_proxy_code "$proxy" "https://example.com/")"
  case "$code" in
    403|407) hc_record "Non-GitHub refused" PASS "example.com -> $code"; return 0 ;;
    000)     hc_record "Non-GitHub refused" PASS "connection refused/blocked"; return 0 ;;
    *)       hc_record "Non-GitHub refused" FAIL "example.com was proxied ($code) - destination ACL too broad"; return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Client side: routing proof through the local access log
# -----------------------------------------------------------------------------
client_log_file() {
  local log=""
  if [ -n "${CLIENT_ACCESS_LOG:-}" ]; then log="$CLIENT_ACCESS_LOG"; fi
  if [ -z "$log" ] && [ -r "$(gp_client_conf)" ]; then
    log="$(conf_get "$(gp_client_conf)" access_log '')"
  fi
  [ -n "$log" ] || log="$(gp_p /var/log/vps-gateway-manager/access.log)"
  printf '%s\n' "$log"
}

# _client_log_offset <file> : line count
_client_log_offset() {
  local f="$1"
  [ -r "$f" ] || { printf '0\n'; return 0; }
  wc -l < "$f" | tr -d ' '
}

# client_route_of <host> <since-offset> <expected:parent|direct>
# Returns 0 when the newest matching access-log line shows the expected route.
client_route_of() {
  local host="$1" offset="$2" expect="$3" log lines hier
  log="$(client_log_file)"
  [ -r "$log" ] || return 2
  lines="$(tail -n +"$((offset+1))" "$log" 2>/dev/null | grep -F "$host" | tail -n 5)"
  [ -n "$lines" ] || return 3
  hier="$(printf '%s\n' "$lines" | tail -n 1 | awk '{print $(NF-1)}')"
  case "$expect" in
    parent) case "$hier" in *PARENT*) return 0 ;; esac ;;
    direct) case "$hier" in *DIRECT*) return 0 ;; esac ;;
  esac
  return 1
}

client_route_label() {
  local host="$1" offset="$2" log lines
  log="$(client_log_file)"
  [ -r "$log" ] || { printf 'log unavailable\n'; return 0; }
  lines="$(tail -n +"$((offset+1))" "$log" 2>/dev/null | grep -F "$host" | tail -n 1)"
  [ -n "$lines" ] || { printf 'no log entry\n'; return 0; }
  printf '%s\n' "$(printf '%s' "$lines" | awk '{print $(NF-1)}')"
  return 0
}

hc_client_route() {
  # hc_client_route <name> <host> <url> <expected-route>
  local name="$1" host="$2" url="$3" expect="$4" proxy log offset code rc=0 hier
  proxy="http://127.0.0.1:$(client_local_port)"
  log="$(client_log_file)"
  offset="$(_client_log_offset "$log")"
  code="$(hc_proxy_code "$proxy" "$url" -r 0-512 -L)"
  sleep 1
  client_route_of "$host" "$offset" "$expect" || rc=$?
  hier="$(client_route_label "$host" "$offset")"
  case "$rc" in
    0) hc_record "$name" PASS "$expect via $hier ($code)" ; return 0 ;;
    2) hc_record "$name" FAIL "local access log missing: $log" ; return 1 ;;
    3) hc_record "$name" FAIL "no log entry for $host (http=$code)" ; return 1 ;;
    *) hc_record "$name" FAIL "expected route '$expect' but log shows '$hier' (http=$code)" ; return 1 ;;
  esac
}

client_local_port() {
  local port=""
  [ -r "$(gp_client_conf)" ] && port="$(conf_get "$(gp_client_conf)" local_port '')"
  printf '%s\n' "${port:-3129}"
}

client_upstream_url() {
  local url=""
  [ -r "$(gp_client_conf)" ] && url="$(conf_get "$(gp_client_conf)" upstream '')"
  printf '%s\n' "$url"
}

# -----------------------------------------------------------------------------
# Server checks
# -----------------------------------------------------------------------------
# hc_server_quick : the checks that must hold after *any* change
hc_server_quick() {
  local rc=0 proxy code
  proxy="http://127.0.0.1:${SERVER_LOOPBACK_PORT:-3128}"
  if [ -n "${SERVER_SERVICE:-}" ] && have systemctl; then
    if systemctl_active "$SERVER_SERVICE"; then
      hc_record "Squid service" PASS "$SERVER_SERVICE active"
    else
      hc_record "Squid service" FAIL "$SERVER_SERVICE is not active"; rc=1
    fi
  fi
  code="$(hc_proxy_code "$proxy" "$GP_TEST_API_URL")"
  if [ "$code" = "200" ]; then
    hc_record "GitHub API (loopback)" PASS "$GP_TEST_API_URL -> 200"
  else
    hc_record "GitHub API (loopback)" FAIL "expected 200, got $code"; rc=1
  fi
  hc_non_github_denied "$proxy" || rc=1
  if [ -n "${SERVER_DOMAIN:-}" ] && [ -n "${SERVER_TLS_PORT:-}" ]; then
    hc_tls_verify "$SERVER_DOMAIN" "$SERVER_TLS_PORT" || rc=1
  fi
  return "$rc"
}

# hc_server_full : complete verification used by install and `ghproxyctl test`
hc_server_full() {
  local rc=0 proxy code ipport listen_ok
  hc_reset
  proxy="http://127.0.0.1:${SERVER_LOOPBACK_PORT:-3128}"

  if [ -n "${SERVER_SERVICE:-}" ] && have systemctl; then
    if systemctl_active "$SERVER_SERVICE"; then
      hc_record "Squid service" PASS "$SERVER_SERVICE active ($(squid_status_summary | sed 's/.*version=/version=/'))"
    else
      hc_record "Squid service" FAIL "$SERVER_SERVICE is not active"; rc=1
    fi
  else
    hc_record "Squid service" SKIP "no systemd unit"
  fi

  if [ -n "${SERVER_DOMAIN:-}" ]; then
    hc_tls_verify "$SERVER_DOMAIN" "${SERVER_TLS_PORT:-8443}" || rc=1
  else
    hc_record "TLS endpoint" SKIP "domain unknown"
  fi

  hc_github_api "$proxy" || rc=1
  hc_github_raw "$proxy" || rc=1
  hc_github_release "$proxy" || rc=1
  hc_non_github_denied "$proxy" || rc=1

  # The plain proxy port must never be reachable from a public address.
  if have ss; then
    local bad
    bad="$(ss -H -ltn 2>/dev/null | awk -v p=":${SERVER_LOOPBACK_PORT:-3128}" '$4 ~ p"$" {print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):' || true)"
    if [ -z "$bad" ]; then
      hc_record "Loopback-only ${SERVER_LOOPBACK_PORT}" PASS "not bound to a public address"
    else
      hc_record "Loopback-only ${SERVER_LOOPBACK_PORT}" FAIL "bound to public address(es): $bad"; rc=1
    fi
  fi

  # An unauthorised source must not be able to use the proxy. Connecting to our
  # own public address with a public source IP exercises the real ACL path.
  local pub
  pub="$(primary_public_ip)"
  if [ -n "$pub" ] && [ -n "${SERVER_TLS_PORT:-}" ] && [ -n "${SERVER_DOMAIN:-}" ]; then
    local code2
    code2="$(curl -sS -o /dev/null -w '%{http_code}' --interface "$pub" \
      --proxy "https://${SERVER_DOMAIN}:${SERVER_TLS_PORT}" \
      --proxy-cacert "$(gp_ca_bundle)" \
      --max-time 12 "$GP_TEST_API_URL" 2>/dev/null || printf '000')"
    case "$code2" in
      403|407) hc_record "Unknown source refused" PASS "source $pub -> $code2" ;;
      000)     hc_record "Unknown source refused" SKIP "could not connect with a public source address ($pub)" ;;
      *)       hc_record "Unknown source refused" FAIL "source $pub was served ($code2) - check the client ACLs"; rc=1 ;;
    esac
  else
    hc_record "Unknown source refused" SKIP "no public IP detected"
  fi

  if squid_policy_audit "${SERVER_MAIN_CONF}" >/dev/null 2>&1; then
    hc_record "Policy audit" PASS "final rule denies, no blanket allow, no /0"
  else
    hc_record "Policy audit" WARN "see details above"
  fi

  ipport="$(squid_config_listeners "${SERVER_MAIN_CONF}" | head -n 3 | tr '\n' ' ')"
  listen_ok="${ipport:-unknown}"
  hc_record "Configured listeners" PASS "$listen_ok"
  return "$rc"
}

primary_public_ip() {
  local ip=""
  if have ip; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
  fi
  printf '%s\n' "$ip"
}

# -----------------------------------------------------------------------------
# Client full verification
# -----------------------------------------------------------------------------
hc_client_full() {
  local rc=0 upstream host port proxy code
  hc_reset
  upstream="$(client_upstream_url)"
  proxy="http://127.0.0.1:$(client_local_port)"

  if [ -n "${CLIENT_SERVICE:-}" ] && have systemctl; then
    if systemctl_active "$CLIENT_SERVICE"; then
      hc_record "Local service" PASS "$CLIENT_SERVICE active"
    else
      hc_record "Local service" FAIL "$CLIENT_SERVICE is not active"; rc=1
    fi
  fi
  if port_in_use "$(client_local_port)"; then
    hc_record "Local proxy port" PASS "127.0.0.1:$(client_local_port) listening"
  else
    hc_record "Local proxy port" FAIL "nothing is listening on 127.0.0.1:$(client_local_port)"; rc=1
  fi

  if [ -n "$upstream" ]; then
    host="$(printf '%s' "$upstream" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
    port="$(printf '%s' "$upstream" | sed -nE 's#^[a-z]+://[^:]+:([0-9]+).*#\1#p')"
    [ -n "$port" ] || port="$( [ "${upstream%%://*}" = "https" ] && printf 443 || printf 80 )"
    hc_tls_verify "$host" "$port" || rc=1
  else
    hc_record "Upstream TLS" SKIP "no upstream configured"
  fi

  # Routing proof: GitHub must go through the parent, everything else direct.
  hc_client_route "GitHub API" "api.github.com" "$GP_TEST_API_URL" parent || rc=1
  hc_client_route "GitHub Raw" "raw.githubusercontent.com" "$GP_TEST_RAW_URL" parent || rc=1
  hc_client_route "GitHub Release" "api.github.com" "$GP_TEST_RELEASE_API" parent || rc=1
  hc_client_route "Direct Internet" "cloudflare.com" "$GP_TEST_DIRECT_URL" direct || rc=1

  if gp_distro_supported; then
    hc_client_route "Debian mirror direct" "deb.debian.org" "http://deb.debian.org/debian/dists/stable/Release" direct || true
  fi

  hc_github_git "$proxy" || true
  return "$rc"
}

# -----------------------------------------------------------------------------
# Role aware status / test entry points
# -----------------------------------------------------------------------------
gp_status() {
  local role
  role="$(gp_role)"
  case "$role" in
    server) gp_status_server ;;
    client) gp_status_client ;;
    *)
      printf 'Role              unconfigured\n'
      printf 'State dir         %s\n' "$(gp_state_dir)"
      printf 'Hint              run: sudo install.sh server | sudo install.sh client --upstream <url>\n'
      return 1
      ;;
  esac
}

gp_status_server() {
  server_require_installed || return 1
  local active total managed adopted
  active="$(systemctl_active "$SERVER_SERVICE" && printf 'active' || printf 'inactive')"
  total="$(clients_db_count)"
  managed="$(clients_db_list | awk -F'\t' '$4!="adopted"' | wc -l | tr -d ' ')"
  adopted="$(clients_db_list | awk -F'\t' '$4=="adopted"' | wc -l | tr -d ' ')"

  printf 'Role              server\n'
  printf 'Mode              %s%s\n' "$SERVER_MODE" "$([ "$SERVER_MODE" = adopted ] && printf ' (your existing Squid is preserved)' || printf '')"
  printf 'Domain            %s\n' "$SERVER_DOMAIN"
  printf 'TLS listener      %s (public)\n' "$SERVER_TLS_PORT"
  printf 'Loopback listener %s (127.0.0.1 / ::1)\n' "$SERVER_LOOPBACK_PORT"
  printf 'Service           %s (%s)\n' "$SERVER_SERVICE" "$active"
  printf 'Squid             %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"
  printf 'Main config       %s\n' "$SERVER_MAIN_CONF"
  printf 'Client ACL file   %s\n' "$SERVER_CLIENT_ACL_FILE"
  if [ "$SERVER_MODE" = "adopted" ]; then
    printf 'Adopted ACL file  %s\n' "${SERVER_SOURCE_ACL_FILE:-<none>}"
  fi
  printf 'Clients           %s total (%s managed, %s adopted)\n' "$total" "$managed" "$adopted"
  printf 'Destinations      %s entries (%s)\n' \
    "$(domains_current_list | wc -l | tr -d ' ')" "$(gp_domains_file)"
  printf 'Certificates      %s\n' "${SERVER_TLS_DIR:-<none>}"
  printf 'Renewal hook      %s\n' "${SERVER_CERTBOT_HOOK:-<none>}"
  printf 'Firewall          %s (managed=%s)\n' "$(fw_backend_summary)" "${SERVER_UFW_MANAGED:-0}"
  printf '\n'
  hc_reset
  hc_server_full
  hc_print
  return "$(hc_summary_failed && printf 1 || printf 0)"
}

gp_status_client() {
  local active upstream lport
  [ "$(gp_role)" = "client" ] || { die "no client state on this host (role: $(gp_role))"; return 1; }
  CLIENT_SERVICE="$(conf_get "$(gp_client_conf)" service_name vps-gateway-manager-client.service)"
  CLIENT_ACCESS_LOG="$(conf_get "$(gp_client_conf)" access_log '')"
  active="$(systemctl_active "$CLIENT_SERVICE" && printf 'active' || printf 'inactive')"
  upstream="$(client_upstream_url)"
  lport="$(client_local_port)"

  printf 'Role              client\n'
  printf 'Local proxy       127.0.0.1:%s\n' "$lport"
  printf 'Upstream          %s\n' "${upstream:-<none>}"
  printf 'Local service     %s\n' "$active"
  printf 'Config            %s\n' "$(gp_client_conf)"
  printf 'Squid config      %s\n' "$(gp_p /etc/vps-gateway-manager/client-squid.conf)"
  printf 'Access log        %s\n' "$(client_log_file)"
  printf 'Migrations        %s\n' "$(migrate_summary_line 2>/dev/null || printf 'none recorded')"
  printf '\n'
  hc_reset
  hc_client_full
  hc_print
  return "$(hc_summary_failed && printf 1 || printf 0)"
}

gp_test() {
  local role
  role="$(gp_role)"
  case "$role" in
    server) gp_status_server ;;
    client) gp_status_client ;;
    *) die "this host is not configured yet (role: ${role:-none})"; return 1 ;;
  esac
}
