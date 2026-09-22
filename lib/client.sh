#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/client.sh
#
# Client-side lifecycle. The client runs its own Squid instance that:
#
#   * listens on 127.0.0.1:3129 and [::1]:3129 only (never a public address)
#   * sends GitHub destinations to the remote TLS parent proxy
#   * sends everything else DIRECT
#   * keeps its own config, pid, logs, spool dir and systemd unit, so an
#     unrelated squid/tinyproxy/xray installation on the same host is untouched
#
# Install order is deliberately "build first, tear down later":
#   record -> backup -> install local proxy -> test everything -> migrate.
# =============================================================================

if [ -n "${GP_CLIENT_SH:-}" ]; then
  return 0
fi
GP_CLIENT_SH=1

CLIENT_MIGRATIONS_DIR() { printf '%s\n' "$(gp_state_dir)/migrations"; }

client_set_defaults() {
  CLIENT_UPSTREAM="${CLIENT_UPSTREAM:-}"
  CLIENT_LOCAL_PORT="${CLIENT_LOCAL_PORT:-3129}"
  CLIENT_SERVICE="${CLIENT_SERVICE:-vps-gateway-manager-client.service}"
  CLIENT_CONF_FILE="${CLIENT_CONF_FILE:-$(gp_p /etc/vps-gateway-manager/client-squid.conf)}"
  CLIENT_RUNTIME_DIR="${CLIENT_RUNTIME_DIR:-$(gp_p /run/vps-gateway-manager)}"
  CLIENT_LOG_DIR="${CLIENT_LOG_DIR:-$(gp_p /var/log/vps-gateway-manager)}"
  CLIENT_SPOOL_DIR="${CLIENT_SPOOL_DIR:-$(gp_p /var/spool/vps-gateway-manager)}"
  CLIENT_ACCESS_LOG="$CLIENT_LOG_DIR/access.log"
  CLIENT_UPSTREAM_CA="${CLIENT_UPSTREAM_CA:-$(gp_ca_bundle)}"
  CLIENT_UPSTREAM_SSL_DOMAIN="${CLIENT_UPSTREAM_SSL_DOMAIN:-}"
  # Address-family model (P0.5):
  #   CLIENT_UPSTREAM_FAMILY      what the operator asked for: auto|4|6
  #   CLIENT_SELECTED_FAMILY      what was actually chosen: 4|6|dual (dual =
  #                               hostname mode, both families verified usable)
  #   CLIENT_UPSTREAM_PEER_ADDRESS the concrete address Squid must connect to
  #                               ("" in hostname mode). The logical TLS name
  #                               always stays CLIENT_UPSTREAM_HOST.
  CLIENT_UPSTREAM_FAMILY="${CLIENT_UPSTREAM_FAMILY:-auto}"
  CLIENT_SELECTED_FAMILY="${CLIENT_SELECTED_FAMILY:-}"
  CLIENT_UPSTREAM_PEER_ADDRESS="${CLIENT_UPSTREAM_PEER_ADDRESS:-}"
  CLIENT_PROFILE_FILE="${CLIENT_PROFILE_FILE:-$(gp_profile_d)/vps-gateway-manager.sh}"
  CLIENT_SUDOERS_FILE="${CLIENT_SUDOERS_FILE:-$(gp_p /etc/sudoers.d)/vps-gateway-manager}"
  CLIENT_UNIT_FILE="${CLIENT_UNIT_FILE:-$(gp_systemd_dir)/${CLIENT_SERVICE}}"
  CLIENT_ADOPT="${CLIENT_ADOPT:-0}"
  CLIENT_MIGRATE_GLOBAL_ENV="${CLIENT_MIGRATE_GLOBAL_ENV:-0}"
  CLIENT_MANAGE_GIT="${CLIENT_MANAGE_GIT:-1}"
  CLIENT_GIT_USERS="${CLIENT_GIT_USERS:-auto}"
  CLIENT_TAG="${CLIENT_TAG:-$(hostname 2>/dev/null | cut -c1-24 || printf 'client')}"
  return 0
}

client_state_write() {
  local conf
  conf="$(gp_client_conf)"
  conf_set "$conf" upstream "$CLIENT_UPSTREAM" 0600
  conf_set "$conf" upstream_host "$CLIENT_UPSTREAM_HOST"
  conf_set "$conf" upstream_port "$CLIENT_UPSTREAM_PORT"
  conf_set "$conf" upstream_scheme "$CLIENT_UPSTREAM_SCHEME"
  conf_set "$conf" upstream_family "${CLIENT_UPSTREAM_FAMILY:-auto}"
  conf_set "$conf" upstream_selected_family "${CLIENT_SELECTED_FAMILY:-}"
  conf_set "$conf" upstream_peer_address "${CLIENT_UPSTREAM_PEER_ADDRESS:-}"
  conf_set "$conf" local_proxy "http://127.0.0.1:${CLIENT_LOCAL_PORT}"
  conf_set "$conf" local_port "$CLIENT_LOCAL_PORT"
  conf_set "$conf" local_host "127.0.0.1"
  conf_set "$conf" service_name "$CLIENT_SERVICE"
  conf_set "$conf" config_file "$CLIENT_CONF_FILE"
  conf_set "$conf" access_log "$CLIENT_ACCESS_LOG"
  conf_set "$conf" upstream_ca "$CLIENT_UPSTREAM_CA"
  conf_set "$conf" version "${VGM_VERSION:-unknown}"
  conf_set "$conf" updated_at "$(gp_ts_human)"
  return 0
}

client_state_load() {
  local conf
  conf="$(gp_client_conf)"
  [ -r "$conf" ] || return 1
  CLIENT_UPSTREAM="$(conf_get "$conf" upstream '')"
  CLIENT_UPSTREAM_HOST="$(conf_get "$conf" upstream_host '')"
  CLIENT_UPSTREAM_PORT="$(conf_get "$conf" upstream_port '')"
  CLIENT_UPSTREAM_SCHEME="$(conf_get "$conf" upstream_scheme https)"
  CLIENT_UPSTREAM_FAMILY="$(conf_get "$conf" upstream_family auto)"
  CLIENT_SELECTED_FAMILY="$(conf_get "$conf" upstream_selected_family '')"
  CLIENT_UPSTREAM_PEER_ADDRESS="$(conf_get "$conf" upstream_peer_address '')"
  CLIENT_LOCAL_PORT="$(conf_get "$conf" local_port 3129)"
  CLIENT_SERVICE="$(conf_get "$conf" service_name vps-gateway-manager-client.service)"
  CLIENT_CONF_FILE="$(conf_get "$conf" config_file "$(gp_p /etc/vps-gateway-manager/client-squid.conf)")"
  CLIENT_ACCESS_LOG="$(conf_get "$conf" access_log "$(gp_p /var/log/vps-gateway-manager/access.log)")"
  # Fill in every remaining path/derived default in one place.
  client_set_defaults
  return 0
}

client_require_installed() {
  if [ "$(gp_role)" != "client" ]; then
    die "this host is not configured as a vps-gateway-manager client (role: '$(gp_role)')"
    return 1
  fi
  client_state_load || { die "client state file missing"; return 1; }
  return 0
}

# -----------------------------------------------------------------------------
# Privilege helpers (git config for the maintenance user)
# -----------------------------------------------------------------------------
as_user() {
  # as_user <user> <command...>
  local user="$1"; shift
  if have runuser; then
    runuser -u "$user" -- "$@"
  elif have sudo; then
    sudo -u "$user" -- "$@"
  elif have su; then
    su -s /bin/sh -c "$(printf '%s ' "$@")" "$user"
  else
    return 127
  fi
}

