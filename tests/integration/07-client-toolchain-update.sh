#!/usr/bin/env bash
# =============================================================================
# integration test :: client management-toolchain update
#
# A real local Squid, pinned to one verified IPv4 upstream, is updated from the
# published v0.5.1 toolchain to this checkout. Upstream, family, peer, config
# and the local process stay put. GitHub still goes FIRSTUP_PARENT; a
# non-GitHub host still goes HIER_DIRECT.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'integ_teardown' EXIT
integ_skip_if_offline https://api.github.com/rate_limit
integ_skip_if_offline https://github.com/xinian5216/vps-gateway-manager/archive/refs/tags/v0.5.1.tar.gz

TLS_PORT=18443
UP_HOST="gh-upd.test"
UP_IP="127.0.0.2"
CERT_DIR="$INTEG_WORK/certs"
GW_CONF="$GP_ROOT/etc/squid/gateway.conf"
CLIENT_CONF="$GP_ROOT/etc/vps-gateway-manager/client.conf"
CLIENT_SQUID="$GP_ROOT/etc/vps-gateway-manager/client-squid.conf"
CLIENT_ACCESS="$GP_ROOT/var/log/vps-gateway-manager/access.log"

integ_add_host_alias "$UP_HOST" "$UP_IP"
mkdir -p "$CERT_DIR" "$GP_ROOT/etc/squid" "$GP_ROOT/var/log/squid-gateway" "$GP_ROOT/spool" "$GP_ROOT/run"
integ_make_ca "$CERT_DIR" || exit 1
integ_make_cert "$CERT_DIR" gateway "$UP_HOST" "$UP_IP" || exit 1
integ_trust_ca "$CERT_DIR/ca.pem" || true
integ_fix_tls_perms "$CERT_DIR"
integ_fix_perms

cat >"$GW_CONF" <<EOF
visible_hostname gsp-upd-gateway
pid_filename $GP_ROOT/run/gateway.pid
coredump_dir $GP_ROOT/spool
cache_effective_user $(squid_effective_user)
cache_effective_group $(squid_effective_group)
access_log $GP_ROOT/var/log/squid-gateway/access.log
cache_log $GP_ROOT/var/log/squid-gateway/cache.log
buffered_logs off
cache deny all
https_port ${UP_IP}:${TLS_PORT} tls-cert=$CERT_DIR/gateway.fullchain.pem tls-key=$CERT_DIR/gateway.key
acl src_ok src 127.0.0.1/32
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
assert_ok "gateway config parses" squid_parse "$GW_CONF"
GW_PID="$(integ_start_squid "$GW_CONF" "$GP_ROOT/run/gateway.pid" "$GP_ROOT/gateway.out")"
assert_ok "gateway listener is up" integ_wait_port "$TLS_PORT" 20

t_begin "client install"
OUT="$(run_install client --upstream "https://${UP_HOST}:${TLS_PORT}" --upstream-family 4 --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client install exits 0"
CONF_SUM="$(gp_sha256 "$CLIENT_CONF")"
SQUID_SUM="$(gp_sha256 "$CLIENT_SQUID")"
FAMILY="$(conf_get "$CLIENT_CONF" upstream_selected_family)"
PEER="$(conf_get "$CLIENT_CONF" upstream_peer_address)"
LOCAL_PID="$(squid_daemon_pid "$CLIENT_SQUID" 2>/dev/null || true)"
[ -n "$LOCAL_PID" ] && t_ok "local squid pid $LOCAL_PID" || t_fail "local squid pid missing"
printf '%s\n' "$LOCAL_PID" >"$GP_ROOT/run/squid.pid"

