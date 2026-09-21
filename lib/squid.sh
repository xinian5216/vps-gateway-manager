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

# squid_running_config_contains <pattern> [loopback-port]
# Asks the running daemon for its *effective* configuration (cache manager) and
# looks for <pattern>. Returns 0 found, 1 not found, 2 undetermined.
# This is how a reload is verified for real: the files on disk can be correct
# while the daemon is still serving an older configuration.
#
# The dump is only trusted when it looks like a configuration: if it does not
# contain any recognisable directive the result is "undetermined" rather than
# "not found", so an unexpected dump format cannot make the tool refuse a change
# that actually worked.
squid_running_config_contains() {
  local pattern="$1" port="${2:-${SERVER_LOOPBACK_PORT:-3128}}" dump=""
  [ -n "$pattern" ] || return 2
  if ! have curl; then return 2; fi
  dump="$(curl -sS --max-time 10 --proxy "http://127.0.0.1:$port" \
          --proxy-cacert "$(gp_ca_bundle)" \
          "http://127.0.0.1/squid-internal-mgr/config" 2>/dev/null || true)"
  if [ -z "$dump" ]; then return 2; fi
  case "$dump" in
    *"http_access"*|*"acl "*|*"http_port"*|*"https_port"*) ;;
    *) log_debug "the cache manager config dump is not in a recognised format; cannot verify"
       return 2 ;;
  esac
  case "$dump" in
    *"$pattern"*) return 0 ;;
    *) return 1 ;;
  esac
}

# squid_cache_log <config> -> the cache_log path from the config
squid_cache_log() {
  local conf="$1" logfile=""
  [ -r "$conf" ] || return 1
  logfile="$(sed -n 's/^[[:space:]]*cache_log[[:space:]]\+\([^ ]*\).*/\1/p' "$conf" | head -n 1)"
  [ -n "$logfile" ] || return 1
  logfile="${logfile%\"}"; logfile="${logfile#\"}"
  printf '%s\n' "$logfile"
  return 0
}

# squid_cache_log_lines <config> -> number of lines currently in cache_log
squid_cache_log_lines() {
  local logfile=""
  logfile="$(squid_cache_log "$1" 2>/dev/null || true)"
  [ -n "$logfile" ] || { printf '0\n'; return 0; }
  if [ -r "$logfile" ]; then wc -l < "$logfile" | tr -d ' '; else printf '0\n'; fi
  return 0
}

# squid_wait_reconfigure_complete <config> <cache-log-offset> [timeout]
#
# Waits until the daemon has finished a reconfigure cycle that started AFTER the
# recorded offset. Evidence, in this order:
#   1. a new "Reconfiguring Squid Cache" line appears after the offset
#   2. no FATAL/Bungled line appears in the same window
#   3. the plain listener accepts connections again
#   4. the same daemon is still alive and is the only one for this configuration
# Returns 0 when the cycle is confirmed, 1 when it is not (the caller decides
# whether to roll back or restart).
squid_wait_reconfigure_complete() {
  local conf="$1" offset="${2:-0}" timeout="${3:-20}" pid_before="${4:-}"
  local logfile="" seen=0 i=0 port="${SERVER_LOOPBACK_PORT:-${CLIENT_LOCAL_PORT:-}}"
  local pid_after="" fatal=""
  if [ "${GP_SKIP_NET_CHECKS:-0}" = "1" ]; then
    # Sandbox / stub environments have no real daemon and no cache log.
    log_debug "GP_SKIP_NET_CHECKS=1: not waiting for a reconfigure cycle"
    return 0
  fi
  logfile="$(squid_cache_log "$conf" 2>/dev/null || true)"
  if [ -z "$logfile" ] || [ ! -r "$logfile" ]; then
    log_debug "no readable cache_log for $conf; cannot confirm the reconfigure cycle"
    return 1
  fi
  while [ "$i" -lt "$timeout" ]; do
    local window
    window="$(tail -n +"$((offset+1))" "$logfile" 2>/dev/null || true)"
    if printf '%s' "$window" | grep -qE '^(FATAL|Bungled)'; then
      fatal="$(printf '%s' "$window" | grep -E '^(FATAL|Bungled)' | head -n 1)"
      break
    fi
    if printf '%s' "$window" | grep -qi 'Reconfiguring Squid Cache'; then
      seen=1
      break
    fi
    sleep 1; i=$((i+1))
  done
  if [ "$seen" != "1" ]; then
    if [ -n "$fatal" ]; then
      log_err "Squid reported a configuration error during the reload:"
      log_err "  $fatal"
    else
      log_warn "no reconfigure cycle was observed in ${timeout}s (cache log: $logfile)"
    fi
    return 1
  fi
  log_debug "reconfigure cycle observed after ${i}s (cache log: $logfile)"
  # The listener must be accepting again before anyone probes the proxy.
  i=0
  while [ "$i" -lt "$timeout" ]; do
    if [ -z "$port" ] || port_accepts_connections "$port"; then break; fi
    sleep 1; i=$((i+1))
  done
  pid_after="$(squid_daemon_pid "$conf" 2>/dev/null || true)"
  if [ -n "$pid_before" ] && [ "$pid_before" != "$pid_after" ]; then
    log_warn "the squid PID changed during the reload ($pid_before -> ${pid_after:-none})"
  fi
  if [ -z "$pid_after" ]; then
    log_err "no Squid daemon is running for $conf after the reload"
    return 1
  fi
  return 0
}

