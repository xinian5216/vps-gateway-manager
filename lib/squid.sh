#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/squid.sh
#
# Squid discovery, validation (squid -k parse), reload, and read-only
# inspection of an existing production Squid installation.
#
# Nothing here writes configuration; see lib/server.sh and lib/client.sh.
# =============================================================================

if [ -n "${GP_SQUID_SH:-}" ]; then
  return 0
fi
GP_SQUID_SH=1

SQUID_BIN=""
SQUID_VERSION=""
SQUID_MAJOR=""
SQUID_FLAVOR=""      # openssl | gnutls | none
SQUID_UNIT=""
SQUID_TLS_CAPABLE="0"
SQUID_VENDOR_PKG=""

# Minimum Squid version we support. The HTTPS forward proxy (http_port tls-cert)
# and cache_peer tls options we rely on are stable from 5.x onwards.
GP_SQUID_MIN_MAJOR=5

# Refuse to touch a Squid build that cannot do what this project needs.
squid_check_min_version() {
  if [ "${SQUID_MAJOR:-0}" -lt "$GP_SQUID_MIN_MAJOR" ]; then
    log_err "Squid ${SQUID_VERSION:-unknown} is too old (need >= ${GP_SQUID_MIN_MAJOR}.x for TLS forward proxying)."
    log_err "Install the squid-openssl package from Debian/Ubuntu instead of building an incompatible proxy."
    return 1
  fi
  if [ "$SQUID_TLS_CAPABLE" != "1" ]; then
    log_err "this Squid build reports no TLS support (flavor: ${SQUID_FLAVOR:-none})."
    log_err "Install squid-openssl (Debian/Ubuntu) and re-run."
    return 1
  fi
  return 0
}

squid_binary_path() {
  local p
  for p in "$(gp_p /usr/sbin/squid)" "$(gp_p /usr/local/sbin/squid)" /usr/sbin/squid /usr/local/sbin/squid; do
    if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  if have squid; then command -v squid; return 0; fi
  return 1
}

squid_pkg_candidates() {
  printf '%s\n' 'squid-openssl' 'squid'
}

squid_pkg_installed() {
  local pkg="$1"
  if have dpkg-query; then
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'
  else
    return 1
  fi
}

squid_pkg_version() {
  local pkg="$1"
  have dpkg-query && dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null
}

squid_version_ge_major() {
  local major="$1"
  [ -n "$SQUID_MAJOR" ] || return 1
  [ "$SQUID_MAJOR" -ge "$major" ] 2>/dev/null
}

# squid_detect
# Populates SQUID_* globals. Returns non-zero when no usable squid is present.
squid_detect() {
  SQUID_BIN="$(squid_binary_path)" || return 1
  local v
  v="$("$SQUID_BIN" -v 2>&1 || true)"
  SQUID_VERSION="$(printf '%s\n' "$v" | sed -n 's/.*Version[[:space:]]\+\([0-9][0-9A-Za-z.+~-]*\).*/\1/p' | head -n 1)"
  [ -n "$SQUID_VERSION" ] || SQUID_VERSION="unknown"
  SQUID_MAJOR="$(printf '%s' "$SQUID_VERSION" | sed -n 's/^\([0-9]\+\).*/\1/p')"
  [ -n "$SQUID_MAJOR" ] || SQUID_MAJOR=0
  case "$v" in
    *--with-openssl*) SQUID_FLAVOR="openssl" ;;
    *--with-gnutls*)  SQUID_FLAVOR="gnutls" ;;
    *--with-ssl*)     SQUID_FLAVOR="ssl" ;;
    *)                SQUID_FLAVOR="none" ;;
  esac
  case "$SQUID_FLAVOR" in
    openssl|gnutls|ssl) SQUID_TLS_CAPABLE="1" ;;
    *) SQUID_TLS_CAPABLE="0" ;;
  esac
  local pkg
  for pkg in squid-openssl squid; do
    if squid_pkg_installed "$pkg"; then SQUID_VENDOR_PKG="$pkg"; break; fi
  done
  return 0
}

# Detect the systemd unit that owns a given squid binary/config.
squid_detect_unit() {
  local unit
  SQUID_UNIT=""
  if have systemctl; then
    for unit in squid.service squid4.service; do
      if systemctl_cmd list-unit-files "$unit" >/dev/null 2>&1; then
        if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^$unit"; then
          SQUID_UNIT="$unit"; return 0
        fi
      fi
    done
    # Fall back to whatever provides the running process.
    local running
    running="$(systemctl list-units --type=service --state=running 2>/dev/null | awk '/squid/{print $1; exit}')"
    [ -n "$running" ] && { SQUID_UNIT="$running"; return 0; }
  fi
  return 1
}

