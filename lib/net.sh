#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/net.sh
#
# Address / URL / domain validation. Everything the toolchain accepts as a
# "client" or as a "domain" passes through this file first.
#
# Hard rules (see SECURITY.md):
#   * Clients are accepted as exact hosts only: IPv4 -> /32, IPv6 -> /128.
#     A /64 (or any other prefix) is rejected; there is no shortcut.
#   * Wildcards, 0.0.0.0, ::, multicast and broadcast are rejected.
#   * Domains must be exact hostnames or leading-dot suffixes. Broad CDN
#     suffixes that would turn this into an open proxy are rejected.
# =============================================================================

if [ -n "${GP_NET_SH:-}" ]; then
  return 0
fi
GP_NET_SH=1

# -----------------------------------------------------------------------------
# IPv4 / IPv6 primitives
# -----------------------------------------------------------------------------
is_ipv4() {
  local ip="$1" o
  case "$ip" in
    *[!0-9.]*|'') return 1 ;;
  esac
  IFS='.' read -r -a _octets <<< "$ip"
  [ "${#_octets[@]}" -eq 4 ] || return 1
  for o in "${_octets[@]}"; do
    [ -n "$o" ] || return 1
    [ "${#o}" -le 3 ] || return 1
    # leading zeros create ambiguity between decimal and octal
    case "$o" in 0[0-9]*) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
  return 0
}

is_ipv6() {
  local ip="$1"
  case "$ip" in
    ''|*[!0-9A-Fa-f:.]*) return 1 ;;
  esac
  case "$ip" in
    *:*) return 0 ;;
    *)   return 1 ;;
  esac
}

ip_version() {
  local ip="$1"
  if is_ipv4 "$ip"; then printf '4\n'; return 0; fi
  if is_ipv6 "$ip"; then printf '6\n'; return 0; fi
  return 1
}

# Expand an IPv6 address to 32 nibbles (used only for comparisons).
_ipv6_expand() {
  local ip="$1" left right i
  local -a groups
  case "$ip" in
    *::*)
      left="${ip%%::*}"; right="${ip##*::}"
      ;;
    *)
      left="$ip"; right=""
      ;;
  esac
  local lgroups=() rgroups=()
  if [ -n "$left" ]; then IFS=':' read -r -a lgroups <<< "$left"; fi
  if [ -n "$right" ]; then IFS=':' read -r -a rgroups <<< "$right"; fi
  local missing=$(( 8 - ${#lgroups[@]} - ${#rgroups[@]} ))
  [ "$missing" -ge 0 ] || return 1
  groups=("${lgroups[@]}")
  for ((i=0;i<missing;i++)); do groups+=("0"); done
  if [ "${#rgroups[@]}" -gt 0 ]; then groups+=("${rgroups[@]}"); fi
  [ "${#groups[@]}" -eq 8 ] || return 1
  for i in "${groups[@]}"; do printf '%04x' "$((16#${i:-0}))"; done
  printf '\n'
}

ipv6_is_unspecified() { [ "$(_ipv6_expand "$1")" = "00000000000000000000000000000000" ]; }
ipv6_is_loopback()    { [ "$(_ipv6_expand "$1")" = "00000000000000000000000000000001" ]; }
ipv6_is_multicast()   { case "$(_ipv6_expand "$1")" in ff*) return 0 ;; *) return 1 ;; esac; }
ipv6_is_linklocal()   { case "$(_ipv6_expand "$1")" in fe80*) return 0 ;; *) return 1 ;; esac; }

ipv4_is_unspecified() { [ "$1" = "0.0.0.0" ]; }
ipv4_is_broadcast()   { [ "$1" = "255.255.255.255" ]; }
ipv4_is_loopback()    { case "$1" in 127.*) return 0 ;; *) return 1 ;; esac; }
ipv4_is_multicast()   { case "$1" in 22[4-9].*|23[0-9].*) return 0 ;; *) return 1 ;; esac; }
ipv4_is_private() {
  case "$1" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) return 0 ;;
    *) return 1 ;;
  esac
}

