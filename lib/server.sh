#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/server.sh
#
# Server-side lifecycle:
#   * fresh install of a dedicated GitHub-only TLS forward proxy (Squid)
#   * non-destructive adoption of an existing production proxy
#   * per-client ACL + firewall management
#   * destination list management
#   * health checks and status
#
# Every mutating path runs inside a txn (lib/txn.sh) and ends with a health
# check; a failed check rolls the whole change back.
# =============================================================================

if [ -n "${GP_SERVER_SH:-}" ]; then
  return 0
fi
GP_SERVER_SH=1

GP_CLIENTS_BEGIN="# >>> vps-gateway-manager clients (managed block) >>>"
GP_CLIENTS_END="# <<< vps-gateway-manager clients (managed block) <<<"
GP_DOMAINS_BEGIN="# >>> vps-gateway-manager domains (managed block) >>>"
GP_DOMAINS_END="# <<< vps-gateway-manager domains (managed block) <<<"

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
server_state_write() {
  local conf
  conf="$(gp_server_conf)"
  conf_set "$conf" mode "${SERVER_MODE:-fresh}" 0600
  conf_set "$conf" domain "${SERVER_DOMAIN:-}"
  conf_set "$conf" tls_port "${SERVER_TLS_PORT:-8443}"
  conf_set "$conf" loopback_port "${SERVER_LOOPBACK_PORT:-3128}"
  conf_set "$conf" service_name "${SERVER_SERVICE:-squid}"
  conf_set "$conf" squid_bin "${SQUID_BIN:-}"
  conf_set "$conf" squid_version "${SQUID_VERSION:-}"
  conf_set "$conf" squid_flavor "${SQUID_FLAVOR:-}"
  conf_set "$conf" squid_pkg "${SQUID_VENDOR_PKG:-}"
  conf_set "$conf" main_config "${SERVER_MAIN_CONF:-}"
  conf_set "$conf" source_acl_file "${SERVER_SOURCE_ACL_FILE:-}"
  conf_set "$conf" domain_acl_name "${SERVER_DOMAIN_ACL_NAME:-}"
  conf_set "$conf" operator_domain_acl_name "${SERVER_OPERATOR_DOMAIN_ACL_NAME:-}"
  conf_set "$conf" client_acl_file "${SERVER_CLIENT_ACL_FILE:-}"
  conf_set "$conf" domains_file "${SERVER_DOMAINS_FILE:-}"
  conf_set "$conf" tls_cert_dir "${SERVER_TLS_DIR:-}"
  conf_set "$conf" cert_live_dir "${SERVER_CERT_LIVE_DIR:-}"
  conf_set "$conf" certbot_hook "${SERVER_CERTBOT_HOOK:-}"
  conf_set "$conf" ufw_managed "${SERVER_UFW_MANAGED:-0}"
  conf_set "$conf" version "${VGM_VERSION:-unknown}"
  conf_set "$conf" updated_at "$(gp_ts_human)"
  return 0
}

server_state_load() {
  local conf
  conf="$(gp_server_conf)"
  [ -r "$conf" ] || return 1
  SERVER_MODE="$(conf_get "$conf" mode fresh)"
  SERVER_DOMAIN="$(conf_get "$conf" domain '')"
  SERVER_TLS_PORT="$(conf_get "$conf" tls_port 8443)"
  SERVER_LOOPBACK_PORT="$(conf_get "$conf" loopback_port 3128)"
  SERVER_SERVICE="$(conf_get "$conf" service_name squid)"
  # The detected Squid must survive a write/load round trip: `ghproxyctl status`
  # runs in a fresh process and would otherwise print empty fields.
  SQUID_BIN="$(conf_get "$conf" squid_bin "${SQUID_BIN:-}")"
  SQUID_VERSION="$(conf_get "$conf" squid_version "${SQUID_VERSION:-}")"
  SQUID_FLAVOR="$(conf_get "$conf" squid_flavor "${SQUID_FLAVOR:-}")"
  SQUID_VENDOR_PKG="$(conf_get "$conf" squid_pkg "${SQUID_VENDOR_PKG:-}")"
  SERVER_MAIN_CONF="$(conf_get "$conf" main_config "$(gp_squid_conf_dir)/squid.conf")"
  SERVER_SOURCE_ACL_FILE="$(conf_get "$conf" source_acl_file '')"
  SERVER_DOMAIN_ACL_NAME="$(conf_get "$conf" domain_acl_name "$GP_MANAGED_DOMAIN_ACL_NAME")"
  SERVER_OPERATOR_DOMAIN_ACL_NAME="$(conf_get "$conf" operator_domain_acl_name '')"
  SERVER_CLIENT_ACL_FILE="$(conf_get "$conf" client_acl_file "$(gp_squid_conf_d)/00-vps-gateway-manager-clients.conf")"
  SERVER_DOMAINS_FILE="$(conf_get "$conf" domains_file "$(gp_domains_file)")"
  SERVER_TLS_DIR="$(conf_get "$conf" tls_cert_dir "$(gp_squid_conf_dir)/tls")"
  SERVER_CERT_LIVE_DIR="$(conf_get "$conf" cert_live_dir '')"
  SERVER_CERTBOT_HOOK="$(conf_get "$conf" certbot_hook '')"
  SERVER_UFW_MANAGED="$(conf_get "$conf" ufw_managed 0)"
  return 0
}

