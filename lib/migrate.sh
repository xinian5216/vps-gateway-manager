#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/migrate.sh
#
# Migration of an *existing* GitHub proxy configuration to the local smart
# proxy. Design rules:
#
#   * build first, tear down later - the local proxy must pass every health
#     check before a single service is touched (enforced by the caller);
#   * only components this project understands are migrated automatically;
#     anything else is reported and needs `ghproxyctl migrate service <name>`;
#   * every change is reversible: the previous file content is stored under
#     /etc/vps-gateway-manager/migrations/ and `migrate_restore_all` puts it back
#     (used by uninstall and by automatic rollback on failure);
#   * no token, no endpoint, no ExecStart, no unit body is ever modified -
#     only the four proxy variables and NO_PROXY.
# =============================================================================

if [ -n "${GP_MIGRATE_SH:-}" ]; then
  return 0
fi
GP_MIGRATE_SH=1

MIGRATE_SUPPORTED_SERVICES="komari-agent xray-manager"
MIGRATE_SCAN_DIRS="${MIGRATE_SCAN_DIRS:-/etc/systemd/system /etc/xray-manager /etc/profile.d /etc/environment}"

migrate_dir()      { printf '%s\n' "$(gp_state_dir)/migrations"; }
migrate_backup_dir() { printf '%s\n' "$(migrate_dir)/backups"; }

migrate_record_file() { printf '%s\n' "$(migrate_dir)/$1.env"; }

# -----------------------------------------------------------------------------
# Recording / restoring
# -----------------------------------------------------------------------------
# migrate_backup_target <name> <file>  -> prints the backup path (or "")
migrate_backup_target() {
  local name="$1" target="$2" dest
  dest="$(migrate_backup_dir)/${name}.bak"
  if gp_dry_run; then
    log_dry "back up $target -> $dest"
    printf '%s\n' "$dest"
    return 0
  fi
  gp_mkdir "$(migrate_backup_dir)" 0700 || return 1
  if [ -e "$target" ]; then
    cp -a "$target" "$dest" || return 1
  else
    : > "${dest}.absent"
  fi
  printf '%s\n' "$dest"
  return 0
}

# migrate_record_write <name> key=value ...
migrate_record_write() {
  local name="$1"; shift
  local file pair
  file="$(migrate_record_file "$name")"
  if gp_dry_run; then
    log_dry "record migration '$name' in $file"
    return 0
  fi
  gp_mkdir "$(migrate_dir)" 0700 || return 1
  {
    printf '# vps-gateway-manager migration record (used for automatic restore)\n'
    printf 'name=%s\n' "$name"
    for pair in "$@"; do printf '%s\n' "$pair"; done
  } | gp_atomic_write "$file" 0600
  return 0
}

migrate_record_get() {
  local name="$1" key="$2" f
  f="$(migrate_record_file "$name")"
  [ -r "$f" ] || return 1
  sed -n "s/^${key}=//p" "$f" | tail -n 1
}

migrate_record_list() {
  local d f
  d="$(migrate_dir)"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -name '*.env' -type f 2>/dev/null | sort
}

migrate_restore_record() {
  local f="$1" name kind target had_file backup_file unit rc=0
  name="$(sed -n 's/^name=//p' "$f" | head -n1)"
  [ -n "$name" ] || name="$(basename "$f" .env)"
  kind="$(sed -n 's/^kind=//p' "$f" | head -n1)"
  if [ -z "$name" ]; then return 0; fi
  log_info "restoring migration: $name ($kind)"
  case "$kind" in
    git)
      local user home key before
      user="$(sed -n 's/^user=//p' "$f" | head -n1)"
      home="$(sed -n 's/^home=//p' "$f" | head -n1)"
      key="$(sed -n 's/^key=//p' "$f" | head -n1)"
      before="$(sed -n 's/^before=//p' "$f" | head -n1)"
      if [ -n "$user" ] && [ -n "$key" ]; then
        if [ "$before" = "__UNSET__" ] || [ -z "$before" ]; then
          as_user "$user" env HOME="$home" git config --global --unset "$key" 2>/dev/null || true
        else
          as_user "$user" env HOME="$home" git config --global "$key" "$before" 2>/dev/null || rc=1
        fi
      fi
      ;;
    *)
      target="$(sed -n 's/^target=//p' "$f" | head -n1)"
      had_file="$(sed -n 's/^had_file=//p' "$f" | head -n1)"
      backup_file="$(sed -n 's/^backup_file=//p' "$f" | head -n1)"
      unit="$(sed -n 's/^unit=//p' "$f" | head -n1)"
      if [ -z "$target" ]; then return 0; fi
      if [ "$had_file" = "1" ] && [ -r "$backup_file" ]; then
        mkdir -p "$(dirname "$target")" 2>/dev/null || true
        cp -a "$backup_file" "$target" || rc=1
        log_info "restored $target"
      else
        rm -f "$target" 2>/dev/null || true
        log_info "removed $target (it did not exist before the migration)"
      fi
      if [ -n "$unit" ] && have systemctl; then
        systemctl_cmd daemon-reload || true
        systemctl_cmd restart "$unit" || log_warn "could not restart $unit after restore"
      fi
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    if ! gp_dry_run; then
      mv -f "$f" "${f}.restored" 2>/dev/null || rm -f "$f" 2>/dev/null || true
    fi
  fi
  return "$rc"
}

