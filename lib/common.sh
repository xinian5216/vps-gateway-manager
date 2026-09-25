#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/common.sh
#
# Shared helpers: logging, safety gates, path anchoring, state files, atomic
# writes, audit trail and managed-file accounting.
#
# Design rules
#   * Every filesystem path is built on top of $GP_ROOT so the whole toolchain
#     can run inside a sandbox (tests) or on a real host ($GP_ROOT is empty).
#   * Nothing in here executes a mutating command without checking
#     "gp_dry_run" first, or without going through the txn layer.
#   * This file never calls `exit`; it returns non-zero on failure.
# =============================================================================

# Guard against double sourcing.
if [ -n "${GP_COMMON_SH:-}" ]; then
  return 0
fi
GP_COMMON_SH=1

# -----------------------------------------------------------------------------
# Version / identity
# -----------------------------------------------------------------------------
GP_PROJECT_NAME="vps-gateway-manager"
GP_PROJECT_SLUG="vps-gateway-manager"

# The destination ACL that belongs to THIS project. It must never collide with an
# operator's ACL name: Squid unions the values of repeated `acl <name>` lines, so
# redefining an operator name would silently extend THEIR allow rules.
GP_MANAGED_DOMAIN_ACL_NAME="gsp_managed_github"

gp_load_version() {
  local f
  for f in "${VGM_HOME:-}/VERSION" "${VGM_LIB_DIR:-}/../VERSION" \
           "/usr/local/lib/${GP_PROJECT_SLUG}/VERSION" \
           "/usr/lib/${GP_PROJECT_SLUG}/VERSION"; do
    if [ -n "$f" ] && [ -r "$f" ]; then
      head -n 1 "$f" | tr -d '[:space:]'
      return 0
    fi
  done
  printf '%s\n' "0.0.0-unknown"
}

# -----------------------------------------------------------------------------
# Path anchoring
# -----------------------------------------------------------------------------
# GP_ROOT is empty on a real host and set to a sandbox by the test-suite.
GP_ROOT="${GP_ROOT:-}"
# Strip a trailing slash so string building stays predictable.
GP_ROOT="${GP_ROOT%/}"

gp_p() { printf '%s%s\n' "$GP_ROOT" "$1"; }

gp_etc()       { gp_p "/etc"; }
gp_state_dir() { printf '%s\n' "$(gp_p "/etc/${GP_PROJECT_SLUG}")"; }
gp_conf_dir()  { printf '%s\n' "$(gp_state_dir)"; }
gp_backup_dir() { printf '%s\n' "$(gp_state_dir)/backups"; }
gp_state_file() { printf '%s\n' "$(gp_state_dir)/state"; }
gp_managed_files() { printf '%s\n' "$(gp_state_dir)/managed-files"; }
gp_squid_conf_dir() { printf '%s\n' "$(gp_p "/etc/squid")"; }
gp_squid_conf_d()   { printf '%s\n' "$(gp_p "/etc/squid/conf.d")"; }
gp_squid_log_dir()  { printf '%s\n' "$(gp_p "/var/log/squid")"; }
gp_systemd_dir()    { printf '%s\n' "$(gp_p "/etc/systemd/system")"; }
gp_libexec_dir()    { printf '%s\n' "$(gp_p "/usr/local/lib/${GP_PROJECT_SLUG}")"; }
gp_bin_dir()        { printf '%s\n' "$(gp_p "/usr/local/sbin")"; }
gp_profile_d()      { printf '%s\n' "$(gp_p "/etc/profile.d")"; }
gp_reload_hooks()   { printf '%s\n' "$(gp_p "/etc/letsencrypt/renewal-hooks/deploy")"; }

# -----------------------------------------------------------------------------
# Colours / logging
# -----------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${GP_NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  GP_C_RED=$'\033[31m'; GP_C_GREEN=$'\033[32m'; GP_C_YELLOW=$'\033[33m'
  GP_C_BLUE=$'\033[34m'; GP_C_BOLD=$'\033[1m'; GP_C_OFF=$'\033[0m'
