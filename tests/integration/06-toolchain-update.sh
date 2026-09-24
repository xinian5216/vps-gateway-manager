#!/usr/bin/env bash
# =============================================================================
# integration test :: management-toolchain update on a real adopted Squid
#
# Builds a production-shaped adopted server, replaces the installed toolchain
# with the published v0.5.1 tree, then updates it to this checkout. The update
# must change the management tool and nothing else: same Squid process, same
# operator files, same inventory, no reload.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'integ_teardown' EXIT
integ_skip_if_offline https://api.github.com/rate_limit
integ_skip_if_offline https://github.com/xinian5216/vps-gateway-manager/archive/refs/tags/v0.5.1.tar.gz

DOMAIN="gh.smartproxy.test"
integ_add_host_alias "$DOMAIN"
PLAIN_PORT=3128
TLS_PORT=8443
MAIN_CONF="$GP_ROOT/etc/squid/squid.conf"
CONF_D="$GP_ROOT/etc/squid/conf.d"
WHITELIST="$CONF_D/github-whitelist.conf"
TLS_DIR="$GP_ROOT/etc/squid/tls"
CERT_DIR="$INTEG_WORK/certs"

mkdir -p "$CONF_D" "$TLS_DIR" "$GP_ROOT/var/log/squid" "$GP_ROOT/var/spool/squid" \
  "$GP_ROOT/spool/squid" "$GP_ROOT/run" "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy"
sed -e "s#@@ROOT@@#$GP_ROOT#g" "$INTEG_ROOT/tests/fixtures/production-debian13/squid.conf" >"$MAIN_CONF"
sed -e "s#@@ROOT@@#$GP_ROOT#g" -e "s#@@CERT@@#$TLS_DIR#g" \
  -e "s#203\.0\.113\.11#127.0.0.11#g" -e "s#203\.0\.113\.12#127.0.0.12#g" \
  -e "s#203\.0\.113\.13#127.0.0.13#g" \
  "$INTEG_ROOT/tests/fixtures/production-debian13/conf.d/github-whitelist.conf" >"$WHITELIST"
if ! ip -6 addr show dev lo 2>/dev/null | grep -q 'inet6 ::1'; then
  sed -i '/^http_port \[::1\]:3128$/d' "$MAIN_CONF"
fi
sed -i '/^http_access deny all$/d' "$WHITELIST"
integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }
integ_make_cert "$CERT_DIR" gateway "$DOMAIN" 127.0.0.1 || { printf 'could not create a certificate\n'; exit 1; }
cp "$CERT_DIR/gateway.fullchain.pem" "$TLS_DIR/fullchain.pem"
cp "$CERT_DIR/gateway.key" "$TLS_DIR/privkey.pem"
integ_fix_tls_perms "$TLS_DIR"
integ_fix_perms
integ_trust_ca "$CERT_DIR/ca.pem" || true

t_begin "the production-shaped proxy is serving"
integ_start_squid "$MAIN_CONF" "$GP_ROOT/run/squid.pid" "$GP_ROOT/production.log" >/dev/null
assert_ok "plain listener is up" integ_wait_port "$PLAIN_PORT" 25
DAEMON_PID="$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)"
[ -n "$DAEMON_PID" ] && t_ok "daemon identified" || t_fail "no daemon identified"
printf '%s\n' "$DAEMON_PID" >"$GP_ROOT/run/squid.pid"

t_begin "formal adoption"
OUT="$(run_install server --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "adoption exits successfully"

install_published_v051() {
  local archive="$INTEG_WORK/v0.5.1.tar.gz" unpack="$INTEG_WORK/v051-unpack" dir
  # Unpack into a private directory. A find over $INTEG_WORK also sees the
  # v0.6.0 source copy, and which install.sh comes first is not stable.
  if [ ! -r "$archive" ]; then
    curl -fsSL --retry 2 --connect-timeout 20 --max-time 180 \
      -o "$archive" \
      https://github.com/xinian5216/vps-gateway-manager/archive/refs/tags/v0.5.1.tar.gz \
      || return 1
  fi
  rm -rf "$unpack"
  mkdir -p "$unpack"
  tar -xzf "$archive" -C "$unpack" || return 1
  dir="$(find "$unpack" -maxdepth 2 -mindepth 2 -type f -name install.sh | head -n 1)"
  dir="${dir%/install.sh}"
  [ -r "$dir/VERSION" ] || return 1
  [ "$(head -n 1 "$dir/VERSION" | tr -d '[:space:]')" = "0.5.1" ] || return 1
  rm -rf "$(gp_libexec_dir)"
  mkdir -p "$(gp_libexec_dir)" "$(gp_bin_dir)"
  cp -a "$dir/lib" "$(gp_libexec_dir)/lib"
  [ -d "$dir/templates" ] && cp -a "$dir/templates" "$(gp_libexec_dir)/templates"
  cp -a "$dir/VERSION" "$(gp_libexec_dir)/VERSION"
  cp -a "$dir/bin/ghproxyctl" "$(gp_bin_dir)/ghproxyctl"
  chmod 0755 "$(gp_bin_dir)/ghproxyctl"
  return 0
}

