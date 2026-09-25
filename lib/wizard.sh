#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/wizard.sh
#
# Interactive front end only. Install, update, rollback and health all live in
# the libraries this file calls. A menu path and a CLI path must not diverge.
#
# Non-TTY input is refused unless the caller has already decided this is an
# interactive session (GP_INTERACTIVE=yes) or a test has opted into a pipe
# (VGM_WIZARD_ALLOW_PIPE=1). Automation uses ghproxyctl update, not this menu.
# =============================================================================

if [ -n "${GP_WIZARD_SH:-}" ]; then
  return 0
fi
GP_WIZARD_SH=1

wizard_is_interactive() {
  if [ "${GP_INTERACTIVE:-auto}" = "yes" ]; then
    return 0
  fi
  if [ "${VGM_WIZARD_ALLOW_PIPE:-0}" = "1" ]; then
    return 0
  fi
  gp_is_interactive
}

# wizard_read <prompt> -> one line on stdout. EOF is a failure (caller exits).
wizard_read() {
  local prompt="$1" ans=""
  if ! wizard_is_interactive; then
    die "stdin is not a terminal. Use 'install.sh server|client ...' or 'ghproxyctl update ...'."
    return 1
  fi
  printf '%s' "$prompt" >&2
  IFS= read -r ans || return 1
  printf '%s\n' "$ans"
  return 0
}

# Default is always no. --yes does not answer this: migrations and other
# high-impact choices must not be enabled just because a menu was used.
wizard_confirm_no() {
  local q="$1" ans=""
  if ! wizard_is_interactive; then
    log_info "$q -> no (non-interactive default)"
    return 1
  fi
  printf '%s [y/N] ' "$q" >&2
  IFS= read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

wizard_on_interrupt() {
  GP_ERROR_REPORTED=1
  log_err "interrupted"
  exit 130
}

wizard_hostname() {
  hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown\n'
}

wizard_os_line() {
  local id ver
  id="$(gp_os_id 2>/dev/null || true)"
  ver="$(gp_os_version 2>/dev/null || true)"
  if [ -n "$id" ]; then
    printf '%s %s\n' "$id" "$ver"
  else
    uname -s 2>/dev/null || printf 'unknown\n'
  fi
}

wizard_latest_line() {
  local latest rc=0
  latest="$(update_discover_latest 2>/dev/null)" || rc=$?
  if [ "$rc" != "0" ] || [ -z "$latest" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  printf '%s\n' "$latest"
}

wizard_banner() {
  local state="$1" ver latest mode=""
  ver="$(update_read_current_version 2>/dev/null || printf 'not installed')"
  latest="$(wizard_latest_line)"
  printf '\n%s\n' "=================================================="
  printf '%s\n' "          VPS Gateway Manager"
  printf '%s\n' "=================================================="
  printf '\n'
  printf 'Host          : %s\n' "$(wizard_hostname)"
  printf 'System        : %s\n' "$(wizard_os_line)"
  printf 'State         : %s\n' "$state"
  printf 'Role          : %s\n' "$(gp_detect_label "$state")"
  case "$state" in
    SERVER_FRESH) mode="fresh" ;;
    SERVER_ADOPTED) mode="adopted" ;;
    CLIENT) mode="client" ;;
  esac
  [ -n "$mode" ] && printf 'Mode          : %s\n' "$mode"
  printf 'Installed     : %s\n' "$ver"
  printf 'Latest stable : %s\n' "$latest"
  printf '\n'
  case "$state" in
    SERVER_FRESH|SERVER_ADOPTED)
      if server_state_load 2>/dev/null; then
        printf 'Squid service : %s\n' "${SERVER_SERVICE:-squid}"
        printf 'TLS port      : %s\n' "${SERVER_TLS_PORT:-}"
        printf 'Clients       : %s\n' "$(clients_db_count 2>/dev/null || printf 0)"
      fi
      if have ufw; then
        printf 'Firewall      : ufw present\n'
      else
        printf 'Firewall      : ufw absent\n'
      fi
      ;;
    CLIENT)
      if client_state_load 2>/dev/null; then
        printf 'Local port    : %s\n' "${CLIENT_LOCAL_PORT:-}"
        printf 'Upstream      : %s\n' "${CLIENT_UPSTREAM:-}"
        printf 'Family        : %s\n' "${CLIENT_UPSTREAM_FAMILY:-auto}"
      fi
      ;;
    BROKEN|CONFLICT)
      printf 'Automatic install and update are disabled for this state.\n'
      ;;
  esac
  printf '%s\n' "--------------------------------------------------"
  return 0
}