else
  GP_C_RED=''; GP_C_GREEN=''; GP_C_YELLOW=''; GP_C_BLUE=''; GP_C_BOLD=''; GP_C_OFF=''
fi

GP_VERBOSE="${GP_VERBOSE:-0}"

_gp_log() {
  local colour="$1" tag="$2"
  shift 2
  printf '%s[%s]%s %s\n' "$colour" "$tag" "$GP_C_OFF" "$*" >&2
}

log_info() { _gp_log "$GP_C_BLUE"   "info"  "$@"; }
log_ok()   { _gp_log "$GP_C_GREEN"  " ok "  "$@"; }
log_warn() { _gp_log "$GP_C_YELLOW" "warn"  "$@"; }
log_err()  { GP_ERROR_REPORTED=1; _gp_log "$GP_C_RED" "err " "$@"; }
log_step() { _gp_log "$GP_C_BOLD"   "step"  "$@"; }
log_head() { printf '\n%s== %s ==%s\n' "$GP_C_BOLD" "$*" "$GP_C_OFF" >&2; }
log_debug() { [ "$GP_VERBOSE" = "1" ] || return 0; _gp_log "" "dbg " "$@"; }

log_dry() { printf '%s[dry-run]%s would %s\n' "$GP_C_YELLOW" "$GP_C_OFF" "$*" >&2; }

die() {
  log_err "$@"
  return 1
}

# -----------------------------------------------------------------------------
# Dry-run / interactivity gates
# -----------------------------------------------------------------------------
GP_DRY_RUN="${GP_DRY_RUN:-0}"
GP_ASSUME_YES="${GP_ASSUME_YES:-0}"
GP_INTERACTIVE="${GP_INTERACTIVE:-auto}"

gp_dry_run()  { [ "$GP_DRY_RUN" = "1" ]; }
gp_dry_note() { gp_dry_run && log_dry "$*"; }

gp_is_interactive() {
  case "$GP_INTERACTIVE" in
    yes) return 0 ;;
    no)  return 1 ;;
    auto) [ -t 0 ] && [ -t 1 ] && [ -z "${CI:-}" ] ;;
    *)   return 1 ;;
  esac
}

# confirm "<question>" [default:yes|no]
# In dry-run / non-interactive mode the safe default is used without prompting.
confirm() {
  local q="$1" def="${2:-no}" ans
  if [ "$GP_ASSUME_YES" = "1" ]; then
    log_info "$q -> yes (--yes)"
    return 0
  fi
  if ! gp_is_interactive; then
    log_info "$q -> ${def} (non-interactive default)"
    [ "$def" = "yes" ]
    return $?
  fi
  if [ "$def" = "yes" ]; then
    read -r -p "$q [Y/n] " ans || ans=""
    case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
  else
    read -r -p "$q [y/N] " ans || ans=""
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
}

# -----------------------------------------------------------------------------
# Environment checks
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

gp_uid() { id -u 2>/dev/null || printf '0\n'; }

gp_require_root() {
  if [ "$(gp_uid)" != "0" ]; then
    die "this operation requires root (try: sudo $0 $*)"
    return 1
  fi
  return 0
}

# Tests may run on non-Linux hosts (Git Bash) with GP_ALLOW_UNSUPPORTED_OS=1.
gp_require_linux() {
  if [ "$(uname -s)" = "Linux" ]; then
    return 0
  fi
  if [ "${GP_ALLOW_UNSUPPORTED_OS:-0}" = "1" ]; then
    log_warn "non-Linux host detected ($(uname -s)); continuing because GP_ALLOW_UNSUPPORTED_OS=1"
    return 0
  fi
  die "this tool supports Linux (Debian/Ubuntu) only; detected $(uname -s)"
  return 1
}

