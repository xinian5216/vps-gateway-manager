#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/update.sh
#
# One management-toolchain updater for both roles. It replaces libraries,
# templates, ghproxyctl, the installer copies and release metadata. It does
# not reinstall a Server or Client, does not reload Squid, and does not touch
# operator config, ACLs, firewall, certificates or migrations.
#
# The switch is transactional and crash-recoverable, not a single atomic
# rename across two directories. A killed update leaves a phase marker; the
# next run restores the last known-good toolchain instead of pretending the
# half-written tree succeeded.
#
# This file never calls gp_install_toolchain. That helper skips silently when
# no source tree is visible, which is exactly the failure this updater must
# not be able to report as success.
# =============================================================================

if [ -n "${GP_UPDATE_SH:-}" ]; then
  return 0
fi
GP_UPDATE_SH=1

UPDATE_WORK=""
UPDATE_LOG=""
UPDATE_ID=""

# -----------------------------------------------------------------------------
# Versions
# -----------------------------------------------------------------------------
update_version_strip() {
  local v="$1"
  v="${v#v}"
  v="${v#V}"
  printf '%s' "$v" | tr -d '[:space:]'
}

# A stable release is dotted numbers only: 0.5.1, 0.6.0. Anything else
# (rc, dev, a raw SHA) is not a stable target.
update_version_is_release() {
  local v
  v="$(update_version_strip "$1")"
  case "$v" in
    ''|*[!0-9.]*) return 1 ;;
    *..*|.*|*. ) return 1 ;;
    *.*.*.*) return 1 ;;
  esac
  case "$v" in
    *.*) ;;
    *) return 1 ;;
  esac
  return 0
}

# update_version_cmp A B -> prints -1, 0, 1. Returns 2 if either side is not
# a release version (the caller must not treat that as "equal").
update_version_cmp() {
  local a b ia ib i
  a="$(update_version_strip "$1")"
  b="$(update_version_strip "$2")"
  update_version_is_release "$a" || return 2
  update_version_is_release "$b" || return 2
  i=0
  while [ "$i" -lt 3 ]; do
    ia="${a%%.*}"
    ib="${b%%.*}"
    if [ "$a" = "$ia" ]; then a=""; else a="${a#*.}"; fi
    if [ "$b" = "$ib" ]; then b=""; else b="${b#*.}"; fi
    ia="${ia:-0}"
    ib="${ib:-0}"
    if [ "$ia" -lt "$ib" ]; then printf '%s\n' -1; return 0; fi
    if [ "$ia" -gt "$ib" ]; then printf '%s\n' 1; return 0; fi
    i=$((i+1))
  done
  printf '%s\n' 0
  return 0
}

update_repo_url() {
  printf '%s\n' "${VGM_REPO_URL:-https://github.com/xinian5216/vps-gateway-manager}"
}

# -----------------------------------------------------------------------------
# Transaction marker
# -----------------------------------------------------------------------------
update_txn_path() { printf '%s\n' "$(gp_state_dir)/update-txn/current"; }
update_backup_dir() { printf '%s\n' "$(gp_state_dir)/toolchain-backups"; }
update_history_file() { printf '%s\n' "$(gp_state_dir)/update-history"; }
update_log_dir() { printf '%s\n' "$(gp_p "/var/log/vps-gateway-manager/update")"; }

update_txn_get() {
  conf_get "$(update_txn_path)" "$1" ""
}

update_txn_set() {
  local key="$1" value="$2" f dir tmp
  f="$(update_txn_path)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  if [ ! -f "$f" ]; then
    : >"$f"
    chmod 0600 "$f" || true
  fi
  tmp="$(mktemp "$dir/.upd.XXXXXX")" || return 1
  if [ -s "$f" ]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done=0 }
      $0 ~ "^" k "=" { if (!done) { print k "=" v; done=1 } ; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '%s=%s\n' "$key" "$value" >"$tmp"
  fi
  chmod 0600 "$tmp" || true
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

update_interrupted() {
  local f result phase
  f="$(update_txn_path)"
  [ -r "$f" ] || return 1
  result="$(conf_get "$f" result '')"
  phase="$(conf_get "$f" phase '')"
  case "$result" in
    success|rolled_back|cancelled|interrupted-restored) return 1 ;;
  esac
  [ -n "$phase" ] || return 1
  return 0
}

update_log() {
  [ -n "$UPDATE_LOG" ] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$UPDATE_LOG" 2>/dev/null || true
  return 0
}

update_open_log() {
  local dir
  dir="$(update_log_dir)"
  mkdir -p "$dir" || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  UPDATE_LOG="$dir/$(date -u +%Y%m%d-%H%M%S)-${UPDATE_ID}.log"
  : >"$UPDATE_LOG"
  chmod 0600 "$UPDATE_LOG" || true
  export UPDATE_LOG
  return 0
}

# -----------------------------------------------------------------------------
# Fetch (TLS on, no insecure flags, no fallback to main)
# -----------------------------------------------------------------------------
update_candidate_proxy() {
  local state port
  if [ -n "${VGM_UPDATE_PROXY:-}" ]; then
    printf '%s\n' "$VGM_UPDATE_PROXY"
    return 0
  fi
  state="$(gp_detect_state)"
  case "$state" in
    CLIENT)
      [ -r "$(gp_client_conf)" ] || return 0
      port="$(conf_get "$(gp_client_conf)" local_port '')"
      [ -n "$port" ] && printf 'http://127.0.0.1:%s\n' "$port"
      ;;
    SERVER_FRESH|SERVER_ADOPTED)
      [ -r "$(gp_server_conf)" ] || return 0
      port="$(conf_get "$(gp_server_conf)" loopback_port '')"
      [ -n "$port" ] && printf 'http://127.0.0.1:%s\n' "$port"
      ;;
  esac
  return 0
}

# update_curl_get <url> <outfile> [proxy]
# Prints "direct" or "local proxy" on success. Never disables TLS verification.
update_curl_get() {
  local url="$1" outfile="$2" proxy="${3:-}" rc=0
  local -a args
  args=(-fsSL --retry 2 --connect-timeout 20 --max-time 180 -o "$outfile")
  if [ -n "$proxy" ]; then
    args+=(--proxy "$proxy")
  fi
  curl "${args[@]}" "$url" || rc=$?
  if [ "$rc" != "0" ]; then
    rm -f "$outfile"
    return "$rc"
  fi
  return 0
}

update_download_url() {
  local url="$1" outfile="$2" proxy="" rc=0 path_used="direct"
  if ! update_curl_get "$url" "$outfile"; then
    rc=$?
    proxy="$(update_candidate_proxy)"
    if [ -z "$proxy" ]; then
      return "$rc"
    fi
    log_info "direct download failed; retrying via local proxy"
    update_log "download retry via local proxy"
    if ! update_curl_get "$url" "$outfile" "$proxy"; then
      return $?
    fi
    path_used="local proxy"
  fi
  printf '%s\n' "$path_used"
  return 0
}