user_home() {
  local user="$1" home
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  [ -n "$home" ] || home="$(eval "printf '%s' ~$user" 2>/dev/null || true)"
  [ -n "$home" ] || return 1
  printf '%s\n' "$home"
}

client_target_users() {
  local list="$1" user out=""
  case "$list" in
    auto)
      out="root"
      if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then out="$out $SUDO_USER"; fi
      ;;
    none) out="" ;;
    *)    out="$(printf '%s' "$list" | tr ',' ' ')" ;;
  esac
  local u
  for u in $out; do
    if ! id "$u" >/dev/null 2>&1; then
      log_warn "skipping git configuration: user '$u' does not exist"
      continue
    fi
    printf '%s\n' "$u"
  done
}

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
client_install_ca() {
  if [ -r "$(gp_ca_bundle)" ]; then return 0; fi
  log_info "installing ca-certificates (required to verify the upstream TLS certificate)"
  if gp_dry_run; then log_dry "apt-get install -y ca-certificates"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates >/dev/null 2>&1 || {
    log_err "could not install ca-certificates; TLS verification is mandatory"
    return 1
  }
  return 0
}

client_install_squid_if_needed() {
  if squid_detect && squid_check_min_version >/dev/null 2>&1; then
    log_ok "using Squid ${SQUID_VERSION} (${SQUID_FLAVOR})"
    return 0
  fi
  local was_active=0 was_enabled=0
  if have systemctl; then
    systemctl_active squid && was_active=1
    # The PRE-INSTALL state is what a rollback must restore - "enable" is not
    # the unconditional inverse of "disable". (Found on the London pilot,
    # whose rollback log ran "systemctl enable squid" although the unit had
    # been absent before the package was installed.)
    systemctl_enabled squid && was_enabled=1
  fi
  server_install_squid_pkg || return 1
  if gp_dry_run; then log_dry "re-detect squid"; return 0; fi
  squid_detect || { log_err "squid is still not available"; return 1; }
  squid_check_min_version || return 1
  # Installing the package usually enables+starts the distribution squid unit.
  # That is a side effect we did not ask for: restore the previous state.
  if [ "$was_active" = "0" ] && have systemctl && systemctl_active squid; then
    log_warn "the squid package started the system squid.service; stopping it again"
    log_warn "(this project never uses the distribution unit - it has its own)"
    systemctl_cmd stop squid || true
    if [ "$was_enabled" = "0" ]; then
      systemctl_cmd disable squid || true
      # Before the install the unit was disabled or absent. Nothing is recorded
      # for the rollback: "disabled + inactive" IS the pre-install state, and
      # an undo command must never enable it.
    fi
    # Enabled-but-inactive before: only the stop deviated, and stopping has
    # already restored exactly that state; the unit stays enabled.
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Upstream address-family selection (P0.5)
# -----------------------------------------------------------------------------
# Production background: a dual-stack `cache_peer <hostname>` is NOT reliable
# when one family is blackholed - the real London pilot produced random
# HIER_NONE/000 for API/Raw while Release passed. The family is therefore chosen
# deterministically BEFORE anything is installed, and a single-family choice is
# pinned to a concrete, probe-verified peer address.

# client_classify_code <code>
# One classification for every probe result. 000 is transport, never "refused".
client_classify_code() {
  case "$1" in
    200)   printf 'PASS (HTTP 200)' ;;
    403|407) printf 'REACHED BUT REFUSED (HTTP %s)' "$1" ;;
    000)   printf 'TRANSPORT UNAVAILABLE (HTTP 000)' ;;
    *)     printf 'REACHED, UNEXPECTED RESPONSE (HTTP %s)' "$1" ;;
  esac
  return 0
}

# client_connect_host <ip> -> the host part of a connect target, brackets for IPv6
client_connect_host() {
  local ip="$1"
  if is_ipv6 "$ip"; then printf '[%s]' "$ip"; else printf '%s' "$ip"; fi
}

# client_peer_token <ip> -> how the address is written in `cache_peer`
# The port is a separate token there, so the numeric form needs no brackets -
# but rather than guessing which spelling THIS Squid accepts, both are offered
# to `squid -k parse` and the one that parses is used. The integration suite
# proves the chosen form with real traffic.
client_peer_token() {
  local ip="$1"
  if ! is_ipv6 "$ip"; then printf '%s' "$ip"; return 0; fi
  if [ "$(client_peer_v6_form)" = "brackets" ]; then printf '[%s]' "$ip"
  else printf '%s' "$ip"; fi
  return 0
}

client_peer_v6_form() {
  if [ -n "${CLIENT_PEER_V6_FORM:-}" ]; then printf '%s' "$CLIENT_PEER_V6_FORM"; return 0; fi
  local a b rc_a=0 rc_b=0
  CLIENT_PEER_V6_FORM="bare"
  if [ -x "${SQUID_BIN:-}" ] || squid_detect >/dev/null 2>&1; then
    a="$(mktemp)"; b="$(mktemp)"
    printf 'cache_peer 2001:db8::1 parent 3128 0 no-query\n' > "$a"
    printf 'cache_peer [2001:db8::1] parent 3128 0 no-query\n' > "$b"
    squid_parse_quiet "$a" >/dev/null 2>&1 || rc_a=$?
    squid_parse_quiet "$b" >/dev/null 2>&1 || rc_b=$?
    rm -f "$a" "$b"
    if [ "$rc_a" = "0" ]; then
      CLIENT_PEER_V6_FORM="bare"
    elif [ "$rc_b" = "0" ]; then
      CLIENT_PEER_V6_FORM="brackets"
    else
      log_warn "neither IPv6 spelling parses in cache_peer on this Squid; using the numeric form"
    fi
  fi
  printf '%s' "$CLIENT_PEER_V6_FORM"
  return 0
}

# client_resolve_candidates <host> <4|6> -> unique addresses of that family
client_resolve_candidates() {
  local host="$1" fam="$2"
  # A literal upstream address is its own candidate.
  if is_ipv4 "$host"; then [ "$fam" = "4" ] && printf '%s\n' "$host"; return 0; fi
  if is_ipv6 "$host"; then [ "$fam" = "6" ] && printf '%s\n' "$host"; return 0; fi
  have getent || return 0
  getent ahosts "$host" 2>/dev/null \
    | awk -v fam="$fam" '
        { addr = $1 }
        fam == 4 && addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print }
        fam == 6 && addr ~ /:/ { print }
      ' \
    | awk '!seen[$0]++'
  return 0
}

# client_probe_target_host -> the host used for CONNECT probes (the GitHub API)
client_probe_target_host() {
  printf '%s' "${GP_TEST_API_URL:-https://api.github.com/rate_limit}" \
    | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#'
}

