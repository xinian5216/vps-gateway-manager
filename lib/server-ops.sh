#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/server-ops.sh
#
# Server operations that change state:
#   * fresh install of a dedicated GitHub egress proxy
#   * non-destructive adoption of an existing production proxy
#   * client ACL + firewall management (client add/remove/list)
#   * server uninstall / unmanage
#
# Everything here is transactional (lib/txn.sh) and ends with a health check.
# =============================================================================

if [ -n "${GP_SERVER_OPS_SH:-}" ]; then
  return 0
fi
GP_SERVER_OPS_SH=1

# Defaults for a fresh install; adoption overrides most of these from discovery.
server_set_defaults() {
  SERVER_MODE="${SERVER_MODE:-fresh}"
  SERVER_DOMAIN="${SERVER_DOMAIN:-}"
  SERVER_TLS_PORT="${SERVER_TLS_PORT:-8443}"
  SERVER_LOOPBACK_PORT="${SERVER_LOOPBACK_PORT:-3128}"
  SERVER_SERVICE="${SERVER_SERVICE:-squid}"
  SERVER_MAIN_CONF="${SERVER_MAIN_CONF:-$(gp_squid_conf_dir)/squid.conf}"
  SERVER_CLIENT_ACL_FILE="${SERVER_CLIENT_ACL_FILE:-$(gp_squid_conf_d)/00-vps-gateway-manager-clients.conf}"
  SERVER_SOURCE_ACL_FILE="${SERVER_SOURCE_ACL_FILE:-$(gp_squid_conf_d)/github-whitelist.conf}"
  SERVER_DOMAIN_ACL_NAME="${SERVER_DOMAIN_ACL_NAME:-gsp_github}"
  SERVER_DOMAINS_FILE="$(gp_domains_file)"
  SERVER_TLS_DIR="${SERVER_TLS_DIR:-$(gp_squid_conf_dir)/tls}"
  SERVER_CERTBOT_HOOK="${SERVER_CERTBOT_HOOK:-$(gp_reload_hooks)/reload-squid-tls.sh}"
  SERVER_UFW_MANAGED="${SERVER_UFW_MANAGED:-0}"
  SERVER_ADMIN_CONTACT="${SERVER_ADMIN_CONTACT:-root@$(hostname 2>/dev/null || printf 'localhost')}"
  SERVER_REPO_URL="${SERVER_REPO_URL:-${VGM_REPO_URL:-https://github.com/xinian5216/vps-gateway-manager}}"
  SERVER_REPO_REF="${SERVER_REPO_REF:-${VGM_REF:-main}}"
  return 0
}

# -----------------------------------------------------------------------------
# Pre-flight validation of a candidate configuration
# -----------------------------------------------------------------------------
# Build a temporary main config that contains the candidate file exactly where
# the real file will live, so `squid -k parse` validates the *future* state
# before anything is replaced.
server_build_candidate_main() {
  # server_build_candidate_main <main-conf> <candidate-file> <final-path>
  local main="$1" candidate="$2" final="$3" out dir glob_line f substituted=0
  local -a globbed=()
  dir="$(dirname "$main")"
  out="$dir/.gsp-candidate-main.$$.conf"
  : > "$out" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      include[[:space:]]*)
        glob_line="$(trim "${line#include}")"
        glob_line="${glob_line%\"}"; glob_line="${glob_line#\"}"
        case "$glob_line" in
          *'*'*)
            globbed=()
            while IFS= read -r f; do [ -n "$f" ] && globbed+=("$f"); done < <(
              find "$(dirname "$glob_line")" -maxdepth 1 -name "$(basename "$glob_line")" 2>/dev/null | sort
            )
            for f in "${globbed[@]}"; do
              if [ "$f" = "$final" ]; then
                printf 'include %s\n' "$candidate" >> "$out"; substituted=1
              else
                printf 'include %s\n' "$f" >> "$out"
              fi
            done
            if [ "$substituted" = "0" ]; then
              printf 'include %s\n' "$candidate" >> "$out"; substituted=1
            fi
            ;;
          *)
            if [ "$glob_line" = "$final" ] || [ "$(realpath -m "$glob_line" 2>/dev/null)" = "$(realpath -m "$final" 2>/dev/null)" ]; then
              printf 'include %s\n' "$candidate" >> "$out"; substituted=1
            else
              printf 'include %s\n' "$glob_line" >> "$out"
            fi
            ;;
        esac
        ;;
      *) printf '%s\n' "$line" >> "$out" ;;
    esac
  done < "$main"
  if [ "$substituted" = "0" ]; then
    log_warn "could not locate the include point for $final in $main"
    log_warn "falling back to validating the fragment on its own (weaker check)"
    printf 'include %s\n' "$candidate" >> "$out"
  fi
  printf '%s\n' "$out"
  return 0
}

# server_validate_candidate <candidate-file> <final-path> [main-conf]
server_validate_candidate() {
  local candidate="$1" final="$2" main="${3:-$SERVER_MAIN_CONF}" tmp_main rc=0 log
  [ -r "$candidate" ] || { die "candidate config not readable: $candidate"; return 1; }
  if [ -z "$main" ] || [ ! -r "$main" ]; then
    log_warn "no main config available; parsing the fragment on its own"
    squid_parse "$candidate" || return 1
    return 0
  fi
  tmp_main="$(server_build_candidate_main "$main" "$candidate" "$final")" || return 1
  log="$(mktemp)"
  if ! squid_parse "$tmp_main" "$log"; then
    rc=1
    log_err "the candidate configuration was rejected; nothing has been changed"
    if txn_is_active && [ -n "${TXN_DIR:-}" ] && [ -d "${TXN_DIR:-}" ]; then
      cp -f "$log" "$TXN_DIR/parse-failure.log" 2>/dev/null || true
    fi
  fi
  rm -f "$tmp_main" "$log"
  return "$rc"
}

# server_apply_clients_file <content-file> [reason] [verify-token]
# Returns 0 when applied (or nothing to do), non-zero on failure.
# <verify-token> is a string that must appear in the daemon's *effective*
# configuration after the reload (e.g. the new ACL name); when the cache manager
# cannot be queried the verification is skipped rather than failed.
server_apply_clients_file() {
  local content="$1" reason="${2:-update client ACLs}" verify_token="${3:-}" rc=0
  txn_require_active || return 1
  if gp_dry_run; then
    log_dry "validate the candidate client config in context (squid -k parse)"
    log_dry "install the validated config -> $SERVER_CLIENT_ACL_FILE"
    log_dry "reload $SERVER_SERVICE, verify the running configuration and re-run the health checks"
    return 0
  fi
  # No-op detection: identical ACL body means no reload at all.
  if [ -r "$SERVER_CLIENT_ACL_FILE" ] && \
     [ "$(server_acl_body "$content")" = "$(server_acl_body "$SERVER_CLIENT_ACL_FILE")" ]; then
    log_info "client ACL configuration already up to date (no reload needed)"
    return 3
  fi
  server_validate_candidate "$content" "$SERVER_CLIENT_ACL_FILE" || return 1
  txn_install_file "$content" "$SERVER_CLIENT_ACL_FILE" 0644 || return 1
  record_managed_file "$SERVER_CLIENT_ACL_FILE" modified
  squid_reload "$SERVER_SERVICE" "$SERVER_MAIN_CONF" || { log_err "squid reload failed"; return 1; }
  txn_service "$SERVER_SERVICE" reload

  # Did the daemon really pick the change up?
  # A token prefixed with '!' must be ABSENT (used when removing a client).
  if [ -n "$verify_token" ]; then
    local want_absent=0 token="$verify_token" vrc=0 i=0
    case "$token" in '!'*) want_absent=1; token="${token#!}" ;; esac
    while [ "$i" -lt 10 ]; do
      vrc=0
      squid_running_config_contains "$token" || vrc=$?
      if [ "$want_absent" = "1" ]; then
        [ "$vrc" -eq 1 ] && break
      else
        [ "$vrc" -ne 1 ] && break
      fi
      sleep 1; i=$((i+1))
    done
    if [ "$want_absent" = "1" ]; then
      case "$vrc" in
        0) log_err "the reload did not take effect: '$token' is still in the running configuration"
           log_err "the daemon is still serving the previous configuration - not keeping this change"
           return 1 ;;
        1) log_ok "the running configuration no longer contains $token" ;;
        *) log_debug "could not read the running configuration; skipping the reload verification" ;;
      esac
    else
      case "$vrc" in
        0) log_ok "the running configuration reflects the change ($token)" ;;
        1) log_err "the reload did not take effect: '$token' is missing from the running configuration"
           log_err "the daemon is still serving the previous configuration - not keeping this change"
           return 1 ;;
        *) log_debug "could not read the running configuration; skipping the reload verification" ;;
      esac
    fi
  fi

  squid_wait_healthy "$SERVER_SERVICE" 15 || return 1
  if declare -F hc_server_quick >/dev/null 2>&1; then
    hc_reset
    if ! hc_server_quick; then
      # Show the operator which check failed, not just that one did.
      hc_print >&2
      log_err "health check failed after: $reason"
      return 1
    fi
  fi
  return 0
}