# Follow /releases/latest. A network error, a non-tag redirect, an empty tag
# or a non-release tag is a hard failure. main is never substituted.
update_discover_latest() {
  local repo url final rc=0 tag
  repo="$(update_repo_url)"
  repo="${repo%/}"
  url="$repo/releases/latest"
  final="$(curl -fsSL --retry 2 --connect-timeout 20 --max-time 60 -o /dev/null -w '%{url_effective}' -L "$url")" || rc=$?
  if [ "$rc" != "0" ] || [ -z "$final" ]; then
    die "could not discover the latest stable release (curl exit $rc). Refusing to fall back to main."
    return 1
  fi
  case "$final" in
    */releases/tag/*) tag="${final##*/}" ;;
    *)
      die "latest release redirect was not a tag URL ($final). Nothing was changed."
      return 1
      ;;
  esac
  if [ -z "$tag" ] || [ "$tag" = "tag" ]; then
    die "latest release redirect had an empty tag. Nothing was changed."
    return 1
  fi
  if ! update_version_is_release "$tag"; then
    die "latest redirect tag '$tag' is not a stable release. Nothing was changed."
    return 1
  fi
  printf '%s\n' "$tag"
  return 0
}

# -----------------------------------------------------------------------------
# Verify a release tree
# -----------------------------------------------------------------------------
update_sha256_line_parts() {
  # prints hash and path for one SHA256SUMS line
  local line="$1" hash path
  hash="$(printf '%s\n' "$line" | awk '{print $1}')"
  path="$(printf '%s\n' "$line" | awk '{print $2}')"
  path="${path#\*}"
  printf '%s\t%s\n' "$hash" "$path"
}

update_verify_sums() {
  local sums="$1" root="$2" line hash path got
  [ -r "$sums" ] || { die "missing SHA256SUMS ($sums)"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    hash="$(printf '%s\n' "$line" | awk '{print $1}')"
    path="$(printf '%s\n' "$line" | awk '{print $2}')"
    path="${path#\*}"
    [ -n "$hash" ] && [ -n "$path" ] || { die "malformed SHA256SUMS line: $line"; return 1; }
    [ -f "$root/$path" ] || { die "manifest file missing: $path"; return 1; }
    got="$(gp_sha256 "$root/$path")" || { die "could not hash $path"; return 1; }
    if [ "$got" != "$hash" ]; then
      die "checksum mismatch for $path"
      return 1
    fi
  done <"$sums"
  for path in VERSION release.meta bin/ghproxyctl lib/common.sh; do
    if ! grep -Eq "(^|[[:space:]])${path}\$" "$sums"; then
      die "SHA256SUMS does not list required file $path"
      return 1
    fi
  done
  return 0
}

update_syntax_check_tree() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bash -n "$f" || { die "syntax error in $f"; return 1; }
  done < <(find "$root" -type f \( -name '*.sh' -o -name 'ghproxyctl' -o -name 'install.sh' -o -name 'uninstall.sh' -o -name 'vgm-bootstrap' \) 2>/dev/null)
  return 0
}

# update_verify_tree <root> <expected-version-or-empty>
# expected version has no leading v. Empty means "trust VERSION inside the tree".
update_verify_tree() {
  local root="$1" expect="${2:-}" ver meta_ver commit channel floor mig reload cmp rc
  [ -d "$root/lib" ] || { die "release tree has no lib/"; return 1; }
  [ -r "$root/bin/ghproxyctl" ] || { die "release tree has no bin/ghproxyctl"; return 1; }
  [ -r "$root/VERSION" ] || { die "release tree has no VERSION"; return 1; }
  [ -r "$root/release.meta" ] || { die "release tree has no release.meta"; return 1; }
  [ -r "$root/SHA256SUMS" ] || { die "release tree has no SHA256SUMS"; return 1; }
  _update_fail_if checksum || return 1
  update_verify_sums "$root/SHA256SUMS" "$root" || return 1
  _update_fail_if unpack || return 1
  ver="$(head -n 1 "$root/VERSION" | tr -d '[:space:]')"
  meta_ver="$(conf_get "$root/release.meta" version '')"
  commit="$(conf_get "$root/release.meta" commit '')"
  channel="$(conf_get "$root/release.meta" channel '')"
  floor="$(conf_get "$root/release.meta" upgrade_from_min '')"
  mig="$(conf_get "$root/release.meta" config_migration '')"
  reload="$(conf_get "$root/release.meta" service_reload '')"
  if [ -z "$ver" ]; then
    die "VERSION is empty. Nothing was changed."
    return 1
  fi
  if [ "$ver" != "$meta_ver" ]; then
    die "VERSION says $ver but release metadata says ${meta_ver:-<empty>}. Nothing was changed."
    return 1
  fi
  if [ -n "$expect" ] && [ "$ver" != "$expect" ]; then
    die "requested $expect but the tree says $ver. Nothing was changed."
    return 1
  fi
  if [ -z "$commit" ]; then
    die "release metadata has no commit. Nothing was changed."
    return 1
  fi
  if [ "$mig" != "0" ] || [ "$reload" != "0" ]; then
    die "this release requires config_migration=$mig service_reload=$reload. A management-tool update will not do that. Nothing was changed."
    return 1
  fi
  if [ -z "$floor" ] || ! update_version_is_release "$floor"; then
    die "release metadata upgrade_from_min is missing or not a release version. Nothing was changed."
    return 1
  fi
  update_syntax_check_tree "$root" || return 1
  UPDATE_TREE_VERSION="$ver"
  UPDATE_TREE_COMMIT="$commit"
  UPDATE_TREE_CHANNEL="$channel"
  UPDATE_TREE_FLOOR="$floor"
  export UPDATE_TREE_VERSION UPDATE_TREE_COMMIT UPDATE_TREE_CHANNEL UPDATE_TREE_FLOOR
  return 0
}

update_channel_label() {
  local channel="${1:-}" commit="${2:-}"
  case "$channel" in
    stable)
      case "$commit" in
        unreleased|*[!0-9A-Fa-f]*|'') printf '%s\n' "development / non-release build" ;;
        *)
          if [ "${#commit}" -eq 40 ]; then
            printf '%s\n' stable
          else
            printf '%s\n' "development / non-release build"
          fi
          ;;
      esac
      ;;
    *) printf '%s\n' "development / non-release build" ;;
  esac
}

# -----------------------------------------------------------------------------
# Baseline / backup / switch
# -----------------------------------------------------------------------------
update_fingerprint() {
  local p="$1"
  if [ -f "$p" ]; then
    gp_sha256 "$p" || printf '%s\n' unreadable
  elif [ -d "$p" ]; then
    find "$p" -type f | sort | while IFS= read -r f; do
      printf '%s %s\n' "$(gp_sha256 "$f" 2>/dev/null || printf missing)" "${f#"$p"/}"
    done | if have sha256sum; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
  else
    printf '%s\n' absent
  fi
}

