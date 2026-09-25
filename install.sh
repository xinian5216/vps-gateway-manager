#!/usr/bin/env bash
# =============================================================================
# vps-gateway-manager :: install.sh
#
# One entry point for both roles:
#
#   sudo bash install.sh server \
#       --domain gh.example.com \
#       --port 8443 \
#       --cf-credentials /root/.secrets/certbot/cloudflare.ini
#
#   sudo bash install.sh server --adopt-existing [--dry-run]
#
#   sudo bash install.sh client --upstream https://gh.example.com:8443 [--adopt-existing]
#
# Everything is idempotent, transactional and reversible. Read SECURITY.md
# before running this against a production host.
#
# This file is intentionally thin: the logic lives in lib/.
# =============================================================================
set -euo pipefail

VGM_SELF="${BASH_SOURCE[0]}"
VGM_HOME="$(cd "$(dirname "$VGM_SELF")" && pwd)"
export VGM_HOME
VGM_LIB_DIR="${VGM_LIB_DIR:-$VGM_HOME/lib}"
VGM_TEMPLATES_DIR="${VGM_TEMPLATES_DIR:-$VGM_HOME/templates}"
export VGM_LIB_DIR VGM_TEMPLATES_DIR

REPO_DEFAULT="https://github.com/xinian5216/vps-gateway-manager"
REF_DEFAULT="main"

# -----------------------------------------------------------------------------
# Self-bootstrap (the documented one-liner downloads only install.sh)
# -----------------------------------------------------------------------------
# bootstrap_is_full_sha <ref> -> true for a full 40-hex commit SHA
bootstrap_is_full_sha() {
  case "$1" in
    *[!0-9A-Fa-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# bootstrap_archive_candidates <repo> <ref> -> candidate archive URLs, most
# specific first. A full commit SHA is fetched directly; any other ref is
# tried as a branch first and then as a tag, because GitHub serves the two
# under different archive paths (refs/heads/... vs refs/tags/...).
bootstrap_archive_candidates() {
  local repo="${1%/}" ref="$2"
  if bootstrap_is_full_sha "$ref"; then
    printf '%s/archive/%s.tar.gz\n' "$repo" "$ref"
    return 0
  fi
  printf '%s/archive/refs/heads/%s.tar.gz\n' "$repo" "$ref"
  printf '%s/archive/refs/tags/%s.tar.gz\n' "$repo" "$ref"
  return 0
}

bootstrap_if_needed() {
  [ -r "$VGM_LIB_DIR/common.sh" ] && return 0
  local repo="$REPO_DEFAULT" ref="$REF_DEFAULT" proxy="" i=0
  local -a args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
      --repo-url)   repo="${args[$((i+1))]:-$repo}" ;;
      --repo-url=*) repo="${args[$i]#*=}" ;;
      --ref)        ref="${args[$((i+1))]:-$ref}" ;;
      --ref=*)      ref="${args[$i]#*=}" ;;
      --upstream)   proxy="${args[$((i+1))]:-}" ;;
      --upstream=*) proxy="${args[$i]#*=}" ;;
    esac
  done
  printf 'vps-gateway-manager: fetching the toolkit (lib/ + templates/) from %s@%s\n' "$repo" "$ref" >&2
  if [ -z "$proxy" ]; then
    printf 'vps-gateway-manager: hint: if this host cannot reach GitHub, pass --upstream <your-proxy>\n' >&2
  fi
  command -v curl >/dev/null 2>&1 || { printf 'curl is required for the initial download\n' >&2; exit 1; }
  local tmp dir url="" tried=""
  local -a curl_args=(-fsSL --retry 3 --connect-timeout 20 --max-time 180)
  [ -n "$proxy" ] && curl_args+=(--proxy "$proxy")
  tmp="$(mktemp -d)"
  # Install exactly the requested ref. When it cannot be fetched this FAILS:
  # there is deliberately no silent fallback to the default branch.
  while IFS= read -r cand; do
    tried="${tried}${tried:+, }${cand}"
    printf 'vps-gateway-manager: fetching %s\n' "$cand" >&2
    if curl "${curl_args[@]}" "$cand" -o "$tmp/repo.tgz"; then
      url="$cand"
      break
    fi
  done < <(bootstrap_archive_candidates "$repo" "$ref")
  if [ -z "$url" ]; then
    printf 'vps-gateway-manager: could not download %s@%s.\n' "$repo" "$ref" >&2
    printf 'vps-gateway-manager: tried: %s\n' "$tried" >&2
    printf 'vps-gateway-manager: no other ref is installed instead - copy the repository\n' >&2
    printf 'vps-gateway-manager: (or a release tarball) to this host and run install.sh from there.\n' >&2
    exit 1
  fi
  tar -xzf "$tmp/repo.tgz" -C "$tmp" || { printf 'vps-gateway-manager: could not unpack %s\n' "$url" >&2; exit 1; }
  # The extracted directory name is not guessable: GitHub strips a leading "v"
  # from tag names (v0.5.0 -> repo-0.5.0) and uses the full SHA for commit
  # archives. Discover it instead of constructing it.
  dir="$(find "$tmp" -maxdepth 2 -mindepth 2 -type f -name install.sh 2>/dev/null | head -n1)"
  dir="${dir%/install.sh}"
  if [ -z "$dir" ] || [ ! -r "$dir/install.sh" ]; then
    printf 'vps-gateway-manager: unexpected archive layout in %s (no install.sh at the top level)\n' "$url" >&2
    exit 1
  fi
  export VGM_HOME="$dir" VGM_LIB_DIR="$dir/lib" VGM_TEMPLATES_DIR="$dir/templates"
  exec bash "$dir/install.sh" "$@"
}