# normalize_client_cidr <ip-or-cidr> -> prints "ip/32" or "ip/128"
# Returns non-zero with an explanatory message on stderr for anything else.
normalize_client_cidr() {
  local input addr prefix ver
  input="$(trim "$1")"
  if [ -z "$input" ]; then
    log_err "empty address"
    return 1
  fi
  case "$input" in
    */0)
      die "refusing to add $input: a /0 prefix would open this proxy to the entire internet"
      return 1
      ;;
  esac
  case "$input" in
    */*)
      addr="${input%%/*}"
      prefix="${input##*/}"
      ;;
    *)
      addr="$input"
      prefix=""
      ;;
  esac
  if ! ver="$(ip_version "$addr")"; then
    log_err "not a valid IPv4/IPv6 address: '$input'"
    return 1
  fi
  case "$ver" in
    4)
      if [ -n "$prefix" ] && [ "$prefix" != "32" ]; then
        log_err "refusing '$input': clients must be exact hosts (IPv4 -> /32). A /$prefix source range is not allowed."
        return 1
      fi
      if ipv4_is_unspecified "$addr"; then die "refusing 0.0.0.0 (unspecified address)"; return 1; fi
      if ipv4_is_broadcast "$addr"; then die "refusing 255.255.255.255 (broadcast address)"; return 1; fi
      if ipv4_is_multicast "$addr"; then die "refusing $addr (multicast address)"; return 1; fi
      printf '%s/32\n' "$addr"
      ;;
    6)
      if [ -n "$prefix" ] && [ "$prefix" != "128" ]; then
        log_err "refusing '$input': clients must be exact hosts (IPv6 -> /128). A /$prefix source range is not allowed."
        return 1
      fi
      if ipv6_is_unspecified "$addr"; then die "refusing :: (unspecified address)"; return 1; fi
      if ipv6_is_multicast "$addr"; then die "refusing $addr (multicast address)"; return 1; fi
      printf '%s/128\n' "$addr"
      ;;
  esac
  return 0
}

# ip_scope <ip> -> public|private|loopback|linklocal|reserved
ip_scope() {
  local ip="$1" ver
  ver="$(ip_version "$ip")" || { printf 'unknown\n'; return 0; }
  if [ "$ver" = "4" ]; then
    ipv4_is_loopback "$ip"    && { printf 'loopback\n'; return 0; }
    ipv4_is_private "$ip"     && { printf 'private\n';  return 0; }
    printf 'public\n'
  else
    ipv6_is_loopback "$ip"  && { printf 'loopback\n'; return 0; }
    ipv6_is_linklocal "$ip" && { printf 'linklocal\n'; return 0; }
    case "$(_ipv6_expand "$ip")" in
      0000*) printf 'reserved\n' ;;
      fc*|fd*) printf 'private\n' ;;
      *) printf 'public\n' ;;
    esac
  fi
}

# validate_client_ip <ip-or-cidr> <name>
# Stricter gate used by `ghproxyctl client add`: public addresses are the norm,
# anything else needs --allow-private.
validate_client_ip() {
  local input="$1" name="$2" allow_private="${3:-0}" cidr ip scope
  cidr="$(normalize_client_cidr "$input")" || return 1
  ip="${cidr%%/*}"
  scope="$(ip_scope "$ip")"
  case "$scope" in
    public) : ;;
    *)
      if [ "$allow_private" != "1" ]; then
        log_err "refusing $ip ($scope address). Client addresses are normally public source IPs."
        log_err "If you really mean it, re-run with --allow-private (loopback/private clients are useful for tests only)."
        return 1
      fi
      log_warn "accepting $scope client address $ip for '$name' because --allow-private was given"
      ;;
  esac
  printf '%s\n' "$cidr"
  return 0
}

# -----------------------------------------------------------------------------
# Domain validation
# -----------------------------------------------------------------------------
# Suffixes that must never be allowed: they are broad CDN platforms, not GitHub.
GP_FORBIDDEN_DOMAIN_SUFFIXES="
amazonaws.com
azureedge.net
cloudfront.net
akamai.net
akamaized.net
fastly.net
fastlylb.net
cloudflare.com
cloudflare.net
googleapis.com
gstatic.com
windows.net
blob.core.windows.net
"