server_require_installed() {
  if [ "$(gp_role)" != "server" ]; then
    die "this host is not configured as a vps-gateway-manager server (role: '$(gp_role)'). Run 'install.sh server' first."
    return 1
  fi
  server_state_load || { die "server state file is missing or unreadable"; return 1; }
  return 0
}

# -----------------------------------------------------------------------------
# Client database (TSV)
#   name <TAB> cidr <TAB> created <TAB> source <TAB> acl_file <TAB> note <TAB> acl_id
#
# `name` keeps exactly what the operator typed (e.g. cn-bj-01) and is used for
# display and lookup; `acl_id` is the Squid-safe identifier (cn_bj_01) used in
# the generated ACL lines.
clients_db_list() {
  local f
  f="$(gp_clients_db)"
  [ -r "$f" ] || return 0
  grep -v '^[[:space:]]*#' "$f" | grep -v '^[[:space:]]*$' || true
}

# clients_db_add <name> <cidr> <source> [acl-file] [note] [acl-id]
#
# One row per client identity:
#   * the same CIDR is an update (metadata refresh), never a second row;
#   * a name or acl_id that already belongs to a DIFFERENT address is refused -
#     silently replacing it would drop a client from the inventory. This is
#     exactly what happened when several adopted hosts share one ACL name;
#     callers must ask clients_unique_import_identity for a free pair.
clients_db_add() {
  local name="$1" cidr="$2" source="${3:-ghproxyctl}" acl_file="${4:-}" note="${5:-}" acl_id="${6:-}"
  local f tmp clash
  f="$(gp_clients_db)"
  [ -n "$acl_id" ] || acl_id="$(slugify "$name")"
  if [ -z "$name" ] || [ -z "$cidr" ]; then
    log_err "clients_db_add: name and cidr are required"
    return 1
  fi
  clash="$(clients_db_list | awk -v n="$name" -v a="$acl_id" -v c="$cidr" -F'\t' \
    '$2 != c && ($1 == n || $7 == a) { printf "%s (%s)", $1, $2; exit }')"
  if [ -n "$clash" ]; then
    log_err "client name/acl_id '$name' already belongs to $clash"
    log_err "refusing to overwrite a different address; choose a unique name"
    return 1
  fi
  if gp_dry_run; then
    log_dry "record client $name -> $cidr (acl_id=$acl_id source=$source)"
    return 0
  fi
  gp_mkdir "$(dirname "$f")" 0700 || return 1
  [ -f "$f" ] || printf '# %s client database (tab separated)\n# name\tcidr\tcreated\tsource\tacl_file\tnote\tacl_id\n' "$GP_PROJECT_NAME" > "$f"
  tmp="${f}.tmp.$$"
  # Replace the row for this address; keep every other row, comments included.
  awk -v c="$cidr" -F'\t' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    $2 == c { next }
    { print }
  ' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$cidr" "$(gp_ts_human)" "$source" "$acl_file" "$note" "$acl_id" >> "$tmp"
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$f" || true
  return 0
}

# clients_unique_import_identity <preferred-display> <preferred-acl-id> <taken-pairs>
#
# <taken-pairs> is a newline-separated list of "display<TAB>acl_id" entries
# already in use (existing inventory rows plus the rows collected in this run).
# Prints "display<TAB>acl_id", suffixed -2/-3/... and _2/_3/... until both are
# free. The adoption plan, the adoption import and `client reimport` all use this
# one function, so the dry-run report and the applied state cannot drift apart.
clients_unique_import_identity() {
  local base="$1" base_id="$2" taken="$3" display acl_id n=2
  [ -n "$base_id" ] || base_id="$(slugify "$base")"
  display="$base"
  acl_id="$base_id"
  while printf '%s\n' "$taken" | awk -F'\t' -v d="$display" -v a="$acl_id" \
        '$1 == d || $2 == a { found = 1 } END { exit !found }'; do
    display="${base}-${n}"
    acl_id="${base_id}_${n}"
    n=$((n + 1))
  done
  printf '%s\t%s\n' "$display" "$acl_id"
  return 0
}