update_protected_paths() {
  local state="$1"
  case "$state" in
    SERVER_FRESH|SERVER_ADOPTED)
      printf '%s\n' "$(gp_server_conf)"
      printf '%s\n' "$(gp_clients_db)"
      printf '%s\n' "$(gp_managed_clients_acl)"
      printf '%s\n' "$(gp_domains_file)"
      if server_state_load; then
        [ -n "${SERVER_MAIN_CONF:-}" ] && printf '%s\n' "$SERVER_MAIN_CONF"
        [ -n "${SERVER_SOURCE_ACL_FILE:-}" ] && printf '%s\n' "$SERVER_SOURCE_ACL_FILE"
        [ -n "${SERVER_CLIENT_ACL_FILE:-}" ] && printf '%s\n' "$SERVER_CLIENT_ACL_FILE"
        [ -n "${SERVER_TLS_DIR:-}" ] && printf '%s\n' "$SERVER_TLS_DIR/fullchain.pem"
        [ -n "${SERVER_TLS_DIR:-}" ] && printf '%s\n' "$SERVER_TLS_DIR/privkey.pem"
        [ -n "${SERVER_CERT_LIVE_DIR:-}" ] && printf '%s\n' "$SERVER_CERT_LIVE_DIR/fullchain.pem"
        [ -n "${SERVER_CERT_LIVE_DIR:-}" ] && printf '%s\n' "$SERVER_CERT_LIVE_DIR/privkey.pem"
        [ -n "${SERVER_CERTBOT_HOOK:-}" ] && printf '%s\n' "$SERVER_CERTBOT_HOOK"
      fi
      ;;
    CLIENT)
      printf '%s\n' "$(gp_client_conf)"
      printf '%s\n' "$(migrate_dir)"
      printf '%s\n' "$(gp_p /etc/environment)"
      if client_state_load; then
        [ -n "${CLIENT_CONF_FILE:-}" ] && printf '%s\n' "$CLIENT_CONF_FILE"
        if [ -n "${CLIENT_SERVICE:-}" ]; then
          printf '%s\n' "$(gp_systemd_dir)/${CLIENT_SERVICE}"
        fi
      fi
      ;;
  esac
}

update_capture_pid() {
  local f
  for f in "$(gp_p /run/squid.pid)" "$(gp_p /var/run/squid.pid)"; do
    if [ -r "$f" ]; then
      tr -d '[:space:]' <"$f"
      return 0
    fi
  done
  printf '%s\n' none
}

update_capture_ufw() {
  local out
  if ! have ufw; then
    printf '%s\n' unavailable
    return 0
  fi
  out="$(ufw status 2>/dev/null || true)"
  if have sha256sum; then
    printf '%s' "$out" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$out" | shasum -a 256 | awk '{print $1}'
  fi
}

update_baseline_file() { printf '%s\n' "$(gp_state_dir)/update-txn/baseline.${UPDATE_ID}"; }

update_write_baseline() {
  local state="$1" dest p fp pid ufw
  dest="$(update_baseline_file)"
  mkdir -p "$(dirname "$dest")" || return 1
  : >"$dest"
  chmod 0600 "$dest" || true
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    fp="$(update_fingerprint "$p")"
    printf 'file\t%s\t%s\n' "$p" "$fp" >>"$dest"
  done < <(update_protected_paths "$state")
  pid="$(update_capture_pid)"
  ufw="$(update_capture_ufw)"
  printf 'pid\tsquid\t%s\n' "$pid" >>"$dest"
  printf 'ufw\tstatus\t%s\n' "$ufw" >>"$dest"
  return 0
}

update_baseline_unchanged() {
  local dest p kind key fp now bad=0
  dest="$(update_baseline_file)"
  [ -r "$dest" ] || { die "baseline file is missing; refusing to call the update successful"; return 1; }
  while IFS=$'\t' read -r kind key fp; do
    [ -n "$kind" ] || continue
    case "$kind" in
      file)
        now="$(update_fingerprint "$key")"
        if [ "$now" != "$fp" ]; then
          log_err "protected file changed: $key"
          bad=1
        fi
        ;;
      pid)
        now="$(update_capture_pid)"
        if [ "$fp" != "none" ] && [ "$now" != "$fp" ]; then
          log_err "Squid PID changed ($fp -> $now); a management update must not reload or restart"
          bad=1
        fi
        ;;
      ufw)
        now="$(update_capture_ufw)"
        if [ "$fp" != "unavailable" ] && [ "$now" != "$fp" ]; then
          log_err "UFW status changed during a management update"
          bad=1
        fi
        ;;
    esac
  done <"$dest"
  [ "$bad" = "0" ] || return 1
  return 0
}

update_backup_create() {
  local id="$1" dest live cli
  dest="$(update_backup_dir)/$id"
  live="$(gp_libexec_dir)"
  cli="$(gp_bin_dir)/ghproxyctl"
  _update_fail_if backup || return 1
  [ -d "$live/lib" ] || { die "refusing to back up: installed library tree is missing"; return 1; }
  [ -f "$cli" ] || { die "refusing to back up: installed ghproxyctl is missing"; return 1; }
  mkdir -p "$dest" || return 1
  chmod 0700 "$dest" || true
  cp -a "$live" "$dest/tree" || { die "backup copy of the library tree failed"; return 1; }
  cp -a "$cli" "$dest/ghproxyctl" || { die "backup copy of ghproxyctl failed"; return 1; }
  chmod 0700 "$dest" || true
  chmod 0600 "$dest/ghproxyctl" 2>/dev/null || true
  {
    printf 'version=%s\n' "$(head -n 1 "$live/VERSION" 2>/dev/null | tr -d '[:space:]')"
    printf 'commit=%s\n' "$(conf_get "$live/release.meta" commit unknown)"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'id=%s\n' "$id"
    printf 'cli_sha256=%s\n' "$(gp_sha256 "$dest/ghproxyctl")"
  } >"$dest/manifest"
  chmod 0600 "$dest/manifest" || true
  printf '%s\n' "$dest"
  return 0
}

update_backup_ok() {
  local dest="$1" ver sha got
  [ -d "$dest/tree/lib" ] || return 1
  [ -f "$dest/ghproxyctl" ] || return 1
  [ -r "$dest/manifest" ] || return 1
  ver="$(conf_get "$dest/manifest" version '')"
  [ -n "$ver" ] || return 1
  [ "$(head -n 1 "$dest/tree/VERSION" 2>/dev/null | tr -d '[:space:]')" = "$ver" ] || return 1
  sha="$(conf_get "$dest/manifest" cli_sha256 '')"
  got="$(gp_sha256 "$dest/ghproxyctl")" || return 1
  [ -n "$sha" ] && [ "$sha" = "$got" ] || return 1
  return 0
}