build_current_source() {
  local dest="$1" f hash
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/lib" "$dest/templates"
  cp -a "$INTEG_ROOT/lib/." "$dest/lib/"
  cp -a "$INTEG_ROOT/templates/." "$dest/templates/"
  cp -a "$INTEG_ROOT/bin/ghproxyctl" "$dest/bin/ghproxyctl"
  cp -a "$INTEG_ROOT/install.sh" "$INTEG_ROOT/uninstall.sh" "$INTEG_ROOT/VERSION" "$dest/"
  cp -a "$INTEG_ROOT/release.meta" "$dest/release.meta"
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
  return 0
}

t_begin "install the published v0.5.1 toolchain over the adopted runtime"
assert_ok "v0.5.1 archive installed" install_published_v051
assert_eq "0.5.1" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "installed ghproxyctl reports 0.5.1"

WL_SUM="$(gp_sha256 "$WHITELIST")"
MAIN_SUM="$(gp_sha256 "$MAIN_CONF")"
KEY_SUM="$(gp_sha256 "$TLS_DIR/privkey.pem")"
DB_SUM="$(gp_sha256 "$(gp_clients_db)")"
ACL_SUM="$(gp_sha256 "$(gp_managed_clients_acl)")"
: >"$INTEG_WORK/service/calls.log"

t_begin "update v0.5.1 to this checkout without touching the runtime"
SRC="$INTEG_WORK/src060"
assert_ok "current source tree packed" build_current_source "$SRC"
GP_ASSUME_YES=1
export GP_ASSUME_YES
OUT="$(update_run --source "$SRC" --allow-development 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "toolchain update exits 0"
assert_contains "$OUT" "development / non-release build" "an unreleased checkout is not labelled stable"
assert_eq "0.6.0" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "ghproxyctl now reports 0.6.0"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "Squid PID is unchanged"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "operator whitelist byte-identical"
assert_eq "$MAIN_SUM" "$(gp_sha256 "$MAIN_CONF")" "operator squid.conf byte-identical"
assert_eq "$KEY_SUM" "$(gp_sha256 "$TLS_DIR/privkey.pem")" "TLS private key byte-identical"
assert_eq "$DB_SUM" "$(gp_sha256 "$(gp_clients_db)")" "client inventory byte-identical"
assert_eq "$ACL_SUM" "$(gp_sha256 "$(gp_managed_clients_acl)")" "managed ACL byte-identical"
if grep -qE 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log" 2>/dev/null; then
  t_fail "update issued a reload or restart"
else
  t_ok "update issued no reload and no restart"
fi
code="$(integ_curl_code --proxy "http://127.0.0.1:${PLAIN_PORT}" https://api.github.com/)"
if [ "$code" != "000" ]; then
  t_ok "GitHub is still reachable through the untouched proxy (HTTP $code)"
else
  t_fail "GitHub through the proxy failed after the toolchain update (HTTP 000)"
fi

t_begin "a post-update health FAIL restores v0.5.1 and leaves Squid alone"
assert_ok "v0.5.1 toolchain restored for the failure injection" install_published_v051
: >"$INTEG_WORK/service/calls.log"
VGM_UPDATE_POST_HEALTH_RESULT=fail
export VGM_UPDATE_POST_HEALTH_RESULT
OUT="$(update_run --source "$SRC" --allow-development 2>&1)"; RC=$?
unset VGM_UPDATE_POST_HEALTH_RESULT
assert_ne "0" "$RC" "injected post-health FAIL is not a successful update"
assert_contains "$OUT" "Previous management toolchain restored successfully." "rollback is explicit"
assert_eq "0.5.1" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "executed version is back to 0.5.1"
assert_eq "$DAEMON_PID" "$(squid_daemon_pid "$MAIN_CONF" 2>/dev/null || true)" "rollback did not replace Squid"
assert_eq "$WL_SUM" "$(gp_sha256 "$WHITELIST")" "rollback left the operator whitelist alone"
if grep -qE 'systemctl (reload|restart)' "$INTEG_WORK/service/calls.log" 2>/dev/null; then
  t_fail "rollback issued a reload or restart"
else
  t_ok "rollback issued no reload and no restart"
fi

t_summary
