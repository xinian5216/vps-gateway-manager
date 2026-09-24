#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/detect.sh
#
# Read-only install-state detection. Never mutates, never guesses a role from
# "Squid happens to be installed", and never treats a lone ghproxyctl binary as
# a successful install.
#
# Results:
#   UNINSTALLED SERVER_FRESH SERVER_ADOPTED CLIENT BROKEN CONFLICT
# =============================================================================

if [ -n "${GP_DETECT_SH:-}" ]; then
  return 0
fi
GP_DETECT_SH=1

# gp_detect_toolchain_present -> 0 when the installed library tree looks real
gp_detect_toolchain_present() {
  local dest
  dest="$(gp_libexec_dir)"
  [ -r "$dest/lib/common.sh" ] && [ -r "$dest/VERSION" ]
}

# gp_detect_cli_present -> 0 when the installed CLI exists and is executable
gp_detect_cli_present() {
  [ -x "$(gp_bin_dir)/ghproxyctl" ] || [ -f "$(gp_bin_dir)/ghproxyctl" ]
}

# gp_detect_project_debris -> 0 when any project-owned state or toolchain exists
gp_detect_project_debris() {
  [ -e "$(gp_role_file)" ] && return 0
  [ -e "$(gp_server_conf)" ] && return 0
  [ -e "$(gp_client_conf)" ] && return 0
  [ -e "$(gp_clients_db)" ] && return 0
  [ -e "$(gp_state_dir)/version" ] && return 0
  [ -d "$(gp_libexec_dir)" ] && return 0
  [ -e "$(gp_bin_dir)/ghproxyctl" ] && return 0
  return 1
}

# gp_detect_state -> one token on stdout. Always returns 0.
# Ambiguity is a state, not a guess.
gp_detect_state() {
  local role server_conf client_conf mode
  role="$(gp_role)"
  server_conf="$(gp_server_conf)"
  client_conf="$(gp_client_conf)"

  # Contradictory evidence is never resolved by picking a role.
  if [ -e "$server_conf" ] && [ -e "$client_conf" ]; then
    printf '%s\n' CONFLICT
    return 0
  fi
  case "$role" in
    server)
      if [ -e "$client_conf" ] && [ ! -e "$server_conf" ]; then
        printf '%s\n' CONFLICT
        return 0
      fi
      ;;
    client)
      if [ -e "$server_conf" ] && [ ! -e "$client_conf" ]; then
        printf '%s\n' CONFLICT
        return 0
      fi
      ;;
    "")
      ;;
    *)
      # A role that is neither server nor client is never treated as uninstalled.
      printf '%s\n' BROKEN
      return 0
      ;;
  esac

  if [ -z "$role" ]; then
    if gp_detect_project_debris; then
      printf '%s\n' BROKEN
    else
      printf '%s\n' UNINSTALLED
    fi
    return 0
  fi

  # A role without a readable matching state file, or without the toolchain
  # that would actually run, is partial. Do not offer install-over or update.
  if ! gp_detect_toolchain_present || ! gp_detect_cli_present; then
    printf '%s\n' BROKEN
    return 0
  fi

  case "$role" in
    server)
      [ -r "$server_conf" ] || { printf '%s\n' BROKEN; return 0; }
      mode="$(conf_get "$server_conf" mode '')"
      case "$mode" in
        adopted) printf '%s\n' SERVER_ADOPTED ;;
        fresh|"") printf '%s\n' SERVER_FRESH ;;
        *) printf '%s\n' BROKEN ;;
      esac
      ;;
    client)
      [ -r "$client_conf" ] || { printf '%s\n' BROKEN; return 0; }
      printf '%s\n' CLIENT
      ;;
  esac
  return 0
}

# gp_detect_allows_mutation <state> -> 0 only for a consistent installed role
gp_detect_allows_mutation() {
  case "$1" in
    SERVER_FRESH|SERVER_ADOPTED|CLIENT) return 0 ;;
    *) return 1 ;;
  esac
}

# Human label for menus. Never invents a role the detector did not return.
gp_detect_label() {
  case "$1" in
    UNINSTALLED)    printf '%s\n' "not installed" ;;
    SERVER_FRESH)   printf '%s\n' "Server" ;;
    SERVER_ADOPTED) printf '%s\n' "Server" ;;
    CLIENT)         printf '%s\n' "Client" ;;
    BROKEN)         printf '%s\n' "BROKEN/PARTIAL" ;;
    CONFLICT)       printf '%s\n' "CONFLICT" ;;
    *)              printf '%s\n' "unknown" ;;
  esac
}