wizard_doctor() {
  if declare -F cmd_doctor >/dev/null 2>&1; then
    cmd_doctor || true
    return 0
  fi
  log_head "doctor"
  printf 'state             : %s\n' "$(gp_detect_state)"
  printf 'role file         : %s\n' "$(gp_role)"
  printf 'libs              : %s\n' "$(gp_libexec_dir)"
  printf 'cli               : %s\n' "$(gp_bin_dir)/ghproxyctl"
  if [ -e "$(gp_server_conf)" ]; then
    printf 'server.conf       : present\n'
  else
    printf 'server.conf       : absent\n'
  fi
  if [ -e "$(gp_client_conf)" ]; then
    printf 'client.conf       : present\n'
  else
    printf 'client.conf       : absent\n'
  fi
  return 0
}

wizard_offer_migrations() {
  log_info "Local proxy install finished. Migrations stay off unless you ask for each one."
  if wizard_confirm_no "Migrate Komari?"; then
    if declare -F migrate_komari_apply >/dev/null 2>&1; then
      migrate_komari_apply || log_warn "Komari migration reported a problem"
    fi
  fi
  if wizard_confirm_no "Migrate xray-manager?"; then
    if declare -F migrate_xray_manager_apply >/dev/null 2>&1; then
      migrate_xray_manager_apply || log_warn "xray-manager migration reported a problem"
    fi
  fi
  if wizard_confirm_no "Configure GitHub-only git proxying?"; then
    if declare -F migrate_git_apply >/dev/null 2>&1; then
      migrate_git_apply || log_warn "git migration reported a problem"
    fi
  fi
  if wizard_confirm_no "Migrate /etc/environment (global, affects every process)?"; then
    CLIENT_MIGRATE_GLOBAL_ENV=1
    export CLIENT_MIGRATE_GLOBAL_ENV
    log_warn "/etc/environment migration was requested; it is not applied by the menu in v0.6.0. Use the documented migrate command if you still want it."
  fi
  return 0
}

wizard_foreign_proxy() {
  local main
  main="$(gp_squid_conf_dir)/squid.conf"
  [ -e "$main" ] || return 1
  grep -q "managed by $GP_PROJECT_NAME" "$main" 2>/dev/null && return 1
  return 0
}

wizard_install_server() {
  local choice domain port saved_dry
  if wizard_foreign_proxy; then
    log_warn "Detected an existing Squid configuration that this project did not create."
    log_warn "A fresh install will not overwrite it."
    printf '%s\n' "1) View adopted-mode read-only check"
    printf '%s\n' "0) Exit"
    choice="$(wizard_read "Select: ")" || return 0
    case "$choice" in
      1)
        saved_dry="${GP_DRY_RUN:-0}"
        GP_DRY_RUN=1
        export GP_DRY_RUN
        server_adopt_run 1 || log_warn "adopted read-only check reported a problem"
        GP_DRY_RUN="$saved_dry"
        export GP_DRY_RUN
        ;;
      0|q|Q|"") return 0 ;;
      *) log_err "invalid selection" ;;
    esac
    return 0
  fi
  domain="$(wizard_read "Server domain: ")" || return 1
  [ -n "$domain" ] || { die "a domain is required"; return 1; }
  port="$(wizard_read "TLS port [8443]: ")" || port=""
  [ -n "$port" ] || port="8443"
  SERVER_DOMAIN="$domain"
  SERVER_TLS_PORT="$port"
  export SERVER_DOMAIN SERVER_TLS_PORT
  if ! wizard_confirm_no "Install a fresh gateway server for $domain:$port?"; then
    log_info "server install cancelled"
    return 0
  fi
  server_fresh_install
}

wizard_install_client() {
  local upstream family port ca rc=0
  upstream="$(wizard_read "Upstream URL: ")" || return 1
  [ -n "$upstream" ] || { die "an upstream URL is required"; return 1; }
  family="$(wizard_read "Upstream family [auto]: ")" || family=""
  [ -n "$family" ] || family="auto"
  port="$(wizard_read "Local port [3129]: ")" || port=""
  [ -n "$port" ] || port="3129"
  ca="$(wizard_read "CA path [default]: ")" || ca=""
  case "$family" in
    auto|4|6) ;;
    *) die "upstream family must be auto, 4 or 6"; return 1 ;;
  esac
  CLIENT_UPSTREAM="$upstream"
  CLIENT_UPSTREAM_FAMILY="$family"
  CLIENT_LOCAL_PORT="$port"
  CLIENT_MIGRATE_GLOBAL_ENV=0
  export CLIENT_UPSTREAM CLIENT_UPSTREAM_FAMILY CLIENT_LOCAL_PORT CLIENT_MIGRATE_GLOBAL_ENV
  if [ -n "$ca" ] && [ "$ca" != "default" ]; then
    CLIENT_UPSTREAM_CA="$ca"
    export CLIENT_UPSTREAM_CA
  fi
  if ! wizard_confirm_no "Install the local proxy first, and do not migrate anything yet?"; then
    log_info "client install cancelled"
    return 0
  fi
  if client_install_run; then
    rc=0
  else
    rc=$?
    log_err "client install failed; migrations were not offered"
    return "$rc"
  fi
  wizard_offer_migrations
  return 0
}