squid_running_pids() {
  if have pgrep; then pgrep -x squid 2>/dev/null || true; fi
}

squid_status_summary() {
  local unit="${1:-$SQUID_UNIT}"
  printf 'binary=%s version=%s flavor=%s unit=%s active=%s enabled=%s pid=%s\n' \
    "${SQUID_BIN:-none}" "${SQUID_VERSION:-unknown}" "${SQUID_FLAVOR:-none}" \
    "${unit:-none}" \
    "$(systemctl_active "$unit" 2>/dev/null && printf yes || printf no)" \
    "$(systemctl_enabled "$unit" 2>/dev/null && printf yes || printf no)" \
    "$(squid_running_pids | tr '\n' ',' | sed 's/,$//')"
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
squid_parse() {
  # squid_parse <config-file> [log-file]
  local conf="$1" log="${2:-}" out rc=0
  [ -r "$conf" ] || { log_err "squid config not readable: $conf"; return 1; }
  [ -n "$SQUID_BIN" ] || squid_detect >/dev/null 2>&1 || { log_err "squid binary not found"; return 1; }
  out="$("$SQUID_BIN" -f "$conf" -k parse 2>&1)" || rc=$?
  if [ -n "$log" ] && ! gp_dry_run; then
    printf '%s\n' "$out" > "$log" 2>/dev/null || true
  fi
  # Squid returns 0 on success; FATAL lines are the real signal.
  if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -qE '^(FATAL|Bungled)'; then
    log_err "squid -k parse failed for $conf"
    printf '%s\n' "$out" | grep -E '^(FATAL|Bungled|ERROR|WARNING: [A-Za-z]* *[Ee]rror)' | head -n 20 >&2 || true
    printf '%s\n' "$out" | tail -n 20 >&2 || true
    return 1
  fi
  log_debug "squid -k parse OK: $conf"
  return 0
}

squid_parse_quiet() {
  local out rc=0
  out="$("$SQUID_BIN" -f "$1" -k parse 2>&1)" || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# -----------------------------------------------------------------------------
# Reload / restart (always inside a transaction on production hosts)
# -----------------------------------------------------------------------------
# squid_reload [unit] [config]
# Prefers `systemctl reload`; falls back to `squid -k reconfigure` on hosts
# without systemd (containers, minimal images) so the same code path works.
squid_reload() {
  local unit="${1:-$SQUID_UNIT}" conf="${2:-${SERVER_MAIN_CONF:-}}"
  if [ -n "$unit" ] && have systemctl && systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    systemctl_cmd reload "$unit"
    return $?
  fi
  if [ -n "$SQUID_BIN" ] && [ -n "$conf" ] && [ -r "$conf" ]; then
    log_debug "no systemd unit for '${unit:-squid}'; reloading directly: $SQUID_BIN -f $conf -k reconfigure"
    if gp_dry_run; then log_dry "squid -f $conf -k reconfigure"; return 0; fi
    if "$SQUID_BIN" -f "$conf" -k reconfigure; then return 0; fi
    log_err "squid -k reconfigure failed for $conf"
    return 1
  fi
  log_warn "cannot reload squid: no systemd unit detected and no configuration path known"
  return 1
}

squid_restart() {
  local unit="${1:-$SQUID_UNIT}"
  [ -n "$unit" ] || { log_err "cannot restart squid: no unit detected"; return 1; }
  if ! have systemctl; then
    log_warn "no systemd on this host: restart $unit manually (the configuration is already installed)"
    return 0
  fi
  systemctl_cmd restart "$unit"
}

# After a reload, make sure the daemon actually came back healthy.
squid_wait_healthy() {
  local unit="${1:-$SQUID_UNIT}" timeout="${2:-15}" i=0
  [ -n "$unit" ] || return 0
  if ! have systemctl; then return 0; fi
  if gp_dry_run; then
    log_dry "wait for $unit to become healthy"
    return 0
  fi
  while [ "$i" -lt "$timeout" ]; do
    if systemctl_active "$unit"; then return 0; fi
    sleep 1; i=$((i+1))
  done
  log_err "service $unit is not active after reload"
  return 1
}

# -----------------------------------------------------------------------------
# Read-only inspection of an existing installation
# -----------------------------------------------------------------------------
# squid_main_config <config> — the path from the unit file (if any), else the default.
squid_main_config() {
  local unit="${1:-$SQUID_UNIT}" conf=""
  if [ -n "$unit" ] && have systemctl; then
    conf="$(systemctl cat "$unit" 2>/dev/null | sed -n 's/^ExecStart=.*[[:space:]]-f[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
  fi
  [ -n "$conf" ] || conf="$(gp_squid_conf_dir)/squid.conf"
  printf '%s\n' "$conf"
}

# squid_conf_includes <main-config> — expanded list of included conf files.
squid_conf_includes() {
  local conf="$1" d
  [ -r "$conf" ] || return 0
  while IFS= read -r line; do
    line="$(trim "$line")"
    case "$line" in
      include\ *|include\	*) : ;;
      *) continue ;;
    esac
    d="$(trim "${line#include}")"
    d="${d%\"}"; d="${d#\"}"
    case "$d" in
      /*) : ;;
      *) d="$(dirname "$conf")/$d" ;;
    esac
    # shellcheck disable=SC2086
    for d in $d; do
      if [ -d "$d" ]; then
        find "$d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort
      elif [ -r "$d" ]; then
        printf '%s\n' "$d"
      fi
    done
  done < "$conf"
}

# squid_acl_src_entries <file> -> "cidr<TAB>name<TAB>raw-line"
squid_acl_src_entries() {
  local file="$1" line name value rest comment
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    # strip comments but remember them (they often carry the node name)
    comment=""
    case "$line" in
      *'#'*) comment="$(printf '%s' "${line#*#}" | tr -d '\r' | xargs 2>/dev/null || true)"; line="${line%%#*}" ;;
    esac
    line="$(trim "$line")"
    case "$line" in
      acl\ *) : ;;
      *) continue ;;
    esac
    # acl <name> src <cidr...>
    name="$(printf '%s' "$line" | awk '{print $2}')"
    [ "$(printf '%s' "$line" | awk '{print $3}')" = "src" ] || continue
    value="$(printf '%s' "$line" | awk '{print $4}')"
    [ -n "$value" ] || continue
    printf '%s\t%s\t%s\n' "$value" "$name" "$comment"
  done < "$file"
}

# squid_acl_domain_refs <file> -> "<acl name><TAB><value>" for dstdomain ACLs
squid_acl_domain_refs() {
  local file="$1" line name value
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    line="${line%%#*}"
    line="$(trim "$line")"
    case "$line" in
      acl\ *) : ;;
      *) continue ;;
    esac
    name="$(printf '%s' "$line" | awk '{print $2}')"
    value="$(printf '%s' "$line" | awk '{print $3}')"
    case "$value" in
      dstdomain|dstdom_regex) : ;;
      *) continue ;;
    esac
    value="$(printf '%s' "$line" | awk '{print $4}')"
    # a quoted value is a file path (or an inline list)
    value="${value%\"}"; value="${value#\"}"
    printf '%s\t%s\n' "$name" "$value"
  done < "$file"
}

# squid_http_access_lines <files...> — ordered list of http_access rules
squid_http_access_lines() {
  local f line
  for f in "$@"; do
    [ -r "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%$'\r'}"
      line="${line%%#*}"
      line="$(trim "$line")"
      case "$line" in
        http_access\ *) printf '%s\t%s\n' "$f" "$line" ;;
      esac
    done < "$f"
  done
}

# squid_effective_access_order <main-config> [depth]
# Walks the configuration the way Squid loads it (main file, with every
# `include` expanded in place, globs in sorted order) and prints every
# http_access rule as "<file><TAB><rule>" in evaluation order.
squid_effective_access_order() {
  local conf="$1" depth="${2:-0}"
  [ "$depth" -lt 6 ] || return 0
  [ -r "$conf" ] || return 0
  local line stripped target f
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    stripped="$(trim "${line%%#*}")"
    case "$stripped" in
      include*)
        target="$(trim "${stripped#include}")"
        target="${target%\"}"; target="${target#\"}"
        case "$target" in
          /*) : ;;
          *) target="$(dirname "$conf")/$target" ;;
        esac
        case "$target" in
          *'*'*)
            while IFS= read -r f; do
              [ -n "$f" ] && squid_effective_access_order "$f" "$((depth+1))"
            done < <(find "$(dirname "$target")" -maxdepth 1 -name "$(basename "$target")" 2>/dev/null | sort)
            ;;
          *)
            squid_effective_access_order "$target" "$((depth+1))"
            ;;
        esac
        ;;
      http_access\ *) printf '%s\t%s\n' "$conf" "$stripped" ;;
    esac
  done < "$conf"
}

# squid_check_managed_ordering <main-config> <managed-file>
# Reports whether a blanket deny rule is evaluated before the managed file's
# allow rules (which would silently deny every managed client).
# Returns 0 when the ordering is safe, 1 when it is not, 2 when undetermined.
squid_check_managed_ordering() {
  local main="$1" managed="$2" line file rule found_managed=0
  while IFS=$'\t' read -r file rule; do
    [ -n "$rule" ] || continue
    if [ "$file" = "$managed" ]; then
      case "$rule" in
        http_access\ allow*) found_managed=1 ;;
      esac
      continue
    fi
    if [ "$found_managed" = "0" ]; then
      case "$rule" in
        'http_access deny all'|'http_access deny !'*)
          log_warn "a blanket deny rule is evaluated before the managed file:"
          log_warn "    $file: $rule"
          return 1
          ;;
      esac
    fi
  done < <(squid_effective_access_order "$main")
  [ "$found_managed" = "1" ] || return 2
  return 0
}

# Does the effective configuration deny everything that is not explicitly allowed?
squid_policy_audit() {
  # Prints findings; returns 1 when a dangerous pattern is detected.
  local main="$1"; shift
  local -a files=("$main" "$@")
  local lines rc=0 last line
  lines="$(squid_http_access_lines "${files[@]}")"
  if [ -z "$lines" ]; then
    log_warn "no http_access rules found - squid would deny all requests by default"
    return 0
  fi
  last="$(printf '%s\n' "$lines" | tail -n 1 | cut -f2-)"
  case "$last" in
    *deny*) log_debug "final http_access rule is a deny: $last" ;;
    *) log_warn "final http_access rule is not a deny: '$last' (non-listed clients may be allowed)" ; rc=1 ;;
  esac
  if printf '%s\n' "$lines" | cut -f2- | grep -qiE 'http_access[[:space:]]+(allow|deny)[[:space:]]+all([[:space:]]|$)'; then
    log_err "configuration contains a blanket 'http_access allow all' - this would be an open proxy"
    rc=1
  fi
  if printf '%s\n' "$lines" | grep -qE '[[:space:]]0\.0\.0\.0/0([[:space:]]|$)|[[:space:]]::/0([[:space:]]|$)'; then # policy-exempt: detection of an unsafe existing config
    log_err "configuration grants access to 0.0.0.0/0 or ::/0 - refusing to manage this host" # policy-exempt: report text
    rc=1
  fi
  return "$rc"
}

# Read the port bindings out of a config file (best effort).
squid_config_listeners() {
  local conf="$1" line
  [ -r "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    line="$(trim "${line%%#*}")"
    case "$line" in
      http_port\ *|https_port\ *) printf '%s\n' "$line" ;;
    esac
  done < "$conf"
}

# Which file in the include set defines the source ACL used by the allow rules?
squid_find_source_acl_file() {
  local -a files=("$@") f out
  for f in "${files[@]}"; do
    # NOTE: capture first, then test. `... | grep -q .` would make the function
    # return 141 (SIGPIPE) under `set -o pipefail` and be treated as "no match".
    out="$(squid_acl_src_entries "$f")"
    if [ -n "$out" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# squid_find_domain_acl_ref <files...> -> "<acl name><TAB><list file|inline>"
squid_find_domain_acl_ref() {
  local -a files=("$@") f entry name value
  for f in "${files[@]}"; do
    entry="$(squid_acl_domain_refs "$f" | head -n 1)"
    if [ -n "$entry" ]; then
      name="${entry%%$'\t'*}"
      value="${entry#*$'\t'}"
      value="${value%\"}"; value="${value#\"}"
      printf '%s\t%s\n' "$name" "$value"
      return 0
    fi
  done
  return 1
}

# Log paths referenced by a config (used by the health checks).
squid_log_paths() {
  local conf="$1" line
  [ -r "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "${line%%#*}")"
    case "$line" in
      access_log\ *|cache_log\ *) printf '%s\n' "$line" ;;
    esac
  done < "$conf"
}

# -----------------------------------------------------------------------------
# Live behaviour probes against a listening squid
# -----------------------------------------------------------------------------
# squid_probe <proxy-url> <target-url> [curl-extra...]
# Returns curl's http code, or 000 when the connection failed.
squid_probe() {
  local proxy="$1" target="$2"
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' \
    --proxy "$proxy" --proxy-cacert "$(gp_ca_bundle)" \
    --max-time "${GP_PROBE_TIMEOUT:-25}" \
    "$@" "$target" 2>/dev/null || printf '000'
}

# squid_access_log_tail <logfile> <lines>
squid_access_log_tail() {
  local log="$1" n="${2:-20}"
  [ -r "$log" ] || return 0
  tail -n "$n" "$log" 2>/dev/null
}