update_restore_from_backup() {
  local backup="$1" expect="${2:-}" live cli got
  _update_fail_if restore || return 1
  update_backup_ok "$backup" || { die "backup failed its integrity check: $backup"; return 1; }
  live="$(gp_libexec_dir)"
  cli="$(gp_bin_dir)/ghproxyctl"
  rm -rf "${live:?}"
  mkdir -p "$(dirname "$live")" "$(dirname "$cli")" || return 1
  cp -a "$backup/tree" "$live" || { die "could not restore the library tree"; return 1; }
  cp -a "$backup/ghproxyctl" "$cli" || { die "could not restore ghproxyctl"; return 1; }
  chmod 0755 "$cli" || true
  if [ -n "$expect" ]; then
    got="$(update_exec_installed_version)" || {
      die "restored ghproxyctl could not be executed"
      return 1
    }
    if [ "$got" != "$expect" ]; then
      die "restore ran but ghproxyctl version is '$got', expected '$expect'"
      return 1
    fi
  fi
  return 0
}

update_stage_build() {
  local id="$1" src="$2" stage
  stage="$(gp_p "/usr/local/lib/.vps-gateway-manager.stage.$id")"
  _update_fail_if staging || return 1
  _update_fail_if disk-full || return 1
  rm -rf "$stage"
  mkdir -p "$stage/bin" || { die "could not create staging directory"; return 1; }
  cp -a "$src/lib" "$stage/lib" || return 1
  if [ -d "$src/templates" ]; then
    cp -a "$src/templates" "$stage/templates" || return 1
  fi
  cp -a "$src/VERSION" "$stage/VERSION" || return 1
  cp -a "$src/release.meta" "$stage/release.meta" || return 1
  cp -a "$src/SHA256SUMS" "$stage/SHA256SUMS" || return 1
  [ -f "$src/install.sh" ] && cp -a "$src/install.sh" "$stage/install.sh"
  [ -f "$src/uninstall.sh" ] && cp -a "$src/uninstall.sh" "$stage/uninstall.sh"
  cp -a "$src/bin/ghproxyctl" "$stage/bin/ghproxyctl" || return 1
  chmod 0755 "$stage/bin/ghproxyctl" || true
  _update_fail_if missing-lib || return 1
  [ -r "$stage/lib/common.sh" ] || { die "staged tree is missing lib/common.sh"; return 1; }
  _update_fail_if missing-cli || return 1
  [ -r "$stage/bin/ghproxyctl" ] || { die "staged tree is missing ghproxyctl"; return 1; }
  update_verify_sums "$stage/SHA256SUMS" "$stage" || { die "staged tree failed checksum verification"; return 1; }
  printf '%s\n' "$stage"
  return 0
}

update_exec_installed_version() {
  local cli out rc=0
  cli="$(gp_bin_dir)/ghproxyctl"
  [ -f "$cli" ] || return 1
  out="$(
    env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR \
      GP_ROOT="${GP_ROOT:-}" \
      GP_NO_COLOR=1 \
      GP_ALLOW_UNSUPPORTED_OS="${GP_ALLOW_UNSUPPORTED_OS:-0}" \
      GP_SKIP_NET_CHECKS="${GP_SKIP_NET_CHECKS:-0}" \
      bash "$cli" version
  )" || rc=$?
  [ "$rc" = "0" ] || return 1
  printf '%s\n' "$out" | awk 'NR==1 { print $2 }'
}

update_prove_installed() {
  local target="$1"
  local file_ver exec_ver meta_ver
  file_ver="$(head -n 1 "$(gp_libexec_dir)/VERSION" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$file_ver" ] || { die "installed VERSION is missing"; return 1; }
  exec_ver="$(update_exec_installed_version)" || { die "installed ghproxyctl could not be executed"; return 1; }
  meta_ver="$(conf_get "$(gp_libexec_dir)/release.meta" version '')"
  if [ "$file_ver" != "$target" ]; then
    die "installed VERSION is $file_ver, target is $target"
    return 1
  fi
  if [ "$exec_ver" != "$target" ]; then
    die "ghproxyctl version is ${exec_ver:-<empty>}, target is $target"
    return 1
  fi
  if [ "$meta_ver" != "$target" ]; then
    die "installed release.meta version is ${meta_ver:-<empty>}, target is $target"
    return 1
  fi
  update_verify_sums "$(gp_libexec_dir)/SHA256SUMS" "$(gp_libexec_dir)" || {
    die "installed checksums do not match the target manifest"
    return 1
  }
  return 0
}

_update_fail_if() {
  local point="$1"
  if [ "${VGM_UPDATE_FAIL_AT:-}" = "$point" ]; then
    die "injected failure at $point"
    return 1
  fi
  return 0
}

_update_crash_if() {
  local point="$1"
  if [ "${VGM_UPDATE_CRASH_AT:-}" = "$point" ]; then
    update_log "injected crash at $point"
    gp_mutation_lock_release || true
    trap - EXIT
    trap - INT
    exit 99
  fi
  return 0
}

update_switch() {
  local id="$1" stage="$2" live prev cli newcli
  live="$(gp_libexec_dir)"
  prev="$(gp_p "/usr/local/lib/.vps-gateway-manager.prev.$id")"
  cli="$(gp_bin_dir)/ghproxyctl"
  update_txn_set phase SWITCH || return 1
  update_txn_set prev "$prev" || return 1
  _update_crash_if before-switch
  _update_fail_if switch-lib || return 1
  rm -rf "$prev"
  mv "$live" "$prev" || { die "could not move the live toolchain aside"; return 1; }
  _update_crash_if after-old-tree-moved
  if ! mv "$stage" "$live"; then
    mv "$prev" "$live" 2>/dev/null || true
    die "could not move the staged toolchain into place; previous tree restored if the rename back succeeded"
    return 1
  fi
  _update_crash_if after-new-tree-switched
  _update_crash_if before-cli-switch
  newcli="$(dirname "$cli")/.ghproxyctl.new.$id"
  _update_fail_if switch-cli || return 1
  if ! cp -a "$live/bin/ghproxyctl" "$newcli"; then
    update_switch_undo "$id"
    die "could not stage the new ghproxyctl"
    return 1
  fi
  chmod 0755 "$newcli" || true
  if ! mv -f "$newcli" "$cli"; then
    rm -f "$newcli"
    update_switch_undo "$id"
    die "could not replace ghproxyctl"
    return 1
  fi
  _update_crash_if after-cli-switch
  return 0
}