# client_candidate_probe <ip> [timeout]
# Read-only probe of ONE candidate upstream address:
#   * TLS handshake to the candidate with SNI and hostname verification against
#     the LOGICAL upstream hostname (never -k, never DONT_VERIFY_*),
#   * a real "CONNECT api.github.com:443" through the upstream, status read.
# Prints the classification line; returns 0 only when the candidate is usable.
client_candidate_probe() {
  local ip="$1" tmo="${2:-10}" name port target out code
  name="$CLIENT_UPSTREAM_HOST"
  port="${CLIENT_UPSTREAM_PORT:-443}"
  target="$(client_probe_target_host)"
  if [ "${CLIENT_UPSTREAM_SCHEME:-https}" = "https" ]; then
    out="$(printf 'CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n' "$target" "$target" \
      | timeout "$tmo" openssl s_client -connect "$(client_connect_host "$ip"):$port" \
          -servername "$name" -verify_return_error -verify_hostname "$name" \
          -CAfile "$(gp_ca_bundle)" 2>&1)" || true
    if printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
      code="$(printf '%s' "$out" | grep -oE 'HTTP/1\.[01][[:space:]][0-9]{3}' | head -n1 | awk '{print $2}')"
    elif printf '%s' "$out" | grep -qE 'Verify return code:|verify error|certificate verify failed'; then
      # The handshake reached certificate verification and failed (this also
      # covers -verify_return_error aborting mid-handshake on an expired or
      # wrong-name certificate). A refused or blackholed connection never gets
      # this far, so this is genuinely TLS - never misreported as transport.
      printf 'CERTIFICATE VERIFICATION FAILED (candidate %s, expected name %s)' "$ip" "$name"
      return 1
    else
      # No handshake output at all: connect refused/timeout/unreachable.
      printf 'TRANSPORT UNAVAILABLE (no response) via %s' "$ip"
      return 1
    fi
  else
    code="$(client_probe_code --proxy "http://$(client_connect_host "$ip"):$port" \
      --connect-timeout "$tmo" --max-time $((tmo + 10)) "https://${target}/rate_limit")"
  fi
  case "$code" in
    200) printf 'PASS (HTTP 200) via %s' "$ip"; return 0 ;;
    403|407) printf 'REACHED BUT REFUSED (HTTP %s) via %s' "$code" "$ip"; return 1 ;;
    '') printf 'TRANSPORT UNAVAILABLE (no response) via %s' "$ip"; return 1 ;;
    *) printf 'REACHED, UNEXPECTED RESPONSE (HTTP %s) via %s' "$code" "$ip"; return 1 ;;
  esac
}

# client_upstream_family_probe <upstream-url> <4|6>
# Read-only probe through the upstream, forced to one address family.
# Prints "unavailable (no local address of this family)" when this host has no
# global address of the family, otherwise the classification of the probe.
#   rc 0 = usable (PASS), rc 1 = reached but refused, rc 2 = transport/other.
client_upstream_family_probe() {
  local upstream="$1" fam="$2" code
  case "$fam" in
    4) [ -n "$(client_egress_v4)" ] || { printf 'unavailable (no local address of this family)\n'; return 2; } ;;
    6) [ -n "$(client_egress_v6)" ] || { printf 'unavailable (no local address of this family)\n'; return 2; } ;;
    *) printf 'unavailable (unknown family)\n'; return 2 ;;
  esac
  code="$(client_probe_code "-$fam" --proxy "$upstream" --proxy-cacert "$(gp_ca_bundle)" \
    --connect-timeout 10 --max-time 20 "${GP_TEST_API_URL:-https://api.github.com/rate_limit}")"
  printf '%s\n' "$(client_classify_code "$code")"
  case "$code" in
    200) return 0 ;;
    403|407) return 1 ;;
    *) return 2 ;;
  esac
}

# client_pick_candidate <4|6>
# Resolves every candidate address of the family and probes them one by one
# (TLS-verified, read-only). The FIRST candidate that really answers 200 wins;
# DNS order alone is never trusted.
client_pick_candidate() {
  local fam="$1" cands ip res n=0
  cands="$(client_resolve_candidates "$CLIENT_UPSTREAM_HOST" "$fam" | head -n 8)"
  if [ -z "$cands" ]; then
    log_err "no DNS record of family $fam exists for $CLIENT_UPSTREAM_HOST"
    return 1
  fi
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    n=$((n+1))
    res="$(client_candidate_probe "$ip")"
    if [ "$?" = "0" ]; then
      CLIENT_UPSTREAM_PEER_ADDRESS="$ip"
      log_ok "upstream peer selected: $ip (TLS name stays $CLIENT_UPSTREAM_HOST)"
      return 0
    fi
    log_info "candidate $ip: $res"
  done <<< "$cands"
  log_err "no $fam candidate of $CLIENT_UPSTREAM_HOST passed the probe ($n tried)"
  return 1
}

# client_select_upstream
# The deterministic selection (runs read-only, before any change):
#   auto + both families PASS  -> hostname mode (dual-stack, verified)
#   auto + one family PASS     -> that family, pinned to a probe-verified peer
#   explicit 4/6               -> that family, pinned
#   nothing usable             -> non-zero, with the precise per-family reason
client_select_upstream() {
  # Memoised within one process: the adoption report and the install that
  # follows it must show - and apply - the same decision.
  if [ "${CLIENT_UPSTREAM_SELECTION_DONE:-0}" = "1" ]; then return 0; fi
  local mode="${CLIENT_UPSTREAM_FAMILY:-auto}" v4_rc=0 v6_rc=0 want_abort=0
  case "$mode" in
    auto|4|6) ;;
    ipv4) mode=4 ;;
    ipv6) mode=6 ;;
    *) die "--upstream-family must be auto, 4 or 6 (got '$mode')"; return 1 ;;
  esac
  CLIENT_UPSTREAM_FAMILY="$mode"
  CLIENT_SELECTED_FAMILY=""
  CLIENT_UPSTREAM_PEER_ADDRESS=""

  CLIENT_V4_SUMMARY="$(client_upstream_family_probe "$CLIENT_UPSTREAM" 4)" || v4_rc=$?
  CLIENT_V6_SUMMARY="$(client_upstream_family_probe "$CLIENT_UPSTREAM" 6)" || v6_rc=$?

  case "$mode" in
    auto)
      if [ "$v4_rc" = "0" ] && [ "$v6_rc" = "0" ]; then
        CLIENT_SELECTED_FAMILY="dual"
      elif [ "$v4_rc" = "0" ]; then
        CLIENT_SELECTED_FAMILY="4"
      elif [ "$v6_rc" = "0" ]; then
        CLIENT_SELECTED_FAMILY="6"
      else
        want_abort=1
      fi
      ;;
    4) [ "$v4_rc" = "0" ] && CLIENT_SELECTED_FAMILY="4" || want_abort=1 ;;
    6) [ "$v6_rc" = "0" ] && CLIENT_SELECTED_FAMILY="6" || want_abort=1 ;;
  esac

  if [ "$want_abort" = "1" ]; then
    log_err "no usable path to the upstream $CLIENT_UPSTREAM_HOST:"
    log_err "  IPv4: $CLIENT_V4_SUMMARY"
    log_err "  IPv6: $CLIENT_V6_SUMMARY"
    if [ "$v4_rc" = "1" ] || [ "$v6_rc" = "1" ]; then
      log_err "  the upstream was REACHED but refused this host: authorise this"
      log_err "  host's exact address on the server (ghproxyctl client add)"
    else
      log_err "  the upstream could not be reached over either family: check the"
      log_err "  route, firewall or a blackholed path - this is NOT an authorisation failure"
    fi
    if [ "$mode" != "auto" ]; then
      log_err "  (--upstream-family $mode was requested explicitly)"
    fi
    return 1
  fi

  if [ "$CLIENT_SELECTED_FAMILY" != "dual" ]; then
    client_pick_candidate "$CLIENT_SELECTED_FAMILY" || return 1
    log_info "upstream family $CLIENT_SELECTED_FAMILY selected (peer $CLIENT_UPSTREAM_PEER_ADDRESS)"
  else
    log_info "both families verified usable: keeping the dual-stack hostname $CLIENT_UPSTREAM_HOST"
  fi
  CLIENT_UPSTREAM_SELECTION_DONE=1
  return 0
}