# Configuration body without the generated header (comments/blank lines).
server_acl_body() {
  local file="$1"
  [ -r "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

# Wrapper for callers: "already up to date" (3) is a success as well.
server_apply_clients_file_or_fail() {
  local rc=0
  server_apply_clients_file "$@" || rc=$?
  case "$rc" in
    0|3) return 0 ;;
    *)   return "$rc" ;;
  esac
}

# txn_install_file, but skip the write when the body is already identical.
# Returns 3 when nothing needed to change.
server_install_if_changed() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if [ -r "$dest" ] && cmp -s <(grep -vE '^[[:space:]]*(#|$)' "$src" || true) \
                               <(grep -vE '^[[:space:]]*(#|$)' "$dest" || true); then
    log_info "$dest is already up to date (no write, no reload)"
    return 3
  fi
  txn_install_file "$src" "$dest" "$mode"
}

# -----------------------------------------------------------------------------
# Pre-flight / packages
# -----------------------------------------------------------------------------
server_preflight_ports() {
  local port owner
  for port in "$SERVER_TLS_PORT" "$SERVER_LOOPBACK_PORT"; do
    if port_in_use "$port"; then
      owner="$(listener_owner "$port")"
      case "$owner" in
        *squid*) log_info "port $port is already served by squid (idempotent re-run)" ; continue ;;
      esac
      log_err "port $port is already in use by another service: ${owner:-unknown}"
      log_err "refusing to take over a port that belongs to another process"
      return 1
    fi
  done
  return 0
}

server_preflight_neighbours() {
  local unit state
  for unit in xray x-ui 3x-ui; do
    if have systemctl && systemctl list-unit-files "$unit.service" >/dev/null 2>&1; then
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
      log_info "neighbour service $unit is ${state:-unknown} (left untouched by this project)"
    fi
  done
  return 0
}

server_install_squid_pkg() {
  local pkg="${SERVER_SQUID_PKG:-squid-openssl}" out rc=0
  if ! have apt-get; then
    die "apt-get not found: install a Squid build with TLS support manually, then re-run with --adopt-existing"
    return 1
  fi
  if squid_pkg_installed "$pkg"; then
    log_ok "package already installed: $pkg $(squid_pkg_version "$pkg")"
    return 0
  fi
  log_info "installing $pkg"
  if gp_dry_run; then
    log_dry "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg"
    return 0
  fi
  apt-get update -qq || log_warn "apt-get update failed; continuing with the existing package lists"
  out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$pkg" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_err "failed to install $pkg"
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /' >&2
    log_err "refusing to silently substitute a different proxy implementation."
    log_err "Install $pkg manually (or pass --squid-pkg) and re-run."
    return 1
  fi
  log_ok "installed $pkg"
  return 0
}

server_install_squid_if_needed() {
  if squid_detect && squid_check_min_version >/dev/null 2>&1; then
    log_ok "using existing Squid ${SQUID_VERSION} (flavor: ${SQUID_FLAVOR})"
  else
    server_install_squid_pkg || return 1
    if gp_dry_run; then
      log_dry "re-detect squid after installing the package"
    else
      squid_detect || { log_err "squid still not available after installation"; return 1; }
      squid_check_min_version || return 1
    fi
  fi
  squid_detect_unit || true
  return 0
}