update_switch_undo() {
  local id="$1" live prev backup
  live="$(gp_libexec_dir)"
  prev="$(gp_p "/usr/local/lib/.vps-gateway-manager.prev.$id")"
  if [ -d "$prev" ]; then
    rm -rf "$live"
    mv "$prev" "$live" || return 1
  fi
  backup="$(update_txn_get backup)"
  if [ -n "$backup" ] && [ -f "$backup/ghproxyctl" ]; then
    cp -a "$backup/ghproxyctl" "$(gp_bin_dir)/ghproxyctl" || return 1
    chmod 0755 "$(gp_bin_dir)/ghproxyctl" || true
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Health. WARN is not a failure. Injection is for tests only.
# -----------------------------------------------------------------------------
update_health_class() {
  local when="$1" out rc=0
  if [ "$when" = "post" ] && [ -n "${VGM_UPDATE_POST_HEALTH_RESULT:-}" ]; then
    printf '%s\n' "$VGM_UPDATE_POST_HEALTH_RESULT"
    return 0
  fi
  if [ -n "${VGM_UPDATE_HEALTH_RESULT:-}" ]; then
    printf '%s\n' "$VGM_UPDATE_HEALTH_RESULT"
    return 0
  fi
  out="$(gp_test 2>&1)" || rc=$?
  update_log "health ($when) rc=$rc"
  printf '%s\n' "$out" >>"${UPDATE_LOG:-/dev/null}" 2>/dev/null || true
  if [ "$rc" != "0" ]; then
    printf '%s\n' fail
    return 0
  fi
  if printf '%s\n' "$out" | grep -q 'WARN'; then
    printf '%s\n' warn
    return 0
  fi
  printf '%s\n' pass
  return 0
}

# -----------------------------------------------------------------------------
# History and rotation
# -----------------------------------------------------------------------------
update_history_append() {
  local result="$1" f dir
  f="$(update_history_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  if [ ! -f "$f" ]; then
    : >"$f"
    chmod 0600 "$f" || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$UPDATE_ID" \
    "$(update_txn_get from_version)" \
    "$(update_txn_get to_version)" \
    "$result" \
    "$(update_txn_get backup)" >>"$f"
  return 0
}

update_history_show() {
  local f line ts id from to result backup
  f="$(update_history_file)"
  if [ ! -s "$f" ]; then
    printf 'no update history\n'
    return 0
  fi
  while IFS=$'\t' read -r ts id from to result backup; do
    [ -n "$ts" ] || continue
    printf '%s  %s -> %s  %s\n' "$ts" "$from" "$to" "$result"
  done <"$f"
  return 0
}

update_rotate_backups() {
  local dir keep=5 current n=0 path
  keep="${VGM_UPDATE_BACKUP_KEEP:-5}"
  dir="$(update_backup_dir)"
  current="$(update_txn_get backup)"
  [ -d "$dir" ] || return 0
  # Newest first. Never delete the backup this update just created, and never
  # delete a backup that fails the integrity check (it may be recovery material).
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path="${path%/}"
    n=$((n+1))
    if [ "$n" -le "$keep" ]; then
      continue
    fi
    if [ "$path" = "$current" ]; then
      continue
    fi
    if ! update_backup_ok "$path"; then
      continue
    fi
    rm -rf "$path"
  done < <(ls -1dt "$dir"/*/ 2>/dev/null || true)
  return 0
}

update_cleanup_work() {
  if [ -n "$UPDATE_WORK" ] && [ -d "$UPDATE_WORK" ]; then
    rm -rf "$UPDATE_WORK"
  fi
  UPDATE_WORK=""
  return 0
}

update_finish_txn() {
  local result="$1" f dest
  update_txn_set result "$result" || true
  f="$(update_txn_path)"
  if [ -f "$f" ]; then
    dest="$(dirname "$f")/finished-${UPDATE_ID}"
    mv -f "$f" "$dest" 2>/dev/null || rm -f "$f"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Unpack a tarball or accept a directory. Work dir is outside the live tree.
# -----------------------------------------------------------------------------
update_prepare_work() {
  UPDATE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vgm-update.XXXXXX")" || return 1
  export UPDATE_WORK
  return 0
}

update_find_tree() {
  local root="$1" dir
  if [ -r "$root/install.sh" ] && [ -d "$root/lib" ]; then
    printf '%s\n' "$root"
    return 0
  fi
  dir="$(find "$root" -maxdepth 2 -mindepth 2 -type f -name install.sh 2>/dev/null | head -n 1)"
  dir="${dir%/install.sh}"
  if [ -n "$dir" ] && [ -d "$dir/lib" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  die "archive layout has no install.sh and lib/ at the top level"
  return 1
}

update_acquire_source() {
  local spec="$1" expect="$2" work tree archive sums base path_used
  update_prepare_work || return 1
  work="$UPDATE_WORK"
  if [ -d "$spec" ]; then
    update_log "Download path: local directory"
    log_info "Download path: local directory"
    tree="$spec"
  elif [ -f "$spec" ]; then
    update_log "Download path: local archive"
    log_info "Download path: local archive"
    base="$(basename "$spec")"
    sums="$(dirname "$spec")/SHA256SUMS"
    [ -r "$sums" ] || { die "local archive requires SHA256SUMS beside $base"; return 1; }
    _update_fail_if checksum || return 1
    update_verify_archive_sum "$sums" "$spec" || return 1
    _update_fail_if unpack || return 1
    tar -xzf "$spec" -C "$work" || { die "could not unpack $spec"; return 1; }
    tree="$(update_find_tree "$work")" || return 1
  else
    _update_fail_if download || return 1
    archive="$work/vps-gateway-manager-${expect}.tar.gz"
    sums="$work/SHA256SUMS"
    path_used="$(update_download_url "${spec}/vps-gateway-manager-${expect}.tar.gz" "$archive")" || {
      die "download failed. Nothing was changed."
      return 1
    }
    update_log "Download path: $path_used"
    log_info "Download path: $path_used"
    update_download_url "${spec}/SHA256SUMS" "$sums" >/dev/null || {
      die "could not download SHA256SUMS. Nothing was changed."
      return 1
    }
    _update_fail_if checksum || return 1
    update_verify_archive_sum "$sums" "$archive" || return 1
    _update_fail_if unpack || return 1
    tar -xzf "$archive" -C "$work" || { die "could not unpack the release archive"; return 1; }
    tree="$(update_find_tree "$work")" || return 1
  fi
  printf '%s\n' "$tree"
  return 0
}

update_verify_archive_sum() {
  local sums="$1" file="$2" base expect got
  base="$(basename "$file")"
  expect="$(awk -v b="$base" '$2==b || $2==("*" b) { print $1; exit }' "$sums")"
  if [ -z "$expect" ]; then
    die "SHA256SUMS has no entry for $base. Nothing was changed."
    return 1
  fi
  got="$(gp_sha256 "$file")" || return 1
  if [ "$got" != "$expect" ]; then
    die "checksum mismatch for $base. Nothing was changed."
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Plan
# -----------------------------------------------------------------------------
update_plan_show() {
  local state="$1" current="$2" target="$3" commit="$4" label="$5"
  printf '\nManagement Tool Update Plan\n\n'
  printf 'Role          : %s\n' "$(gp_detect_label "$state")"
  case "$state" in
    SERVER_ADOPTED) printf 'Mode          : adopted\n' ;;
    SERVER_FRESH)   printf 'Mode          : fresh\n' ;;
    CLIENT)         printf 'Mode          : client\n' ;;
  esac
  printf 'Current       : %s\n' "$current"
  printf 'Target        : %s\n' "$target"
  printf 'Target commit : %s\n' "$commit"
  printf 'Channel       : %s\n' "$label"
  printf '\nWill update:\n'
  printf '  management libraries\n  templates\n  ghproxyctl\n  installer copies\n  updater metadata\n'
  printf '\nWill NOT modify:\n'
  case "$state" in
    SERVER_FRESH|SERVER_ADOPTED)
      printf '  Squid configuration\n  operator whitelist\n  client ACL\n  UFW\n  certificates\n  Certbot\n  server state\n  running Squid process\n'
      ;;
    CLIENT)
      printf '  client Squid config\n  upstream\n  selected family\n  pinned peer\n  Komari\n  xray\n  git config\n  /etc/environment\n  systemd unit\n  migrations\n'
      ;;
  esac
  printf '\nActions:\n  preflight, baseline, backup, stage, switch, post-check, commit\n\n'
  return 0
}

update_check_disk() {
  local avail target
  target="${GP_ROOT:-/}"
  [ -d "$target" ] || target="/"
  if ! have df; then
    log_warn "df is not available; disk space was not checked"
    return 0
  fi
  avail="$(df -Pk "$target" 2>/dev/null | awk 'NR==2 { print $4 }')" || true
  if [ -z "$avail" ]; then
    log_warn "could not read free space; continuing"
    return 0
  fi
  if [ "$avail" -lt 51200 ]; then
    die "not enough free space (${avail} KB free, need 51200)"
    return 1
  fi
  return 0
}

update_on_interrupt() {
  local phase backup from
  GP_ERROR_REPORTED=1
  phase="$(update_txn_get phase)"
  case "$phase" in
    ""|PRECHECK|FETCH|VERIFY|BASELINE)
      update_cleanup_work
      log_err "interrupted during ${phase:-start}; installed toolchain was not changed"
      rm -f "$(update_txn_path)"
      ;;
    *)
      log_err "interrupted during $phase; restoring the previous management toolchain"
      backup="$(update_txn_get backup)"
      from="$(update_txn_get from_version)"
      if [ -n "$backup" ] && update_restore_from_backup "$backup" "$from"; then
        log_err "Previous management toolchain restored successfully."
        update_txn_set result interrupted-restored || true
        update_history_append RESTORED || true
        update_finish_txn interrupted-restored || true
      else
        log_err "RECOVERY FAILED"
        log_err "Manual intervention required."
        update_txn_set result recovery-failed || true
      fi
      ;;
  esac
  exit 130
}

update_arm_interrupt() { trap 'update_on_interrupt' INT; }
update_disarm_interrupt() { trap - INT; }

# -----------------------------------------------------------------------------
# Public operations
# -----------------------------------------------------------------------------
update_check() {
  local current latest rc=0
  current="$(update_read_current_version)" || current="unknown"
  printf 'installed: %s\n' "$current"
  latest="$(update_discover_latest)" || rc=$?
  if [ "$rc" != "0" ]; then
    printf 'latest stable: unavailable\n'
    return 1
  fi
  printf 'latest stable: %s\n' "$latest"
  return 0
}

update_read_current_version() {
  local f
  f="$(gp_libexec_dir)/VERSION"
  [ -r "$f" ] || return 1
  head -n 1 "$f" | tr -d '[:space:]'
}

update_fail_after_backup() {
  local phase="$1" msg="$2" backup from
  log_err "FAIL [$phase]"
  log_err "$msg"
  update_log "FAIL [$phase] $msg"
  backup="$(update_txn_get backup)"
  from="$(update_txn_get from_version)"
  if [ -n "$backup" ] && [ -d "$backup" ]; then
    if update_restore_from_backup "$backup" "$from"; then
      log_err "UPDATE FAILED"
      log_err "Previous management toolchain restored successfully."
      log_err "Runtime configuration was not modified."
      log_err "Backup: $backup"
      update_history_append ROLLED_BACK || true
      update_finish_txn rolled_back || true
    else
      log_err "RECOVERY FAILED"
      log_err "Manual intervention required."
      log_err "Backup: $backup"
      update_txn_set result recovery-failed || true
    fi
  fi
  gp_mutation_lock_release || true
  return 1
}

# update_run [options]
#   --version <tag|sha>   --source <dir|tar>   --allow-downgrade
#   --allow-unhealthy     --allow-development
# GP_DRY_RUN and GP_ASSUME_YES are honoured. --yes does not imply the allow-* flags.
update_run() {
  local version="" source="" allow_down=0 allow_unhealthy=0 allow_dev=0
  local state current target tag expect tree label cmp rc=0
  local backup stage health post
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="${2:-}"; shift 2 ;;
      --version=*) version="${1#*=}"; shift ;;
      --source) source="${2:-}"; shift 2 ;;
      --source=*) source="${1#*=}"; shift ;;
      --allow-downgrade) allow_down=1; shift ;;
      --allow-unhealthy) allow_unhealthy=1; shift ;;
      --allow-development) allow_dev=1; shift ;;
      *) die "unknown update option: $1"; return 2 ;;
    esac
  done

  gp_require_linux || return 1
  gp_require_root || return 1
  state="$(gp_detect_state)"
  if ! gp_detect_allows_mutation "$state"; then
    die "refusing to update: install state is $state. Run doctor. This tool will not guess a role or install over a partial tree."
    return 1
  fi
  if update_interrupted; then
    die "an interrupted update is recorded ($(update_txn_get phase)). Restore it before starting another (ghproxyctl update recover)."
    return 1
  fi

  current="$(update_read_current_version)" || {
    die "installed VERSION is missing or unreadable. Refusing to update a tree whose version cannot be proved."
    return 1
  }
  if ! update_version_is_release "$current"; then
    die "installed version '$current' is not a release version this updater can compare. Nothing was changed."
    return 1
  fi

  UPDATE_ID="$(date -u +%Y%m%d%H%M%S)-$$"
  export UPDATE_ID

  if [ -n "$source" ]; then
    [ -e "$source" ] || { die "update source does not exist: $source"; return 1; }
  fi

  if gp_dry_run; then
    update_run_preview "$state" "$current" "$version" "$source" "$allow_dev" || return 1
    return 0
  fi

  gp_mutation_lock_acquire || return 1
  update_arm_interrupt
  update_open_log || return 1
  update_log "id=$UPDATE_ID role=$state from=$current"

  update_txn_set id "$UPDATE_ID" || return 1
  update_txn_set from_version "$current" || return 1
  update_txn_set phase PRECHECK || return 1
  update_txn_set started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  update_check_disk || { update_fail_before_backup PRECHECK "disk space check failed"; return 1; }

  health="$(update_health_class pre)"
  update_log "pre-health=$health"
  if [ "$health" = "fail" ] && [ "$allow_unhealthy" != "1" ]; then
    log_err "This host already has health failures before the update."
    update_fail_before_backup PRECHECK "refusing to update an already-unhealthy host without --allow-unhealthy"
    return 1
  fi
  if [ "$health" = "fail" ]; then
    log_warn "continuing despite existing health failures (--allow-unhealthy)"
  fi

  update_txn_set phase FETCH || return 1
  if [ -n "$source" ]; then
    tree="$(update_acquire_source "$source" "")" || { update_fail_before_backup FETCH "could not read the update source"; return 1; }
  else
    if [ -z "$version" ] || [ "$version" = "latest" ]; then
      tag="$(update_discover_latest)" || { update_fail_before_backup FETCH "release discovery failed"; return 1; }
    else
      tag="$version"
    fi
    case "$tag" in
      v*) expect="${tag#v}" ;;
      *) expect="$tag"; tag="v$tag" ;;
    esac
    if ! update_version_is_release "$expect"; then
      if [ "$allow_dev" != "1" ]; then
        update_fail_before_backup FETCH "target '$tag' is not a stable release. Pass --allow-development for a non-release target. Nothing was changed."
        return 1
      fi
      log_warn "development / non-release build: $tag"
    fi
    tree="$(update_acquire_source "$(update_repo_url)/releases/download/$tag" "$tag")" || {
      update_fail_before_backup FETCH "download failed"
      return 1
    }
  fi

  update_txn_set phase VERIFY || return 1
  if [ -n "$version" ] && [ "$version" != "latest" ]; then
    expect="$(update_version_strip "$version")"
  else
    expect=""
  fi
  update_verify_tree "$tree" "$expect" || { update_fail_before_backup VERIFY "release verification failed"; return 1; }
  target="$UPDATE_TREE_VERSION"
  label="$(update_channel_label "$UPDATE_TREE_CHANNEL" "$UPDATE_TREE_COMMIT")"
  if [ "$label" != "stable" ] && [ "$allow_dev" != "1" ]; then
    update_fail_before_backup VERIFY "target is a development / non-release build. Pass --allow-development. Nothing was changed."
    return 1
  fi
  rc=0
  cmp="$(update_version_cmp "$current" "$UPDATE_TREE_FLOOR")" || rc=$?
  if [ "$rc" != "0" ]; then
    update_fail_before_backup VERIFY "cannot compare installed $current with upgrade floor ${UPDATE_TREE_FLOOR}. Nothing was changed."
    return 1
  fi
  if [ "$cmp" = "-1" ]; then
    update_fail_before_backup VERIFY "Direct upgrade from this version has not been validated. Upgrade to v${UPDATE_TREE_FLOOR} first."
    return 1
  fi
  rc=0
  cmp="$(update_version_cmp "$current" "$target")" || rc=$?
  if [ "$rc" != "0" ]; then
    update_fail_before_backup VERIFY "cannot compare $current to $target"
    return 1
  fi
  if [ "$cmp" = "0" ]; then
    log_ok "Already up to date."
    update_cleanup_work
    update_finish_txn cancelled
    update_disarm_interrupt
    gp_mutation_lock_release || true
    return 0
  fi
  if [ "$cmp" = "1" ]; then
    if [ "$allow_down" != "1" ]; then
      update_fail_before_backup VERIFY "refusing to downgrade $current -> $target. Use rollback, or pass --allow-downgrade."
      return 1
    fi
    log_warn "downgrade requested: $current -> $target"
  fi

  update_plan_show "$state" "$current" "$target" "$UPDATE_TREE_COMMIT" "$label"
  if ! confirm "Continue?" no; then
    log_info "update cancelled"
    update_cleanup_work
    update_finish_txn cancelled
    update_disarm_interrupt
    gp_mutation_lock_release || true
    return 1
  fi

  update_txn_set to_version "$target" || return 1
  update_txn_set target_commit "$UPDATE_TREE_COMMIT" || return 1
  update_txn_set phase BASELINE || return 1
  update_write_baseline "$state" || { update_fail_before_backup BASELINE "could not record the runtime baseline"; return 1; }
  _update_crash_if after-baseline

  update_txn_set phase BACKUP || return 1
  backup="$(update_backup_create "$UPDATE_ID")" || { update_fail_before_backup BACKUP "backup failed; live toolchain was not replaced"; return 1; }
  update_txn_set backup "$backup" || return 1
  update_backup_ok "$backup" || { update_fail_before_backup BACKUP "backup failed its own integrity check"; return 1; }
  _update_crash_if after-backup

  update_txn_set phase STAGE || return 1
  stage="$(update_stage_build "$UPDATE_ID" "$tree")" || {
    update_fail_after_backup STAGE "staging failed. Live toolchain was not replaced."
    return 1
  }
  update_txn_set staging "$stage" || return 1
  _update_crash_if after-staging

  update_switch "$UPDATE_ID" "$stage" || {
    update_fail_after_backup SWITCH "toolchain switch failed"
    return 1
  }

  update_txn_set phase VERIFY_NEW || return 1
  _update_crash_if before-commit
  _update_fail_if version-check || { update_fail_after_backup VERIFY_NEW "version verification failed"; return 1; }
  update_prove_installed "$target" || { update_fail_after_backup VERIFY_NEW "the new toolchain did not prove it is $target"; return 1; }

  update_txn_set phase HEALTH || return 1
  _update_fail_if post-health || { update_fail_after_backup HEALTH "post-update health check failed"; return 1; }
  post="$(update_health_class post)"
  update_log "post-health=$post"
  if [ "$post" = "fail" ]; then
    update_fail_after_backup HEALTH "post-update health check reported FAIL. Previous toolchain restored if recovery succeeded."
    return 1
  fi
  update_baseline_unchanged || {
    update_fail_after_backup HEALTH "a protected file, the Squid PID or UFW changed"
    return 1
  }

  update_txn_set phase COMMIT || return 1
  update_history_append SUCCESS || { update_fail_after_backup COMMIT "could not record update history"; return 1; }
  update_rotate_backups || log_warn "backup rotation reported a problem; the new backup was kept"
  rm -rf "$(gp_p "/usr/local/lib/.vps-gateway-manager.prev.$UPDATE_ID")" 2>/dev/null || true
  update_cleanup_work
  update_finish_txn success
  update_disarm_interrupt
  gp_mutation_lock_release || true
  if [ "$post" = "warn" ] || [ "$health" = "warn" ]; then
    log_ok "UPDATE SUCCESSFUL WITH WARNINGS"
  else
    log_ok "SUCCESS"
  fi
  log_info "Backup: $backup"
  log_info "Log: $UPDATE_LOG"
  return 0
}

update_fail_before_backup() {
  local phase="$1" msg="$2"
  log_err "FAIL [$phase]"
  log_err "$msg"
  log_err "Nothing was changed."
  update_log "FAIL [$phase] $msg"
  update_cleanup_work
  update_finish_txn cancelled
  update_disarm_interrupt
  gp_mutation_lock_release || true
  return 1
}

update_run_preview() {
  local state="$1" current="$2" version="$3" source="$4" allow_dev="$5"
  local tag expect tree label target
  log_head "DRY RUN - no changes will be made"
  if [ -n "$source" ]; then
    [ -e "$source" ] || { die "update source does not exist: $source"; return 1; }
    tree="$(update_acquire_source "$source" "")" || return 1
  else
    if [ -z "$version" ] || [ "$version" = "latest" ]; then
      tag="$(update_discover_latest)" || return 1
    else
      tag="$version"
    fi
    case "$tag" in
      v*) expect="${tag#v}" ;;
      *) expect="$tag"; tag="v$tag" ;;
    esac
    tree="$(update_acquire_source "$(update_repo_url)/releases/download/$tag" "$tag")" || return 1
  fi
  if [ -n "$version" ] && [ "$version" != "latest" ]; then
    expect="$(update_version_strip "$version")"
  else
    expect=""
  fi
  update_verify_tree "$tree" "$expect" || { update_cleanup_work; return 1; }
  target="$UPDATE_TREE_VERSION"
  label="$(update_channel_label "$UPDATE_TREE_CHANNEL" "$UPDATE_TREE_COMMIT")"
  update_plan_show "$state" "$current" "$target" "$UPDATE_TREE_COMMIT" "$label"
  if [ "$current" = "$target" ]; then
    log_ok "Already up to date."
  fi
  update_cleanup_work
  log_info "dry-run: no files were changed"
  return 0
}

update_recover() {
  local phase backup from live_ver
  gp_require_root || return 1
  if ! update_interrupted; then
    log_info "no interrupted update is recorded"
    return 0
  fi
  phase="$(update_txn_get phase)"
  backup="$(update_txn_get backup)"
  from="$(update_txn_get from_version)"
  log_info "interrupted update: $from -> $(update_txn_get to_version) stopped at $phase"
  case "$phase" in
    ""|PRECHECK|FETCH|VERIFY|BASELINE)
      update_cleanup_work
      update_finish_txn cancelled
      log_ok "interrupted before the toolchain switch; installed files were not changed"
      return 0
      ;;
  esac
  if ! confirm "Restore previous known-good version?" no; then
    log_info "recovery cancelled; the interrupted marker was kept"
    return 1
  fi
  gp_mutation_lock_acquire || return 1
  UPDATE_ID="$(update_txn_get id)"
  [ -n "$UPDATE_ID" ] || UPDATE_ID="recover-$$"
  update_restore_from_backup "$backup" "$from" || {
    log_err "RECOVERY FAILED"
    log_err "Manual intervention required."
    update_txn_set result recovery-failed || true
    return 1
  }
  live_ver="$(update_exec_installed_version)" || true
  update_history_append RESTORED || true
  update_finish_txn interrupted-restored
  log_ok "previous management toolchain restored ($live_ver)"
  log_info "Runtime configuration was not modified."
  log_info "Backup: $backup"
  gp_mutation_lock_release || true
  return 0
}

update_rollback() {
  local to="" pick dest ver created
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      --to=*) to="${1#*=}"; shift ;;
      *) die "unknown rollback option: $1"; return 2 ;;
    esac
  done
  gp_require_root || return 1
  if update_interrupted; then
    die "an interrupted update is still open. Run 'ghproxyctl update recover' first."
    return 1
  fi
  if [ -z "$to" ]; then
    update_list_backups
    die "pass --to <version> (interactive selection is the menu)"
    return 1
  fi
  to="$(update_version_strip "$to")"
  dest="$(update_find_backup "$to")" || {
    die "no integrity-checked backup for $to"
    return 1
  }
  if gp_dry_run; then
    log_dry "restore management toolchain from $dest (version $to)"
    log_info "dry-run: runtime configuration would not be modified"
    return 0
  fi
  if ! confirm "Restore management toolchain $to? Runtime configuration will not be modified." no; then
    log_info "rollback cancelled"
    return 1
  fi
  gp_mutation_lock_acquire || return 1
  UPDATE_ID="rollback-$(date -u +%Y%m%d%H%M%S)-$$"
  update_open_log || return 1
  update_txn_set id "$UPDATE_ID" || return 1
  update_txn_set phase BACKUP || return 1
  update_txn_set from_version "$(update_read_current_version || true)" || return 1
  update_txn_set to_version "$to" || return 1
  # Keep a backup of whatever is installed now, so a bad restore can be undone.
  local safety
  safety="$(update_backup_create "$UPDATE_ID")" || { die "could not back up the current toolchain before rollback"; return 1; }
  update_txn_set backup "$safety" || return 1
  update_txn_set phase SWITCH || return 1
  if ! update_restore_from_backup "$dest" "$to"; then
    log_err "rollback restore failed; attempting to put the pre-rollback toolchain back"
    update_restore_from_backup "$safety" "$(conf_get "$safety/manifest" version '')" || {
      log_err "RECOVERY FAILED"
      log_err "Manual intervention required."
      update_txn_set result recovery-failed || true
      return 1
    }
    update_finish_txn rolled_back
    return 1
  fi
  update_history_append ROLLED_BACK || true
  update_finish_txn success
  log_ok "management toolchain restored to $to"
  log_info "Runtime configuration was not modified."
  log_info "Pre-rollback backup: $safety"
  gp_mutation_lock_release || true
  return 0
}

update_list_backups() {
  local dir path ver created n=0
  dir="$(update_backup_dir)"
  [ -d "$dir" ] || { printf 'no toolchain backups\n'; return 0; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path="${path%/}"
    update_backup_ok "$path" || continue
    n=$((n+1))
    ver="$(conf_get "$path/manifest" version '')"
    created="$(conf_get "$path/manifest" created '')"
    printf '%s) %s   %s   known-good\n' "$n" "$ver" "$created"
  done < <(ls -1dt "$dir"/*/ 2>/dev/null || true)
  [ "$n" = "0" ] && printf 'no integrity-checked toolchain backups\n'
  return 0
}

update_find_backup() {
  local want="$1" dir path ver
  dir="$(update_backup_dir)"
  [ -d "$dir" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path="${path%/}"
    update_backup_ok "$path" || continue
    ver="$(conf_get "$path/manifest" version '')"
    if [ "$ver" = "$want" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(ls -1dt "$dir"/*/ 2>/dev/null || true)
  return 1
}

update_cmd() {
  local sub="${1:-run}"
  shift || true
  case "$sub" in
    run) update_run "$@" ;;
    check) update_check "$@" ;;
    rollback) update_rollback "$@" ;;
    recover) update_recover "$@" ;;
    history) update_history_show "$@" ;;
    *) die "unknown update subcommand: $sub"; return 2 ;;
  esac
}