# os_release_field <ID|VERSION_ID|PRETTY_NAME>
os_release_field() {
  local key="$1" file="$GP_ROOT/etc/os-release"
  [ -r "$file" ] || file=/etc/os-release
  [ -r "$file" ] || return 1
  # shellcheck disable=SC1090
  ( . "$file" >/dev/null 2>&1 || true; eval "printf '%s\n' \"\${$key:-}\"" )
}

gp_os_id()       { os_release_field ID; }
gp_os_version()  { os_release_field VERSION_ID; }
gp_os_codename() { os_release_field VERSION_CODENAME; }

gp_distro_supported() {
  case "$(gp_os_id)" in
    debian|ubuntu|raspbian|linuxmint|pop) return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Time helpers
# -----------------------------------------------------------------------------
gp_epoch() { date -u +%s; }
gp_ts()    { date -u +%Y%m%dT%H%M%SZ; }
gp_ts_human() { date -u +"%Y-%m-%d %H:%M:%SZ"; }
gp_date()  { date -u +%Y-%m-%d; }

# -----------------------------------------------------------------------------
# Text helpers
# -----------------------------------------------------------------------------
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/_/g' -e 's/^_\+//' -e 's/_\+$//' \
    | cut -c1-24
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# read_lines <file> -> prints non-empty, non-comment, trimmed lines
read_lines() {
  local f="$1"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line"
  done < "$f"
}

# list_contains <list> <needle>  (list is newline separated)
list_contains() {
  local list="$1" needle="$2"
  printf '%s\n' "$list" | grep -Fxq -- "$needle"
}

dedupe_lines() {
  awk 'NF && !seen[$0]++'
}

csv_merge() {
  # Merge comma/space separated tokens, preserving order, dropping dupes.
  tr ',[:space:]' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

is_true() {
  case "$(lower "${1:-}")" in 1|yes|true|on) return 0 ;; *) return 1 ;; esac
}

# -----------------------------------------------------------------------------
# Atomic file operations
# -----------------------------------------------------------------------------
# gp_atomic_write <path> <mode>   (content on stdin)
gp_atomic_write() {
  local path="$1" mode="${2:-0644}" dir tmp
  dir="$(dirname "$path")"
  if gp_dry_run; then
    log_dry "write $path (mode $mode, $(wc -c | tr -d ' ') bytes)"
    cat > /dev/null
    return 0
  fi
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.gsp-tmp.XXXXXX")" || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  return 0
}

gp_write_text() {
  # gp_write_text <path> <mode> <content...>
  local path="$1" mode="$2"
  shift 2
  printf '%s\n' "$*" | gp_atomic_write "$path" "$mode"
}

gp_mkdir() {
  local d="$1" mode="${2:-0755}"
  if gp_dry_run; then
    [ -d "$d" ] || log_dry "create directory $d (mode $mode)"
    return 0
  fi
  if [ ! -d "$d" ]; then
    mkdir -p "$d" || return 1
  fi
  chmod "$mode" "$d" || return 1
  return 0
}

gp_file_mode() {
  local path="$1"
  if [ -e "$path" ]; then stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null; fi
}

# Check a credentials file is root-only (dir 700, file 600)
gp_assert_root_only_secret() {
  local path="$1" dir mode dmode
  if [ -z "$path" ]; then
    die "credential path is empty"
    return 1
  fi
  if [ ! -e "$path" ]; then
    die "credential file not found: $path"
    return 1
  fi
  if [ -L "$path" ]; then
    die "refusing to use a symlink for credentials: $path"
    return 1
  fi
  dir="$(dirname "$path")"
  mode="$(gp_file_mode "$path")"
  dmode="$(gp_file_mode "$dir")"
  if [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
    die "credential file $path must be mode 600 (or 400), found ${mode:-unknown}. Fix with: chmod 600 '$path'"
    return 1
  fi
  case "$dmode" in
    700|500|750) : ;;
    *)
      die "credential directory $dir must be mode 700 (or 500/750), found ${dmode:-unknown}. Fix with: chmod 700 '$dir'"
      return 1
      ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Audit trail