# client_upstream_probe_family_flag -> "" or "-4"/"-6" for the selected family
client_upstream_probe_family_flag() {
  case "${CLIENT_SELECTED_FAMILY:-}" in
    4) printf '%s' "-4" ;;
    6) printf '%s' "-6" ;;
    *) printf '' ;;
  esac
}

# client_upstream_refresh : re-resolve and re-verify the upstream path
# DNS answers change; a pinned peer address must not silently rot. This
# re-runs the selection with the recorded mode:
#   * same outcome  -> no-op, nothing is written
#   * new peer/family -> transactional update: render, squid -k parse, reload,
#     full health check; any failure rolls the previous configuration back.
# Komari and every other migration are never touched.
client_upstream_refresh() {
  client_require_installed || return 1
  local old_peer old_sel
  old_sel="$CLIENT_SELECTED_FAMILY"
  old_peer="$CLIENT_UPSTREAM_PEER_ADDRESS"
  log_head "vps-gateway-manager :: client upstream refresh"
  if ! client_select_upstream; then
    log_err "the refresh found no usable path; nothing was changed"
    return 1
  fi
  if [ "$CLIENT_SELECTED_FAMILY" = "$old_sel" ] && [ "$CLIENT_UPSTREAM_PEER_ADDRESS" = "$old_peer" ]; then
    if [ "$CLIENT_SELECTED_FAMILY" = "dual" ]; then
      log_ok "upstream path unchanged (hostname $CLIENT_UPSTREAM_HOST, both families verified)"
    else
      log_ok "upstream path unchanged (family $CLIENT_SELECTED_FAMILY, peer $CLIENT_UPSTREAM_PEER_ADDRESS)"
    fi
    return 0
  fi
  log_info "upstream path changed:"
  log_info "  before: family ${old_sel:-unknown} peer ${old_peer:-<hostname>}"
  log_info "  after : family $CLIENT_SELECTED_FAMILY peer ${CLIENT_UPSTREAM_PEER_ADDRESS:-<hostname>}"
  if gp_dry_run; then
    log_dry "nothing was changed: this was a read-only refresh plan"
    return 0
  fi

  txn_begin "client upstream refresh" || return 1
  trap 'txn_rollback "unexpected error during upstream refresh"' ERR
  local tmp
  tmp="$(mktemp)"
  client_render_squid_conf > "$tmp" || { rm -f "$tmp"; txn_rollback "render"; return 1; }
  if ! squid_parse "$tmp"; then
    rm -f "$tmp"
    txn_rollback "the refreshed configuration does not parse"
    return 1
  fi
  txn_install_file "$tmp" "$CLIENT_CONF_FILE" 0644 || { rm -f "$tmp"; txn_rollback "install"; return 1; }
  rm -f "$tmp"
  record_managed_file "$CLIENT_CONF_FILE" modified

  txn_backup_file "$(gp_client_conf)" || true
  client_state_write

  if ! squid_reload "$CLIENT_SERVICE" "$CLIENT_CONF_FILE"; then
    txn_rollback "the reload could not be confirmed"
    return 1
  fi
  txn_service "$CLIENT_SERVICE" reload

  hc_reset
  if ! hc_client_full; then
    hc_print >&2
    log_err "the local proxy is not healthy with the new upstream path; rolling back"
    txn_rollback "health check failure"
    return 1
  fi
  txn_commit success || return 1
  trap - ERR
  hc_print
  log_ok "upstream path refreshed: family $CLIENT_SELECTED_FAMILY, peer ${CLIENT_UPSTREAM_PEER_ADDRESS:-<hostname>}"
  return 0
}

# -----------------------------------------------------------------------------
# Rendering / installation of the local instance
# -----------------------------------------------------------------------------
client_render_squid_conf() {
  local ipv6_line="" user grp peer_opts ssl_domain="" peer
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  if has_ipv6_loopback; then
    ipv6_line="http_port [::1]:${CLIENT_LOCAL_PORT}"
  else
    ipv6_line="# (no IPv6 loopback on this host: skipping [::1] listener)"
  fi
  if [ "${CLIENT_UPSTREAM_SCHEME:-https}" = "https" ]; then
    peer_opts="tls tls-cafile=${CLIENT_UPSTREAM_CA}"
  else
    peer_opts=""
  fi
  # Network peer vs logical TLS name: with a pinned family the peer token is the
  # concrete address, while ssldomain= keeps the certificate verified against
  # the upstream hostname.
  peer="$CLIENT_UPSTREAM_HOST"
  if [ -n "${CLIENT_UPSTREAM_PEER_ADDRESS:-}" ]; then
    peer="$(client_peer_token "$CLIENT_UPSTREAM_PEER_ADDRESS")"
    ssl_domain="ssldomain=${CLIENT_UPSTREAM_SSL_DOMAIN:-$CLIENT_UPSTREAM_HOST}"
  elif [ -n "${CLIENT_UPSTREAM_SSL_DOMAIN:-}" ]; then
    ssl_domain="ssldomain=${CLIENT_UPSTREAM_SSL_DOMAIN}"
  fi
  render_template client-squid.conf \
    "CLIENT_TAG=$CLIENT_TAG" \
    "LOCAL_PORT=$CLIENT_LOCAL_PORT" \
    "UPSTREAM_HOST=$CLIENT_UPSTREAM_HOST" \
    "UPSTREAM_PEER=$peer" \
    "UPSTREAM_PORT=$CLIENT_UPSTREAM_PORT" \
    "PEER_TLS_OPTIONS=$peer_opts" \
    "PEER_SSL_DOMAIN=$ssl_domain" \
    "DOMAIN_ACL_FILE=$(gp_domains_file)" \
    "PID_FILE=${CLIENT_RUNTIME_DIR:-/run/vps-gateway-manager}/squid.pid" \
    "COREDUMP_DIR=${CLIENT_SPOOL_DIR:-/var/spool/vps-gateway-manager}" \
    "EFFECTIVE_USER=$user" \
    "EFFECTIVE_GROUP=$grp" \
    "ACCESS_LOG=${CLIENT_ACCESS_LOG:-/var/log/vps-gateway-manager/access.log}" \
    "CACHE_LOG=${CLIENT_LOG_DIR:-/var/log/vps-gateway-manager}/cache.log" \
    "IPV6_LOOPBACK_LISTENER=$ipv6_line"
}

client_render_unit() {
  local user grp
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  render_template client.service \
    "SQUID_BIN=${SQUID_BIN:-/usr/sbin/squid}" \
    "CONF_FILE=${CLIENT_CONF_FILE:-/etc/vps-gateway-manager/client-squid.conf}" \
    "RUNTIME_DIR=${CLIENT_RUNTIME_DIR:-/run/vps-gateway-manager}" \
    "LOG_DIR=${CLIENT_LOG_DIR:-/var/log/vps-gateway-manager}" \
    "SPOOL_DIR=${CLIENT_SPOOL_DIR:-/var/spool/vps-gateway-manager}" \
    "EFFECTIVE_USER=$user" \
    "EFFECTIVE_GROUP=$grp"
}