# clients_db_replace_adopted <rows-tsv>
# Replaces every adopted row with the given plan (columns: name, acl_id, cidr,
# note). Managed rows are kept untouched. Used by the reconcile repair path.
clients_db_replace_adopted() {
  local rows="$1" f tmp name acl_id cidr note
  f="$(gp_clients_db)"
  if gp_dry_run; then log_dry "replace adopted rows in $f"; return 0; fi
  tmp="${f}.tmp.$$"
  {
    if [ -r "$f" ]; then grep -E '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true; fi
    clients_db_list | awk -F'\t' '$4 != "adopted" { print }'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  while IFS=$'\t' read -r name acl_id cidr note; do
    [ -n "$name" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$cidr" "$(gp_ts_human)" adopted "$SERVER_SOURCE_ACL_FILE" "${note:-imported}" "$acl_id" >> "$tmp"
  done <<< "$rows"
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$f" || true
  return 0
}

clients_db_remove() {
  local name="$1" slug f tmp
  f="$(gp_clients_db)"
  [ -r "$f" ] || return 1
  slug="$(slugify "$name")"
  if gp_dry_run; then log_dry "remove client $name from $(gp_clients_db)"; return 0; fi
  tmp="${f}.tmp.$$"
  awk -v n="$name" -v s="$slug" -F'\t' \
    '!/^#/ && ($1 == n || $1 == s || $7 == s) { next } { print }' "$f" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

clients_db_get() {
  local name="$1" slug
  slug="$(slugify "$name")"
  clients_db_list | awk -v n="$name" -v s="$slug" -F'\t' '$1 == n || $7 == s || $1 == s { print; exit }'
}

clients_db_field() {
  local name="$1" field="$2" idx
  case "$field" in
    name) idx=1 ;; cidr) idx=2 ;; created) idx=3 ;; source) idx=4 ;;
    acl_file) idx=5 ;; note) idx=6 ;; acl_id) idx=7 ;;
    *) return 1 ;;
  esac
  clients_db_get "$name" | awk -v i="$idx" -F'\t' '{ print $i; exit }'
}

clients_db_find_by_cidr() {
  local cidr="$1"
  clients_db_list | awk -v c="$cidr" -F'\t' '$2 == c { print $1; exit }'
}

clients_db_find_by_acl_id() {
  local acl_id="$1"
  clients_db_list | awk -v a="$acl_id" -F'\t' '$7 == a { print $1; exit }'
}

clients_db_count() { clients_db_list | wc -l | tr -d ' '; }

# -----------------------------------------------------------------------------
# Destination list
# -----------------------------------------------------------------------------
domains_current_list() {
  local f
  f="$(gp_domains_file)"
  [ -r "$f" ] || return 0
  read_lines "$f" | awk '!seen[$0]++'
}

domains_write_list() {
  # domains_write_list <file> ; entries on stdin
  local file="$1" tmp
  if gp_dry_run; then
    log_dry "write destination list to $file"
    cat > /dev/null
    return 0
  fi
  tmp="$(mktemp)" || return 1
  cat > "$tmp"
  gp_atomic_write "$file" 0644 < "$tmp" && { log_debug "wrote $file ($(wc -l < "$tmp" | tr -d ' ') entries)"; rm -f "$tmp"; return 0; }
  rm -f "$tmp"
  return 1
}

domains_seed_from_template() {
  # Copies the documented template (comments stripped) into the runtime file.
  # Idempotent: when the entry set is already correct the file is left alone
  # (no churn, no unnecessary reloads).
  local tpl out current
  tpl="$(gp_templates_dir)/github-domains.txt"
  if [ -r "$tpl" ]; then
    out="$(read_lines "$tpl" | awk '!seen[$0]++')"
  else
    out="$(gp_default_github_domains | read_lines /dev/stdin)"
  fi
  if [ -r "$(gp_domains_file)" ]; then
    current="$(domains_current_list)"
    if [ "$current" = "$out" ]; then
      log_debug "destination list already up to date"
      return 0
    fi
  fi
  {
    printf '# %s github destination list - runtime file\n' "$GP_PROJECT_NAME"
    printf '# generated %s - manage with: ghproxyctl domains add|remove|list\n' "$(gp_ts_human)"
    printf '# only GitHub-operated names belong here; never add shared CDNs (see SECURITY.md)\n'
    printf '%s\n' "$out"
  } | domains_write_list "$(gp_domains_file)"
  # keep the annotated copy for humans
  if [ -r "$tpl" ] && ! gp_dry_run; then
    {
      printf '# copy of templates/github-domains.txt as shipped with %s %s\n' "$GP_PROJECT_NAME" "${VGM_VERSION:-}"
      cat "$tpl"
    } | gp_atomic_write "$(gp_domains_doc)" 0644
  fi
  return 0
}

domains_doc_sync() {
  # Refresh the documented copy so operators can diff what changed.
  local tpl
  tpl="$(gp_templates_dir)/github-domains.txt" 2>/dev/null || tpl=""
  gp_dry_run && { log_dry "refresh $(gp_domains_doc)"; return 0; }
  {
    printf '# runtime destination list for %s (managed)\n\n' "$GP_PROJECT_NAME"
    cat "$(gp_domains_file)" 2>/dev/null || true
    if [ -n "$tpl" ] && [ -r "$tpl" ]; then
      printf '\n\n# ---- upstream template notes ----\n'
      cat "$tpl"
    fi
  } | gp_atomic_write "$(gp_domains_doc)" 0644
  return 0
}

