#!/usr/bin/env bash
# =============================================================================
# vps-gateway-manager :: uninstall.sh
#
#   sudo bash uninstall.sh client            # remove the local proxy + restore
#   sudo bash uninstall.sh client --purge    # also remove state
#   sudo bash uninstall.sh server            # fresh: remove our config
#                                            # adopted: "unmanage" only
#   sudo bash uninstall.sh server --purge
#
# Adopted servers keep their original Squid configuration, certificates and
# clients: uninstall only detaches this tool.
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VGM_LIB_DIR="${VGM_LIB_DIR:-$SELF_DIR/lib}"
VGM_TEMPLATES_DIR="${VGM_TEMPLATES_DIR:-$SELF_DIR/templates}"
export VGM_LIB_DIR VGM_TEMPLATES_DIR

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

VGM_VERSION="$(gp_load_version)"

MODE=""
PURGE=0
GP_DRY_RUN=0
GP_ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    client|server) MODE="$1" ;;
    --purge)  PURGE=1 ;;
    --dry-run) GP_DRY_RUN=1 ;;
    -y|--yes) GP_ASSUME_YES=1 ;;
    --verbose|-v) GP_VERBOSE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
  shift
done
export GP_DRY_RUN GP_ASSUME_YES GP_VERBOSE

gp_require_linux || exit 1
if [ "$(gp_uid)" != "0" ]; then
  log_err "root is required: sudo bash uninstall.sh ${MODE:-<role>}"
  exit 1
fi

if [ -z "$MODE" ]; then
  MODE="$(gp_role)"
  if [ -z "$MODE" ]; then
    log_err "this host is not configured by vps-gateway-manager (no role file)"
    exit 1
  fi
  log_info "detected role: $MODE"
fi

case "$MODE" in
  client) client_uninstall "$PURGE" ;;
  server) server_uninstall "$PURGE" ;;
esac