# squid_config_pid <config> -> the PID recorded in the config's pid file
squid_pidfile_from_config() {
  local conf="$1" pidfile=""
  [ -r "$conf" ] || return 1
  pidfile="$(sed -n 's/^[[:space:]]*pid_filename[[:space:]]\+\([^ ]*\).*/\1/p' "$conf" | head -n 1)"
  [ -n "$pidfile" ] || return 1
  pidfile="${pidfile%\"}"; pidfile="${pidfile#\"}"
  printf '%s\n' "$pidfile"
  return 0
}

squid_config_pid() {
  local conf="$1" pidfile
  pidfile="$(squid_pidfile_from_config "$conf")" || return 1
  [ -r "$pidfile" ] || return 1
  tr -dc '0-9' < "$pidfile" | head -c 10
  return 0
}

# _pid_is_squid_for_config <pid> <config>
# True only when <pid> is a live process whose command line is a squid started
# with <config>. This is what makes a reload safe: a stale pid file must never
# be used to signal an unrelated process, and it must never make Squid start a
# second instance either.
_pid_is_squid_for_config() {
  local pid="$1" conf="$2" cmdline=""
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" -gt 1 ] || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [ -n "$cmdline" ] || return 1
  case "$cmdline" in
    *squid*) : ;;
    *) return 1 ;;
  esac
  if [ -n "$conf" ]; then
    case "$cmdline" in
      *"$conf"*) return 0 ;;
    esac
    # A daemon started without -f uses the default configuration file.
    case "$conf" in
      "$(gp_squid_conf_dir)/squid.conf") case "$cmdline" in *" -f "*) return 1 ;; *) return 0 ;; esac ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# squid_daemon_pid <config> -> the pid of the daemon described by <config>,
# or nothing when the pid file is missing/stale/pointing at something else.
squid_daemon_pid() {
  local conf="$1" pid
  pid="$(squid_config_pid "$conf" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  _pid_is_squid_for_config "$pid" "$conf" || return 1
  printf '%s\n' "$pid"
  return 0
}

# squid_listener_state <config> -> "pid=<pid|none> listeners=<...>"
squid_listener_state() {
  local conf="$1" pid="" listeners=""
  pid="$(squid_daemon_pid "$conf" 2>/dev/null || true)"
  listeners="$(squid_config_listeners "$conf" 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
  printf 'pid=%s listeners=[%s]' "${pid:-none}" "${listeners:-none}"
}