install_published_v051() {
  local archive="$INTEG_WORK/v0.5.1.tar.gz" dir
  curl -fsSL --retry 2 --connect-timeout 20 --max-time 180 \
    -o "$archive" \
    https://github.com/xinian5216/vps-gateway-manager/archive/refs/tags/v0.5.1.tar.gz || return 1
  tar -xzf "$archive" -C "$INTEG_WORK" || return 1
  dir="$(find "$INTEG_WORK" -maxdepth 2 -mindepth 2 -type f -name install.sh | head -n 1)"
  dir="${dir%/install.sh}"
  rm -rf "$(gp_libexec_dir)"
  mkdir -p "$(gp_libexec_dir)" "$(gp_bin_dir)"
  cp -a "$dir/lib" "$(gp_libexec_dir)/lib"
  [ -d "$dir/templates" ] && cp -a "$dir/templates" "$(gp_libexec_dir)/templates"
  cp -a "$dir/VERSION" "$(gp_libexec_dir)/VERSION"
  cp -a "$dir/bin/ghproxyctl" "$(gp_bin_dir)/ghproxyctl"
  chmod 0755 "$(gp_bin_dir)/ghproxyctl"
}

build_current_source() {
  local dest="$1" f hash
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/lib" "$dest/templates"
  cp -a "$INTEG_ROOT/lib/." "$dest/lib/"
  cp -a "$INTEG_ROOT/templates/." "$dest/templates/"
  cp -a "$INTEG_ROOT/bin/ghproxyctl" "$dest/bin/ghproxyctl"
  cp -a "$INTEG_ROOT/install.sh" "$INTEG_ROOT/uninstall.sh" "$INTEG_ROOT/VERSION" "$INTEG_ROOT/release.meta" "$dest/"
  (
    cd "$dest" || exit 1
    find . -type f ! -name SHA256SUMS -print | sed 's#^\./##' | sort >"$INTEG_WORK/sums.list"
  )
  : >"$dest/SHA256SUMS"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hash="$(gp_sha256 "$dest/$f")" || return 1
    printf '%s  %s\n' "$hash" "$f" >>"$dest/SHA256SUMS"
  done <"$INTEG_WORK/sums.list"
}

t_begin "update the client toolchain"
assert_ok "v0.5.1 toolchain installed" install_published_v051
SRC="$INTEG_WORK/src060"
assert_ok "source tree packed" build_current_source "$SRC"
GP_ASSUME_YES=1
export GP_ASSUME_YES
: >"$INTEG_WORK/service/calls.log"
OUT="$(update_run --source "$SRC" --allow-development 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client toolchain update exits 0"
assert_eq "0.6.0" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "client ghproxyctl reports 0.6.0"
assert_eq "$CONF_SUM" "$(gp_sha256 "$CLIENT_CONF")" "client.conf byte-identical"
assert_eq "$SQUID_SUM" "$(gp_sha256 "$CLIENT_SQUID")" "client squid config byte-identical"
assert_eq "$FAMILY" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "selected family unchanged"
assert_eq "$PEER" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "pinned peer unchanged"
assert_eq "$LOCAL_PID" "$(squid_daemon_pid "$CLIENT_SQUID" 2>/dev/null || true)" "local squid PID unchanged"
if grep -qE 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log" 2>/dev/null; then
  t_fail "client update issued a reload or restart"
else
  t_ok "client update issued no reload and no restart"
fi

skip="$(integ_access_log_count "$CLIENT_ACCESS")"
code="$(integ_curl_code --proxy http://127.0.0.1:3129 https://api.github.com/)"
[ "$code" != "000" ] && t_ok "GitHub still reachable via the local proxy (HTTP $code)" || t_fail "GitHub via the local proxy failed"
sleep 1
hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'api.github.com' "$skip")"
assert_contains "$hier" "PARENT" "GitHub still uses the parent ($hier)"
skip="$(integ_access_log_count "$CLIENT_ACCESS")"
code="$(integ_curl_code --proxy http://127.0.0.1:3129 https://www.cloudflare.com/cdn-cgi/trace)"
[ "$code" != "000" ] && t_ok "non-GitHub still reachable (HTTP $code)" || t_fail "non-GitHub probe failed"
sleep 1
hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'cloudflare.com' "$skip")"
assert_contains "$hier" "DIRECT" "non-GitHub still goes direct ($hier)"

t_summary