client_prepare_dirs() {
  local user grp d
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  # Record the PRE-INSTALL state of the runtime/log/spool directories (usually
  # "absent"): a rollback must remove them together with whatever the failed
  # run left inside - txn_mkdir alone only removes empty directories.
  for d in "$CLIENT_RUNTIME_DIR" "$CLIENT_LOG_DIR" "$CLIENT_SPOOL_DIR"; do
    txn_backup_file "$d" || return 1
  done
  txn_mkdir "$(gp_state_dir)" 0700 || return 1
  txn_mkdir "$CLIENT_RUNTIME_DIR" 0755 || return 1
  txn_mkdir "$CLIENT_LOG_DIR" 0755 || return 1
  txn_mkdir "$CLIENT_SPOOL_DIR" 0755 || return 1
  if ! gp_dry_run; then
    chown -R "$user:$grp" "$CLIENT_RUNTIME_DIR" "$CLIENT_LOG_DIR" "$CLIENT_SPOOL_DIR" 2>/dev/null || true
    chmod 0755 "$CLIENT_RUNTIME_DIR" "$CLIENT_LOG_DIR" "$CLIENT_SPOOL_DIR" 2>/dev/null || true
  fi
  return 0
}

client_install_squid_conf() {
  local tmp
  tmp="$(mktemp)"
  client_render_squid_conf > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! gp_dry_run; then
    if ! squid_parse "$tmp"; then
      rm -f "$tmp"
      log_err "the generated client configuration does not parse"
      return 1
    fi
  else
    log_dry "validate the generated client config with squid -k parse"
  fi
  txn_install_file "$tmp" "$CLIENT_CONF_FILE" 0644 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  record_managed_file "$CLIENT_CONF_FILE" created
  return 0
}

client_install_unit_file() {
  local tmp
  tmp="$(mktemp)"
  client_render_unit > "$tmp" || { rm -f "$tmp"; return 1; }
  txn_install_file "$tmp" "$CLIENT_UNIT_FILE" 0644 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  record_managed_file "$CLIENT_UNIT_FILE" created
  systemctl_cmd daemon-reload
  txn_cmd "systemctl daemon-reload"
  return 0
}

client_start_service() {
  if gp_dry_run; then
    log_dry "systemctl enable --now $CLIENT_SERVICE"
    log_dry "wait for 127.0.0.1:$CLIENT_LOCAL_PORT to accept connections"
    return 0
  fi
  # The journal records FORWARD actions (the engine inverts them on rollback),
  # exactly like server-ops does. (P0.5: this used to record the *undo* verbs,
  # so a rollback re-enabled and re-started a unit that had never existed
  # before the install.) Enablement is only journaled when we change it, so a
  # rollback restores the PRE-INSTALL state, not more.
  local was_enabled=0
  systemctl_enabled "$CLIENT_SERVICE" && was_enabled=1
  if [ "$was_enabled" = "0" ]; then
    txn_service "$CLIENT_SERVICE" enable
  fi
  systemctl_cmd enable "$CLIENT_SERVICE" || true
  if systemctl_active "$CLIENT_SERVICE"; then
    squid_reload "$CLIENT_SERVICE" "$CLIENT_CONF_FILE" || return 1
    txn_service "$CLIENT_SERVICE" reload
  else
    txn_service "$CLIENT_SERVICE" start
    systemctl_cmd start "$CLIENT_SERVICE" || return 1
  fi
  local i=0
  while [ "$i" -lt 15 ]; do
    systemctl_active "$CLIENT_SERVICE" && break
    sleep 1; i=$((i+1))
  done
  systemctl_active "$CLIENT_SERVICE" || { log_err "$CLIENT_SERVICE did not start"; return 1; }
  # Squid binds its listeners a moment after the unit becomes active.
  wait_for_port "$CLIENT_LOCAL_PORT" 15 || { log_err "the local proxy is not accepting connections"; return 1; }
  return 0
}

# -----------------------------------------------------------------------------
# Shell environment (/etc/profile.d) and sudo environment
# -----------------------------------------------------------------------------
client_collect_no_proxy() {
  # Unions every NO_PROXY value we can find, plus the mandatory loopback set.
  local merged="" f val
  merged="localhost,127.0.0.1,::1,169.254.169.254"
  for f in "$(gp_p /etc/environment)" /etc/environment; do
    [ -r "$f" ] || continue
    val="$(sed -n 's/^[[:space:]]*\(NO_PROXY\|no_proxy\)=//p' "$f" | tail -n 1 | tr -d '"'"'"'')"
    if [ -n "$val" ]; then merged="$merged,$val"; fi
  done
  if [ -d "$(gp_profile_d)" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$f" = "${CLIENT_PROFILE_FILE:-}" ] && continue
      val="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?\(NO_PROXY\|no_proxy\)=//p' "$f" | tail -n 1 | tr -d '"'"'"'')"
      if [ -n "$val" ]; then merged="$merged,$val"; fi
    done < <(find "$(gp_profile_d)" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort)
  fi
  val="${NO_PROXY:-${no_proxy:-}}"
  if [ -n "$val" ]; then merged="$merged,$val"; fi
  # Recorded merges from migrations (e.g. the Komari NO_PROXY list).
  if [ -d "$(CLIENT_MIGRATIONS_DIR)" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      val="$(sed -n 's/^no_proxy=//p' "$f" | tail -n 1)"
      if [ -n "$val" ]; then merged="$merged,$val"; fi
    done < <(find "$(CLIENT_MIGRATIONS_DIR)" -maxdepth 1 -name '*.env' -type f 2>/dev/null | sort)
  fi
  printf '%s\n' "$merged" | csv_merge
}

client_install_profile() {
  local no_proxy tmp
  no_proxy="$(client_collect_no_proxy)"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# =============================================================================
# vps-gateway-manager :: shell environment
#
# Installed by install.sh client. Uninstall with: sudo ghproxyctl uninstall
#
# GitHub traffic goes through the local smart proxy (127.0.0.1:${CLIENT_LOCAL_PORT}),
# which forwards GitHub to ${CLIENT_UPSTREAM:-the upstream proxy} and sends
# everything else DIRECT.
#
# NO_PROXY keeps your previous entries: they were merged, not replaced.
# =============================================================================
HTTP_PROXY="http://127.0.0.1:${CLIENT_LOCAL_PORT}"
HTTPS_PROXY="http://127.0.0.1:${CLIENT_LOCAL_PORT}"
http_proxy="http://127.0.0.1:${CLIENT_LOCAL_PORT}"
https_proxy="http://127.0.0.1:${CLIENT_LOCAL_PORT}"

NO_PROXY="${no_proxy}"
no_proxy="\${NO_PROXY}"

# Keep entries a login shell may have set before this file was read.
gsp_no_proxy_extra="\${NO_PROXY:-}"
case "\$gsp_no_proxy_extra" in
  ""|"${no_proxy}") : ;;
  *) NO_PROXY="${no_proxy},\$gsp_no_proxy_extra"; no_proxy="\$NO_PROXY" ;;
esac
unset gsp_no_proxy_extra

export HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
EOF
  txn_install_file "$tmp" "$CLIENT_PROFILE_FILE" 0644 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  record_managed_file "$CLIENT_PROFILE_FILE" created
  return 0
}

