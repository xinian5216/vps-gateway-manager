#!/usr/bin/env bash
# =============================================================================
# integration test :: first install through the gateway (no direct GitHub)
#
# A brand-new VPS that cannot reach GitHub directly (mainland China,
# IPv6-only) installs through an authorised HTTPS gateway instead. The
# single-file first hop comes from the official Tag through the gateway;
# vgm-bootstrap then discovers the latest stable release, downloads the
# artifact and its SHA256SUMS through the gateway, verifies the outer and the
# inner manifests and runs the release's install.sh - with the client pinned
# to IPv6 (--upstream-family 6).
#
# While this runs, direct TCP/443 is rejected for every user except the Squid
# daemon (when iptables is available): an acquisition request that bypassed
# the gateway cannot succeed. The suite also separates the two failures new
# VPSes actually hit: a gateway source-ACL refusal (fix: authorise the exact
# /32 or /128) and a plain network failure.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'unblock_direct_443; ip -6 addr del "$TEST_V6_CIDR" dev lo 2>/dev/null || true; integ_teardown' EXIT
integ_skip_if_offline https://api.github.com/rate_limit
integ_skip_if_offline https://github.com/xinian5216/vps-gateway-manager/releases/latest

GW="gw6.vgm-bootstrap.test"
GW_URL="https://gw6.vgm-bootstrap.test:9443"
GW_DEAD_URL="https://gw-dead.vgm-bootstrap.test:9"
TLS_PORT=9443
TEST_V6_CIDR="fd00:6:17::1/64"
RAW_BASE="https://raw.githubusercontent.com/xinian5216/vps-gateway-manager/v0.6.0"
CERT_DIR="$INTEG_WORK/certs"
GW_CONF="$GP_ROOT/etc/squid/gateway.conf"
GW_LOG="$GP_ROOT/var/log/squid-gateway/access.log"
GW_CACHE_LOG="$GP_ROOT/var/log/squid-gateway/cache.log"
CLIENT_CONF="$GP_ROOT/etc/vps-gateway-manager/client.conf"
CLIENT_SQUID="$GP_ROOT/etc/vps-gateway-manager/client-squid.conf"
CLIENT_ACCESS="$GP_ROOT/var/log/vps-gateway-manager/access.log"

integ_add_host_alias "$GW" "::1"
integ_add_host_alias "gw-dead.vgm-bootstrap.test" "::1"
mkdir -p "$CERT_DIR" "$GP_ROOT/etc/squid" "$GP_ROOT/var/log/squid-gateway" "$GP_ROOT/spool" "$GP_ROOT/run"
integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway "$GW" 127.0.0.1 || { printf 'could not create a certificate\n'; exit 1; }
integ_trust_ca "$CERT_DIR/ca.pem" || true
assert_ok "the test CA is in the system trust store" integ_trust_ca "$CERT_DIR/ca.pem"
integ_fix_tls_perms "$CERT_DIR"
integ_fix_perms
SBUNDLE="$GP_ROOT/etc/ssl/certs/ca-certificates.crt"
mkdir -p "$(dirname "$SBUNDLE")"
{ cat /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; cat "$CERT_DIR/ca.pem"; } >"$SBUNDLE"

# The IPv6-only simulation needs a usable (global-scope) IPv6 address on this
# host: the client's family pre-check refuses to pin a family the host cannot
# egress from, exactly like a real IPv6-only VPS (which always has one).
assert_ok "a global IPv6 address exists for the IPv6-only simulation" \
  ip -6 addr replace "$TEST_V6_CIDR" dev lo

write_gateway_conf() {
  local src="$1" user grp
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  cat > "$GW_CONF" <<EOF
visible_hostname gsp-bootstrap-gateway
pid_filename $GP_ROOT/run/gateway.pid
coredump_dir $GP_ROOT/spool
cache_effective_user $user
cache_effective_group $grp
access_log $GW_LOG
cache_log $GW_CACHE_LOG
buffered_logs off
cache deny all
https_port [::1]:${TLS_PORT} tls-cert=$CERT_DIR/gateway.fullchain.pem tls-key=$CERT_DIR/gateway.key
acl src_ok src $src
acl safe port 80 443
acl ssl port 443
acl connect method CONNECT
acl github_dst dstdomain .github.com .githubusercontent.com .githubassets.com ghcr.io .github.io
http_access deny !safe
http_access deny connect !ssl
http_access allow src_ok connect ssl github_dst
http_access allow src_ok safe github_dst
http_access deny all
EOF
}