domains_add_entry() {
  local entry="$1" list
  list="$(domains_current_list)"
  if list_contains "$list" "$entry"; then
    log_info "destination already present: $entry"
    return 3
  fi
  printf '%s\n' "$list" "$entry" | domains_write_list "$(gp_domains_file)" || return 1
  domains_doc_sync
  return 0
}

domains_remove_entry() {
  local entry="$1" list new
  list="$(domains_current_list)"
  if ! list_contains "$list" "$entry"; then
    log_info "destination not present: $entry"
    return 3
  fi
  new="$(printf '%s\n' "$list" | grep -vxF -- "$entry" || true)"
  printf '%s\n' "$new" | domains_write_list "$(gp_domains_file)" || return 1
  domains_doc_sync
  return 0
}

# -----------------------------------------------------------------------------
# Rendering
# -----------------------------------------------------------------------------
# The source ACL is one file-backed ACL:
#
#   acl gsp_managed_clients src "<managed-clients.acl>"
#   http_access allow gsp_managed_clients <domain-acl>
#
# Two reasons this shape is mandatory:
#   * Squid ANDs the ACL names on a single http_access line. Writing several
#     per-client ACL names into one rule ("allow A B github_domains") means
#     "a source that is both A and B", i.e. nothing - it can never match.
#     A file-backed source ACL ORs its entries, which is what we want.
#   * add/remove then rewrites only a plain list of CIDRs, so the configuration
#     structure stays stable and there is nothing to chunk.
server_render_managed_clients_acl() {
  local name cidr created source _acl _note _acl_id count=0
  printf '# %s managed client sources (one exact host per line)\n' "$GP_PROJECT_NAME"
  printf '# generated %s by %s %s - do not edit; use ghproxyctl client add|remove\n' \
    "$(gp_ts_human)" "$GP_PROJECT_NAME" "${VGM_VERSION:-}"
  printf '# Squid ORs the entries of a file-backed src ACL. IPv4 /32 and IPv6 /128 only.\n'
  printf '# Clients adopted from the operator own configuration file are NOT listed here:\n'
  printf '# they are authorised by that file, and duplicating them here would keep them\n'
  printf '# authorised even after the operator removes them.\n'
  while IFS=$'\t' read -r name cidr created source _acl _note _acl_id; do
    [ -n "$cidr" ] || continue
    if [ "$source" = "adopted" ]; then continue; fi
    printf '%s\n' "$cidr"
    count=$((count+1))
  done < <(clients_db_list)
  [ "$count" -gt 0 ] || printf '# (no clients are authorised by this list yet)\n'
  return 0
}

server_render_clients_file() {
  # Prints the managed conf.d file to stdout.
  local define_domain_acl="${1:-0}" name cidr created source _acl _note acl_id any=0
  printf '# %s - managed client access rules\n' "$GP_PROJECT_NAME"
  printf '# file state: managed by %s -- generated, do not edit by hand\n' "$GP_PROJECT_NAME"
  printf '# generated %s by %s %s\n' "$(gp_ts_human)" "$GP_PROJECT_NAME" "${VGM_VERSION:-}"
  printf '# use `ghproxyctl client add|remove` - DO NOT EDIT BY HAND; local changes are lost.\n'
  printf '#\n'
  printf '# Why the "00-" prefix: Squid evaluates http_access rules in file load order.\n'
  printf '# On an adopted server this file must be read before any pre-existing rule in\n'
  printf '# the same directory, otherwise a deny rule in another conf.d file would\n'
  printf '# shadow the clients managed here.\n'
  printf '#\n'
  printf '# The source ACL is file backed on purpose: Squid ANDs several ACL names on a\n'
  printf '# single http_access line, so per-client ACL names must never be combined in\n'
  printf '# one rule. The file ORs its entries and is maintained by ghproxyctl.\n'
  printf '#\n'
  printf '# Destination isolation: Squid UNIONs repeated definitions of one ACL name, so\n'
  printf '# an operator ACL name must never be redefined here - that would silently\n'
  printf '# extend the operator own allow rules with our managed destinations.\n'
  if [ -n "${SERVER_OPERATOR_DOMAIN_ACL_NAME:-}" ]; then
    printf '# Operator destination ACL (left untouched): %s\n' "$SERVER_OPERATOR_DOMAIN_ACL_NAME"
  fi
  printf '%s\n' "$GP_CLIENTS_BEGIN"
  if [ "$define_domain_acl" = "1" ]; then
    printf '# project-owned destination ACL (never an operator name)\n'
    printf 'acl %s dstdomain "%s"\n' "${SERVER_DOMAIN_ACL_NAME:-$GP_MANAGED_DOMAIN_ACL_NAME}" "$(gp_domains_file)"
  fi
  printf 'acl gsp_managed_clients src "%s"\n' "$(gp_managed_clients_acl)"
  printf 'http_access allow gsp_managed_clients %s\n' "${SERVER_DOMAIN_ACL_NAME:-$GP_MANAGED_DOMAIN_ACL_NAME}"
  printf '%s\n' "$GP_CLIENTS_END"
  printf '\n# Authorised clients (metadata only; the ACL above is the effective list):\n'
  while IFS=$'\t' read -r name cidr created source _acl _note acl_id; do
    [ -n "$name" ] || continue
    any=1
    if [ "$source" = "adopted" ]; then
      printf '#   %-22s %-44s adopted (authorised by your own configuration file)\n' "$name" "$cidr"
    else
      printf '#   %-22s %-44s managed (acl_id=%s, added %s)\n' "$name" "$cidr" "${acl_id:-$(slugify "$name")}" "$created"
    fi
  done < <(clients_db_list)
  [ "$any" = "1" ] || printf '#   (none yet: ghproxyctl client add <ip> <name>)\n'
  # NOTE: this file intentionally contains NO "http_access deny all".
  # Squid's built-in default is deny, and in adopt mode this file is loaded
  # before the pre-existing whitelist file. A deny rule here would shadow the
  # operator's existing clients and break a working production proxy.
  return 0
}