wizard_uninstalled_menu() {
  local choice
  wizard_banner UNINSTALLED
  printf '%s\n' "Choose a role. An already-installed host is never shown this menu."
  printf '%s\n' "1) Gateway Server"
  printf '%s\n' "2) Client"
  printf '%s\n' "3) Environment diagnosis"
  printf '%s\n' "0) Exit"
  choice="$(wizard_read "Select: ")" || return 0
  case "$choice" in
    1) wizard_install_server || true ;;
    2) wizard_install_client || true ;;
    3) wizard_doctor || true ;;
    0|q|Q) return 0 ;;
    "") log_info "blank selection" ;;
    *) log_err "invalid selection: $choice" ;;
  esac
  return 0
}

wizard_installed_menu() {
  local state="$1" choice
  while true; do
    wizard_banner "$state"
    printf '%s\n' "1) Status"
    printf '%s\n' "2) Health check"
    printf '%s\n' "3) Update management tool"
    printf '%s\n' "4) Version / release information"
    printf '%s\n' "5) Roll back management tool"
    printf '%s\n' "6) Doctor"
    printf '%s\n' "7) Update history / logs"
    printf '%s\n' "0) Exit"
    choice="$(wizard_read "Select: ")" || return 0
    case "$choice" in
      1) gp_status || true ;;
      2) gp_test || true ;;
      3) update_run || true ;;
      4) update_check || true ;;
      5) update_list_backups; log_info "To restore one, run: ghproxyctl update rollback --to <version>" ;;
      6) wizard_doctor || true ;;
      7) update_history_show || true ;;
      0|q|Q) return 0 ;;
      "") log_info "blank selection" ;;
      *) log_err "invalid selection: ${choice}" ;;
    esac
  done
}

wizard_recovery_menu() {
  local choice phase
  phase="$(update_txn_get phase)"
  printf '\n%s\n' "Detected an interrupted update."
  printf 'Previous version: %s\n' "$(update_txn_get from_version)"
  printf 'Target version:   %s\n' "$(update_txn_get to_version)"
  printf 'Stopped at:       %s\n' "$phase"
  printf '%s\n' "1) Restore previous known-good version"
  printf '%s\n' "2) Inspect details"
  printf '%s\n' "0) Exit"
  choice="$(wizard_read "Select: ")" || return 0
  case "$choice" in
    1) update_recover || true ;;
    2)
      printf 'id: %s\n' "$(update_txn_get id)"
      printf 'phase: %s\n' "$phase"
      printf 'backup: %s\n' "$(update_txn_get backup)"
      printf 'log dir: %s\n' "$(update_log_dir)"
      ;;
    0|q|Q) return 0 ;;
    *) log_err "invalid selection" ;;
  esac
  return 0
}

wizard_broken_menu() {
  local state="$1" choice
  wizard_banner "$state"
  printf '%s\n' "1) Doctor"
  printf '%s\n' "2) Inspect detection"
  printf '%s\n' "0) Exit"
  printf '%s\n' "Install and update are disabled until the state is consistent."
  choice="$(wizard_read "Select: ")" || return 0
  case "$choice" in
    1|2) wizard_doctor || true ;;
    0|q|Q) return 0 ;;
    *) log_err "invalid selection; refusing to install over $state" ;;
  esac
  return 0
}

wizard_main() {
  local state
  if ! wizard_is_interactive; then
    die "stdin is not a terminal. Use 'install.sh server|client ...' or 'ghproxyctl update ...'."
    return 1
  fi
  trap 'wizard_on_interrupt' INT
  if update_interrupted; then
    wizard_recovery_menu
    return $?
  fi
  state="$(gp_detect_state)"
  case "$state" in
    UNINSTALLED) wizard_uninstalled_menu ;;
    SERVER_FRESH|SERVER_ADOPTED|CLIENT) wizard_installed_menu "$state" ;;
    BROKEN|CONFLICT) wizard_broken_menu "$state" ;;
    *) wizard_broken_menu BROKEN ;;
  esac
}