BLOCKED=0
wait_gone() {
  local pid="$1" i=0
  while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    i=$((i+1))
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 1
  return 0
}

block_direct_443() {
  # Best effort: reject direct HTTPS for everyone except the Squid daemon -
  # exactly the "no direct GitHub" property of the hosts this feature serves.
  local user
  user="$(squid_effective_user)"
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$user" -j ACCEPT 2>/dev/null || return 1
  iptables -A OUTPUT -p tcp --dport 443 -j REJECT 2>/dev/null || return 1
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$user" -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -p tcp --dport 443 -j REJECT 2>/dev/null || true
  fi
  return 0
}

unblock_direct_443() {
  [ "${BLOCKED:-0}" = "1" ] || return 0
  iptables -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(squid_effective_user)" -j ACCEPT 2>/dev/null || true
  iptables -D OUTPUT -p tcp --dport 443 -j REJECT 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(squid_effective_user)" -j ACCEPT 2>/dev/null || true
    ip6tables -D OUTPUT -p tcp --dport 443 -j REJECT 2>/dev/null || true
  fi
  BLOCKED=0
  return 0
}

t_begin "the gateway serves on IPv6 and authorises nobody yet"
write_gateway_conf "2001:db8::99/128"
assert_ok "gateway config parses" squid_parse "$GW_CONF"
GW_PID="$(integ_start_squid "$GW_CONF" "$GP_ROOT/run/gateway.pid" "$GW_CACHE_LOG")"
assert_ok "gateway listener is up" integ_wait_port "$TLS_PORT" 20
[ -n "$GW_PID" ] && t_ok "gateway daemon identified ($GW_PID)" || t_fail "no gateway daemon"

t_begin "direct GitHub is blocked while the install downloads (best effort)"
if block_direct_443; then
  BLOCKED=1
  t_ok "outbound 443 is rejected for every user except the Squid daemon"
else
  t_skip "direct-path block unavailable (iptables)"
fi

t_begin "an unauthorised VPS is refused by the gateway ACL, not by the network"
OUT="$(bash "$INTEG_ROOT/bin/vgm-bootstrap" --upstream "$GW_URL" client --upstream-family 6 --no-git-config --dry-run --yes 2>&1)"; RC=$?
printf 'unauthorised-run rc=%s\n%s\n' "$RC" "$OUT" >&2
assert_ne "0" "$RC" "an unauthorised client cannot install"
assert_contains "$OUT" "authorize this host" "the refusal is attributed to the gateway ACL"
assert_contains "$OUT" "/32 or /128" "the fix is an exact address in the gateway ACL"
assert_not_contains "$OUT" "unreachable (network)" "a gateway refusal is not blamed on the network"

t_begin "an unreachable gateway is a network failure, not an ACL refusal"
OUT="$(bash "$INTEG_ROOT/bin/vgm-bootstrap" --upstream "$GW_DEAD_URL" client --dry-run --yes 2>&1)"; RC=$?
printf 'unreachable-run rc=%s\n%s\n' "$RC" "$OUT" >&2
assert_ne "0" "$RC" "an unreachable gateway cannot install"
assert_contains "$OUT" "host or gateway unreachable (network)" "the failure is classified as network"
assert_not_contains "$OUT" "/32 or /128" "a network failure does not blame the ACL"

t_begin "authorise the exact /128 and the gateway serves this VPS"
kill "$GW_PID" 2>/dev/null || true
wait_gone "$GW_PID"
# The daemon is gone: any remaining pid file is provably stale, and Squid
# refuses to start while one exists.
rm -f "$GP_ROOT/run/gateway.pid"
write_gateway_conf "::1/128"
GW_PID="$(integ_start_squid "$GW_CONF" "$GP_ROOT/run/gateway.pid" "$GW_CACHE_LOG")"
assert_ok "gateway listener is back" integ_wait_port "$TLS_PORT" 20