# server_render_main_config : the squid.conf used for a *fresh* install
server_render_main_config() {
  local ipv6_line="" contact
  contact="${SERVER_ADMIN_CONTACT:-root@$(hostname 2>/dev/null || printf 'localhost')}"
  if has_ipv6_loopback; then
    ipv6_line="http_port [::1]:${SERVER_LOOPBACK_PORT}"
  else
    ipv6_line="# (no IPv6 loopback on this host: skipping [::1] listener)"
  fi
  render_template server-squid.conf \
    "VISIBLE_HOSTNAME=$SERVER_DOMAIN" \
    "ADMIN_CONTACT=$contact" \
    "TLS_PORT=$SERVER_TLS_PORT" \
    "LOOPBACK_PORT=$SERVER_LOOPBACK_PORT" \
    "TLS_CERT=$SERVER_TLS_DIR/fullchain.pem" \
    "TLS_KEY=$SERVER_TLS_DIR/privkey.pem" \
    "DOMAIN_ACL_FILE=$(gp_domains_file)" \
    "CLIENT_ACL_FILE=$SERVER_CLIENT_ACL_FILE" \
    "PID_FILE=${SERVER_PID_FILE:-/run/squid.pid}" \
    "COREDUMP_DIR=${SERVER_SPOOL_DIR:-/var/spool/squid}" \
    "EFFECTIVE_USER=$(squid_effective_user)" \
    "EFFECTIVE_GROUP=$(squid_effective_group)" \
    "ACCESS_LOG=$(gp_squid_log_dir)/access.log" \
    "CACHE_LOG=$(gp_squid_log_dir)/cache.log" \
    "IPV6_LOOPBACK_LISTENER=$ipv6_line"
}

squid_effective_user() {
  if id proxy >/dev/null 2>&1; then printf 'proxy'; return 0; fi
  if id squid >/dev/null 2>&1; then printf 'squid'; return 0; fi
  if id www-data >/dev/null 2>&1; then printf 'www-data'; return 0; fi
  printf 'nobody'
}

squid_effective_group() {
  local user
  user="$(squid_effective_user)"
  id -gn "$user" 2>/dev/null || printf 'nogroup'
}

# -----------------------------------------------------------------------------
# Package handling
# -----------------------------------------------------------------------------
server_install_squid_pkg() {
  local pkg="${SERVER_SQUID_PKG:-squid-openssl}" out rc=0
  if ! have apt-get; then
    die "no apt-get found: install Squid with TLS support manually, then re-run with --adopt-existing"
    return 1
  fi
  if squid_pkg_installed "$pkg"; then
    log_ok "package already installed: $pkg $(squid_pkg_version "$pkg")"
    return 0
  fi
  log_info "installing $pkg (this may take a moment)"
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
    log_err "refusing to substitute a different proxy implementation automatically."
    log_err "Install $pkg manually and re-run."
    return 1
  fi
  log_ok "installed $pkg"
  return 0
}

# -----------------------------------------------------------------------------
# TLS material
# -----------------------------------------------------------------------------
server_tls_dir_prepare() {
  local dir="$1" user grp
  user="$(squid_effective_user)"
  grp="$(squid_effective_group)"
  txn_mkdir "$dir" 0750 || return 1
  if ! gp_dry_run; then
    chown "root:$grp" "$dir" 2>/dev/null || true
    chmod 0750 "$dir" || true
  fi
  return 0
}