migrate_restore_all() {
  local f any=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    migrate_restore_record "$f" || log_warn "restore failed for $f"
  done < <(migrate_record_list)
  [ "$any" = "0" ] && log_debug "no migrations to restore"
  return 0
}

migrate_summary_line() {
  local n=0 f
  while IFS= read -r f; do [ -n "$f" ] && n=$((n+1)); done < <(migrate_record_list)
  if [ "$n" -eq 0 ]; then printf 'none recorded\n'; else printf '%s component(s) migrated (restorable)\n' "$n"; fi
  return 0
}

# -----------------------------------------------------------------------------
# Detection helpers
# -----------------------------------------------------------------------------
# Does this value point at our upstream proxy?
value_is_upstream() {
  local value="$1" host port
  [ -n "$value" ] || return 1
  [ -n "$CLIENT_UPSTREAM" ] || return 1
  host="$CLIENT_UPSTREAM_HOST"
  port="$CLIENT_UPSTREAM_PORT"
  case "$value" in
    *"$host:$port"*) return 0 ;;
    *"$host"*) return 0 ;;
  esac
  return 1
}

unit_exists() {
  have systemctl && systemctl list-unit-files "$1" >/dev/null 2>&1
}

# unit_proxy_vars <unit> -> "KEY=VALUE" lines from the merged environment
unit_proxy_vars() {
  local unit="$1" envs
  have systemctl || return 0
  envs="$(systemctl show "$unit" -p Environment 2>/dev/null | sed 's/^Environment=//')"
  printf '%s\n' "$envs" | tr ' ' '\n' | grep -iE '^(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy)=' || true
}

# unit_files <unit> -> config file(s) that mention proxy variables
unit_proxy_files() {
  local unit="$1" f
  have systemctl || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -r "$f" ] || continue
    if grep -qiE '^[[:space:]]*Environment=.*(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)' "$f"; then
      printf '%s\n' "$f"
    fi
  done < <(systemctl cat "$unit" 2>/dev/null | sed -n 's/^# *\(.*\)$/\1/p' | grep -E '^/' | sort -u)
}

dropin_dir_for() { printf '%s\n' "$(gp_systemd_dir)/$1.d"; }

# unit_name_from_path <file> -> the systemd unit a unit/drop-in file belongs to
unit_name_from_path() {
  local f="$1" dir base
  dir="$(dirname "$f")"
  case "$dir" in
    *.d) base="$(basename "$dir")"; printf '%s\n' "${base%.d}" ;;
    *)   base="$(basename "$f")"; printf '%s\n' "${base%.service}" ;;
  esac
}