server_obtain_certificate() {
  local domain creds email args=() rc=0
  domain="${SERVER_DOMAIN}"
  creds="${SERVER_CF_CREDENTIALS:-}"
  email="${SERVER_EMAIL:-}"
  if [ -r "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
    log_ok "certificate already present for $domain"
    return 0
  fi
  if [ -z "$creds" ]; then
    die "no certificate for $domain and no --cf-credentials given; cannot obtain one"
    return 1
  fi
  gp_assert_root_only_secret "$creds" || return 1
  if ! have certbot; then
    log_info "installing certbot and the Cloudflare DNS plugin"
    if gp_dry_run; then
      log_dry "apt-get install -y certbot python3-certbot-dns-cloudflare"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null 2>&1 \
        || { log_err "failed to install certbot packages"; return 1; }
    fi
  fi
  args=(certonly --non-interactive --agree-tos --dns-cloudflare
        --dns-cloudflare-credentials "$creds"
        --dns-cloudflare-propagation-seconds "${SERVER_CF_PROPAGATION:-30}"
        -d "$domain" --keep-until-expiring)
  if [ -n "$email" ]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
  log_info "requesting a Let's Encrypt certificate for $domain via Cloudflare DNS-01"
  if gp_dry_run; then
    log_dry "certbot ${args[*]}"
    return 0
  fi
  certbot "${args[@]}" >/dev/null 2>&1 || rc=1
  if [ "$rc" -ne 0 ] || [ ! -r "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
    log_err "certificate request failed; aborting (nothing else was changed)"
    return 1
  fi
  log_ok "certificate obtained for $domain"
  return 0
}

# -----------------------------------------------------------------------------
# Fresh install
# -----------------------------------------------------------------------------
server_fresh_install() {
  local rc=0 tmp_clients tmp_main cert_src main
  log_head "vps-gateway-manager :: fresh server install"
  server_set_defaults

  if [ -z "$SERVER_DOMAIN" ]; then
    die "--domain is required for a fresh install, e.g. --domain gh.example.com"
    return 1
  fi
  validate_hostname_strict "$SERVER_DOMAIN" || { die "invalid --domain '$SERVER_DOMAIN'"; return 1; }
  case "$SERVER_DOMAIN" in
    example.com|*.example.com|example.org|*.example.org|example.net|*.example.net|example|*.example)
      die "--domain '$SERVER_DOMAIN' is the placeholder from the documentation - use your real hostname"
      return 1
      ;;
  esac

  main="$SERVER_MAIN_CONF"
  if [ -e "$main" ] && ! grep -q "managed by $GP_PROJECT_NAME" "$main" 2>/dev/null; then
    log_err "$main already exists and was not created by $GP_PROJECT_NAME."
    if [ "${SERVER_ALLOW_OVERWRITE_MAIN:-0}" != "1" ]; then
      log_err "This host already runs a proxy. Use:"
      log_err "    install.sh server --adopt-existing        # take over without rewriting anything"
      log_err "or pass --force-replace-main-config if you really want to replace that file."
      return 1
    fi
    log_warn "--force-replace-main-config given: the existing file will be backed up first"
  fi
  if squid_detect >/dev/null 2>&1 && squid_detect_unit && systemctl_active "$SQUID_UNIT"; then
    if ! grep -q "managed by $GP_PROJECT_NAME" "$main" 2>/dev/null; then
      die "$SQUID_UNIT is already running with a foreign configuration - use --adopt-existing"
      return 1
    fi
  fi
  server_preflight_ports || return 1
  server_preflight_neighbours

  txn_begin "fresh server install (${SERVER_DOMAIN}:${SERVER_TLS_PORT})" || return 1
  trap 'txn_rollback "unexpected error during fresh install"' ERR

  server_install_squid_if_needed || { txn_rollback "squid unavailable"; return 1; }
  if [ -n "${SQUID_UNIT:-}" ]; then SERVER_SERVICE="$SQUID_UNIT"; fi

  txn_mkdir "$(gp_state_dir)" 0700 || { txn_rollback "state dir"; return 1; }
  txn_mkdir "$(gp_state_dir)/state" 0700 || { txn_rollback "state dir"; return 1; }
  if ! gp_dry_run; then
    printf 'server\n' | gp_atomic_write "$(gp_role_file)" 0600
    printf '%s\n' "${VGM_VERSION:-unknown}" | gp_atomic_write "$(gp_state_dir)/version" 0644
  fi

  domains_seed_from_template || { txn_rollback "destination list"; return 1; }
  record_managed_file "$(gp_domains_file)" created

  # TLS material: reuse an existing certificate when there is one.
  cert_src="${SERVER_CERT_SOURCE:-/etc/letsencrypt/live/${SERVER_DOMAIN}}"
  SERVER_CERT_LIVE_DIR="$cert_src"
  if [ ! -r "$cert_src/fullchain.pem" ] || [ ! -r "$cert_src/privkey.pem" ]; then
    if [ "${SERVER_OBTAIN_CERT:-1}" = "1" ]; then
      server_obtain_certificate || { txn_rollback "certificate"; return 1; }
    else
      log_warn "no certificate at $cert_src and certificate issuance disabled; expecting it to appear later"
    fi
  fi
  server_tls_dir_prepare "$SERVER_TLS_DIR" || { txn_rollback "tls dir"; return 1; }
  if [ -r "$cert_src/fullchain.pem" ]; then
    server_install_tls_material "$cert_src" "$SERVER_TLS_DIR" || { txn_rollback "tls material"; return 1; }
  fi

  # Certbot deploy hook keeps renewals flowing into the Squid TLS directory.
  if [ -d "$(gp_p /etc/letsencrypt)" ]; then
    txn_mkdir "$(gp_reload_hooks)" 0755 || true
    server_install_deploy_hook "$SERVER_CERTBOT_HOOK" "$SERVER_DOMAIN" "$SERVER_TLS_DIR" "$SERVER_SERVICE" \
      || { txn_rollback "certbot hook"; return 1; }
  else
    log_warn "no /etc/letsencrypt on this host; skipping the certificate deploy hook"
  fi

  # Managed client file + main configuration.
  tmp_clients="$(mktemp)"
  server_render_clients_file 0 > "$tmp_clients" || { rm -f "$tmp_clients"; txn_rollback "render clients"; return 1; }
  tmp_main="$(mktemp)"
  server_render_main_config > "$tmp_main" || { rm -f "$tmp_main" "$tmp_clients"; txn_rollback "render main"; return 1; }

  # Validate both together, exactly as they will be loaded.
  if ! gp_dry_run; then
    local probe_dir candidate_probe
    probe_dir="$(mktemp -d)"
    cp -f "$tmp_clients" "$probe_dir/candidate.conf"
    cp -f "$tmp_main" "$probe_dir/main.conf"
    if ! squid_parse "$probe_dir/main.conf" 2>/dev/null; then
      rm -rf "$probe_dir" "$tmp_main" "$tmp_clients"
      log_err "the generated configuration does not parse; aborting before touching the running system"
      txn_rollback "generated config invalid"
      return 1
    fi
    rm -rf "$probe_dir"
    candidate_probe=""
    : "$candidate_probe"
  else
    log_dry "validate the generated configuration with squid -k parse"
  fi

  local irc=0
  server_install_if_changed "$tmp_clients" "$SERVER_CLIENT_ACL_FILE" 0644 || irc=$?
  if [ "$irc" -ne 0 ] && [ "$irc" -ne 3 ]; then
    rm -f "$tmp_main" "$tmp_clients"; txn_rollback "install clients"; return 1
  fi
  irc=0
  server_install_if_changed "$tmp_main" "$SERVER_MAIN_CONF" 0644 || irc=$?
  if [ "$irc" -ne 0 ] && [ "$irc" -ne 3 ]; then
    rm -f "$tmp_main" "$tmp_clients"; txn_rollback "install main"; return 1
  fi
  rm -f "$tmp_main" "$tmp_clients"
  record_managed_file "$SERVER_CLIENT_ACL_FILE" created
  record_managed_file "$SERVER_MAIN_CONF" created

  if gp_dry_run; then
    log_dry "validate $SERVER_MAIN_CONF with squid -k parse"
  else
    squid_parse "$SERVER_MAIN_CONF" || { txn_rollback "config invalid"; return 1; }
  fi
  # Firewall: enable management, snapshot the state for the audit trail.
  fw_detect
  if [ "$FW_TYPE" = "ufw" ] && [ "$FW_ACTIVE" = "1" ]; then
    SERVER_UFW_MANAGED=1
    if ! gp_dry_run && [ -d "${TXN_DIR:-}" ]; then
      fw_capture_state "$TXN_DIR/ufw-before.txt" || true
    fi
    if grep -qE "^[[:space:]]*ALLOW[[:space:]]+(Anywhere|Anywhere \(v6\))[[:space:]]+${SERVER_TLS_PORT}" <(ufw status 2>/dev/null || true); then
      log_warn "ufw already allows port ${SERVER_TLS_PORT} from anywhere; Squid ACLs remain the authoritative gate"
      log_warn "consider restricting that rule - this project will not remove rules it did not create"
    fi
  else
    log_info "ufw is not active (backend: $FW_TYPE); access control relies on Squid ACLs"
  fi

  server_state_write
  record_managed_file "$(gp_server_conf)" created

  # Start the service.
  if [ -n "$SERVER_SERVICE" ] && have systemctl; then
    if systemctl_active "$SERVER_SERVICE"; then
      txn_service "$SERVER_SERVICE" restart
      squid_restart "$SERVER_SERVICE" || { txn_rollback "restart failed"; return 1; }
    else
      txn_service "$SERVER_SERVICE" start
      systemctl_cmd start "$SERVER_SERVICE" || { txn_rollback "start failed"; return 1; }
    fi
    squid_wait_healthy "$SERVER_SERVICE" 20 || { txn_rollback "service unhealthy"; return 1; }
  else
    log_warn "no systemd unit detected for squid; start it manually, then run 'ghproxyctl test'"
  fi

  if gp_dry_run; then
    log_dry "run the full health check suite (TLS, GitHub API/Raw/Release, deny path, listeners)"
  elif declare -F hc_server_full >/dev/null 2>&1; then
    if ! hc_server_full; then
      log_err "health checks failed; rolling back the whole install"
      txn_rollback "health check failure"
      return 1
    fi
  fi

  txn_commit success || return 1
  trap - ERR
  txn_prune_backups 20
  log_ok "server install complete"
  return "$rc"
}

# -----------------------------------------------------------------------------
# Adoption of an existing production proxy (read-only analysis)
# -----------------------------------------------------------------------------
# Globals filled by server_adopt_analyze:
#   ADOPT_OK, ADOPT_MAIN_CONF, ADOPT_INCLUDES, ADOPT_SOURCE_ACL_FILE,
#   ADOPT_DOMAIN_ACL_NAME, ADOPT_DOMAIN_ACL_FILE, ADOPT_TLS_CERT, ADOPT_TLS_KEY,
#   ADOPT_TLS_DIR, ADOPT_HOOK, ADOPT_LOOPBACK_PORT, ADOPT_TLS_PORT,
#   ADOPT_IMPORT_CLIENTS (tsv), ADOPT_IMPORT_DOMAINS (lines),
#   ADOPT_FINDINGS (lines), ADOPT_MANAGED_OK
server_adopt_analyze() {
  local main includes f entry
  ADOPT_OK=0
  ADOPT_MAIN_CONF=""
  ADOPT_INCLUDES=""
  ADOPT_SOURCE_ACL_FILE=""
  ADOPT_DOMAIN_ACL_NAME=""
  ADOPT_DOMAIN_ACL_FILE=""
  ADOPT_TLS_CERT=""
  ADOPT_TLS_KEY=""
  ADOPT_TLS_DIR=""
  ADOPT_HOOK=""
  ADOPT_LOOPBACK_PORT=""
  ADOPT_TLS_PORT=""
  ADOPT_IMPORT_CLIENTS=""
  ADOPT_IMPORT_DOMAINS=""
  ADOPT_FINDINGS=""
  ADOPT_MANAGED_OK=1

  if ! squid_detect; then
    ADOPT_FINDINGS="${ADOPT_FINDINGS}
- Squid is not installed on this host: nothing to adopt (use a fresh install instead)"
    return 1
  fi
  squid_detect_unit || true
  main="$(squid_main_config "${SQUID_UNIT:-}")"
  ADOPT_MAIN_CONF="$main"
  if [ ! -r "$main" ]; then
    ADOPT_FINDINGS="${ADOPT_FINDINGS}
- main Squid config is not readable: $main"
    return 1
  fi
  includes="$(squid_conf_includes "$main")"
  ADOPT_INCLUDES="$includes"

  # TLS listener(s) and certificate paths
  while IFS= read -r entry; do
    case "$entry" in
      http_port\ *|https_port\ *)
        if printf '%s' "$entry" | grep -q 'tls-cert='; then
          ADOPT_TLS_PORT="$(printf '%s' "$entry" | awk '{print $2}' | sed 's/^[^:]*://')"
          ADOPT_TLS_CERT="$(printf '%s' "$entry" | sed -n 's/.*tls-cert=\([^ ]*\).*/\1/p')"
          ADOPT_TLS_KEY="$(printf '%s' "$entry" | sed -n 's/.*tls-key=\([^ ]*\).*/\1/p')"
        fi
        case "$entry" in
          *127.0.0.1:*|*::1:*) ADOPT_LOOPBACK_PORT="$(printf '%s' "$entry" | awk '{print $2}' | sed 's/.*://')" ;;
        esac
        ;;
    esac
  done < <(squid_config_listeners "$main")
  if [ -z "$ADOPT_TLS_PORT" ]; then
    ADOPT_MANAGED_OK=0
    ADOPT_FINDINGS="${ADOPT_FINDINGS}