# -----------------------------------------------------------------------------
# Reload / restart (always inside a transaction on production hosts)
# -----------------------------------------------------------------------------
# _sighup_is_ignored <pid>
# True when the process has SIGHUP ignored (SigIgn bit 1 in /proc/<pid>/status).
# Such a daemon can never be reconfigured by a signal: it was started by
# something that ignored SIGHUP (for example a shell background job). Reloading
# it would silently do nothing, so the caller refuses instead.
_sighup_is_ignored() {
  local pid="$1" mask=""
  [ -r "/proc/$pid/status" ] || return 1
  mask="$(sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$pid/status" | head -n 1)"
  [ -n "$mask" ] || return 1
  case "$mask" in
    *[13579bBdDfF]) return 0 ;;
    *) return 1 ;;
  esac
}

# squid_reload [unit] [config]
#
# Rules:
#   * with systemd: `systemctl reload <unit>` (the unit owns the process)
#   * without systemd: signal the *validated* daemon with SIGHUP
#   * never run `squid -k reconfigure`: when the pid file is stale that command
#     silently starts a SECOND Squid instance instead of reloading, and the
#     second instance then fights over the listening ports
#   * when no live daemon matches the configuration, refuse and report - the
#     caller rolls back instead of leaving a half-applied change
#   * afterwards verify that the same process is still serving and that the
#     plain listener accepts connections again
#
# NOTE (verified with real Squid 5.7): Squid EXITS on a configuration error
# during a reload ("FATAL: Bungled ... Terminated abnormally"). The candidate
# configuration is therefore always validated with `squid -k parse` *before* it
# is installed, and callers must be prepared to bring the daemon back if a
# reload still fails (see txn_rollback).
squid_reload() {
  local unit="${1:-$SQUID_UNIT}" conf="${2:-${SERVER_MAIN_CONF:-}}" rc=0
  local pid_before="" pid_after="" state_before="" state_after="" offset=0

  if [ -n "$conf" ] && [ -r "$conf" ]; then
    state_before="$(squid_listener_state "$conf")"
    pid_before="$(squid_daemon_pid "$conf" 2>/dev/null || true)"
    offset="$(squid_cache_log_lines "$conf")"
  fi
  log_debug "reload start: ${state_before:-unknown} cache-log-offset=$offset"

  if gp_dry_run; then
    log_dry "reload squid (${unit:-direct signal}): systemctl reload / kill -HUP <validated pid>"
    return 0
  fi

  if [ -n "$unit" ] && have systemctl && systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    systemctl_cmd reload "$unit" || rc=$?
    if [ "$rc" -eq 0 ] && ! systemctl_active "$unit"; then
      log_err "$unit is not active after the reload"
      return 1
    fi
  elif [ -n "$conf" ] && [ -r "$conf" ]; then
    if [ -z "$pid_before" ]; then
      log_err "refusing to reload: no live Squid daemon matches $conf"
      log_err "  the pid file is missing, stale, or belongs to another process."
      log_err "  Reloading anyway would start a SECOND Squid instance that fights"
      log_err "  over the listening ports. Start the daemon through its unit (or by"
      log_err "  hand) and run this command again."
      return 1
    fi
    if _sighup_is_ignored "$pid_before"; then
      log_err "the running Squid (pid $pid_before) has SIGHUP ignored - it cannot be reloaded"
      log_err "  this happens when the daemon was started by something that ignores SIGHUP"
      log_err "  (for example a shell background job). Start it from its systemd unit and"
      log_err "  run this command again; refusing to pretend the configuration was applied."
      return 1
    fi
    log_info "signalling squid (pid $pid_before) with SIGHUP"
    kill -HUP "$pid_before" || { log_err "could not signal squid (pid $pid_before)"; return 1; }
  else
    log_warn "cannot reload squid: no systemd unit detected and no configuration path known"
    return 1
  fi

  if [ "$rc" -ne 0 ]; then
    log_err "the reload command failed"
    return "$rc"
  fi

  # A delivered signal is NOT proof that the configuration was re-read: wait for
  # an actual reconfigure cycle in the cache log and for the listener to come
  # back. "The port still answers" would also be true for a reload that never
  # happened.
  if [ -n "$conf" ] && [ -r "$conf" ]; then
    if ! squid_wait_reconfigure_complete "$conf" "$offset" 20 "$pid_before"; then
      log_err "could not confirm that the reload was applied"
      return 1
    fi
    state_after="$(squid_listener_state "$conf")"
    pid_after="$(squid_daemon_pid "$conf" 2>/dev/null || true)"
    log_debug "reload done: ${state_after:-unknown}"
    if [ -n "$pid_before" ] && [ -n "$pid_after" ] && [ "$pid_before" != "$pid_after" ]; then
      log_warn "the squid process changed during the reload ($pid_before -> $pid_after)"
      log_warn "a reload must not replace the daemon; check the pid file and the unit"
    fi
  fi
  return 0
}