client_install_sudoers() {
  local tmp
  if [ ! -d "$(dirname "$CLIENT_SUDOERS_FILE")" ]; then
    log_debug "no /etc/sudoers.d on this host; skipping the sudo environment file"
    return 0
  fi
  if ! have visudo; then
    log_warn "visudo is not available; refusing to install an unvalidated sudoers file"
    return 0
  fi
  tmp="$(mktemp)"
  render_template sudoers.conf > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log_err "the generated sudoers file failed 'visudo -cf'; not installing it"
    return 1
  fi
  chmod 0440 "$tmp"
  txn_install_file "$tmp" "$CLIENT_SUDOERS_FILE" 0440 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  if ! gp_dry_run; then
    if ! visudo -c >/dev/null 2>&1; then
      log_err "the system sudoers configuration is now invalid; removing our file again"
      rm -f "$CLIENT_SUDOERS_FILE"
      return 1
    fi
  fi
  record_managed_file "$CLIENT_SUDOERS_FILE" created
  log_ok "sudo environment passthrough installed ($CLIENT_SUDOERS_FILE)"
  return 0
}

# -----------------------------------------------------------------------------
# Git configuration (GitHub only, never a global http.proxy)
# -----------------------------------------------------------------------------
client_git_proxy_url() { printf 'http://127.0.0.1:%s\n' "$CLIENT_LOCAL_PORT"; }

client_git_record() {
  local user="$1" home="$2" key="$3" before="$4" applied="$5" f
  f="$(CLIENT_MIGRATIONS_DIR)/git-${user}.env"
  {
    printf 'name=git-%s\n' "$user"
    printf 'kind=git\nuser=%s\nhome=%s\nkey=%s\nbefore=%s\napplied=%s\nrecorded_at=%s\n' \
      "$user" "$home" "$key" "$before" "$applied" "$(gp_ts_human)"
  } | gp_atomic_write "$f" 0600
  return 0
}

client_git_configure_user() {
  local user="$1" home="" key="http.https://github.com.proxy" want before rc=0
  want="$(client_git_proxy_url)"
  home="$(user_home "$user")" || { log_warn "cannot resolve the home directory of '$user'"; return 0; }
  if ! have git; then log_debug "git is not installed; skipping git configuration"; return 0; fi
  before="$(as_user "$user" env HOME="$home" git config --global --get "$key" 2>/dev/null || true)"
  if [ "$before" = "$want" ]; then
    log_ok "git proxy already correct for $user ($key)"
    return 0
  fi
  if gp_dry_run; then
    log_dry "git config --global $key=$want (for $user; previous: ${before:-unset})"
    return 0
  fi
  as_user "$user" env HOME="$home" git config --global "$key" "$want" || rc=1
  if [ "$rc" -ne 0 ]; then
    log_warn "could not set $key for $user"
    return 0
  fi
  client_git_record "$user" "$home" "$key" "${before:-__UNSET__}" "$want"
  txn_cmd "[ '${before:-__UNSET__}' = __UNSET__ ] && ( command -v runuser >/dev/null && runuser -u '$user' -- env HOME='$home' git config --global --unset '$key' || true ) || ( command -v runuser >/dev/null && runuser -u '$user' -- env HOME='$home' git config --global '$key' '$before' || true )"
  log_ok "configured git for $user: $key=$want (previous: ${before:-unset})"
  return 0
}

client_git_configure() {
  local users u
  [ "$CLIENT_MANAGE_GIT" = "1" ] || { log_info "git configuration skipped (--no-git-config)"; return 0; }
  users="$(client_target_users "${CLIENT_GIT_USERS:-auto}")"
  if [ -z "$users" ]; then
    log_info "no users targeted for git configuration"
    return 0
  fi
  printf '%s\n' "$users" | while IFS= read -r u; do
    [ -n "$u" ] || continue
    client_git_configure_user "$u" || true
  done
  return 0
}

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
client_install_run() {
  local rc=0
  log_head "vps-gateway-manager :: client install"
  client_set_defaults

  if [ -z "$CLIENT_UPSTREAM" ]; then
    die "--upstream is required, e.g. --upstream https://gh.example.com:8443"
    return 1
  fi
  client_parse_upstream || return 1

  if [ "$(gp_role)" = "server" ]; then
    die "this host is already configured as a proxy server; a client install would overwrite its state"
    return 1
  fi

  if port_in_use "$CLIENT_LOCAL_PORT"; then
    local owner
    owner="$(listener_owner "$CLIENT_LOCAL_PORT")"
    case "$owner" in
      *squid*) log_info "port $CLIENT_LOCAL_PORT already served by squid (idempotent re-run)" ;;
      *) die "port $CLIENT_LOCAL_PORT is already in use: ${owner:-unknown}"; return 1 ;;
    esac
  fi

  # Read-only family/candidate selection BEFORE anything is installed. When no
  # path to the upstream is usable this aborts with nothing written on disk and
  # nothing migrated (the London pilot's lesson: never let a broken family be
  # discovered by the health checks after the fact).
  if ! client_select_upstream; then
    log_err "no usable upstream path; nothing was installed"
    return 1
  fi

  txn_begin "client install (upstream ${CLIENT_UPSTREAM})" || return 1
  trap 'txn_rollback "unexpected error during client install"' ERR

  client_install_ca || { txn_rollback "ca-certificates"; return 1; }
  client_install_squid_if_needed || { txn_rollback "squid unavailable"; return 1; }
  client_prepare_dirs || { txn_rollback "directories"; return 1; }

  if ! gp_dry_run; then
    # Journal the state writes too (P0.5 / §10): a rollback must remove them,
    # leaving the host unconfigured exactly as it was before the install.
    txn_write_text "$(gp_role_file)" 0600 "client" || return 1
    txn_write_text "$(gp_state_dir)/version" 0644 "${VGM_VERSION:-unknown}" || return 1
  fi
  txn_backup_file "$(gp_domains_file)" || true
  domains_seed_from_template || { txn_rollback "destination list"; return 1; }
  record_managed_file "$(gp_domains_file)" created

  client_install_squid_conf || { txn_rollback "squid config"; return 1; }
  client_install_unit_file || { txn_rollback "systemd unit"; return 1; }
  client_install_profile || { txn_rollback "profile.d"; return 1; }
  client_install_sudoers || { txn_rollback "sudoers"; return 1; }

  txn_backup_file "$(gp_client_conf)" || true
  client_state_write
  record_managed_file "$(gp_client_conf)" created

  client_start_service || { txn_rollback "service start"; return 1; }
  sleep 1

  hc_reset
  if gp_dry_run; then
    log_dry "run the client health suite: upstream TLS, GitHub API/Raw/Release through the parent, non-GitHub direct"
  elif ! hc_client_full; then
    hc_print >&2
    log_err "client health checks failed; rolling back the install"
    txn_rollback "health check failure"
    return 1
  fi

  # Git configuration happens only after the proxy is proven to work.
  client_git_configure || true

  txn_commit success || return 1
  trap - ERR
  rc=0
  gp_install_toolchain || log_warn "toolchain installation reported a problem"
  txn_prune_backups 20
  hc_print
  log_ok "client install complete"
  return "$rc"
}