server_install_tls_material() {
  local src_dir="$1" dest_dir="$2" grp
  grp="$(squid_effective_group)"
  [ -r "$src_dir/fullchain.pem" ] || { die "missing $src_dir/fullchain.pem"; return 1; }
  [ -r "$src_dir/privkey.pem" ] || { die "missing $src_dir/privkey.pem"; return 1; }
  txn_install_file "$src_dir/fullchain.pem" "$dest_dir/fullchain.pem" 0644 || return 1
  txn_install_file "$src_dir/privkey.pem" "$dest_dir/privkey.pem" 0640 || return 1
  if ! gp_dry_run; then
    chown "root:$grp" "$dest_dir/fullchain.pem" "$dest_dir/privkey.pem" 2>/dev/null || true
  fi
  record_managed_file "$dest_dir/fullchain.pem" created
  record_managed_file "$dest_dir/privkey.pem" created
  return 0
}

server_cert_bot_available() {
  have certbot
}

server_install_deploy_hook() {
  local hook="$1" domain="$2" tls_dir="$3" unit="$4" tmp
  tmp="$(mktemp)" || return 1
  cat > "$tmp" <<EOF
#!/bin/sh
# =============================================================================
# vps-gateway-manager :: certbot deploy hook
#
# Installs a renewed certificate for $domain into the Squid TLS directory and
# reloads the proxy. Generated by install.sh - managed file.
#
# Safety: the new certificate is only activated after Squid accepts the
# configuration that references it; on failure the previous files are restored.
# =============================================================================
set -eu

DOMAIN="$domain"
TLS_DIR="$tls_dir"
UNIT="$unit"
LINEAGE="\${RENEWED_LINEAGE:-/etc/letsencrypt/live/\$DOMAIN}"
LOG="\${TLS_DIR}/deploy-hook.log"

log() { printf '%s %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$*" >> "\$LOG" 2>/dev/null || true; }

case "\${RENEWED_DOMAINS:-} \$DOMAIN" in
  *"\$DOMAIN"*) : ;;
  *) log "skipping: renewal for '\${RENEWED_DOMAINS:-unknown}' does not include \$DOMAIN"; exit 0 ;;
esac

[ -r "\$LINEAGE/fullchain.pem" ] || { log "missing \$LINEAGE/fullchain.pem"; exit 1; }

backup="\$(mktemp -d)"
cp -p "\$TLS_DIR/fullchain.pem" "\$backup/fullchain.pem" 2>/dev/null || true
cp -p "\$TLS_DIR/privkey.pem"   "\$backup/privkey.pem"   2>/dev/null || true

install -m 0644 "\$LINEAGE/fullchain.pem" "\$TLS_DIR/fullchain.pem"
install -m 0640 "\$LINEAGE/privkey.pem"   "\$TLS_DIR/privkey.pem"

if ! /usr/sbin/squid -k parse >/dev/null 2>&1; then
  log "squid -k parse failed after installing the renewed certificate; restoring previous files"
  [ -f "\$backup/fullchain.pem" ] && install -m 0644 "\$backup/fullchain.pem" "\$TLS_DIR/fullchain.pem"
  [ -f "\$backup/privkey.pem" ]   && install -m 0640 "\$backup/privkey.pem"   "\$TLS_DIR/privkey.pem"
  rm -rf "\$backup"
  exit 1
fi

if systemctl reload "\$UNIT" 2>/dev/null; then
  log "reloaded \$UNIT with the renewed certificate for \$DOMAIN"
else
  log "systemctl reload \$UNIT failed; leaving the new certificate in place for the next restart"
fi
rm -rf "\$backup"
exit 0
EOF
  txn_install_file "$tmp" "$hook" 0755 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  record_managed_file "$hook" created
  return 0
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------
server_ufw_sync_client() {
  # server_ufw_sync_client <cidr> <name> [remove]
  local cidr="$1" name="$2" action="${3:-add}" spec marker rc=0
  if [ "${SERVER_UFW_MANAGED:-0}" != "1" ]; then
    log_debug "ufw management disabled for this host"
    return 0
  fi
  fw_detect
  spec="$(fw_rule_spec "$cidr" "$SERVER_TLS_PORT")"
  marker="$(fw_marker "$name")"
  case "$action" in
    add)
      fw_add_rule "$spec" "$marker" || rc=$?
      if [ "$rc" -eq 0 ]; then
        txn_ufw_add "$spec"
      elif [ "$rc" -eq 3 ]; then
        rc=0
      fi
      ;;
    remove)
      fw_delete_owned_rule "$spec" "$marker" || rc=$?
      [ "$rc" -eq 4 ] && rc=0
      ;;
  esac
  return "$rc"
}

# -----------------------------------------------------------------------------
# Discovery (read-only) - the core of --adopt-existing
# -----------------------------------------------------------------------------
SERVER_DISCOVERY=""