# squid_clear_stale_pidfile <config>
# A pid file that does not belong to a live Squid for this configuration makes
# Squid refuse to start ("Found fresh instance PID file ..."). Removing it is
# safe exactly because the validation above proved it is stale, and it is what a
# service manager's stop would have left behind.
squid_clear_stale_pidfile() {
  local conf="$1" pidfile=""
  pidfile="$(squid_pidfile_from_config "$conf" 2>/dev/null || true)"
  [ -n "$pidfile" ] || return 0
  [ -e "$pidfile" ] || return 0
  if [ -n "$(squid_daemon_pid "$conf" 2>/dev/null || true)" ]; then
    return 0
  fi
  log_warn "removing the stale pid file $pidfile (it does not belong to a running Squid)"
  gp_dry_run && { log_dry "remove $pidfile"; return 0; }
  rm -f "$pidfile" 2>/dev/null || true
  return 0
}

squid_restart() {
  local unit="${1:-$SQUID_UNIT}" conf="${2:-${SERVER_MAIN_CONF:-}}"
  [ -n "$unit" ] || { log_err "cannot restart squid: no unit detected"; return 1; }
  if ! have systemctl; then
    log_warn "no systemd on this host: restart $unit manually (the configuration is already installed)"
    return 0
  fi
  # A stale pid file makes Squid refuse to start, so clear it first.
  if [ -n "$conf" ]; then squid_clear_stale_pidfile "$conf"; fi
  systemctl_cmd restart "$unit"
}