domain_is_forbidden_broad() {
  local host suffix
  host="$(lower "${1#.}")"
  for suffix in $GP_FORBIDDEN_DOMAIN_SUFFIXES; do
    case "$host" in
      "$suffix"|*".$suffix") return 0 ;;
    esac
  done
  return 1
}

# validate_domain_entry <domain> [allow_broad:0|1]
# Prints the normalised entry (leading dot preserved) or fails.
validate_domain_entry() {
  local raw allow_broad host label
  raw="$(trim "$1")"
  allow_broad="${2:-0}"
  [ -n "$raw" ] || { log_err "empty domain"; return 1; }
  case "$raw" in
    *" "*|*"	"*) log_err "domain contains whitespace: '$raw'"; return 1 ;;
    *://*) log_err "domain must be a hostname, not a URL: '$raw'"; return 1 ;;
    */|*/*) log_err "domain must not contain a path: '$raw'"; return 1 ;;
  esac
  case "$raw" in
    *"*"*) log_err "wildcards are not supported, use a leading dot for subdomains: '$raw'"; return 1 ;;
  esac
  host="$(lower "${raw#.}")"
  case "$host" in
    *[!a-z0-9.-]*|.*|*.) log_err "invalid hostname: '$raw'"; return 1 ;;
  esac
  case "$host" in
    *.*) : ;;
    *) log_err "invalid hostname (needs at least one dot): '$raw'"; return 1 ;;
  esac
  local label
  IFS='.' read -r -a _labels <<< "$host"
  for label in "${_labels[@]}"; do
    [ -n "$label" ] || { log_err "empty label in '$raw'"; return 1; }
    [ "${#label}" -le 63 ] || { log_err "label too long in '$raw'"; return 1; }
    case "$label" in
      -*|*-) log_err "invalid label '$label' in '$raw'"; return 1 ;;
    esac
  done
  if [ "${#host}" -gt 253 ]; then log_err "hostname too long: '$raw'"; return 1; fi
  if domain_is_forbidden_broad "$host" && [ "$allow_broad" != "1" ]; then
    log_err "'$raw' points at a broad CDN platform, not GitHub."
    log_err "Allowing it would turn this GitHub-only proxy into a general-purpose proxy."
    log_err "Add the exact hostname instead (e.g. github-cloud.s3.amazonaws.com)."
    return 1
  fi
  if [ "${raw#.}" != "$raw" ]; then printf '.%s\n' "$host"; else printf '%s\n' "$host"; fi
  return 0
}

# -----------------------------------------------------------------------------
# URL parsing
# -----------------------------------------------------------------------------
# parse_upstream_url <url> -> prints "host<TAB>port<TAB>scheme<TAB>path"
parse_upstream_url() {
  local url scheme rest hostport port host
  url="$(trim "$1")"
  case "$url" in
    "" ) log_err "empty upstream URL"; return 1 ;;
  esac
  case "$url" in
    *://*) ;;
    *) log_err "upstream must include a scheme, e.g. https://proxy.example.com:8443"; return 1 ;;
  esac
  scheme="$(lower "${url%%://*}")"
  rest="${url#*://}"
  case "$scheme" in
    http|https) : ;;
    *) log_err "unsupported upstream scheme '$scheme' (only http and https are supported)"; return 1 ;;
  esac
  case "$rest" in
    *@*) log_err "upstream URL must not contain credentials"; return 1 ;;
  esac
  case "$rest" in
    */*) hostport="${rest%%/*}"; rest_path="/${rest#*/}" ;;
    *)   hostport="$rest"; rest_path="/" ;;
  esac
  case "$rest_path" in
    ""|"/") : ;;
    *) log_err "upstream URL must not contain a path (found '$rest_path')"; return 1 ;;
  esac
  [ -n "$hostport" ] || { log_err "upstream URL has no host"; return 1; }
  case "$hostport" in
    \[*\])
      host="${hostport#[}"; host="${host%]}"
      port=""
      is_ipv6 "$host" || { log_err "'$host' is not a valid IPv6 literal"; return 1; }
      ;;
    \[*\]:*)
      host="${hostport#[}"; host="${host%%]*}"; port="${hostport##*:}"
      is_ipv6 "$host" || { log_err "'$host' is not a valid IPv6 literal"; return 1; }
      ;;
    *:*)
      host="${hostport%%:*}"; port="${hostport##*:}"
      is_ipv4 "$host" || validate_hostname_strict "$host" || return 1
      ;;
    *)
      host="$hostport"; port=""
      validate_hostname_strict "$host" || return 1
      ;;
  esac
  if [ -z "$port" ]; then
    case "$scheme" in
      https) port=443 ;;
      http)  port=80 ;;
    esac
  fi
  case "$port" in
    *[!0-9]*|'') log_err "invalid port '$port' in upstream URL"; return 1 ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { log_err "port out of range: $port"; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$host" "$port" "$scheme" "$rest_path"
  return 0
}