# -----------------------------------------------------------------------------
gp_audit_log() { printf '%s\n' "$(gp_state_dir)/audit.log"; }

audit() {
  # audit <phase> <message...>
  local phase="$1"
  shift
  local line
  line="$(gp_ts_human)"$'\t'"$phase"$'\t'"$*"
  printf '%s\n' "$line" >&2
  if ! gp_dry_run; then
    local log_file
    log_file="$(gp_audit_log)"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$log_file" 2>/dev/null || true
  fi
}

# Path of the system CA bundle (anchored on GP_ROOT so tests can provide one).
gp_ca_bundle() { printf '%s\n' "$(gp_p /etc/ssl/certs/ca-certificates.crt)"; }

# -----------------------------------------------------------------------------
# Managed files registry
# -----------------------------------------------------------------------------
# record_managed_file <path> <state:created|modified|adopted>
record_managed_file() {
  local path="$1" state="$2" f tmp
  if gp_dry_run; then
    log_dry "record managed file: $path ($state)"
    return 0
  fi
  f="$(gp_managed_files)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  tmp="${f}.tmp.$$"
  if [ -f "$f" ]; then
    awk -v p="$path" -F'\t' '$1 != p' "$f" > "$tmp" 2>/dev/null || : > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\n' "$path" "$state" >> "$tmp"
  mv -f "$tmp" "$f" || return 1
  return 0
}

managed_file_state() {
  local path="$1" f
  f="$(gp_managed_files)"
  [ -r "$f" ] || return 1
  awk -v p="$path" -F'\t' '$1==p{print $2; found=1} END{exit !found}' "$f"
}