server_discovery_render() {
  local main includes src_file f unit state d_name d_type d_value d_src _d_src
  printf '== host ==\n'
  printf 'hostname: %s\n' "$(hostname 2>/dev/null || printf unknown)"
  printf 'distribution: %s %s (%s)\n' "$(gp_os_id)" "$(gp_os_version)" "$(gp_os_codename)"
  printf 'kernel: %s\n' "$(uname -r)"
  printf 'project version: %s\n' "${VGM_VERSION:-unknown}"

  printf '\n== squid ==\n'
  if squid_detect; then
    printf 'binary: %s\n' "$SQUID_BIN"
    printf 'version: %s (flavor=%s tls_capable=%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR" "$SQUID_TLS_CAPABLE"
    printf 'package: %s %s\n' "${SQUID_VENDOR_PKG:-none}" "$(squid_pkg_version "${SQUID_VENDOR_PKG:-squid}" 2>/dev/null)"
    squid_detect_unit
    printf 'systemd unit: %s\n' "${SQUID_UNIT:-none}"
    printf 'unit active: %s\n' "$(systemctl_active "$SQUID_UNIT" && printf yes || printf no)"
    printf 'unit enabled: %s\n' "$(systemctl_enabled "$SQUID_UNIT" && printf yes || printf no)"
    printf 'pids: %s\n' "$(squid_running_pids | tr '\n' ' ')"
    printf 'squid -v:\n'
    "$SQUID_BIN" -v 2>&1 | sed 's/^/  /'
  else
    printf 'squid: NOT FOUND\n'
    printf 'recommendation: install squid-openssl, or run this on the host that already proxies GitHub\n'
  fi

  printf '\n== configuration ==\n'
  main="$(squid_main_config "${SQUID_UNIT:-}")"
  printf 'main config: %s\n' "$main"
  includes=""
  local -a inc_arr2=()
  if [ -r "$main" ]; then
    includes="$(squid_conf_includes "$main")"
    if [ -n "$includes" ]; then
      while IFS= read -r f; do [ -n "$f" ] && inc_arr2+=("$f"); done <<< "$includes"
    fi
    printf 'included files (in load order):\n'
    printf '%s\n' "$includes" | sed 's/^/  /'
    printf 'configured listeners:\n'
    squid_config_listeners "$main" | sed 's/^/  /'
    printf 'effective http_access order (main file + includes, as Squid loads it):\n'
    squid_effective_access_order "$main" | while IFS=$'\t' read -r f r; do
      printf '  %s: %s\n' "$(basename "$f")" "$r"
    done
    printf 'policy audit:\n'
    # The audit must judge the EFFECTIVE configuration: on a production host the
    # terminal "deny all" and the allow rules live in conf.d, not in the main file.
    squid_policy_audit "$main" ${inc_arr2[@]+"${inc_arr2[@]}"} | sed 's/^/  /' || true
  else
    printf 'main config NOT readable\n'
  fi

  printf '\n== acl / sources ==\n'
  src_file=""
  if [ "${#inc_arr2[@]}" -gt 0 ]; then
    src_file="$(squid_find_source_acl_file "${inc_arr2[@]}" 2>/dev/null || true)"
  fi
  printf 'source acl file: %s\n' "${src_file:-not detected}"
  if [ -n "$src_file" ]; then
    printf 'source entries (cidr / acl name / comment):\n'
    while IFS=$'\t' read -r cidr name comment; do
      [ -n "$cidr" ] || continue
      printf '  %-48s %-22s %s\n' "$cidr" "$name" "${comment:-<no comment>}"
    done < <(squid_acl_src_entries "$src_file")
    printf 'count: %s\n' "$(squid_acl_src_entries "$src_file" | wc -l | tr -d ' ')"
  fi
  printf 'destination acl declarations (name / type / value / source):\n'
  if [ "${#inc_arr2[@]}" -gt 0 ] || [ -r "$main" ]; then
    while IFS=$'\t' read -r d_name d_type d_value d_src; do
      [ -n "$d_name" ] || continue
      case "$d_type" in
        file)   printf '  %-18s file    %s  (from %s)\n' "$d_name" "$d_value" "$(basename "$d_src")" ;;
        inline) printf '  %-18s inline  %s  (from %s)\n' "$d_name" "$d_value" "$(basename "$d_src")" ;;
        regex)  printf '  %-18s regex   %s  (from %s, not imported)\n' "$d_name" "$d_value" "$(basename "$d_src")" ;;
        *)      printf '  %-18s %s  %s  (from %s)\n' "$d_name" "$d_type" "$d_value" "$(basename "$d_src")" ;;
      esac
    done < <(squid_dst_acls "$main" ${inc_arr2[@]+"${inc_arr2[@]}"})
  fi
  printf 'destination list file(s) and entry counts:\n'
  while IFS=$'\t' read -r d_name d_type d_value _d_src; do
    [ "$d_type" = "file" ] || continue
    [ -n "$d_value" ] || continue
    printf '  %s (%s entries)\n' "$d_value" "$(read_lines "$d_value" 2>/dev/null | wc -l | tr -d ' ')"
    read_lines "$d_value" 2>/dev/null | sed 's/^/      /'
  done < <(squid_dst_acls "$main" ${inc_arr2[@]+"${inc_arr2[@]}"})

  printf '\n== live listeners ==\n'
  if have ss; then ss -H -ltnp 2>/dev/null | sed 's/^/  /'; else printf '  ss unavailable\n'; fi

  printf '\n== tls material ==\n'
  for d in "$(gp_squid_conf_dir)/tls" /etc/letsencrypt/live; do
    [ -d "$d" ] || continue
    printf '%s:\n' "$d"
    find "$d" -maxdepth 2 \( -type f -o -type l \) 2>/dev/null | sed 's/^/  /'
  done
  printf 'certificate summary:\n'
  local pem=""
  for pem in "$(gp_squid_conf_dir)/tls/fullchain.pem" /etc/letsencrypt/live/*/fullchain.pem; do
    [ -r "$pem" ] || continue
    printf '  %s\n' "$pem"
    if have openssl; then
      openssl x509 -in "$pem" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/      /'
    fi
  done

  printf '\n== certbot ==\n'
  printf 'certbot: %s\n' "$(have certbot && { certbot --version 2>&1 | head -n1; } || printf 'not installed')"
  printf 'deploy hooks:\n'
  find "$(gp_reload_hooks)" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sed 's/^/  /'
  printf 'renewal configs:\n'
  find /etc/letsencrypt/renewal -maxdepth 1 -type f 2>/dev/null | sed 's/^/  /'
  printf 'renewal timer:\n'
  systemctl_cmd list-timers certbot.timer --no-pager 2>/dev/null | head -n 3 | sed 's/^/  /'

  printf '\n== firewall ==\n'
  fw_detect
  printf '%s\n' "$(fw_backend_summary)"
  if [ "$FW_TYPE" = "ufw" ]; then
    ufw status verbose 2>&1 | sed 's/^/  /'
  fi

  printf '\n== services that MUST NOT be touched ==\n'
  for unit in xray x-ui 3x-ui xray-manager xray-manager.service; do
    if have systemctl && systemctl list-unit-files "$unit" >/dev/null 2>&1; then
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
      printf '  %-22s %s\n' "$unit" "${state:-unknown}"
    fi
  done
  printf 'listeners on ports 443 / 4428:\n'
  if have ss; then
    ss -H -ltnp 2>/dev/null | grep -E ':(443|4428)([[:space:]]|$)' | sed 's/^/  /' || printf '  none\n'
  fi

  printf '\n== log files ==\n'
  for f in "$(gp_squid_log_dir)/access.log" "$(gp_squid_log_dir)/cache.log"; do
    if [ -r "$f" ]; then
      printf '  %s (%s bytes, last line:)\n' "$f" "$(wc -c < "$f" | tr -d ' ')"
      tail -n 1 "$f" 2>/dev/null | sed 's/^/      /'
    else
      printf '  %s (not readable)\n' "$f"
    fi
  done
  return 0
}

SERVER_DISCOVERY_RC=0

# Collects the read-only host report into a temporary file and returns non-zero
# when it could not be completed. The caller prints whatever was collected (see
# server_discovery_print), so a report never turns into "the command printed a
# title and stopped". The temporary path is an implementation detail and must
# never reach the user.
server_discovery_collect() {
  SERVER_DISCOVERY_RC=0
  # Collecting twice must not leak the previous report file.
  if [ -n "${SERVER_DISCOVERY:-}" ] && [ -f "$SERVER_DISCOVERY" ]; then
    rm -f "$SERVER_DISCOVERY" 2>/dev/null || true
  fi
  SERVER_DISCOVERY="$(mktemp)" || { SERVER_DISCOVERY_RC=1; return 1; }
  # A report must never abort half way: run the collector without errexit.
  ( set +e; server_discovery_render ) > "$SERVER_DISCOVERY" 2>&1 || SERVER_DISCOVERY_RC=$?
  if [ ! -s "$SERVER_DISCOVERY" ]; then
    SERVER_DISCOVERY_RC=1
    printf '== discovery error ==\nthe collector produced no output (see the errors above)\n' >> "$SERVER_DISCOVERY"
  elif ! grep -q '^== squid ==$' "$SERVER_DISCOVERY"; then
    SERVER_DISCOVERY_RC=1
    printf '\n== discovery error ==\nthe collector stopped before the squid section was completed\n' >> "$SERVER_DISCOVERY"
  fi
  [ "$SERVER_DISCOVERY_RC" -eq 0 ]
}

# Removes the collected report file. Called once the report has been printed.
server_discovery_cleanup() {
  if [ -n "${SERVER_DISCOVERY:-}" ] && [ -f "$SERVER_DISCOVERY" ]; then
    rm -f "$SERVER_DISCOVERY" 2>/dev/null || true
  fi
  SERVER_DISCOVERY=""
  return 0
}

server_discovery_print() {
  if [ -n "${SERVER_DISCOVERY:-}" ] && [ -r "$SERVER_DISCOVERY" ]; then
    cat "$SERVER_DISCOVERY"
    return 0
  fi
  printf 'the read-only discovery report was not collected\n' >&2
  return 1
}

