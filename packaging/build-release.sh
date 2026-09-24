#!/usr/bin/env bash
# =============================================================================
# Build the management-tool release artifact. Does not publish anything.
#
#   bash packaging/build-release.sh [--development] [output-dir]
#
# A stable artifact (vps-gateway-manager-v<VERSION>.tar.gz) is refused unless
# release.meta says channel=stable and commit is a 40-hex SHA. Development
# trees must pass --development; that writes a -dev artifact so it cannot be
# dropped in as the formal Release asset.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="stable"
if [ "${1:-}" = "--development" ]; then
  MODE="development"
  shift
fi
OUT="${1:-$ROOT/dist}"
VER="$(head -n 1 "$ROOT/VERSION" | tr -d '[:space:]')"
META_VER="$(awk -F= '$1=="version"{print $2; exit}' "$ROOT/release.meta" | tr -d '[:space:]')"
META_COMMIT="$(awk -F= '$1=="commit"{print $2; exit}' "$ROOT/release.meta" | tr -d '[:space:]')"
META_CHANNEL="$(awk -F= '$1=="channel"{print $2; exit}' "$ROOT/release.meta" | tr -d '[:space:]')"
if [ "$MODE" = "stable" ]; then
  if [ "$META_CHANNEL" != "stable" ] || [ "$META_COMMIT" = "unreleased" ] || [ "${#META_COMMIT}" -ne 40 ]; then
    printf 'refusing to build a stable artifact from channel=%s commit=%s\n' \
      "${META_CHANNEL:-empty}" "${META_COMMIT:-empty}" >&2
    printf 'pass --development for a non-release package, or set a stable release.meta first\n' >&2
    exit 1
  fi
  if [ "$META_VER" != "$VER" ]; then
    printf 'VERSION %s does not match release.meta %s\n' "$VER" "${META_VER:-empty}" >&2
    exit 1
  fi
  NAME="vps-gateway-manager-v${VER}"
else
  NAME="vps-gateway-manager-v${VER}-dev"
fi
[ -n "$VER" ] || { printf 'VERSION is empty\n' >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vgm-pack.XXXXXX")"
TREE="$STAGE/$NAME"

mkdir -p "$TREE/bin" "$TREE/lib" "$OUT"
cp -a "$ROOT/lib/." "$TREE/lib/"
if [ -d "$ROOT/templates" ]; then
  cp -a "$ROOT/templates" "$TREE/templates"
fi
cp -a "$ROOT/bin/ghproxyctl" "$TREE/bin/ghproxyctl"
cp -a "$ROOT/bin/vgm-bootstrap" "$TREE/bin/vgm-bootstrap"
cp -a "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/VERSION" "$ROOT/release.meta" "$TREE/"
chmod 0755 "$TREE/bin/ghproxyctl" "$TREE/bin/vgm-bootstrap" "$TREE/install.sh" "$TREE/uninstall.sh"

# Member checksums. Paths are relative to the release root.
(
  cd "$TREE"
  files="$(find . -type f ! -name SHA256SUMS | sed 's#^\./##' | sort)"
  : > SHA256SUMS
  for f in $files; do
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$f" >> SHA256SUMS
    else
      shasum -a 256 "$f" >> SHA256SUMS
    fi
  done
)

tar -czf "$OUT/$NAME.tar.gz" -C "$STAGE" "$NAME"
if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum "$OUT/$NAME.tar.gz" | awk '{print $1}')"
else
  hash="$(shasum -a 256 "$OUT/$NAME.tar.gz" | awk '{print $1}')"
fi
printf '%s  %s\n' "$hash" "$NAME.tar.gz" > "$OUT/SHA256SUMS"
rm -rf "$STAGE"
printf '%s\n' "$OUT/$NAME.tar.gz"
