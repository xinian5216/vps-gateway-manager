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

# is_ipv6 <addr>
# Structural validation (RFC 4291 textual grammar), not just a charset check:
#   * groups of 1-4 hex digits, at most one "::" run, never three colons
#   * exactly 8 groups when fully written; "::" must compress at least one
#   * an embedded IPv4 tail (::ffff:1.2.3.4) is allowed only as the final
#     component and must itself be a valid IPv4 address
# Anything malformed is rejected here and can never reach an ACL.
is_ipv6() {
  local ip="$1" exp
  case "$ip" in
    ''|*[!0-9A-Fa-f:.]*) return 1 ;;
  esac
  case "$ip" in
    *:*) : ;;
    *)   return 1 ;;
  esac
  case "$ip" in
    *:::*)   return 1 ;;   # three or more consecutive colons
    *::*::*) return 1 ;;   # more than one "::" compression run
  esac
  exp="$(_ipv6_expand "$ip")" || return 1
  [ "${#exp}" -eq 32 ] || return 1
  return 0
}

ip_version() {
  local ip="$1"
  if is_ipv4 "$ip"; then printf '4\n'; return 0; fi
  if is_ipv6 "$ip"; then printf '6\n'; return 0; fi
  return 1
}

# Expand an IPv6 address to 32 nibbles (used only for comparisons).
# Handles the RFC 4291 textual form with an embedded IPv4 tail
# (::ffff:1.2.3.4 -> ...:ffff:0102:0304). Every group is validated BEFORE any
# arithmetic happens and nothing is printed for invalid input: the old code
# evaluated $((16#1.2.3.4)) on the dotted tail, bash printed "value too great
# for base" on stderr, and the surrounding assertions still passed.
_ipv6_expand() {
  local ip="$1" left right i v4 hi lo out="" missing compressed=0
  local -a groups lgroups=() rgroups=() vo
  case "$ip" in
    *:*) : ;;
    *)   return 1 ;;
  esac
  case "$ip" in
    *:::*)   return 1 ;;    # three or more consecutive colons
    *::*::*) return 1 ;;    # more than one "::" compression run
  esac
  case "$ip" in
    :*) case "$ip" in ::*) ;; *) return 1 ;; esac ;;   # leading single colon
  esac
  case "$ip" in
    *:) case "$ip" in *::) ;; *) return 1 ;; esac ;;   # trailing single colon
  esac
  # embedded IPv4 tail: only the final component (RFC 4291 §2.2)
  case "$ip" in
    *.*.*.*)
      v4="${ip##*:}"
      is_ipv4 "$v4" || return 1
      IFS='.' read -r -a vo <<< "$v4"
      hi=$(( ${vo[0]} * 256 + ${vo[1]} ))
      lo=$(( ${vo[2]} * 256 + ${vo[3]} ))
      ip="${ip%:*}:$(printf '%x' "$hi"):$(printf '%x' "$lo")"
      ;;
  esac
  case "$ip" in
    *::*)
      compressed=1
      left="${ip%%::*}"; right="${ip##*::}"
      ;;
    *)
      left="$ip"; right=""
      ;;
  esac
  if [ -n "$left" ]; then IFS=':' read -r -a lgroups <<< "$left"; fi
  if [ -n "$right" ]; then IFS=':' read -r -a rgroups <<< "$right"; fi
  if [ "$compressed" = "1" ]; then
    missing=$(( 8 - ${#lgroups[@]} - ${#rgroups[@]} ))
    [ "$missing" -ge 1 ] || return 1    # "::" must compress at least one group
  else
    missing=0
    [ $(( ${#lgroups[@]} + ${#rgroups[@]} )) -eq 8 ] || return 1
  fi
  groups=("${lgroups[@]}")
  for ((i=0;i<missing;i++)); do groups+=("0"); done
  if [ "${#rgroups[@]}" -gt 0 ]; then groups+=("${rgroups[@]}"); fi
  [ "${#groups[@]}" -eq 8 ] || return 1
  # validate every group first; only then do any arithmetic
  for i in "${groups[@]}"; do
    [ -n "$i" ] || return 1
    [ "${#i}" -le 4 ] || return 1
    case "$i" in *[!0-9A-Fa-f]*) return 1 ;; esac
  done
  for i in "${groups[@]}"; do
    out="${out}$(printf '%04x' "$((16#$i))")"
  done
  printf '%s\n' "$out"
  return 0
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

# domain_is_forbidden_scope <host>
# True for the shared platform in its own right: the ROOT of a forbidden
# platform (amazonaws.com, cloudfront.net, ...) or one of its well-known
# multi-tenant service endpoints (s3.amazonaws.com and the regional s3.*
# forms). ONE hostname here reaches every tenant of the platform, so it can
# never be allowed - the exact-host override does not apply to it.
domain_is_forbidden_scope() {
  local host suffix
  host="$(lower "${1#.}")"
  case "$host" in
    s3.amazonaws.com|s3.*.amazonaws.com|s3-accelerate.amazonaws.com) return 0 ;;
  esac
  for suffix in $GP_FORBIDDEN_DOMAIN_SUFFIXES; do
    [ "$host" = "$suffix" ] && return 0
  done
  return 1
}

# validate_domain_entry <domain> [mode]
#   mode 0 (default) - strict: shared CDN platforms are refused entirely
#   mode 1           - explicit exact-host approval (CLI --force): ONE specific
#                      resource host on a shared platform (a bucket, a
#                      distribution) is accepted. The platform root, its
#                      multi-tenant service endpoints and the leading-dot
#                      suffix form stay refused - no flag can open a whole
#                      shared platform.
#   mode 2           - normalisation only (used by `domains remove`), so an
#                      operator can always delete an entry that today's policy
#                      would never have accepted.
# Prints the normalised entry (leading dot preserved) or fails.
validate_domain_entry() {
  local raw mode host label
  raw="$(trim "$1")"
  mode="${2:-0}"
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
  IFS='.' read -r -a _labels <<< "$host"
  for label in "${_labels[@]}"; do
    [ -n "$label" ] || { log_err "empty label in '$raw'"; return 1; }
    [ "${#label}" -le 63 ] || { log_err "label too long in '$raw'"; return 1; }
    case "$label" in
      -*|*-) log_err "invalid label '$label' in '$raw'"; return 1 ;;
    esac
  done
  if [ "${#host}" -gt 253 ]; then log_err "hostname too long: '$raw'"; return 1; fi
  if [ "$mode" != "2" ] && domain_is_forbidden_broad "$host"; then
    if [ "${raw#.}" != "$raw" ] || domain_is_forbidden_scope "$host"; then
      log_err "'$raw' is a shared CDN platform (or a multi-tenant service endpoint of one), not GitHub."
      log_err "No override can allow it: one entry here would reach every tenant behind that platform."
      return 1
    fi
    if [ "$mode" != "1" ]; then
      log_err "'$raw' is a resource host on a shared CDN platform, not a GitHub-operated name."
      log_err "If GitHub really serves this exact host, re-run with --force (exact host only; suffixes stay refused)."
      return 1
    fi
    log_warn "allowing '$raw' by explicit override: exact resource host on a shared CDN platform (its suffix is never allowed)"
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

# port_accepts_connections <port> [host]
# A real TCP connect, not just "something is bound": during a Squid reload the
# listener sockets are closed and re-opened, and a health check that runs in that
# window would see a refused connection and wrongly fail.
# Implemented with a minimal HTTP request (curl is a declared dependency) so no
# bash-specific /dev/tcp behaviour is involved.
port_accepts_connections() {
  local port="$1" host="${2:-127.0.0.1}" code=""
  [ -n "$port" ] || return 0
  if ! have curl; then return 0; fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
          "http://${host}:${port}/" 2>/dev/null)" || true
  case "$code" in
    ''|000) return 1 ;;
    *) return 0 ;;
  esac
}

# wait_for_port <port> <seconds> [host]
wait_for_port() {
  local port="$1" timeout="${2:-15}" host="${3:-127.0.0.1}" i=0
  [ -n "$port" ] || return 0
  if gp_dry_run; then
    log_dry "wait for ${host}:${port} to accept connections"
    return 0
  fi
  if [ "${GP_SKIP_NET_CHECKS:-0}" = "1" ]; then
    # Sandbox/test environments have no real listener; the real wait is
    # exercised by the integration suite.
    log_debug "GP_SKIP_NET_CHECKS=1: not waiting for ${host}:${port}"
    return 0
  fi
  while [ "$i" -lt "$timeout" ]; do
    if port_accepts_connections "$port" "$host"; then
      [ "$i" -gt 0 ] && log_debug "${host}:${port} accepting connections after ${i}s"
      return 0
    fi
    sleep 1; i=$((i+1))
  done
  log_warn "${host}:${port} did not accept connections within ${timeout}s"
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
# small and reviewed, and kept in sync with templates/github-domains.txt (the
# authoritative destination list); the suffix entries there already cover the
# narrower hosts (gist.github.com under .github.com, the container and object
# hosts under .githubusercontent.com).
gp_default_github_domains() {
  cat <<'EOF'
.github.com
.githubusercontent.com
.githubassets.com
ghcr.io
.github.io
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