# After a reload, make sure the daemon actually came back healthy.
# Two things are checked: the systemd unit (when it is managed by systemd) and
# the plain proxy port accepting TCP connections. The port check matters because
# Squid closes and re-opens its listeners while reconfiguring - a health check
# that runs in that window would see "connection refused" and would roll back a
# change that is actually fine.
squid_wait_healthy() {
  local unit="${1:-$SQUID_UNIT}" timeout="${2:-15}" i=0 port=""
  if gp_dry_run; then
    log_dry "wait for ${unit:-squid} and the proxy port to become healthy"
    return 0
  fi
  if [ -n "$unit" ] && have systemctl; then
    while [ "$i" -lt "$timeout" ]; do
      if systemctl_active "$unit"; then break; fi
      sleep 1; i=$((i+1))
    done
    if ! systemctl_active "$unit"; then
      log_err "service $unit is not active after reload"
      return 1
    fi
  fi
  port="${SERVER_LOOPBACK_PORT:-${CLIENT_LOCAL_PORT:-}}"
  wait_for_port "$port" "$timeout" || return 1
  return 0
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

# squid_effective_config_files <main-config> [depth]
# The EFFECTIVE configuration: the main file plus every file it includes, in
# load order, recursively. This is what Squid itself reads, so anything that
# inspects "the configuration" must use this rather than the main file alone -
# a production host routinely keeps https_port, ACLs and rules in conf.d.
squid_effective_config_files() {
  local conf="$1" depth="${2:-0}" line stripped target f
  [ "$depth" -lt 8 ] || return 0
  [ -r "$conf" ] || return 0
  printf '%s\n' "$conf"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    stripped="$(trim "${line%%#*}")"
    case "$stripped" in
      include\ *|include\	*) : ;;
      *) continue ;;
    esac
    target="$(trim "${stripped#include}")"
    target="${target%\"}"; target="${target#\"}"
    case "$target" in
      /*) : ;;
      *) target="$(dirname "$conf")/$target" ;;
    esac
    case "$target" in
      *'*'*)
        while IFS= read -r f; do
          [ -n "$f" ] && squid_effective_config_files "$f" "$((depth+1))"
        done < <(find "$(dirname "$target")" -maxdepth 1 -name "$(basename "$target")" 2>/dev/null | sort)
        ;;
      *)
        [ -r "$target" ] && squid_effective_config_files "$target" "$((depth+1))"
        ;;
    esac
  done < "$conf"
  return 0
}

# squid_conf_includes <main-config> — every included file, in load order.
squid_conf_includes() {
  local conf="$1"
  [ -r "$conf" ] || return 0
  squid_effective_config_files "$conf" | tail -n +2 | awk '!seen[$0]++'
  return 0
}

# squid_acl_src_entries <file> -> "cidr<TAB>name<TAB>comment"
# Squid ORs several `acl <name> src ...` lines (and several values on one line),
# so every address is reported. One exact host per row.
squid_acl_src_entries() {
  local file="$1" line name value comment
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
    # acl <name> src <cidr...>   (possibly several addresses on one line)
    name="$(printf '%s' "$line" | awk '{print $2}')"
    [ "$(printf '%s' "$line" | awk '{print $3}')" = "src" ] || continue
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      printf '%s\t%s\t%s\n' "$value" "$name" "$comment"
    done < <(printf '%s' "$line" | awk '{ for (i = 4; i <= NF; i++) print $i }')
  done < "$file"
  return 0
}

# squid_acl_dst_entries <file> -> "<name><TAB><type><TAB><value><TAB><source>"
#
# Typed destination discovery. The old flat "<name> <value>" output could not
# tell a list file apart from an inline domain, so a production configuration
# such as
#
#   acl github_dst dstdomain .github.com
#   acl github_dst dstdomain ghcr.io
#
# was treated as a reference to a file called ".github.com".
#
#   type=file   : quoted token or an absolute path -> the list file
#   type=inline : a domain served directly by the directive
#   type=regex  : a dstdom_regex pattern (reported, never imported verbatim)
#
# Squid ORs repeated definitions of one ACL name (that is normal, not a
# duplicate): every definition yields rows here.
squid_acl_dst_entries() {
  local file="$1" line name kind rest token quoted
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
    kind="$(printf '%s' "$line" | awk '{print $3}')"
    case "$kind" in
      dstdomain) : ;;
      dstdom_regex)
        # the whole remainder is one pattern
        rest="$(printf '%s' "$line" | awk '{ $1 = $2 = $3 = ""; sub(/^[ \t]+/, ""); print }')"
        [ -n "$rest" ] && printf '%s\tregex\t%s\t%s\n' "$name" "$rest" "$file"
        continue
        ;;
      *) continue ;;
    esac
    rest="$(printf '%s' "$line" | awk '{ $1 = $2 = $3 = ""; sub(/^[ \t]+/, ""); print }')"
    while [ -n "$rest" ]; do
      rest="${rest#"${rest%%[![:space:]]*}"}"   # drop leading whitespace
      [ -n "$rest" ] || break
      quoted=0
      case "$rest" in
        \"*)
          quoted=1
          token="${rest#\"}"
          rest="${token#*\"}"
          token="${token%%\"*}"
          ;;
        *)
          token="${rest%%[[:space:]]*}"
          rest="${rest#"$token"}"
          ;;
      esac
      [ -n "$token" ] || continue
      if [ "$quoted" = "1" ] || { [ "$quoted" = "0" ] && [ "${token#/}" != "$token" ]; }; then
        printf '%s\tfile\t%s\t%s\n' "$name" "$token" "$file"
      else
        printf '%s\tinline\t%s\t%s\n' "$name" "$token" "$file"
      fi
    done
  done < "$file"
  return 0
}

# squid_dst_acls <files...> -> typed destination ACL rows (see above), in load order.
squid_dst_acls() {
  local f
  for f in "$@"; do
    [ -r "$f" ] || continue
    squid_acl_dst_entries "$f"
  done
  return 0
}

# squid_dst_acl_used <files...> -> the destination ACL name that http_access
# rules actually reference (first one in load order), if any.
squid_dst_acl_used() {
  local -a files=("$@") names rule f token
  local rows
  rows="$(squid_dst_acls "${files[@]}")"
  [ -n "$rows" ] || return 1
  names="$(printf '%s\n' "$rows" | cut -f1 | awk '!seen[$0]++')"
  while IFS=$'\t' read -r f rule; do
    [ -n "$rule" ] || continue
    for token in $rule; do
      case "$token" in
        http_access|allow|deny|all|!*) continue ;;
      esac
      if printf '%s\n' "$names" | grep -qx -- "$token"; then
        printf '%s\n' "$token"
        return 0
      fi
    done
  done < <(squid_http_access_lines "${files[@]}")
  printf '%s\n' "$names" | head -n 1
  return 0
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

# squid_rule_allows_all <http_access rule> -> 0 only for an unconditional
# "http_access allow all".
#
# The distinction matters: "http_access deny all" is the safe, expected
# terminator of every production configuration, and a rule whose ACLs are
# localhost/allowed_clients/CONNECT/... is a normal restriction. Only an
# "allow" whose FIRST ACL is the built-in "all" ACL grants everything.
squid_rule_allows_all() {
  local tok seen_allow=0
  for tok in $1; do
    case "$tok" in
      http_access) continue ;;
      allow) seen_allow=1 ;;
      deny) return 1 ;;
      all)
        if [ "$seen_allow" = "1" ]; then return 0; fi
        return 1
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# Does the effective configuration deny everything that is not explicitly allowed?
squid_policy_audit() {
  # Prints findings; returns 1 when a dangerous pattern is detected.
  local main="$1"; shift
  local -a files=("$main" "$@")
  local lines rc=0 last rule _file last_verb
  lines="$(squid_http_access_lines "${files[@]}")"
  if [ -z "$lines" ]; then
    log_warn "no http_access rules found - squid would deny all requests by default"
    return 0
  fi
  last="$(printf '%s\n' "$lines" | tail -n 1 | cut -f2-)"
  last_verb="$(printf '%s' "$last" | awk '{print $2}')"
  case "$last_verb" in
    deny) log_debug "final http_access rule is a deny: $last" ;;
    *) log_warn "final http_access rule is not a deny: '$last' (non-listed clients may be allowed)" ; rc=1 ;;
  esac
  # Only a literal "http_access allow all" is an open proxy. "http_access deny
  # all" must be reported as the safe terminator it is - this is decided token
  # by token, never by substring matching on "allow".
  while IFS=$'\t' read -r _file rule; do
    [ -n "$rule" ] || continue
    if squid_rule_allows_all "$rule"; then
      log_err "configuration contains a blanket 'http_access allow all' - this would be an open proxy"
      rc=1
    fi
  done < <(printf '%s\n' "$lines")
  if printf '%s\n' "$lines" | grep -qE '[[:space:]]0\.0\.0\.0/0([[:space:]]|$)|[[:space:]]::/0([[:space:]]|$)'; then # policy-exempt: detection of an unsafe existing config
    log_err "configuration grants access to 0.0.0.0/0 or ::/0 - refusing to manage this host" # policy-exempt: report text
    rc=1
  fi
  return "$rc"
}

# Read the port bindings out of the effective configuration: the main file AND
# every file it includes. A production host commonly keeps https_port in
# conf.d, so reading only the main file would report "no TLS listener".
squid_config_listeners() {
  local conf="$1" file line
  [ -r "$conf" ] || return 0
  while IFS= read -r file; do
    [ -r "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%$'\r'}"
      line="$(trim "${line%%#*}")"
      case "$line" in
        http_port\ *|https_port\ *) printf '%s\n' "$line" ;;
      esac
    done < "$file"
  done < <(squid_effective_config_files "$conf")
  return 0
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