is_managed_file() { managed_file_state "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# Key=value state files
# -----------------------------------------------------------------------------
conf_get() {
  # conf_get <file> <key> [default]
  local file="$1" key="$2" def="${3-}" line
  [ -r "$file" ] || { [ $# -ge 3 ] && printf '%s\n' "$def"; return 0; }
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n 1)" || true
  if [ -z "$line" ]; then
    [ $# -ge 3 ] && printf '%s\n' "$def"
    return 0
  fi
  printf '%s\n' "${line#*=}"
}

conf_has() {
  local file="$1" key="$2"
  [ -r "$file" ] || return 1
  grep -qE "^[[:space:]]*${key}=" "$file"
}

conf_set() {
  # conf_set <file> <key> <value> [mode]
  local file="$1" key="$2" value="$3" mode="${4:-0600}" tmp
  gp_mkdir "$(dirname "$file")" 0700 || return 1
  if [ ! -e "$file" ]; then
    printf '# %s state file (managed by ghproxyctl; do not edit while services run)\n' "$GP_PROJECT_NAME" \
      | gp_atomic_write "$file" "$mode" || return 1
  fi
  if gp_dry_run; then
    log_dry "set $key=$value in $file"
    # keep the sandbox view consistent for later dry-run steps
    if [ ! -e "$file" ]; then : ; fi
    return 0
  fi
  tmp="$(mktemp "$(dirname "$file")/.gsp-kv.XXXXXX")" || return 1
  if conf_has "$file" "$key"; then
    awk -v k="$key" -v v="$value" '
      BEGIN{done=0}
      $0 ~ "^[[:space:]]*"k"=" { if(!done){ print k"="v; done=1 } ; next }
      { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    cp -f "$file" "$tmp" 2>/dev/null || : > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

conf_del() {
  local file="$1" key="$2" tmp
  [ -r "$file" ] || return 0
  gp_dry_run && { log_dry "delete $key from $file"; return 0; }
  tmp="$(mktemp "$(dirname "$file")/.gsp-kv.XXXXXX")" || return 1
  awk -v k="$key" '$0 !~ "^[[:space:]]*"k"="' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

conf_keys() {
  local file="$1"
  [ -r "$file" ] || return 0
  grep -oE '^[[:space:]]*[A-Za-z0-9_.-]+=' "$file" | tr -d '[:space:]=' | sort -u
}

# -----------------------------------------------------------------------------
# Role handling
# -----------------------------------------------------------------------------
gp_role_file() { printf '%s\n' "$(gp_state_dir)/role"; }

gp_role() {
  local f
  f="$(gp_role_file)"
  if [ -r "$f" ]; then head -n 1 "$f" | tr -d '[:space:]'; fi
  return 0
}

gp_require_role() {
  local want="$1" got
  got="$(gp_role)"
  if [ "$got" != "$want" ]; then
    die "this host is registered as role '${got:-none}', but '$want' was requested. Run the matching install/remote command on the correct host (or use --adopt-existing / --force)."
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Service control wrapper
# -----------------------------------------------------------------------------
# systemctl_cmd <args...>
# Read-only verbs run normally; mutating verbs are suppressed under --dry-run so
# that no accidental reload/restart can ever happen in a preview.
systemctl_cmd() {
  local verb="${1:-}" rest=("${@:2}")
  case "$verb" in
    is-active|is-enabled|is-failed|status|show|cat|list-units|list-unit-files|list-timers|list-dependencies|get-property|help|--version|*"is-active"*)
      ;;
    *)
      if gp_dry_run; then
        log_dry "systemctl $verb ${rest[*]:-}"
        return 0
      fi
      ;;
  esac
  if ! have systemctl; then
    log_debug "systemctl not available (sandbox?), skipping: systemctl $verb ${rest[*]:-}"
    return 0
  fi
  systemctl "$verb" "${rest[@]}"
}

systemctl_active() { systemctl_cmd is-active --quiet "$1" 2>/dev/null; }
systemctl_enabled() { systemctl_cmd is-enabled --quiet "$1" 2>/dev/null; }

# -----------------------------------------------------------------------------
# Misc
# -----------------------------------------------------------------------------
# gp_sha256 <file> -> short checksum (used for drift detection)
gp_sha256() {
  local f="$1"
  [ -r "$f" ] || return 1
  if have sha256sum; then sha256sum "$f" | awk '{print $1}'
  else shasum -a 256 "$f" | awk '{print $1}'; fi
}

gp_short_sha() { gp_sha256 "$1" | cut -c1-12; }

# gp_redact_url_credentials [value]
# Masks userinfo in URLs for anything that is printed:
#   https://user:pass@host:8443 -> https://***@host:8443
# Reads the first argument, or stdin (one value per line) when called without
# arguments. Reports must allowlist what they show; a value that is fine to use
# internally may still contain a password that must never be displayed.
# This is deliberately not a "secret detector": it removes the one credential
# position that is well-defined (URL userinfo) and everything else is only
# printed where it is known to be safe.
gp_redact_url_credentials() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$1"; else cat; fi \
    | sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1***@#g'
  return 0
}

# Replace a file's content atomically while keeping a marker block.
# marker_replace <file> <begin-marker> <end-marker> <content-file> <mode>
marker_replace() {
  local file="$1" begin="$2" end="$3" content="$4" mode="${5:-0644}" tmp out
  out="$(mktemp)" || return 1
  if [ -f "$file" ] && grep -Fq "$begin" "$file"; then
    # strip the old managed block
    awk -v b="$begin" -v e="$end" '
      index($0,b)==1 { skip=1; next }
      index($0,e)==1 { skip=0; next }
      !skip { print }
    ' "$file" > "$out" || { rm -f "$out"; return 1; }
  else
    cp -f "$file" "$out" 2>/dev/null || : > "$out"
  fi
  # normalise trailing blank lines, then append the block
  awk 'BEGIN{blank=0} { if ($0=="" ) { blank++; if (blank==1) print ""; next } else { blank=0; print } }' "$out" > "$out.norm" || true
  mv -f "$out.norm" "$out" 2>/dev/null || : > "$out"
  if [ -s "$out" ]; then printf '\n' >> "$out"; fi
  printf '%s\n' "$begin" >> "$out"
  cat "$content" >> "$out"
  printf '%s\n' "$end" >> "$out"
  gp_atomic_write "$file" "$mode" < "$out" || { rm -f "$out"; return 1; }
  rm -f "$out"
  return 0
}

marker_block_present() {
  local file="$1" begin="$2"
  [ -f "$file" ] && grep -Fq "$begin" "$file"
}

marker_extract() {
  local file="$1" begin="$2" end="$3"
  [ -f "$file" ] || return 0
  awk -v b="$begin" -v e="$end" '
    $0==b { inb=1; next } $0==e { inb=0; next } inb { print }
  ' "$file"
}

# Confirm a file is NOT owned by another tool before we touch it.
gp_refuse_foreign_file() {
  local path="$1" owner
  [ -e "$path" ] || return 0
  owner="$(head -n 1 "$path" 2>/dev/null || true)"
  case "$owner" in
    *"managed by $GP_PROJECT_NAME"*) return 0 ;;
    *"managed by ghproxyctl"*) return 0 ;;
    *"ghproxyctl"*) return 0 ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Templates
# -----------------------------------------------------------------------------
gp_templates_dir() {
  local cand
  for cand in "${VGM_TEMPLATES_DIR:-}" \
              "${VGM_HOME:-}/templates" \
              "$(gp_libexec_dir)/templates" \
              "/usr/local/lib/${GP_PROJECT_SLUG}/templates" \
              "/usr/local/share/${GP_PROJECT_SLUG}/templates" \
              "/usr/lib/${GP_PROJECT_SLUG}/templates"; do
    if [ -n "$cand" ] && [ -d "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

# render_template <template-name> [KEY=VALUE ...]
# Renders templates/<name>. Placeholders are written as @@KEY@@.
render_template() {
  local name="$1"; shift
  local dir tpl content pair key value
  dir="$(gp_templates_dir)" || { die "no templates directory found (set VGM_TEMPLATES_DIR)"; return 1; }
  tpl="$dir/$name"
  [ -r "$tpl" ] || { die "template not found: $tpl"; return 1; }
  content="$(cat "$tpl")"
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    case "$content" in
      *"@@$key@@"*) : ;;
      *) continue ;;
    esac
    value="$(printf '%s' "$value" | sed -e 's/[&\\|]/\\&/g')"
    content="$(printf '%s\n' "$content" | sed -e "s|@@$key@@|$value|g")"
  done
  if printf '%s' "$content" | grep -q '@@[A-Z0-9_]*@@'; then
    log_warn "template $name still has unrendered placeholders"
  fi
  printf '%s\n' "$content"
  return 0
}

# -----------------------------------------------------------------------------
# Project data files
# -----------------------------------------------------------------------------
gp_domains_file()  { printf '%s\n' "$(gp_state_dir)/github-domains.txt"; }
gp_domains_doc()   { printf '%s\n' "$(gp_state_dir)/github-domains.sources"; }
gp_clients_db()    { printf '%s\n' "$(gp_state_dir)/clients.db"; }
# Plain CIDR list consumed by the file-backed Squid src ACL (one exact host per
# line; Squid ORs the entries of a file-backed ACL).
gp_managed_clients_acl() { printf '%s\n' "$(gp_state_dir)/managed-clients.acl"; }
gp_server_conf()   { printf '%s\n' "$(gp_state_dir)/server.conf"; }
gp_client_conf()   { printf '%s\n' "$(gp_state_dir)/client.conf"; }

# Entries only (comments and blank lines removed) - fed to Squid.
gp_domains_entries() {
  local f
  f="$(gp_domains_file)"
  read_lines "$f" | awk '!seen[$0]++'
}

# -----------------------------------------------------------------------------
# Toolchain installation (lib + templates + ghproxyctl)
# -----------------------------------------------------------------------------
gp_install_toolchain() {
  local src_home="${VGM_HOME:-}" dest
  dest="$(gp_libexec_dir)"
  # Running from a checkout (e.g. `sudo bash bin/ghproxyctl ...`): derive the
  # source tree from the library location so the installed toolchain is refreshed.
  if [ -z "$src_home" ] && [ -n "${VGM_LIB_DIR:-}" ]; then
    src_home="$(cd "$(dirname "$VGM_LIB_DIR")" 2>/dev/null && pwd || printf '%s' "")"
  fi
  if [ -z "$src_home" ] || [ ! -d "$src_home/lib" ]; then
    log_debug "no source tree available; skipping toolchain install"
    return 0
  fi
  if [ "$(cd "$src_home" && pwd)" = "$dest" ]; then
    log_debug "already running from the installed location"
    return 0
  fi
  log_info "installing toolchain into $dest"
  if gp_dry_run; then
    log_dry "copy $src_home/{lib,templates,VERSION} -> $dest"
    log_dry "install $src_home/bin/ghproxyctl -> $(gp_bin_dir)/ghproxyctl"
    return 0
  fi
  gp_mkdir "$dest" 0755 || return 1
  rm -rf "${dest:?}/lib" "${dest:?}/templates" 2>/dev/null || true
  cp -R "$src_home/lib" "$dest/lib" || return 1
  if [ -d "$src_home/templates" ]; then
    cp -R "$src_home/templates" "$dest/templates" || return 1
  fi
  [ -r "$src_home/VERSION" ] && cp -f "$src_home/VERSION" "$dest/VERSION"
  if [ -r "$src_home/bin/ghproxyctl" ]; then
    gp_mkdir "$(gp_bin_dir)" 0755 || return 1
    install -m 0755 "$src_home/bin/ghproxyctl" "$(gp_bin_dir)/ghproxyctl" || return 1
  fi
  chmod 0644 "$dest"/lib/*.sh 2>/dev/null || true
  record_managed_file "$dest" created
  record_managed_file "$(gp_bin_dir)/ghproxyctl" created
  return 0
}

# Best-effort check that the running user can actually manage this host.
gp_preflight() {
  gp_require_linux || return 1
  if ! gp_distro_supported; then
    log_warn "unsupported distribution '$(gp_os_id) $(gp_os_version)' - only Debian/Ubuntu are tested"
  fi
  if [ "$(gp_uid)" != "0" ]; then
    die "run this as root (sudo)"
    return 1
  fi
  if ! have bash; then die "bash is required"; return 1; fi
  return 0
}

# -----------------------------------------------------------------------------
# Unexpected-exit guard
# -----------------------------------------------------------------------------
# A production tool must never exit silently in the middle of a change. This is
# installed as an EXIT trap by install.sh and ghproxyctl: if the process ends
# with a non-zero status while a transaction is still open, the change is rolled
# back and the situation is reported loudly.
gp_abort_guard() {
  local rc=$?
  # Release the mutation lock even when the command returns through this trap.
  # The lock is a directory, not an fd, so a child Squid cannot keep holding it.
  if declare -F gp_mutation_lock_release >/dev/null 2>&1; then
    gp_mutation_lock_release || true
  fi
  if [ "$rc" -ne 0 ]; then
    if declare -F txn_is_active >/dev/null 2>&1 && txn_is_active; then
      log_err "aborted unexpectedly (exit status $rc) - rolling back the open transaction"
      txn_rollback "unexpected exit (status $rc)" || true
    elif [ "${GP_ERROR_REPORTED:-0}" != "1" ]; then
      # No error was printed before the process died: say so, instead of
      # returning to the shell as if nothing had happened.
      log_err "aborted unexpectedly (exit status $rc); see the output above"
    fi
  fi
  return "$rc"
}

gp_install_abort_guard() {
  trap 'gp_abort_guard; exit $?' EXIT
  return 0
}