bootstrap_if_needed "$@"

# shellcheck source=/dev/null
. "$VGM_LIB_DIR/common.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/net.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/txn.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/squid.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/firewall.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/health.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/server.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/server-ops.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/client.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/migrate.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/detect.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/lock.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/update.sh"
# shellcheck source=/dev/null
. "$VGM_LIB_DIR/wizard.sh"

VGM_VERSION="$(gp_load_version)"

usage() {
  cat <<'EOF'
vps-gateway-manager :: install.sh

USAGE
  sudo bash install.sh                         # interactive wizard (TTY)
  sudo bash install.sh --interactive
  sudo bash install.sh server [options]
  sudo bash install.sh client --upstream <url> [options]
  sudo bash install.sh --help | --version

SERVER OPTIONS
  --domain <host>            public proxy hostname (fresh install; required)
  --port <port>              public TLS proxy port (default 8443)
  --loopback-port <port>     plain HTTP proxy port on loopback (default 3128)
  --cf-credentials <path>    root-only Cloudflare API ini for certbot DNS-01
                             (file 600, directory 700). Never pass tokens on
                             the command line.
  --email <address>          certbot account email (optional)
  --adopt-existing           take over an existing Squid proxy without
                             rewriting its configuration (recommended for a
                             host that already proxies GitHub)
  --acl-file <path>          override the client ACL file (adopt only)
  --client-acl-file <path>   where this tool writes its own client ACLs
  --domain-acl-name <name>   destination ACL name to use (adopt only)
  --cert-source <dir>        directory holding fullchain.pem/privkey.pem
  --no-obtain-cert           do not request a certificate automatically
  --no-ufw                   do not touch the firewall at all
  --squid-pkg <package>      package to install when squid is missing
                             (default squid-openssl)
  --force-replace-main-config  allow replacing a squid.conf we did not create
  --repo-url <url>           repository used for client onboarding commands
  --ref <git-ref>            branch, tag (e.g. v0.5.0) or full commit SHA for
                             the toolkit download and the onboarding commands

CLIENT OPTIONS
  --upstream <url>           https://host:port of the GitHub egress proxy
  --local-port <port>        local smart proxy port (default 3129)
  --adopt-existing           detect and migrate Komari, xray-manager and Git
  --migrate-global-env       allow migrating /etc/environment (global!)
  --no-git-config            do not touch any ~/.gitconfig
  --git-users root,user      restrict git configuration to these users
  --upstream-ca <path>       CA bundle used to verify the upstream (default:
                             /etc/ssl/certs/ca-certificates.crt)
  --upstream-ssl-domain <n>  certificate name to verify on the upstream
  --upstream-family <f>      address family to use for the upstream:
                             auto (default; verified per family, the working
                             family is pinned to a probe-verified peer),
                             4 or 6 (explicit, still probe-verified)
  --allow-plaintext-upstream allow an http:// upstream (not recommended)
  --local-port-conflict-check  (internal) verify the port is free

COMMON OPTIONS
  --dry-run                  show exactly what would happen; change nothing
  -y, --yes                  assume yes for confirmations
  --verbose                  verbose logging
  --help                     this help
  --version                  print the version

EXAMPLES
  # brand new dedicated proxy server
  sudo bash install.sh server --domain gh.example.com \
       --cf-credentials /root/.secrets/certbot/cloudflare.ini

  # take over the proxy that is already running on this host (read-only first)
  sudo bash install.sh server --adopt-existing --dry-run

  # new client VPS
  sudo bash install.sh client --upstream https://gh.example.com:8443

  # existing client that already points at the remote proxy
  sudo bash install.sh client --upstream https://gh.example.com:8443 --adopt-existing
EOF
}