client_parse_upstream() {
  local parsed
  parsed="$(parse_upstream_url "$CLIENT_UPSTREAM")" || return 1
  CLIENT_UPSTREAM_HOST="$(printf '%s' "$parsed" | cut -f1)"
  CLIENT_UPSTREAM_PORT="$(printf '%s' "$parsed" | cut -f2)"
  CLIENT_UPSTREAM_SCHEME="$(printf '%s' "$parsed" | cut -f3)"
  if [ "$CLIENT_UPSTREAM_SCHEME" != "https" ] && [ "${CLIENT_ALLOW_PLAINTEXT_UPSTREAM:-0}" != "1" ]; then
    die "upstream scheme '$CLIENT_UPSTREAM_SCHEME' would send proxy traffic without TLS"
    log_err "use https:// (or pass --allow-plaintext-upstream if you really mean it)"
    return 1
  fi
  if [ -n "${CLIENT_UPSTREAM_CA:-}" ] && [ ! -r "$CLIENT_UPSTREAM_CA" ]; then
    die "CA bundle not readable: $CLIENT_UPSTREAM_CA"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Adopt an existing client (Komari / xray-manager / Git already on the remote proxy)
# -----------------------------------------------------------------------------
# client_probe_code <curl args...> -> the HTTP status of a proxy request, or 000
# when it could not be completed.
# curl already prints the "%{http_code}" marker (000) and then exits non-zero on
# a connection failure; appending another "000" from a fallback would produce
# "000000" and hide the real result. The value is sanitised to one status code.
client_probe_code() {
  local code=""
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)" || true
  case "$code" in
    ''|*[!0-9]*) code=000 ;;
  esac
  printf '%s\n' "$code"
  return 0
}

# Check whether the remote proxy already authorises this host's egress address.
# This is a read-only probe (a GitHub request THROUGH the upstream) and therefore
# runs in dry-run mode too: it writes nothing, changes nothing and never touches
# the whitelist. TLS is always verified (no -k/--insecure); the timeout is bounded.
# When a family is selected the probe is forced to that family, so the whitelist
# verdict matches the path the local proxy will actually use.
hc_upstream_whitelist_check() {
  local upstream="$1" code famflag
  famflag="$(client_upstream_probe_family_flag)"
  code="$(client_probe_code ${famflag:+"$famflag"} --proxy "$upstream" --proxy-cacert "$(gp_ca_bundle)" \
    --connect-timeout 10 --max-time 20 https://api.github.com/rate_limit)"
  printf '%s\n' "$code"
  case "$code" in
    200) return 0 ;;
    *)   return 1 ;;
  esac
}

# Global (non-link-local) egress addresses, one per line.
client_egress_v4() {
  have ip || return 0
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  return 0
}

client_egress_v6() {
  have ip || return 0
  ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^fe80' || true
  return 0
}

client_egress_addresses() {
  printf 'IPv4: %s\n' "$(client_egress_v4 | tr '\n' ' ' | sed 's/ $//' | sed 's/^$/none/')"
  printf 'IPv6: %s\n' "$(client_egress_v6 | tr '\n' ' ' | sed 's/ $//' | sed 's/^$/none/')"
  return 0
}

# komari_execstart_report <unit>
# Prints the allowlisted summary of the service's ExecStart. The raw command
# line is NEVER printed, not even truncated: credentials can sit in flags
# (-t/--token and friends), URIs, headers or environment assignments, and
# "cut -c" is not redaction. Only presence is reported.
komari_execstart_report() {
  local unit="$1" raw="" endpoint="not found" token="not found"
  raw="$(systemctl show "$unit" -p ExecStart 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    printf '  ExecStart         : not detected\n'
    return 0
  fi
  printf '  ExecStart         : detected (redacted; the command line is never displayed)\n'
  if printf '%s' "$raw" | grep -qE '(^|[[:space:]])(-e|--endpoint)(=|[[:space:]])'; then
    endpoint="detected, value hidden"
  fi
  if printf '%s' "$raw" | grep -qE '(^|[[:space:]])(-t|--token)(=|[[:space:]])'; then
    token="detected, value hidden"
  fi
  printf '  Endpoint          : %s\n' "$endpoint"
  printf '  Token             : %s\n' "$token"
  return 0
}

client_adopt_report() {
  local upstream="$1" code rc=0
  log_head "client adoption plan (read-only)"
  printf 'host                : %s\n' "$(hostname 2>/dev/null || printf unknown)"
  printf 'distribution        : %s %s\n' "$(gp_os_id)" "$(gp_os_version)"
  printf 'upstream            : %s\n' "$upstream"
  printf 'local proxy         : 127.0.0.1:%s (new, loopback only)\n' "${CLIENT_LOCAL_PORT:-3129}"
  printf 'egress addresses    :\n'
  client_egress_addresses | sed 's/^/  /'
  printf 'upstream path       :\n'
  # The same read-only selection the install will apply (memoised in-process).
  if client_select_upstream; then
    printf '  IPv4: %s\n' "${CLIENT_V4_SUMMARY:-not probed}"
    printf '  IPv6: %s\n' "${CLIENT_V6_SUMMARY:-not probed}"
    if [ "$CLIENT_SELECTED_FAMILY" = "dual" ]; then
      printf '  selected family    : hostname (both families verified usable)\n'
    else
      printf '  selected family    : IPv%s\n' "$CLIENT_SELECTED_FAMILY"
      printf '  selected peer      : %s (TLS name stays %s)\n' \
        "$CLIENT_UPSTREAM_PEER_ADDRESS" "$CLIENT_UPSTREAM_HOST"
    fi
  else
    # A 000 result is transport, never an authorisation verdict; a single
    # working family is auto-selected instead of warning about it.
    printf '  IPv4: %s\n' "${CLIENT_V4_SUMMARY:-not probed}"
    printf '  IPv6: %s\n' "${CLIENT_V6_SUMMARY:-not probed}"
    printf '  selected family    : NONE - no usable path to the upstream\n'
  fi
  printf '\n'

  if migrate_komari_plan; then
    printf 'Komari agent        : %s\n' "$KOMARI_UNIT"
    printf '  unit files        :\n'
    printf '%s\n' "$KOMARI_FILES" | sed '/^$/d' | sed 's/^/    /'
    komari_execstart_report "$KOMARI_UNIT"
    printf '  current proxy     :\n'
    unit_proxy_vars "$KOMARI_UNIT" | gp_redact_url_credentials | sed 's/^/    /'
    printf '  NO_PROXY          : %s\n' "${KOMARI_NO_PROXY:-<none>}"
    printf '  EnvironmentFile   : %s\n' "$([ "$KOMARI_ENVFILE" = "1" ] && printf 'present (manual migration required)' || printf 'not used')"
    if [ "$KOMARI_HAS_UPSTREAM" = "1" ]; then
      printf '  plan              : rewrite the 4 proxy variables -> http://127.0.0.1:%s, merge NO_PROXY, daemon-reload, restart, verify\n' "$CLIENT_LOCAL_PORT"
    else
      printf '  plan              : no change (does not point at %s)\n' "$upstream"
    fi
    printf '\n'
  else
    printf 'Komari agent        : not detected\n\n'
  fi

  migrate_xray_manager_plan
  if [ "$XRAYM_PRESENT" = "1" ]; then
    printf 'xray-manager        : %s = %s\n' "$XRAYM_FILE" \
      "$(gp_redact_url_credentials "$XRAYM_VALUE")"
    if value_is_upstream "$XRAYM_VALUE"; then
      printf '  plan              : rewrite -> http://127.0.0.1:%s (backup kept)\n' "$CLIENT_LOCAL_PORT"
    else
      printf '  plan              : no change\n'
    fi
  else
    printf 'xray-manager        : %s not present (nothing created without confirmation)\n' "$XRAYM_FILE"
  fi
  printf '\n'

  printf 'Git configuration   :\n'
  local u before generic
  for u in $(client_target_users "${CLIENT_GIT_USERS:-auto}"); do
    [ -n "$u" ] || continue
    before="$(as_user "$u" env HOME="$(user_home "$u")" git config --global --get http.https://github.com.proxy 2>/dev/null || true)"
    generic="$(as_user "$u" env HOME="$(user_home "$u")" git config --global --get http.proxy 2>/dev/null || true)"
    printf '  %-10s http.https://github.com.proxy = %s\n' "$u" "${before:-<unset>}"
    printf '  %-10s http.proxy                    = %s\n' "$u" "${generic:-<unset>}"
  done
  printf '\n'

  migrate_environment_plan
  if [ "$ENV_HAS_UPSTREAM" = "1" ]; then
    printf '/etc/environment    : points at the upstream proxy (global)\n'
    printf '  plan              : %s\n' \
      "$([ "${CLIENT_MIGRATE_GLOBAL_ENV:-0}" = "1" ] && printf 'migrate (explicitly requested)' || printf 'LEAVE UNCHANGED - needs --migrate-global-env')"
    printf '\n'
  fi

  # Read-only probe through the upstream. Runs in dry-run mode as well: it is a
  # TLS-verified GitHub request and changes nothing (the whitelist itself is
  # never touched - that happens on the server, by the operator).
  printf 'remote whitelist check (does %s already allow this host?):\n' "$upstream"
  code="$(hc_upstream_whitelist_check "$upstream")" || rc=1
  case "$code" in
    200)     printf '  PASS: a GitHub request through the upstream succeeded\n' ;;
    403|407) printf '  FAIL: the upstream refused this host (HTTP %s).\n' "$code"
             printf '        On the server run:  ghproxyctl client add <this-host-egress-ip> <name>\n' ;;
    000)     printf '  FAIL: TRANSPORT UNAVAILABLE (HTTP %s) - the upstream was not reached;\n' "$code"
             printf '        check the address, route, firewall or a blackholed path.\n'
             printf '        This is NOT an authorisation problem.\n' ;;
    *)       printf '  WARN: could not verify through the upstream (HTTP %s)\n' "$code" ;;
  esac
  printf '\n'
  log_head "what will NOT be touched"
  printf '  * Komari Endpoint, Token and ExecStart\n'
  printf '  * any systemd unit body other than the four proxy variables\n'
  printf '  * other proxy software (xray, 3x-ui, tinyproxy, distribution squid)\n'
  printf '  * firewall rules, routes, DNS\n'
  return "$rc"
}