# -----------------------------------------------------------------------------
# Scan (read-only)
# -----------------------------------------------------------------------------
# Prints one line per finding: "<component>\t<support>\t<location>\t<detail>"
migrate_scan_raw() {
  local f unit file line

  # 1. systemd units in the documented scope only
  for f in "$(gp_systemd_dir)"/*.service "$(gp_systemd_dir)"/*/*.d/*.conf "$(gp_systemd_dir)"/*/*.d/*.override.conf; do
    [ -e "$f" ] || continue
    if grep -qiE '(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)[[:space:]]*=' "$f"; then
      unit="$(unit_name_from_path "$f")"
      line="$(grep -iE '^(Environment=)?.*(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)=' "$f" | head -n1)"
      if printf '%s' "$line" | grep -q "$CLIENT_UPSTREAM_HOST"; then
        case " $MIGRATE_SUPPORTED_SERVICES " in
          *" $unit "*) printf '%s\tauto-supported\t%s\t%s\n' "$unit" "$f" "$line" ;;
          *)           printf '%s\tmanual-review\t%s\t%s\n' "$unit" "$f" "$line" ;;
        esac
      fi
    fi
  done

  # 2. xray-manager download_proxy
  f="$(gp_p /etc/xray-manager/download_proxy)"
  if [ -r "$f" ]; then
    line="$(head -n1 "$f" | tr -d '[:space:]')"
    if value_is_upstream "$line"; then
      printf 'xray-manager\tauto-supported\t%s\t%s\n' "$f" "$line"
    fi
  fi

  # 3. git configuration of root and of the invoking user
  local user home before
  for user in root ${SUDO_USER:-} ; do
    [ -n "$user" ] || continue
    home="$(user_home "$user" 2>/dev/null)" || continue
    [ -r "$home/.gitconfig" ] || continue
    before="$(as_user "$user" env HOME="$home" git config --global --get http.https://github.com.proxy 2>/dev/null || true)"
    if value_is_upstream "$before"; then
      printf 'Git config (%s)\tauto-supported\t%s/.gitconfig\thttp.https://github.com.proxy=%s\n' "$user" "$home" "$before"
    fi
    before="$(as_user "$user" env HOME="$home" git config --global --get http.proxy 2>/dev/null || true)"
    if value_is_upstream "$before"; then
      printf 'Git config (%s)\tmanual-review\t%s/.gitconfig\thttp.proxy=%s (generic, applies to every site)\n' "$user" "$home" "$before"
    fi
  done

  # 4. global environment files
  for f in "$(gp_p /etc/environment)" "$(gp_p /etc/profile.d)"/*.sh; do
    [ -r "$f" ] || continue
    if grep -qiE '(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)[[:space:]]*=' "$f"; then
      line="$(grep -iE '(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)=' "$f" | head -n1)"
      if printf '%s' "$line" | grep -q "$CLIENT_UPSTREAM_HOST"; then
        printf '%s\tmanual-review\t%s\t%s\n' "$(basename "$f")" "$f" "$line"
      fi
    fi
  done
  return 0
}

migrate_scan() {
  local raw
  client_state_load 2>/dev/null || true
  if [ -z "${CLIENT_UPSTREAM:-}" ]; then
    die "no upstream recorded; run this on an installed client"
    return 1
  fi
  log_head "migration scan (read-only)"
  printf 'upstream: %s\n\n' "$CLIENT_UPSTREAM"
  raw="$(migrate_scan_raw)"
  if [ -z "$raw" ]; then
    printf 'no existing references to %s were found.\n' "$CLIENT_UPSTREAM"
    return 0
  fi
  printf '%-34s %-16s %s\n' "COMPONENT" "SUPPORT" "LOCATION"
  printf '%-34s %-16s %s\n' "---------" "-------" "--------"
  printf '%s\n' "$raw" | while IFS=$'\t' read -r component support location detail; do
    [ -n "$component" ] || continue
    printf '%-34s %-16s %s\n' "$component" "$support" "$location"
    if [ -n "$detail" ]; then
      printf '%-34s %-16s   %s\n' "" "" "$(printf '%s' "$detail" | cut -c1-110 | gp_redact_url_credentials)"
    fi
  done
  printf '\nLegend: auto-supported = migrated by "install.sh client --adopt-existing"
        manual-review  = reported only; migrate explicitly with
                         "ghproxyctl migrate service <name>" or by hand\n'
  return 0
}

migrate_scan_list() {
  # machine readable: component, support, location, detail
  client_state_load 2>/dev/null || true
  migrate_scan_raw
}

# -----------------------------------------------------------------------------
# Komari
# -----------------------------------------------------------------------------
komari_units() {
  local u
  for u in komari-agent komari-agent.service; do
    if unit_exists "$u"; then printf '%s\n' "${u%.service}"; return 0; fi
  done
  return 1
}

migrate_komari_plan() {
  # Fills KOMARI_* globals: UNIT, FILES (newline), HAS_UPSTREAM, NO_PROXY,
  # ENVFILE (set when the unit uses EnvironmentFile=, which we must not touch)
  KOMARI_UNIT=""
  KOMARI_FILES=""
  KOMARI_HAS_UPSTREAM=0
  KOMARI_NO_PROXY=""
  KOMARI_ENVFILE=0
  local unit f
  unit="$(komari_units)" || return 1
  KOMARI_UNIT="$unit"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    KOMARI_FILES="${KOMARI_FILES}${f}
"
    if grep -qiE '^[[:space:]]*EnvironmentFile=' "$f"; then
      KOMARI_ENVFILE=1
    fi
    if grep -qiE '^[[:space:]]*Environment=.*(HTTPS_PROXY|HTTP_PROXY|https_proxy|http_proxy)=' "$f" \
       && grep -q "$CLIENT_UPSTREAM_HOST" "$f"; then
      KOMARI_HAS_UPSTREAM=1
    fi
  done < <(unit_proxy_files "$unit")
  KOMARI_NO_PROXY="$(unit_proxy_vars "$unit" | sed -n 's/^[Nn][Oo]_[Pp][Rr][Oo][Xx][Yy]=//p' | tail -n1)"
  [ -n "$KOMARI_FILES" ] || return 1
  return 0
}

# Rewrite only the proxy lines of a systemd Environment= fragment.
_komari_rewrite_env_file() {
  local src="$1" dest="$2" local_url="$3" merged_no_proxy="$4"
  awk -v localurl="$local_url" -v noproxy="$merged_no_proxy" '
    BEGIN { IGNORECASE = 1 }
    /^[[:space:]]*Environment=/ {
      line=$0
      # Split "Environment=" payload on spaces; each token is KEY=VALUE or a
      # quoted string. Rebuild the line, replacing only the proxy keys.
      n=split(substr(line, index(line, "=")+1), toks, /[ \t]+/)
      out=""
      for (i=1; i<=n; i++) {
        tok=toks[i]
        if (tok == "") continue
        gsub(/^"|"$/, "", tok)
        split(tok, kv, "=")
        key=toupper(kv[1])
        if (key == "HTTP_PROXY" || key == "HTTPS_PROXY") tok=kv[1]"="localurl
        else if (key == "NO_PROXY") tok=kv[1]"="noproxy
        if (out == "") out=tok; else out=out" "tok
      }
      print "Environment=\""out"\""
      next
    }
    { print }
  ' "$src" > "$dest"
  return 0
}

migrate_komari_apply() {
  local unit files f had=0 backup target tmp no_proxy merged logs rc=0 restart_since new_pid
  unit="$KOMARI_UNIT"
  files="$(printf '%s\n' "$KOMARI_FILES" | grep -v '^$' || true)"
  if [ -z "$files" ]; then
    log_warn "no Komari drop-in files found; nothing to migrate"
    return 0
  fi
  if [ "$KOMARI_ENVFILE" = "1" ]; then
    log_err "the Komari unit uses EnvironmentFile=, which overrides Environment="
    log_err "migrating it automatically would be unsafe - review it by hand:"
    printf '%s\n' "$files" | sed 's/^/    /' >&2
    return 2
  fi

  # Which file actually carries the upstream proxy? Prefer a drop-in.
  target="$(printf '%s\n' "$files" | grep -E '\.d/' | head -n1)"
  [ -n "$target" ] || target="$(printf '%s\n' "$files" | head -n1)"

  log_info "Komari unit: $unit"
  log_info "Komari file to adjust: $target"

  if gp_dry_run; then
    log_dry "rewrite HTTP_PROXY/HTTPS_PROXY in $target -> http://127.0.0.1:${CLIENT_LOCAL_PORT}"
    log_dry "merge NO_PROXY with: $(client_collect_no_proxy)"
    log_dry "systemctl daemon-reload && systemctl restart $unit"
    log_dry "verify: is-active, WebSocket v2 in the journal, no x509/proxyconnect/websocket/reset transport errors (Ping/ICMP monitor timeouts excluded)"
    return 0
  fi

  backup="$(migrate_backup_target "komari-${unit}" "$target")" || return 1
  [ -n "$backup" ] || return 1
  if [ -e "$target" ]; then had=1; fi

  no_proxy="${KOMARI_NO_PROXY:-}"
  merged="$(client_collect_no_proxy)"
  if [ -n "$no_proxy" ]; then
    merged="$(printf '%s,%s\n' "$merged" "$no_proxy" | csv_merge)"
  fi

  tmp="$(mktemp)"
  _komari_rewrite_env_file "$target" "$tmp" "http://127.0.0.1:${CLIENT_LOCAL_PORT}" "$merged" || rc=1
  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    log_err "could not rewrite $target"
    return 1
  fi
  # Sanity: the endpoint/token/exec lines must be untouched.
  local before_lines after_lines
  before_lines="$(grep -cvE '^[[:space:]]*Environment=' "$target" 2>/dev/null || printf 0)"
  after_lines="$(grep -cvE '^[[:space:]]*Environment=' "$tmp" 2>/dev/null || printf 0)"
  if [ "$before_lines" != "$after_lines" ]; then
    rm -f "$tmp"
    log_err "refusing to install $target: non-Environment lines would change ($before_lines -> $after_lines)"
    return 1
  fi
  if grep -qiE 'ExecStart|Token|Endpoint' "$target" 2>/dev/null; then
    if ! diff <(grep -iE 'ExecStart|Token|Endpoint' "$target" 2>/dev/null) \
               <(grep -iE 'ExecStart|Token|Endpoint' "$tmp" 2>/dev/null) >/dev/null 2>&1; then
      rm -f "$tmp"
      log_err "refusing to install $target: ExecStart/Token/Endpoint would change"
      return 1
    fi
  fi

  install -m 0644 "$tmp" "$target" || { rm -f "$tmp"; log_err "install of $target failed"; return 1; }
  rm -f "$tmp"

  migrate_record_write "komari-${unit}" \
    "kind=systemd-dropin" \
    "target=$target" \
    "had_file=$had" \
    "backup_file=$backup" \
    "unit=$unit" \
    "before_upstream=$CLIENT_UPSTREAM" \
    "applied_upstream=http://127.0.0.1:${CLIENT_LOCAL_PORT}" \
    "no_proxy=$merged" \
    "recorded_at=$(gp_ts_human)" || log_warn "could not write the migration record"

  systemctl_cmd daemon-reload || true
  # Verification analyses THIS process only: journal lines since the restart,
  # tagged with the new MainPID. Errors from a previous PID or an older time
  # window must never fail a healthy migration.
  restart_since="$(date '+%Y-%m-%d %H:%M:%S')"
  if ! systemctl_cmd restart "$unit"; then
    log_err "restarting $unit failed; restoring the previous configuration"
    migrate_restore_record "$(migrate_record_file "komari-${unit}")"
    return 1
  fi
  new_pid="$(migrate_komari_main_pid "$unit")"
  if ! migrate_komari_verify "$unit" "$new_pid" "$restart_since"; then
    log_err "Komari verification failed; restoring the previous configuration"
    migrate_restore_record "$(migrate_record_file "komari-${unit}")"
    logs="$(komari_logs "$unit" 120 | tail -n 5)"
    [ -n "$logs" ] && printf '%s\n' "$logs" >&2
    return 1
  fi
  log_ok "Komari migrated to the local smart proxy"
  return 0
}

komari_logs() {
  local unit="$1" secs="${2:-120}" since="${3:-}"
  have journalctl || return 0
  if [ -n "$since" ]; then
    journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null || true
  else
    journalctl -u "$unit" --since "-${secs}s" --no-pager 2>/dev/null || true
  fi
}

# migrate_komari_main_pid <unit> -> the unit's current MainPID ("" when unknown)
# Used to analyse only the process that runs AFTER the migration restart, so a
# previous PID's errors can never fail a healthy migration.
migrate_komari_main_pid() {
  local pid
  pid="$(systemctl_cmd show "$1" -p MainPID 2>/dev/null | sed -n 's/^MainPID=//p' | head -n1 | tr -d '[:space:]')"
  [ "$pid" = "0" ] && pid=""
  printf '%s' "$pid"
  return 0
}

# migrate_komari_scope_to_pid <logs> <pid>
# Keep only the journal lines tagged with <pid>. Fail-safe by design: when the
# pid is unknown, or when NO line carries a pid tag (unknown log format), every
# line is kept - a real error must never hide behind this filter.
migrate_komari_scope_to_pid() {
  local logs="$1" pid="$2" tagged
  [ -n "$pid" ] || { printf '%s\n' "$logs"; return 0; }
  tagged="$(printf '%s\n' "$logs" | grep -F "[${pid}]" || true)"
  if [ -z "$tagged" ]; then
    printf '%s\n' "$logs"
    return 0
  fi
  printf '%s\n' "$tagged"
  return 0
}

# migrate_komari_error_lines <logs>
# Lines that prove the PROXY / TLS / WEBSOCKET path is broken.
#
# Komari also runs its own Ping/ICMP monitoring and logs "Ping i/o timeout"when a MONITORED TARGET stops answering: that is an application-level monitor
# result, not a proxy-path failure (the London node logged it persistentlyacross two PIDs while "WebSocket connected" showed the panel path healthy).
# So a timeout only loses its error verdict on a pure ping/icmp monitor line -
# every other timeout (websocket/tcp/proxy reads and dials) and every x509 /
# proxyconnect / connection-reset / websocket failure still counts. Nothing is
# ever treated as success unconditionally.
migrate_komari_error_lines() {
  local logs="$1" line is_timeout is_monitor
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    is_timeout=0
    is_monitor=0
    if printf '%s' "$line" | grep -qi 'i/o timeout'; then
      is_timeout=1
      if printf '%s' "$line" | grep -qiE '(^|[[:space:]])(ping|icmp)[[:space:]:]'; then
        is_monitor=1
      fi
    fi
    # A ping/icmp monitor line is only noise when it says nothing about the
    # websocket/proxy transport itself ("websocket ping: i/o timeout" stays an
    # error).
    if [ "$is_monitor" = "1" ] && ! printf '%s' "$line" | grep -qiE 'websocket|proxy|x509|dial|tls|tcp|connect'; then
      continue
    fi
    if [ "$is_timeout" = "1" ] || \
       printf '%s' "$line" | grep -qiE 'x509|proxyconnect|connection reset|websocket.*(fail|refus|1006|handshake)'; then
      printf '%s\n' "$line"
    fi
  done <<EOF
$logs
EOF
  return 0
}

# migrate_komari_verify <unit> [main-pid] [restart-since]
# The migration is verified when the unit is active, the logs of the CURRENT
# process (scoped by MainPID, and since the restart) show no proxy/TLS/websocket
# transport failures, and - best evidence - the WebSocket session is connected.
migrate_komari_verify() {
  local unit="$1" pid="${2:-}" since="${3:-}" logs active errors
  active="$(systemctl_cmd is-active "$unit" 2>/dev/null || true)"
  if [ "$active" != "active" ]; then
    log_err "$unit is not active (state: ${active:-unknown})"
    return 1
  fi
  logs="$(komari_logs "$unit" 180 "$since")"
  logs="$(migrate_komari_scope_to_pid "$logs" "$pid")"
  errors="$(migrate_komari_error_lines "$logs")"
  if [ -n "$errors" ]; then
    log_err "$unit logs still show proxy/TLS/websocket transport errors:"
    printf '%s\n' "$errors" | tail -n 5 >&2
    return 1
  fi
  if printf '%s' "$logs" | grep -qiE 'websocket connected'; then
    log_ok "$unit: $(printf '%s' "$logs" | grep -iE 'websocket connected' | tail -n1 | cut -c1-110)"
    return 0
  fi
  log_warn "$unit is active and shows no proxy errors, but no WebSocket v2 line appeared yet"
  log_warn "verify manually: journalctl -u $unit -n 50"
  return 0
}

# -----------------------------------------------------------------------------
# xray-manager
# -----------------------------------------------------------------------------
migrate_xray_manager_plan() {
  XRAYM_FILE="$(gp_p /etc/xray-manager/download_proxy)"
  XRAYM_PRESENT=0
  XRAYM_VALUE=""
  if [ -r "$XRAYM_FILE" ]; then
    XRAYM_PRESENT=1
    XRAYM_VALUE="$(head -n1 "$XRAYM_FILE" | tr -d '[:space:]')"
  fi
  return 0
}

migrate_xray_manager_apply() {
  local backup rc=0
  migrate_xray_manager_plan
  if [ "$XRAYM_PRESENT" = "0" ]; then
    log_info "xray-manager: $XRAYM_FILE does not exist"
    if confirm "Create $XRAYM_FILE pointing at the local smart proxy?" no; then
      if gp_dry_run; then
        log_dry "create $XRAYM_FILE with http://127.0.0.1:${CLIENT_LOCAL_PORT}"
        return 0
      fi
      printf 'http://127.0.0.1:%s\n' "$CLIENT_LOCAL_PORT" | gp_atomic_write "$XRAYM_FILE" 0644
      migrate_record_write "xray-manager-download-proxy" \
        "kind=file" "target=$XRAYM_FILE" "had_file=0" "backup_file=-" \
        "before_upstream=none" "applied_upstream=http://127.0.0.1:${CLIENT_LOCAL_PORT}" \
        "recorded_at=$(gp_ts_human)"
      log_ok "xray-manager download_proxy created"
    else
      log_info "xray-manager left unchanged"
    fi
    return 0
  fi
  if ! value_is_upstream "$XRAYM_VALUE"; then
    log_info "xray-manager download_proxy points elsewhere ($XRAYM_VALUE); leaving it alone"
    return 0
  fi
  if gp_dry_run; then
    log_dry "rewrite $XRAYM_FILE: $XRAYM_VALUE -> http://127.0.0.1:${CLIENT_LOCAL_PORT}"
    return 0
  fi
  backup="$(migrate_backup_target "xray-manager" "$XRAYM_FILE")" || return 1
  printf 'http://127.0.0.1:%s\n' "$CLIENT_LOCAL_PORT" | gp_atomic_write "$XRAYM_FILE" 0644 || rc=1
  if [ "$rc" -ne 0 ]; then
    log_err "could not update $XRAYM_FILE"
    return 1
  fi
  migrate_record_write "xray-manager-download-proxy" \
    "kind=file" "target=$XRAYM_FILE" "had_file=1" "backup_file=$backup" \
    "before_upstream=$XRAYM_VALUE" "applied_upstream=http://127.0.0.1:${CLIENT_LOCAL_PORT}" \
    "recorded_at=$(gp_ts_human)"
  log_ok "xray-manager download_proxy now uses the local smart proxy"
  return 0
}

# -----------------------------------------------------------------------------
# Git
# -----------------------------------------------------------------------------
migrate_git_apply() {
  local users u before generic rc=0
  users="$(client_target_users "${CLIENT_GIT_USERS:-auto}")"
  [ -n "$users" ] || { log_info "git: no users targeted"; return 0; }
  printf '%s\n' "$users" | while IFS= read -r u; do
    [ -n "$u" ] || continue
    before="$(as_user "$u" env HOME="$(user_home "$u")" git config --global --get http.https://github.com.proxy 2>/dev/null || true)"
    generic="$(as_user "$u" env HOME="$(user_home "$u")" git config --global --get http.proxy 2>/dev/null || true)"
    if value_is_upstream "$before"; then
      log_info "git ($u): migrating http.https://github.com.proxy"
      client_git_configure_user "$u" || rc=1
    elif value_is_upstream "$generic"; then
      log_warn "git ($u): http.proxy=$generic applies to *every* Git site, which is the old, discouraged setup"
      if confirm "Replace it with a GitHub-only proxy setting for $u?" yes; then
        if gp_dry_run; then
          log_dry "unset http.proxy for $u and set http.https://github.com.proxy"
        else
          as_user "$u" env HOME="$(user_home "$u")" git config --global --unset http.proxy 2>/dev/null || true
          client_git_configure_user "$u" || rc=1
          migrate_record_write "git-generic-${u}" \
            "kind=git" "user=$u" "home=$(user_home "$u")" \
            "key=http.proxy" "before=$generic" "applied=__UNSET__" \
            "recorded_at=$(gp_ts_human)"
        fi
      else
        log_info "git ($u): left unchanged"
      fi
    else
      # No upstream reference: make sure the GitHub-only setting exists.
      client_git_configure_user "$u" || rc=1
    fi
  done
  return "$rc"
}

# -----------------------------------------------------------------------------
# /etc/environment and profile.d (needs an explicit opt-in)
# -----------------------------------------------------------------------------
migrate_environment_plan() {
  ENV_FILE="$(gp_p /etc/environment)"
  ENV_HAS_UPSTREAM=0
  if [ -r "$ENV_FILE" ] && grep -qiE '(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)=' "$ENV_FILE"; then
    if grep -q "$CLIENT_UPSTREAM_HOST" "$ENV_FILE"; then ENV_HAS_UPSTREAM=1; fi
  fi
  return 0
}

migrate_environment_apply() {
  local backup tmp rc=0
  migrate_environment_plan
  if [ "$ENV_HAS_UPSTREAM" != "1" ]; then
    log_info "/etc/environment does not reference the upstream proxy"
    return 0
  fi
  log_warn "/etc/environment configures the upstream proxy globally for the whole machine."
  log_warn "Changing it affects software this project knows nothing about."
  if [ "${CLIENT_MIGRATE_GLOBAL_ENV:-0}" != "1" ]; then
    log_err "refusing to modify /etc/environment without --migrate-global-env"
    log_err "review it manually, or re-run with: --migrate-global-env"
    return 3
  fi
  if gp_dry_run; then
    log_dry "rewrite the proxy variables in $ENV_FILE -> http://127.0.0.1:${CLIENT_LOCAL_PORT}"
    return 0
  fi
  backup="$(migrate_backup_target "environment" "$ENV_FILE")" || return 1
  tmp="$(mktemp)"
  sed -E "s#^([[:space:]]*(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)=).*#\1\"http://127.0.0.1:${CLIENT_LOCAL_PORT}\"#I" \
    "$ENV_FILE" > "$tmp" || rc=1
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return 1; fi
  install -m 0644 "$tmp" "$ENV_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  migrate_record_write "environment" \
    "kind=file" "target=$ENV_FILE" "had_file=1" "backup_file=$backup" \
    "before_upstream=$CLIENT_UPSTREAM" "applied_upstream=http://127.0.0.1:${CLIENT_LOCAL_PORT}" \
    "recorded_at=$(gp_ts_human)"
  log_ok "/etc/environment now points at the local smart proxy"
  return 0
}

# -----------------------------------------------------------------------------
# Explicit migration for an unknown systemd service
# -----------------------------------------------------------------------------
migrate_service_apply() {
  local unit="$1" files f target backup had=0 rc=0 merged
  unit="${unit%.service}"
  unit_exists "$unit" || { die "no such systemd unit: $unit"; return 1; }
  if list_contains "$(printf '%s\n' $MIGRATE_SUPPORTED_SERVICES)" "$unit"; then
    log_info "$unit is a supported component; the standard migration is preferred"
  fi
  files="$(unit_proxy_files "$unit")"
  if [ -z "$files" ]; then
    die "$unit does not reference a proxy in its unit files (nothing to migrate)"
    return 1
  fi

  # Refuse components we do not understand unless the operator asked for it.
  if ! confirm "Migrate $unit (files: $(printf '%s' "$files" | tr '\n' ' '))?" no; then
    log_info "aborted"
    return 0
  fi

  local any=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    had=0
    if [ -e "$f" ]; then had=1; fi
    if ! grep -q "$CLIENT_UPSTREAM_HOST" "$f"; then continue; fi
    if gp_dry_run; then
      log_dry "rewrite proxy variables in $f -> http://127.0.0.1:${CLIENT_LOCAL_PORT}"
      continue
    fi
    backup="$(migrate_backup_target "service-${unit}-$(basename "$f")" "$f")" || { rc=1; continue; }
    merged="$(client_collect_no_proxy)"
    target="$f"
    tmp="$(mktemp)"
    _komari_rewrite_env_file "$f" "$tmp" "http://127.0.0.1:${CLIENT_LOCAL_PORT}" "$merged" || rc=1
    if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
      local fmode
      fmode="$(gp_file_mode "$f" 2>/dev/null)"
      [ -n "$fmode" ] || fmode=0644
      install -m "$fmode" "$tmp" "$target" || rc=1
      any=1
      migrate_record_write "service-${unit}-$(basename "$f")" \
        "kind=systemd-dropin" "target=$target" "had_file=$had" "backup_file=$backup" \
        "unit=$unit" "before_upstream=$CLIENT_UPSTREAM" \
        "applied_upstream=http://127.0.0.1:${CLIENT_LOCAL_PORT}" \
        "recorded_at=$(gp_ts_human)"
    fi
    rm -f "$tmp"
  done <<< "$files"

  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  if [ "$any" = "0" ] && ! gp_dry_run; then
    log_info "nothing to change for $unit"
    return 0
  fi
  systemctl_cmd daemon-reload || true
  if ! systemctl_cmd restart "$unit"; then
    log_err "restarting $unit failed, restoring"
    migrate_restore_all || true
    return 1
  fi
  if ! systemctl_active "$unit"; then
    log_err "$unit is not active after migration, restoring"
    migrate_restore_all || true
    return 1
  fi
  log_ok "$unit migrated"
  return 0
}

migrate_report_manual() {
  # List every component that still points at the upstream but needs a human.
  local raw any=0 component support location detail
  client_state_load 2>/dev/null || true
  [ -n "${CLIENT_UPSTREAM:-}" ] || return 0
  raw="$(migrate_scan_raw)"
  [ -n "$raw" ] || return 0
  while IFS=$'\t' read -r component support location detail; do
    [ -n "$component" ] || continue
    case "$support" in
      manual-review)
        if [ "$any" = "0" ]; then
          log_head "components that still use the remote proxy (manual review)"
          any=1
        fi
        printf '  %-24s %s\n' "$component" "$location"
        printf '  %-24s %s\n' "" "$(printf '%s' "$detail" | cut -c1-110 | gp_redact_url_credentials)"
        ;;
    esac
  done <<< "$raw"
  if [ "$any" = "1" ]; then
    printf '\n  Migrate one explicitly with:  ghproxyctl migrate service <unit>\n'
    printf '  Migrate everything understood: install.sh client --adopt-existing\n'
    printf '  Leave as is:                  nothing (this project will not touch them)\n'
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Orchestration used by `install.sh client --adopt-existing`
# -----------------------------------------------------------------------------
migrate_auto_apply() {
  local rc=0 did=0
  log_head "migrating existing GitHub proxy configuration"

  if migrate_komari_plan; then
    if [ "$KOMARI_HAS_UPSTREAM" = "1" ]; then
      did=1
      migrate_komari_apply || { log_err "Komari migration failed (previous configuration restored)"; rc=1; }
    else
      log_info "Komari is present but does not point at $CLIENT_UPSTREAM; leaving it alone"
    fi
  else
    log_debug "Komari agent not found"
  fi

  if [ "$did" = "0" ]; then
    log_info "no auto-supported systemd component needed migration"
  fi

  migrate_xray_manager_apply || { log_warn "xray-manager migration reported a problem"; rc=1; }
  migrate_git_apply || { log_warn "git migration reported a problem"; rc=1; }

  migrate_environment_plan
  if [ "$ENV_HAS_UPSTREAM" = "1" ]; then
    # NOTE: keep this in its own variable - reusing $rc here would wipe the
    # failure status of an earlier component migration.
    local env_rc=0
    migrate_environment_apply || env_rc=$?
    case "$env_rc" in
      0) : ;;
      3) log_warn "/etc/environment still points at the remote proxy (needs --migrate-global-env)" ;;
      *) log_warn "/etc/environment migration failed"; rc=1 ;;
    esac
  fi

  # Report everything that was left alone (unknown services, global env, ...).
  migrate_report_manual
  return "$rc"
}

migrate_report() {
  local f kind target
  log_head "migration report"
  if ! migrate_record_list | grep -q .; then
    printf 'no migrations recorded on this host\n'
    return 0
  fi
  printf '%-40s %-18s %s\n' "COMPONENT" "KIND" "TARGET"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kind="$(sed -n 's/^kind=//p' "$f" | head -n1)"
    target="$(sed -n 's/^target=//p' "$f" | head -n1)"
    if [ -z "$target" ] && [ "$kind" = "git" ]; then
      target="$(sed -n 's/^user=//p' "$f" | head -n1)@$(sed -n 's/^home=//p' "$f" | head -n1):$(sed -n 's/^key=//p' "$f" | head -n1)"
    fi
    printf '%-40s %-18s %s\n' \
      "$(sed -n 's/^name=//p' "$f" | head -n1)" \
      "$kind" \
      "$target"
  done < <(migrate_record_list)
  printf '\nundo everything with: sudo ghproxyctl migrate restore\n'
  return 0
}