- no TLS listener (http_port ... tls-cert=) found: this does not look like the HTTPS forward proxy, or it lives in an included file"
  fi
  if [ -n "$ADOPT_TLS_CERT" ]; then
    ADOPT_TLS_DIR="$(dirname "$ADOPT_TLS_CERT")"
  fi

  # Source ACL file + client inventory
  local -a inc_arr=()
  if [ -n "$includes" ]; then
    while IFS= read -r f; do [ -n "$f" ] && inc_arr+=("$f"); done <<< "$includes"
  fi
  ADOPT_SOURCE_ACL_FILE="$(squid_find_source_acl_file "${inc_arr[@]}" 2>/dev/null || true)"
  if [ -z "$ADOPT_SOURCE_ACL_FILE" ]; then
    ADOPT_MANAGED_OK=0
    ADOPT_FINDINGS="${ADOPT_FINDINGS}
- could not identify the file holding the client 'acl ... src' entries"
  fi
  if [ -n "$ADOPT_SOURCE_ACL_FILE" ]; then
    local cidr aclname comment n=0 normalised scope display acl_id suffix
    while IFS=$'\t' read -r cidr aclname comment; do
      [ -n "$cidr" ] || continue
      n=$((n+1))
      if ! normalised="$(normalize_client_cidr "$cidr" 2>/dev/null)"; then
        ADOPT_MANAGED_OK=0
        ADOPT_FINDINGS="${ADOPT_FINDINGS}