client_adopt_run() {
  local rc=0 upstream already=0 snapshot
  log_head "vps-gateway-manager :: client adopt-existing"
  client_set_defaults
  if [ -z "$CLIENT_UPSTREAM" ] && [ -r "$(gp_client_conf)" ]; then
    CLIENT_UPSTREAM="$(conf_get "$(gp_client_conf)" upstream '')"
  fi
  if [ -z "$CLIENT_UPSTREAM" ]; then
    die "--upstream is required (e.g. --upstream https://gh.example.com:8443)"
    return 1
  fi
  client_parse_upstream || return 1

  # 1. inspect the current state (also useful as the humans' before-picture).
  #    The scan is kept in a private temporary file for this run only; nothing is
  #    persisted and the file is removed below.
  snapshot="$(mktemp)"
  migrate_scan_raw > "$snapshot" 2>/dev/null || true
  if gp_dry_run; then
    log_info "current proxy references inspected (read-only; nothing persisted)"
  else
    log_info "current proxy references inspected (see report below)"
  fi

  # 2. plan
  if gp_dry_run; then
    client_adopt_report "$CLIENT_UPSTREAM" || rc=$?
    rm -f "$snapshot"
    printf '\n'
    log_dry "nothing was changed: this was a read-only adoption analysis"
    if [ "$rc" -ne 0 ]; then
      log_warn "the remote whitelist pre-check did not pass; nothing was changed"
    fi
    return "$rc"
  fi

  client_adopt_report "$CLIENT_UPSTREAM" || rc=$?
  rm -f "$snapshot"
  if [ "$rc" -ne 0 ]; then
    log_warn "the remote whitelist pre-check did not pass"
    if [ "${CLIENT_FORCE_ADOPT:-0}" != "1" ]; then
      log_err "aborting before any change: the local proxy could not reach GitHub through the upstream."
      log_err "Fix the whitelist on the server first, or re-run with --force to continue anyway."
      return 1
    fi
    log_warn "--force given: continuing despite the failed pre-check"
    rc=0
  fi

  # 3. local smart proxy: install (or verify) BEFORE anything is migrated
  if [ "$(gp_role)" = "client" ] && systemctl_active "$CLIENT_SERVICE" 2>/dev/null; then
    already=1
  fi
  if [ "$already" = "0" ]; then
    log_step "step 1/3: installing the local smart proxy"
    client_install_run || { log_err "local proxy installation failed; nothing was migrated"; return 1; }
  else
    log_step "step 1/3: local smart proxy already installed; re-verifying"
    hc_reset
    hc_client_full && hc_print || { log_err "existing local proxy verification failed"; return 1; }
  fi

  # 4. migrations (Komari, xray-manager, Git, optional global env)
  log_step "step 2/3: migrating existing components"
  if ! migrate_auto_apply; then
    log_err "one or more migrations failed; affected components were restored to their previous configuration"
    rc=1
  fi

  # 5. verify the local proxy is still healthy after the migrations
  log_step "step 3/3: final verification"
  hc_reset
  if ! hc_client_full; then
    hc_print >&2
    log_err "the local proxy is not healthy after migration; see above"
    rc=1
  else
    hc_print
  fi

  migrate_report
  if [ "$rc" -eq 0 ]; then
    log_ok "client adoption complete"
  else
    log_warn "client adoption finished with problems - review the report above"
  fi
  return "$rc"
}

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
client_uninstall() {
  local rc=0 purge="${1:-0}" user
  client_require_installed || return 1
  log_head "vps-gateway-manager :: client uninstall"

  if ! confirm "Remove the local smart proxy and restore migrated settings?" no; then
    log_info "aborted by the operator"
    return 0
  fi

  # 1. Restore migrations first (Komari, xray-manager, git, ...) so that the
  #    machines keep their previous GitHub path before the proxy goes away.
  if declare -F migrate_restore_all >/dev/null 2>&1; then
    migrate_restore_all || log_warn "some migrations could not be restored automatically"
  fi

  if have systemctl; then
    if systemctl_active "$CLIENT_SERVICE"; then
      systemctl_cmd stop "$CLIENT_SERVICE" || true
    fi
    systemctl_cmd disable "$CLIENT_SERVICE" || true
  fi

  txn_begin "client uninstall" || return 1
  trap 'txn_rollback "unexpected error during client uninstall"' ERR
  txn_remove_file "$CLIENT_UNIT_FILE" || true
  txn_remove_file "$CLIENT_CONF_FILE" || true
  txn_remove_file "$CLIENT_PROFILE_FILE" || true
  txn_remove_file "$CLIENT_SUDOERS_FILE" || true
  if [ "$purge" = "1" ]; then
    txn_remove_file "$(gp_client_conf)" || true
    txn_remove_file "$(gp_domains_file)" || true
    txn_remove_file "$(gp_role_file)" || true
    txn_remove_file "$(gp_state_dir)/version" || true
    txn_remove_file "$(gp_bin_dir)/ghproxyctl" || true
  fi
  systemctl_cmd daemon-reload
  txn_commit success || return 1
  trap - ERR
  rc=0
  log_ok "client uninstalled"
  for user in $(client_target_users "${CLIENT_GIT_USERS:-auto}"); do
    log_info "git configuration for $user was restored by the migration rollback"
  done
  if [ "$purge" != "1" ]; then
    log_info "state kept in $(gp_state_dir) (use --purge to remove it)"
  fi
  return "$rc"
}