MODE=""
INTERACTIVE=0
ADOPT=0
SERVER_DOMAIN="${SERVER_DOMAIN:-}"
SERVER_TLS_PORT="${SERVER_TLS_PORT:-8443}"
SERVER_LOOPBACK_PORT="${SERVER_LOOPBACK_PORT:-3128}"
SERVER_CF_CREDENTIALS="${SERVER_CF_CREDENTIALS:-}"
SERVER_EMAIL="${SERVER_EMAIL:-}"
SERVER_UFW_MANAGED="${SERVER_UFW_MANAGED:-1}"
SERVER_SQUID_PKG="${SERVER_SQUID_PKG:-squid-openssl}"
SERVER_ALLOW_OVERWRITE_MAIN=0
SERVER_ALLOW_DUPLICATE_CLIENT=0
SERVER_OBTAIN_CERT=1
CLIENT_ALLOW_PLAINTEXT_UPSTREAM=0
CLIENT_MANAGE_GIT=1
CLIENT_GIT_USERS="auto"
CLIENT_MIGRATE_GLOBAL_ENV=0
NO_UFW=0

require_value() {
  # require_value <flag> <value>
  if [ -z "${2:-}" ]; then
    log_err "$1 requires a value"
    exit 2
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      server|client)
        if [ -n "$MODE" ]; then log_err "only one role can be given"; exit 2; fi
        MODE="$1"
        ;;
      --adopt-existing)      ADOPT=1 ;;
      --domain)              require_value "$1" "${2:-}"; SERVER_DOMAIN="$2"; shift ;;
      --port)                require_value "$1" "${2:-}"; SERVER_TLS_PORT="$2"; shift ;;
      --loopback-port)       require_value "$1" "${2:-}"; SERVER_LOOPBACK_PORT="$2"; shift ;;
      --cf-credentials)      require_value "$1" "${2:-}"; SERVER_CF_CREDENTIALS="$2"; shift ;;
      --email)               require_value "$1" "${2:-}"; SERVER_EMAIL="$2"; shift ;;
      --acl-file)            require_value "$1" "${2:-}"; SERVER_SOURCE_ACL_FILE="$2"; shift ;;
      --client-acl-file)     require_value "$1" "${2:-}"; SERVER_CLIENT_ACL_FILE="$2"; shift ;;
      --domain-acl-name)     require_value "$1" "${2:-}"; SERVER_DOMAIN_ACL_NAME="$2"; shift ;;
      --cert-source)         require_value "$1" "${2:-}"; SERVER_CERT_SOURCE="$2"; shift ;;
      --squid-pkg)           require_value "$1" "${2:-}"; SERVER_SQUID_PKG="$2"; shift ;;
      --repo-url)            require_value "$1" "${2:-}"; SERVER_REPO_URL="$2"; VGM_REPO_URL="$2"; shift ;;
      --ref)                 require_value "$1" "${2:-}"; SERVER_REPO_REF="$2"; VGM_REF="$2"; shift ;;
      --upstream)            require_value "$1" "${2:-}"; CLIENT_UPSTREAM="$2"; shift ;;
      --upstream-family)    require_value "$1" "${2:-}"; CLIENT_UPSTREAM_FAMILY="$2"; shift ;;
      --local-port)          require_value "$1" "${2:-}"; CLIENT_LOCAL_PORT="$2"; shift ;;
      --upstream-ca)         require_value "$1" "${2:-}"; CLIENT_UPSTREAM_CA="$2"; shift ;;
      --upstream-ssl-domain) require_value "$1" "${2:-}"; CLIENT_UPSTREAM_SSL_DOMAIN="$2"; shift ;;
      --git-users)           require_value "$1" "${2:-}"; CLIENT_GIT_USERS="$2"; shift ;;
      --allow-plaintext-upstream) CLIENT_ALLOW_PLAINTEXT_UPSTREAM=1 ;;
      --migrate-global-env)  CLIENT_MIGRATE_GLOBAL_ENV=1 ;;
      --no-git-config)       CLIENT_MANAGE_GIT=0 ;;
      --no-obtain-cert)      SERVER_OBTAIN_CERT=0 ;;
      --no-ufw)              NO_UFW=1 ;;
      --force-replace-main-config) SERVER_ALLOW_OVERWRITE_MAIN=1 ;;
      --force)               SERVER_ALLOW_DUPLICATE_CLIENT=1 ;;
      --restart-if-needed)   SERVER_RESTART_IF_NEEDED=yes ;;
      --interactive)         INTERACTIVE=1 ;;
      --dry-run)             GP_DRY_RUN=1 ;;
      -y|--yes)              GP_ASSUME_YES=1 ;;
      --verbose|-v)          GP_VERBOSE=1 ;;
      --repo-url=*)          SERVER_REPO_URL="${1#*=}"; VGM_REPO_URL="${1#*=}" ;;
      --ref=*)               SERVER_REPO_REF="${1#*=}"; VGM_REF="${1#*=}" ;;
      --upstream=*)          CLIENT_UPSTREAM="${1#*=}" ;;
      --version)             printf '%s %s\n' "$GP_PROJECT_NAME" "$VGM_VERSION"; exit 0 ;;
      -h|--help)             usage; exit 0 ;;
      *) log_err "unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  if [ -z "$MODE" ]; then
    if [ "$INTERACTIVE" = "1" ] || wizard_is_interactive; then
      if ! wizard_is_interactive; then
        log_err "stdin is not a terminal. Use 'install.sh server|client ...' or 'ghproxyctl update ...'."
        exit 1
      fi
      wizard_main
      exit $?
    fi
    usage
    exit 2
  fi
  export GP_DRY_RUN GP_ASSUME_YES GP_VERBOSE
  gp_mutation_lock_acquire || exit 1
  gp_require_linux || exit 1
  if [ "$(gp_uid)" != "0" ]; then
    log_err "root is required: use 'sudo bash install.sh $MODE ...'"
    exit 1
  fi
  if [ "$NO_UFW" = "1" ]; then
    SERVER_UFW_MANAGED=0
    log_info "firewall management disabled (--no-ufw)"
  fi
  if [ "${GP_DRY_RUN:-0}" = "1" ]; then
    log_head "DRY RUN - no changes will be made"
  fi

  case "$MODE" in
    server)
      if [ "$ADOPT" = "1" ]; then
        if [ "${GP_DRY_RUN:-0}" = "1" ]; then
          server_adopt_run 1
        else
          server_adopt_run 0
        fi
      else
        server_fresh_install
      fi
      ;;
    client)
      if [ "$ADOPT" = "1" ]; then
        client_adopt_run
      else
        client_install_run
      fi
      ;;
    *) usage; exit 2 ;;
  esac
}

gp_install_abort_guard
main "$@"