validate_hostname_strict() {
  local host="$1" label
  host="$(lower "$host")"
  [ -n "$host" ] || return 1
  [ "${#host}" -le 253 ] || return 1
  case "$host" in
    *[!a-z0-9.-]*|.*|*.) return 1 ;;
  esac
  case "$host" in
    *.*) : ;;
    *) return 1 ;;
  esac
  IFS='.' read -r -a _labels <<< "$host"
  for label in "${_labels[@]}"; do
    [ -n "$label" ] || return 1
    [ "${#label}" -le 63 ] || return 1
    case "$label" in -*|*-) return 1 ;; esac
  done
  return 0
}

# domain_matches_list <host> <newline separated entries with optional leading dot>
# Leading-dot entries follow Squid dstdomain semantics: ".example.com" matches
# "example.com" and any subdomain of it.
domain_matches_list() {
  local host="$1" list="$2" entry
  host="$(lower "$host")"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry="$(lower "$entry")"
    case "$entry" in
      .*)
        [ "$host" = "${entry#.}" ] && return 0
        case "$host" in *"$entry") return 0 ;; esac
        ;;
      *)
        [ "$host" = "$entry" ] && return 0
        ;;
    esac
  done <<< "$list"
  return 1
}

# resolve_host <hostname> -> prints one address per line (v4+v6)
resolve_host() {
  local host="$1"
  if have getent; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | dedupe_lines
  elif have dig; then
    dig +short A "$host" 2>/dev/null; dig +short AAAA "$host" 2>/dev/null
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Local interface helpers (used to decide which loopback listeners to create)
# -----------------------------------------------------------------------------
local_loopback_addresses() {
  if have ip; then
    ip -o addr show dev lo 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  else
    printf '127.0.0.1\n::1\n'
  fi
}

has_ipv4_loopback() { local_loopback_addresses | grep -qx '127.0.0.1'; }
has_ipv6_loopback() { local_loopback_addresses | grep -qx '::1'; }

# port_in_use <port> [host]
port_in_use() {
  local port="$1" host="${2:-}"
  if have ss; then
    if [ -n "$host" ]; then
      ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
      return 1
    fi
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    return 1
  fi
  if have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    return 1
  fi
  return 1
}

# listener_owner <port> -> "proto user/pid" summary, best effort
listener_owner() {
  local port="$1"
  if have ss; then
    ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $4" "$6}' | head -n 2
  fi
}

# -----------------------------------------------------------------------------
# GitHub target policy helpers
# -----------------------------------------------------------------------------
# Hosts that are required for a GitHub-only egress path. Kept deliberately
# small and reviewed; see docs/DOMAINS.md for the provenance of each entry.
gp_default_github_domains() {
  cat <<'EOF'
# --- core GitHub -----------------------------------------------------------
.github.com
.githubusercontent.com
.githubassets.com
# --- GitHub Pages / gist (needed by some installers) -----------------------
gist.github.com
# --- GitHub container registry (ghcr.io) -----------------------------------
ghcr.io
pkg-containers.githubusercontent.com
.objects.githubusercontent.com
EOF
}

# classify_host <host> -> github|other
host_is_github() {
  local host="$1" list
  list="$(gp_default_github_domains)"
  domain_matches_list "$host" "$list"
}

is_github_url() {
  local url="$1" host
  host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://##; s#^[^/@]*@##; s#[:/].*$##')"
  host_is_github "$host"
}