- source entry '$cidr' (acl $aclname${comment:+, comment \"$comment\"}) is not an exact host: left unmanaged, review manually"
        continue
      fi
      scope="$(ip_scope "${normalised%%/*}")"
      display="$(trim "$comment")"
      [ -n "$display" ] || display="$aclname"
      [ -n "$display" ] || display="client-$n"
      acl_id="$(slugify "$display")"
      [ -n "$acl_id" ] || acl_id="client_$n"
      suffix=2
      while [ -n "$(printf '%s\n' "$ADOPT_IMPORT_CLIENTS" | awk -v a="$acl_id" -F'\t' '$2 == a {print 1; exit}')" ]; do
        acl_id="$(slugify "$display")_$suffix"; suffix=$((suffix+1))
      done
      if [ -n "$(printf '%s\n' "$ADOPT_IMPORT_CLIENTS" | awk -v c="$normalised" -F'\t' '$3 == c')" ]; then
        ADOPT_FINDINGS="${ADOPT_FINDINGS}
- duplicate source $normalised (acl $aclname): imported once"
        continue
      fi
      ADOPT_IMPORT_CLIENTS="${ADOPT_IMPORT_CLIENTS}${display}	${acl_id}	${normalised}	${aclname}	${comment:--}	${scope}
"
    done < <(squid_acl_src_entries "$ADOPT_SOURCE_ACL_FILE")
  fi

  # Destination ACL + list
  local dref dname dpath
  dref="$(squid_find_domain_acl_ref "$main" "${inc_arr[@]}" 2>/dev/null || true)"
  if [ -n "$dref" ]; then
    dname="${dref%%$'\t'*}"
    dpath="${dref#*$'\t'}"
    ADOPT_DOMAIN_ACL_NAME="$dname"
    ADOPT_DOMAIN_ACL_FILE="$dpath"
    if [ -r "$dpath" ]; then
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if validate_domain_entry "$entry" 0 >/dev/null 2>&1; then
          ADOPT_IMPORT_DOMAINS="${ADOPT_IMPORT_DOMAINS}${entry}
"
        else
          ADOPT_FINDINGS="${ADOPT_FINDINGS}
- existing destination '$entry' is a broad/shared platform: NOT imported into the managed list (existing clients keep using it); narrow it and add it with 'ghproxyctl domains add' if managed clients need it"
        fi
      done < <(read_lines "$dpath")
    else
      ADOPT_FINDINGS="${ADOPT_FINDINGS}
- destination list file '$dpath' is not readable as a file (inline dstdomain list?)"
    fi
  else
    ADOPT_FINDINGS="${ADOPT_FINDINGS}
- no dstdomain-style ACL detected in the existing configuration"
  fi

  # Certbot hook
  if [ -d "$(gp_reload_hooks)" ]; then
    ADOPT_HOOK="$(find "$(gp_reload_hooks)" -maxdepth 1 -type f 2>/dev/null | head -n 1)"
  fi

  # Policy audit of the existing configuration
  if ! squid_policy_audit "$main" "${inc_arr[@]}" >/dev/null 2>&1; then
    ADOPT_FINDINGS="${ADOPT_FINDINGS}
- policy audit produced warnings for the existing configuration (see the report above)"
  fi

  # Would the managed file be shadowed by an existing blanket deny rule?
  # (Only meaningful once the managed file actually grants access to someone.)
  if [ -r "$SERVER_CLIENT_ACL_FILE" ] && grep -qE '^http_access[[:space:]]+allow' "$SERVER_CLIENT_ACL_FILE" 2>/dev/null; then
    local order_rc=0
    squid_check_managed_ordering "$main" "$SERVER_CLIENT_ACL_FILE" >/dev/null 2>&1 || order_rc=$?
    if [ "$order_rc" = "1" ]; then
      ADOPT_MANAGED_OK=0
      ADOPT_FINDINGS="${ADOPT_FINDINGS}
- a blanket deny rule is evaluated before $SERVER_CLIENT_ACL_FILE: clients added with
  ghproxyctl would be refused. Review the http_access order shown above (the managed
  file is named 00-... so it loads first inside conf.d; check the main config itself)."
    fi
  fi

  # Live check: is the loopback port actually serving?
  fw_detect
  ADOPT_OK=1
  return 0
}

server_adopt_report() {
  local line
  log_head "vps-gateway-manager :: adoption plan (read-only analysis)"
  server_discovery_print
  printf '\n' >&2
  log_head "adoption plan"
  printf 'managed service        : %s\n' "${SQUID_UNIT:-<none detected>}"
  printf 'squid                   : %s (%s, %s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR" "${SQUID_BIN}"
  printf 'main configuration      : %s\n' "$ADOPT_MAIN_CONF"
  printf 'client ACL file (yours) : %s\n' "${ADOPT_SOURCE_ACL_FILE:-<none>}"
  printf 'destination ACL         : %s -> %s\n' "${ADOPT_DOMAIN_ACL_NAME:-<none>}" "${ADOPT_DOMAIN_ACL_FILE:-<none>}"
  printf 'TLS listener            : %s (cert %s)\n' "${ADOPT_TLS_PORT:-<none>}" "${ADOPT_TLS_CERT:-<none>}"
  printf 'loopback listener       : %s\n' "${ADOPT_LOOPBACK_PORT:-<none>}"
  printf 'certbot deploy hook     : %s\n' "${ADOPT_HOOK:-<none>}"
  printf 'firewall                : %s\n' "$(fw_backend_summary)"
  printf '\n'
  printf 'clients found in your ACL file: %s\n' "$(printf '%s\n' "$ADOPT_IMPORT_CLIENTS" | grep -c . || true)"
  if [ -n "$ADOPT_IMPORT_CLIENTS" ]; then
    printf '  %-22s %-44s %s\n' "IMPORTED AS" "SOURCE" "ORIGINAL COMMENT"
    while IFS=$'\t' read -r display acl_id c a cm sc; do
      [ -n "$display" ] || continue
      [ "$cm" = "-" ] && cm=""
      printf '  %-22s %-44s %s\n' "$display" "$c" "${cm:-<none>} (acl $a, ${sc:-unknown}, id=$acl_id)"
    done <<< "$ADOPT_IMPORT_CLIENTS"
  fi
  printf '\n'
  printf 'destination entries imported into the managed list: %s\n' "$(printf '%s\n' "$ADOPT_IMPORT_DOMAINS" | grep -c . || true)"
  printf '%s\n' "$ADOPT_IMPORT_DOMAINS" | while IFS= read -r line; do
    if [ -n "$line" ]; then printf '  %s\n' "$line"; fi
  done
  printf '\n'
  log_head "files this project WILL create"
  printf '  %s/ (role, version, server.conf, clients.db, github-domains.txt, state/, backups/)\n' "$(gp_state_dir)"
  printf '  %s  (new, additive: no client ACLs at first)\n' "$SERVER_CLIENT_ACL_FILE"
  printf '  %s  (toolchain + ghproxyctl)\n' "$(gp_libexec_dir)"
  printf '  %s\n' "$(gp_bin_dir)/ghproxyctl"
  printf '\n'
  log_head "files this project will NOT touch during adoption"
  printf '  %s   (your main config)\n' "$ADOPT_MAIN_CONF"
  printf '  %s   (your client ACLs)\n' "${ADOPT_SOURCE_ACL_FILE:-<none>}"
  printf '  %s   (your destination list)\n' "${ADOPT_DOMAIN_ACL_FILE:-<none>}"
  printf '  %s\n' "${ADOPT_TLS_DIR:-<your TLS directory>}"
  printf '  %s\n' "${ADOPT_HOOK:-<your certbot hook>}"
  printf '  existing firewall rules, xray, x-ui, 443, 4428\n'
  printf '\n'
  log_head "risk notes"
  printf '  * adoption performs no reload and no restart: it only adds files\n'
  printf '  * the new conf.d file is validated with "squid -k parse" against your real config first\n'
  printf '  * it contains no "http_access deny" rule, so it cannot shadow your existing clients\n'
  printf '  * a reload only happens later, when you run "ghproxyctl client add"\n'
  if [ -n "$ADOPT_FINDINGS" ]; then
    printf '\nfindings that need your attention:\n'
    printf '%s\n' "$ADOPT_FINDINGS" | sed '/^$/d' | sed 's/^/  /'
  fi
  if [ "$ADOPT_MANAGED_OK" != "1" ]; then
    printf '\n'
    log_warn "some entries could not be classified automatically; they stay unmanaged and are listed above"
  fi
  printf '\n'
  return 0
}

server_adopt_run() {
  local dry="${1:-0}" rc=0 tmp
  log_head "vps-gateway-manager :: adopting the existing proxy"
  server_set_defaults

  server_adopt_analyze || { log_err "adoption analysis failed"; return 1; }

  # Take over discovered values, keeping the operator's own config untouched.
  SERVER_MODE="adopted"
  [ -n "$ADOPT_TLS_PORT" ] && SERVER_TLS_PORT="$ADOPT_TLS_PORT"
  [ -n "$ADOPT_LOOPBACK_PORT" ] && SERVER_LOOPBACK_PORT="$ADOPT_LOOPBACK_PORT"
  [ -n "$ADOPT_SOURCE_ACL_FILE" ] && SERVER_SOURCE_ACL_FILE="$ADOPT_SOURCE_ACL_FILE"
  [ -n "$ADOPT_DOMAIN_ACL_NAME" ] && SERVER_DOMAIN_ACL_NAME="$ADOPT_DOMAIN_ACL_NAME"
  [ -n "$ADOPT_TLS_DIR" ] && SERVER_TLS_DIR="$ADOPT_TLS_DIR"
  [ -n "$ADOPT_HOOK" ] && SERVER_CERTBOT_HOOK="$ADOPT_HOOK"
  [ -n "${SQUID_UNIT:-}" ] && SERVER_SERVICE="$SQUID_UNIT"
  if [ -z "$SERVER_DOMAIN" ]; then
    SERVER_DOMAIN="$(openssl x509 -in "${ADOPT_TLS_CERT:-/dev/null}" -noout -subject 2>/dev/null \
      | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p' | head -n1)"
  fi
  if [ -z "$SERVER_DOMAIN" ]; then
    SERVER_DOMAIN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  fi
  if [ "$dry" = "1" ] || gp_dry_run; then
    server_adopt_report
    printf '\n'
    log_dry "nothing was changed: this was a read-only adoption analysis"
    return 0
  fi

  server_adopt_report

  txn_begin "adopt existing proxy (${SERVER_DOMAIN})" || return 1
  trap 'txn_rollback "unexpected error during adoption"' ERR

  txn_mkdir "$(gp_state_dir)" 0700 || { txn_rollback "state dir"; return 1; }
  txn_mkdir "$(gp_state_dir)/state" 0700 || { txn_rollback "state dir"; return 1; }
  if ! gp_dry_run; then
    printf 'server\n' | gp_atomic_write "$(gp_role_file)" 0600
    printf '%s\n' "${VGM_VERSION:-unknown}" | gp_atomic_write "$(gp_state_dir)/version" 0644
  fi

  # Destination list: template defaults + everything already whitelisted.
  domains_seed_from_template || { txn_rollback "destination list"; return 1; }
  if [ -n "$ADOPT_IMPORT_DOMAINS" ]; then
    while IFS= read -r tmp; do
      [ -n "$tmp" ] || continue
      domains_add_entry "$tmp" || true
    done <<< "$ADOPT_IMPORT_DOMAINS"
  fi
  record_managed_file "$(gp_domains_file)" created

  # Client inventory (imported clients remain owned by the operator's file).
  while IFS=$'\t' read -r display acl_id cidr aclname comment scope; do
    [ -n "$display" ] || continue
    [ "$comment" = "-" ] && comment=""
    clients_db_add "$display" "$cidr" adopted "$SERVER_SOURCE_ACL_FILE" "${comment:-acl $aclname ($scope)}" "$acl_id" || true
  done <<< "$ADOPT_IMPORT_CLIENTS"
  txn_backup_file "$(gp_clients_db)" || true

  # Our own additive conf.d file. Empty of clients on purpose.
  tmp="$(mktemp)"
  server_render_clients_file 1 > "$tmp" || { rm -f "$tmp"; txn_rollback "render clients"; return 1; }
  server_validate_candidate "$tmp" "$SERVER_CLIENT_ACL_FILE" "$SERVER_MAIN_CONF" \
    || { rm -f "$tmp"; txn_rollback "candidate rejected"; return 1; }
  txn_install_file "$tmp" "$SERVER_CLIENT_ACL_FILE" 0644 || { rm -f "$tmp"; txn_rollback "install clients"; return 1; }
  rm -f "$tmp"
  record_managed_file "$SERVER_CLIENT_ACL_FILE" created

  # Validate the *real* configuration with the new file in place. No reload yet.
  if ! squid_parse "$SERVER_MAIN_CONF"; then
    txn_rollback "existing config no longer parses with the additive file"
    log_err "adoption aborted; your proxy was not modified"
    return 1
  fi

  # Live sanity check of the running service (read-only).
  if [ -n "$SERVER_SERVICE" ] && have systemctl; then
    if ! systemctl_active "$SERVER_SERVICE"; then
      log_warn "$SERVER_SERVICE is not active right now - adoption continues, but check it"
    fi
  fi

  fw_detect
  if [ "$FW_TYPE" = "ufw" ] && [ "$FW_ACTIVE" = "1" ]; then
    SERVER_UFW_MANAGED=1
    if [ -d "${TXN_DIR:-}" ]; then fw_capture_state "$TXN_DIR/ufw-before.txt" || true; fi
  fi

  server_state_write
  txn_backup_file "$(gp_server_conf)" || true
  record_managed_file "$(gp_server_conf)" created
  record_managed_file "$(gp_clients_db)" created
  if ! gp_dry_run; then
    gp_install_toolchain || log_warn "toolchain installation reported a problem"
  fi

  txn_commit success || return 1
  trap - ERR
  rc=0
  log_ok "adoption complete: this proxy is now visible to ghproxyctl"
  log_info "your original configuration was not modified; access is unchanged"
  log_info "next: 'ghproxyctl status', then 'ghproxyctl client add <ip> <name>' for new nodes"
  return "$rc"
}

# -----------------------------------------------------------------------------
# Client management
# -----------------------------------------------------------------------------
server_onboarding_hint() {
  local domain="${SERVER_DOMAIN:-gh.example.com}" port="${SERVER_TLS_PORT:-8443}"
  local repo="${SERVER_REPO_URL:-https://github.com/xinian5216/vps-gateway-manager}"
  local ref="${SERVER_REPO_REF:-main}"
  local raw="$repo"
  case "$repo" in
    https://github.com/*) raw="https://raw.githubusercontent.com/${repo#https://github.com/}/$ref" ;;
  esac
  cat <<EOF

Client added.

Run on client:

curl --proxy https://${domain}:${port} \\
  -fsSL \\
  ${raw}/install.sh \\
  -o /tmp/vps-gateway-manager.sh

sudo bash /tmp/vps-gateway-manager.sh client \\
  --upstream https://${domain}:${port}

EOF
  return 0
}

server_client_list() {
  server_require_installed || return 1
  local name cidr created source acl note ufw_state managed_suffix
  printf '%-22s %-44s %-11s %-20s %s\n' "NAME" "SOURCE ADDRESS" "ORIGIN" "ADDED" "STATE"
  printf '%-22s %-44s %-11s %-20s %s\n' "----" "--------------" "------" "-----" "-----"
  if [ "$(clients_db_count)" = "0" ]; then
    printf '(no clients yet - add one with: ghproxyctl client add <ip> <name>)\n'
    return 0
  fi
  while IFS=$'\t' read -r name cidr created source acl note acl_id; do
    [ -n "$name" ] || continue
    if [ "$source" = "adopted" ]; then
      managed_suffix="adopted - edit ${acl:-the original ACL file}"
      ufw_state="n/a"
    else
      fw_detect
      ufw_state="$(fw_rule_exists "$(fw_rule_spec "$cidr" "$SERVER_TLS_PORT")" && printf 'yes' || printf 'no')"
      managed_suffix="managed (acl gsp_c_${acl_id:-$(slugify "$name")})"
    fi
    printf '%-22s %-44s %-11s %-20s %s\n' "$name" "$cidr" "$source" "$created" \
      "ufw=${ufw_state} ${managed_suffix}"
  done < <(clients_db_list)
  return 0
}

# server_client_add <ip> <name> [allow_private]
server_client_add() {
  local ip="$1" name="$2" allow_private="${3:-0}"
  local cidr display acl_id existing by_cidr tmp rc=0 suffix=2
  server_require_installed || return 1

  cidr="$(validate_client_ip "$ip" "$name" "$allow_private")" || return 1
  display="$(trim "$name")"
  [ -n "$display" ] || { die "client name must not be empty"; return 1; }
  case "$display" in
    *[!A-Za-z0-9._-]*) die "client name '$display' may only contain letters, digits, dot, dash and underscore"; return 1 ;;
  esac
  acl_id="$(slugify "$display")"
  [ -n "$acl_id" ] || { die "client name '$display' produces an empty ACL identifier"; return 1; }
  [ "${#acl_id}" -le 24 ] || { die "client name '$display' is too long (max 24 usable characters)"; return 1; }
  # Keep the Squid ACL identifier unique even for names that slugify alike.
  while [ -n "$(clients_db_find_by_acl_id "$acl_id")" ]; do
    acl_id="$(slugify "$display")_$suffix"
    suffix=$((suffix+1))
  done

  existing="$(clients_db_get "$display")"
  if [ -n "$existing" ]; then
    by_cidr="$(clients_db_field "$display" cidr)"
    if [ "$by_cidr" = "$cidr" ]; then
      log_ok "client '$display' already authorised for $cidr (nothing to do)"
      server_onboarding_hint
      return 0
    fi
    die "client name '$display' already exists with a different address ($by_cidr)"
    return 1
  fi
  by_cidr="$(clients_db_find_by_cidr "$cidr")"
  if [ -n "$by_cidr" ]; then
    log_ok "address $cidr is already authorised as '$by_cidr' (nothing to do)"
    server_onboarding_hint
    return 0
  fi

  # A duplicate in the operator's own (adopted) file is confusing: report it.
  if [ -n "$SERVER_SOURCE_ACL_FILE" ] && [ -r "$SERVER_SOURCE_ACL_FILE" ]; then
    if squid_acl_src_entries "$SERVER_SOURCE_ACL_FILE" | cut -f1 | grep -qxF "$cidr"; then
      if [ "${SERVER_ALLOW_DUPLICATE_CLIENT:-0}" != "1" ]; then
        log_err "$cidr is already present in $SERVER_SOURCE_ACL_FILE (not managed by this tool)"
        log_err "That entry already authorises the node. Add --force to create a second, managed entry anyway."
        return 1
      fi
      log_warn "creating a managed entry for $cidr although it also exists in $SERVER_SOURCE_ACL_FILE"
    fi
  fi

  txn_begin "client add $display ($cidr)" || return 1
  trap 'txn_rollback "unexpected error while adding a client"' ERR

  # The inventory is part of the change: without this the ACL file would be
  # rolled back while the client stayed in clients.db (and the next render would
  # put it back into the configuration).
  txn_backup_file "$(gp_clients_db)" || true
  clients_db_add "$display" "$cidr" ghproxyctl "$SERVER_CLIENT_ACL_FILE" "added by ghproxyctl" "$acl_id" \
    || { txn_rollback "client db"; return 1; }

  tmp="$(mktemp)"
  server_render_clients_file "$([ "$SERVER_MODE" = "adopted" ] && printf 1 || printf 0)" > "$tmp" \
    || { rm -f "$tmp"; txn_rollback "render"; return 1; }

  # Firewall first (a failure here must abort before we touch Squid).
  server_ufw_sync_client "$cidr" "$acl_id" add || { rm -f "$tmp"; txn_rollback "firewall rule"; return 1; }

  # ACL: validate -> atomic replace -> reload (and prove it took effect) -> health
  server_apply_clients_file_or_fail "$tmp" "client add $display" "gsp_c_$acl_id" \
    || { rm -f "$tmp"; txn_rollback "config apply"; return 1; }
  rm -f "$tmp"

  if gp_dry_run; then
    txn_commit success || return 1
    trap - ERR
    log_dry "client '$display' ($cidr) would be authorised"
    server_onboarding_hint
    return 0
  fi

  if declare -F hc_server_quick >/dev/null 2>&1; then
    if ! hc_server_quick; then
      txn_rollback "post-change health check failed"
      return 1
    fi
  fi

  txn_commit success || return 1
  trap - ERR
  rc=0
  log_ok "client '$display' ($cidr) authorised"
  server_onboarding_hint
  return "$rc"
}

# server_client_remove <name>
server_client_remove() {
  local name slug cidr source acl row tmp rc=0
  server_require_installed || return 1
  slug="$(trim "${1:-}")"
  [ -n "$slug" ] || { die "usage: ghproxyctl client remove <name>"; return 1; }
  row="$(clients_db_get "$slug")"
  if [ -z "$row" ]; then
    die "no client named '$slug'"
    return 1
  fi
  name="$(clients_db_field "$slug" name)"
  cidr="$(clients_db_field "$slug" cidr)"
  source="$(clients_db_field "$slug" source)"
  acl="$(clients_db_field "$slug" acl_file)"
  local acl_id
  acl_id="$(clients_db_field "$slug" acl_id)"
  [ -n "$acl_id" ] || acl_id="$(slugify "$name")"

  if [ "$source" = "adopted" ]; then
    log_err "client '$name' was adopted from your existing configuration ($acl)."
    log_err "This project will not rewrite a file it does not own."
    log_err "Remove the 'acl ... src' line for $cidr from that file, reload squid, then run:"
    log_err "    ghproxyctl client forget $name"
    return 1
  fi

  txn_begin "client remove $name ($cidr)" || return 1
  trap 'txn_rollback "unexpected error while removing a client"' ERR

  txn_backup_file "$(gp_clients_db)" || true
  clients_db_remove "$name" || { txn_rollback "client db"; return 1; }
  tmp="$(mktemp)"
  server_render_clients_file "$([ "$SERVER_MODE" = "adopted" ] && printf 1 || printf 0)" > "$tmp" \
    || { rm -f "$tmp"; txn_rollback "render"; return 1; }
  server_apply_clients_file_or_fail "$tmp" "client remove $name" "!gsp_c_$acl_id" \
    || { rm -f "$tmp"; txn_rollback "config apply"; return 1; }
  rm -f "$tmp"

  # Firewall rule: only the one we created (marker checked).
  server_ufw_sync_client "$cidr" "$acl_id" remove || true

  if gp_dry_run; then
    txn_commit success || return 1
    trap - ERR
    log_dry "client '$name' ($cidr) would be removed"
    return 0
  fi

  if declare -F hc_server_quick >/dev/null 2>&1; then
    if ! hc_server_quick; then
      txn_rollback "post-change health check failed"
      return 1
    fi
  fi

  txn_commit success || return 1
  trap - ERR
  rc=0
  log_ok "client '$name' ($cidr) removed"
  return "$rc"
}

# server_client_forget <name> : drop the DB row without touching any config
server_client_forget() {
  local name row
  server_require_installed || return 1
  name="$(trim "${1:-}")"
  [ -n "$name" ] || { die "usage: ghproxyctl client forget <name>"; return 1; }
  row="$(clients_db_get "$name")"
  [ -n "$row" ] || { die "no client named '$name'"; return 1; }
  name="$(clients_db_field "$name" name)"
  txn_begin "client forget $name" || return 1
  txn_backup_file "$(gp_clients_db)" || true
  clients_db_remove "$name" || { txn_rollback "db"; return 1; }
  txn_commit success || return 1
  log_ok "client '$name' removed from the inventory (configuration untouched)"
  return 0
}

# server_client_reimport : re-import clients from an adopted ACL file
server_client_reimport() {
  local cidr aclname comment n=0 normalised display acl_id added=0
  server_require_installed || return 1
  [ -n "$SERVER_SOURCE_ACL_FILE" ] || { die "no adopted source ACL file recorded"; return 1; }
  [ -r "$SERVER_SOURCE_ACL_FILE" ] || { die "source ACL file is not readable: $SERVER_SOURCE_ACL_FILE"; return 1; }
  if [ "$(clients_db_count)" != "0" ] && [ "${SERVER_FORCE_REIMPORT:-0}" != "1" ]; then
    log_warn "the inventory already contains clients; only new addresses will be added"
  fi
  while IFS=$'\t' read -r cidr aclname comment; do
    [ -n "$cidr" ] || continue
    n=$((n+1))
    normalised="$(normalize_client_cidr "$cidr" 2>/dev/null)" || { log_warn "skipping non-host entry: $cidr"; continue; }
    [ -n "$(clients_db_find_by_cidr "$normalised")" ] && continue
    display="${comment:-}"
    [ -n "$display" ] || display="${aclname}"
    [ -n "$display" ] || display="client-$n"
    [ -n "$(clients_db_get "$display")" ] && display="${display}-$n"
    acl_id="$(slugify "$display")"
    [ -n "$acl_id" ] || acl_id="client_$n"
    while [ -n "$(clients_db_find_by_acl_id "$acl_id")" ]; do acl_id="${acl_id}_$n"; done
    clients_db_add "$display" "$normalised" adopted "$SERVER_SOURCE_ACL_FILE" "${comment:-acl $aclname}" "$acl_id" || continue
    log_ok "imported $display -> $normalised"
    added=$((added+1))
  done < <(squid_acl_src_entries "$SERVER_SOURCE_ACL_FILE")
  log_info "$added new client(s) imported"
  return 0
}

# -----------------------------------------------------------------------------
# Destination list management
# -----------------------------------------------------------------------------
server_domains_apply() {
  # Validate + reload after the runtime list changed.
  local rc=0
  if gp_dry_run; then
    log_dry "validate $SERVER_MAIN_CONF with squid -k parse, reload $SERVER_SERVICE, re-run health checks"
    return 0
  fi
  squid_parse "$SERVER_MAIN_CONF" || return 1
  squid_reload "$SERVER_SERVICE" "$SERVER_MAIN_CONF" || return 1
  txn_service "$SERVER_SERVICE" reload
  squid_wait_healthy "$SERVER_SERVICE" 15 || return 1
  if declare -F hc_server_quick >/dev/null 2>&1; then hc_server_quick || rc=$?; fi
  return "$rc"
}

server_domains_add() {
  local entry="$1" allow_broad="${2:-0}" normalised rc=0
  server_require_installed || return 1
  normalised="$(validate_domain_entry "$entry" "$allow_broad")" || return 1
  txn_begin "domains add $normalised" || return 1
  trap 'txn_rollback "unexpected error while adding a destination"' ERR
  txn_backup_file "$(gp_domains_file)" || true
  domains_add_entry "$normalised" || { txn_rollback "add entry"; return 1; }
  record_managed_file "$(gp_domains_file)" modified
  server_domains_apply || { txn_rollback "reload/health check"; return 1; }
  txn_commit success || return 1
  trap - ERR
  log_ok "destination added: $normalised"
  return "$rc"
}

server_domains_remove() {
  local entry="$1" normalised rc=0
  server_require_installed || return 1
  normalised="$(validate_domain_entry "$entry" 1)" || return 1
  txn_begin "domains remove $normalised" || return 1
  trap 'txn_rollback "unexpected error while removing a destination"' ERR
  txn_backup_file "$(gp_domains_file)" || true
  domains_remove_entry "$normalised" || { txn_rollback "remove entry"; return 1; }
  server_domains_apply || { txn_rollback "reload/health check"; return 1; }
  txn_commit success || return 1
  trap - ERR
  log_ok "destination removed: $normalised"
  return "$rc"
}

server_domains_list() {
  server_require_installed || return 1
  printf '# managed destination list: %s\n' "$(gp_domains_file)"
  domains_current_list | sed 's/^/  /'
  return 0
}

# -----------------------------------------------------------------------------
# Uninstall / unmanage
# -----------------------------------------------------------------------------
server_uninstall() {
  local purge="${1:-0}" rc=0 name cidr source
  server_require_installed || return 1
  log_head "vps-gateway-manager :: server uninstall (mode: $SERVER_MODE)"

  if [ "$SERVER_MODE" = "adopted" ] && [ "$purge" != "1" ]; then
    log_info "adopted mode: this will only remove this project's own files and firewall rules"
    log_info "your Squid service, configuration, certificates and clients are preserved"
  elif [ "$SERVER_MODE" = "fresh" ] && [ "$purge" != "1" ]; then
    log_warn "fresh mode: the proxy configuration created by this project will be removed"
    log_info "packages (squid-openssl, certbot) are never removed automatically"
  else
    log_warn "--purge requested: removes every file this project created, including /etc/vps-gateway-manager"
  fi

  if ! confirm "Proceed with uninstall?" no; then
    log_info "aborted by the operator"
    return 0
  fi

  txn_begin "server uninstall ($SERVER_MODE)" || return 1
  trap 'txn_rollback "unexpected error during uninstall"' ERR

  # 1. Firewall rules we created (managed clients only).
  if [ "$SERVER_UFW_MANAGED" = "1" ]; then
    fw_detect
    while IFS=$'\t' read -r name cidr _created source _acl _note; do
      [ -n "$name" ] || continue
      [ "$source" = "adopted" ] && continue
      server_ufw_sync_client "$cidr" "$name" remove || log_warn "could not remove the firewall rule for $name"
    done < <(clients_db_list)
  fi

  # 2. Our additive conf.d file.
  txn_remove_file "$SERVER_CLIENT_ACL_FILE" || log_warn "could not remove $SERVER_CLIENT_ACL_FILE"

  # 3. Main config: only in fresh mode and only when we created it.
  if [ "$SERVER_MODE" = "fresh" ] && [ -r "$SERVER_MAIN_CONF" ] \
     && grep -q "managed by $GP_PROJECT_NAME" "$SERVER_MAIN_CONF" 2>/dev/null; then
    local prev
    prev="$(find "$(gp_backup_dir)" -name 'journal.tsv' -type f 2>/dev/null | sort | head -n1)"
    if [ -n "$prev" ]; then
      log_info "a previous configuration exists in $prev; it is kept for manual restore"
    fi
    if [ -n "$SERVER_SERVICE" ] && have systemctl && systemctl_active "$SERVER_SERVICE"; then
      txn_service "$SERVER_SERVICE" stop
      systemctl_cmd stop "$SERVER_SERVICE" || log_warn "could not stop $SERVER_SERVICE"
    fi
    txn_remove_file "$SERVER_MAIN_CONF" || log_warn "could not remove $SERVER_MAIN_CONF"
  fi

  # 4. State (always keep an emergency copy outside the state dir).
  local keep
  keep="$(gp_p /var/backups)/vps-gateway-manager"
  if [ "$purge" != "1" ]; then
    log_info "keeping a final copy of the state and backups in $keep"
    if ! gp_dry_run; then
      mkdir -p "$keep" || true
      cp -a "$(gp_state_dir)/." "$keep/" 2>/dev/null || true
    fi
  else
    log_info "purge: including the state directory in the backup copy before deletion"
    if ! gp_dry_run; then
      mkdir -p "$keep" || true
      cp -a "$(gp_state_dir)/." "$keep/" 2>/dev/null || true
    fi
  fi
  if [ "$purge" = "1" ]; then
    txn_remove_file "$(gp_state_dir)/clients.db" || true
    txn_remove_file "$(gp_state_dir)/server.conf" || true
    txn_remove_file "$(gp_state_dir)/github-domains.txt" || true
    txn_remove_file "$(gp_state_dir)/github-domains.sources" || true
    txn_remove_file "$(gp_state_dir)/role" || true
    txn_remove_file "$(gp_state_dir)/version" || true
  fi
  txn_remove_file "$(gp_bin_dir)/ghproxyctl" || true

  if declare -F hc_server_quick >/dev/null 2>&1 && [ "$SERVER_MODE" = "fresh" ] && systemctl_active "$SERVER_SERVICE"; then
    hc_server_quick || log_warn "service health check failed after uninstall (expected in fresh mode)"
  fi

  txn_commit success || return 1
  trap - ERR
  rc=0
  if [ "$SERVER_MODE" = "adopted" ]; then
    log_ok "uninstalled: this proxy is no longer managed by vps-gateway-manager (it keeps working as before)"
  else
    log_ok "uninstalled: vps-gateway-manager files removed"
  fi
  return "$rc"
}

