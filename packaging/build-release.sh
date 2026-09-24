#!/usr/bin/env bash
# =============================================================================
# Build the management-tool release artifact. Does not publish anything.
#
#   bash packaging/build-release.sh [output-dir]
#
# Writes:
#   vps-gateway-manager-v<VERSION>.tar.gz
#   SHA256SUMS          (hash of that archive)
# The archive itself also contains a SHA256SUMS of the files the updater
# installs, plus release.meta.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
VER="$(head -n 1 "$ROOT/VERSION" | tr -d '[:space:]')"
[ -n "$VER" ] || { printf 'VERSION is empty\n' >&2; exit 1; }
NAME="vps-gateway-manager-v${VER}"
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