t_begin "the single-file first hop arrives through the gateway"
RC=0
curl --proxy "$GW_URL" --noproxy '' -fsSL --connect-timeout 20 --max-time 60 \
  -o "$INTEG_WORK/install-from-raw.sh" "$RAW_BASE/install.sh" || RC=$?
assert_eq "0" "$RC" "install.sh from the official Tag is fetched through the gateway"
assert_ok "the fetched install.sh parses" bash -n "$INTEG_WORK/install-from-raw.sh"

t_begin "bootstrap acquisition runs with direct GitHub unavailable"
OUT="$(bash "$INTEG_ROOT/bin/vgm-bootstrap" --upstream "$GW_URL" client --upstream-family 6 --no-git-config --dry-run --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "discovery, artifact download and verification succeed through the gateway"

t_begin "first install: the release installs the IPv6-pinned client"
OUT="$(bash "$INTEG_ROOT/bin/vgm-bootstrap" --upstream "$GW_URL" client --upstream-family 6 --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the gateway first install succeeds"

VER="$(head -n 1 "$(gp_libexec_dir)/VERSION" 2>/dev/null | tr -d '[:space:]')"
assert_matches_line "$VER" '^[0-9]+\.[0-9]+\.[0-9]+$' "the installed release tree reports a version"
assert_eq "$VER" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "ghproxyctl reports the downloaded release version"
# The release payload's completeness (bin/vgm-bootstrap included) is enforced
# by the bootstrap's inner SHA256SUMS verification before install.sh runs (unit
# suite 20), and the update path stages the full tree (suite 06). The installed
# layout is the installer's toolchain contract: lib, templates, VERSION and
# ghproxyctl.
assert_file_exists "$(gp_libexec_dir)/lib/update.sh" "the installed toolchain carries the update engine"
assert_file_exists "$(gp_bin_dir)/ghproxyctl" "the control tool is installed"

t_begin "every acquisition request went through the gateway"
# vgm-bootstrap queries github.com/releases/latest and downloads the release
# assets from github.com; the single-file first hop comes from
# raw.githubusercontent.com. api.github.com is not part of this path.
for host in github.com raw.githubusercontent.com; do
  if grep -q "$host" "$GW_LOG" 2>/dev/null; then
    t_ok "the gateway served $host"
  else
    t_fail "no gateway request for $host (a direct bypass would leave no trace here)"
  fi
done

t_begin "the installed client is pinned to IPv6 and routes correctly"
assert_eq "6" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "the client pinned upstream family 6"
PEER="$(conf_get "$CLIENT_CONF" upstream_peer_address)"
assert_matches_line "$PEER" '^[0-9a-fA-F:]+$' "the pinned peer is an IPv6 address"
LOCAL_PID="$(squid_daemon_pid "$CLIENT_SQUID" 2>/dev/null || true)"
[ -n "$LOCAL_PID" ] && t_ok "local client squid is running ($LOCAL_PID)" || t_fail "no local client squid"
skip="$(integ_access_log_count "$CLIENT_ACCESS")"
code="$(integ_curl_code --proxy http://127.0.0.1:3129 https://api.github.com/)"
[ "$code" != "000" ] && t_ok "GitHub is reachable through the client proxy (HTTP $code)" || t_fail "GitHub through the client proxy failed"
sleep 1
hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'api.github.com' "$skip")"
assert_contains "$hier" "PARENT" "GitHub uses the gateway parent ($hier)"
skip="$(integ_access_log_count "$CLIENT_ACCESS")"
code="$(integ_curl_code --proxy http://127.0.0.1:3129 https://www.cloudflare.com/cdn-cgi/trace)"
[ "$code" != "000" ] && t_ok "non-GitHub is reachable (HTTP $code)" || t_fail "non-GitHub probe failed"
sleep 1
hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'cloudflare.com' "$skip")"
assert_contains "$hier" "DIRECT" "non-GitHub goes direct ($hier)"

unblock_direct_443
t_summary
