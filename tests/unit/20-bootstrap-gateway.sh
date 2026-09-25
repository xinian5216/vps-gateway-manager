#!/usr/bin/env bash
# =============================================================================
# unit test :: vgm-bootstrap first install through a gateway proxy
#
# A host that cannot reach GitHub directly (mainland China, IPv6-only) must be
# able to install through an authorised HTTPS gateway. With --upstream EVERY
# request vgm-bootstrap makes - latest-release lookup, redirect follows,
# SHA256SUMS and tarball downloads - goes through that gateway; no request may
# fall back to the direct path. TLS verification stays on (no insecure
# switch), the outer AND the inner SHA256 manifests are checked, failures are
# reported by class (DNS, network, gateway ACL, TLS), and every install
# argument reaches install.sh unchanged.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup

CURL_DIR="$STUB_STATE/curl"
GW="https://gw.test.invalid:8443"
GW6="https://[fd00::2]:8443"
TAG="v0.6.1"
TOP="vps-gateway-manager-0.6.1"
TARBALL="vps-gateway-manager-v0.6.1.tar.gz"

write_tree_sums() {
  local root="$1" f hash
  : > "$root/SHA256SUMS"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hash="$(sha256sum "$root/$f" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$f" >> "$root/SHA256SUMS"
  done < <( (cd "$root" && find . -type f ! -name SHA256SUMS -print | sed 's#^\./##' | sort) )
}

# make_release <tarball> <top> [corrupt-inner]
make_release() {
  local out="$1" top="$2" corrupt="${3:-}" stage
  stage="$SANDBOX/rel-$RANDOM$RANDOM"
  mkdir -p "$stage/$top/lib" "$stage/$top/bin" "$stage/$top/templates"
  cat > "$stage/$top/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'FAKE-INSTALL executed\n'
printf 'FAKE-INSTALL args: %s\n' "$*"
EOF
  : > "$stage/$top/lib/common.sh"
  : > "$stage/$top/bin/vgm-bootstrap"
  : > "$stage/$top/templates/github-domains.txt"
  printf '0.6.1\n' > "$stage/$top/VERSION"
  printf 'version=0.6.1\ncommit=unreleased\nupgrade_from_min=0.5.1\nconfig_migration=0\nservice_reload=0\nchannel=stable\n' \
    > "$stage/$top/release.meta"
  write_tree_sums "$stage/$top"
  if [ -n "$corrupt" ]; then
    awk 'NR==1 { print "0000000000000000000000000000000000000000000000000000000000000000  " $2; next } { print }' \
      "$stage/$top/SHA256SUMS" > "$stage/$top/SHA256SUMS.x"
    mv "$stage/$top/SHA256SUMS.x" "$stage/$top/SHA256SUMS"
  fi
  tar -czf "$out" -C "$stage" "$top"
  rm -rf "$stage"
}

# make_outer_sums <tarball> <sums-out> [broken]
make_outer_sums() {
  local hash
  hash="$(sha256sum "$1" | awk '{print $1}')"
  if [ -n "${3:-}" ]; then
    hash="0000000000000000000000000000000000000000000000000000000000000000"
  fi
  printf '%s  %s\n' "$hash" "$(basename "$1")" > "$2"
}

set_discovery() {
  printf 'releases/latest\t200\n' > "$CURL_DIR/rules"
  printf 'releases/latest\t%s\n' \
    "${1:-https://github.com/xinian5216/vps-gateway-manager/releases/tag/$TAG}" > "$CURL_DIR/redirects"
}

serve() { printf '%s\t%s\n' "$1" "$2" >> "$CURL_DIR/files"; }

reset_curl() {
  : > "$CURL_DIR/calls.log"
  : > "$CURL_DIR/files"
  rm -f "$CURL_DIR/fail" "$CURL_DIR/fail-with" "$CURL_DIR/rules" "$CURL_DIR/redirects"
}

fail_with() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$CURL_DIR/fail-with"; }

# setup_release [corrupt-inner] [broken-outer]
setup_release() {
  make_release "$CURL_DIR/$TARBALL" "$TOP" "${1:-}"
  make_outer_sums "$CURL_DIR/$TARBALL" "$CURL_DIR/rel.SHA256SUMS" "${2:-}"
  set_discovery
  serve "releases/download/$TAG/$TARBALL" "$CURL_DIR/$TARBALL"
  serve "releases/download/$TAG/SHA256SUMS" "$CURL_DIR/rel.SHA256SUMS"
}

run_vgm() { bash "$REPO_ROOT/bin/vgm-bootstrap" "$@"; }
calls() { cat "$CURL_DIR/calls.log" 2>/dev/null || true; }
calls_with() { calls | grep -c -- "$1" || true; }

# -----------------------------------------------------------------------------
t_begin "direct install is unchanged without --upstream"
reset_curl
setup_release
OUT="$(run_vgm client --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "a direct first install succeeds"
assert_contains "$OUT" 'FAKE-INSTALL executed' "the downloaded tree is installed"
assert_contains "$OUT" 'FAKE-INSTALL args: client --yes' "arguments reach install.sh"
assert_file_not_contains "$CURL_DIR/calls.log" '--proxy' "no proxy flag appears on the direct path"

# -----------------------------------------------------------------------------
t_begin "every request goes through the gateway, none may bypass it"
reset_curl
setup_release
OUT="$(run_vgm --upstream "$GW" client --upstream "$GW" --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the gateway first install succeeds"
assert_contains "$OUT" 'FAKE-INSTALL executed' "the downloaded tree is installed"
assert_eq "3" "$(calls | grep -c . || true)" "exactly three requests were made"
assert_eq "3" "$(calls_with --proxy)" "every request carried --proxy"
assert_eq "3" "$(calls_with --noproxy)" "every request disabled no_proxy exceptions"
assert_eq "3" "$(calls_with "https://gw.test.invalid:8443")" "every request used the gateway URL"
assert_eq "$(calls | grep -c . || true)" "$(calls_with --proxy)" "no request bypassed the gateway"

# -----------------------------------------------------------------------------
t_begin "the latest-release redirect drives the download"
reset_curl
setup_release
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
assert_eq "0" "$RC" "the redirected tag installs"
assert_file_contains "$CURL_DIR/calls.log" 'releases/latest' "the lookup endpoint is used"
assert_file_contains "$CURL_DIR/calls.log" "releases/download/$TAG/$TARBALL" "the redirect target's tag is downloaded"
assert_file_not_contains "$CURL_DIR/calls.log" 'archive/refs' "no source archive is fetched"

# -----------------------------------------------------------------------------
t_begin "an IPv6-only gateway address is used verbatim"
reset_curl
setup_release
OUT="$(run_vgm --upstream "$GW6" client --upstream-family 6 --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the IPv6 gateway first install succeeds"
assert_eq "3" "$(calls_with 'https://\[fd00::2\]:8443')" "every request used the IPv6 gateway address"
assert_contains "$OUT" "FAKE-INSTALL args: --upstream $GW6 client --upstream-family 6 --yes" \
  "the gateway address and family choice reach install.sh"

# -----------------------------------------------------------------------------
t_begin "a TLS failure aborts and is reported as TLS"
reset_curl
setup_release
fail_with "releases/latest" 60 "curl: (60) SSL certificate problem: unable to get local issuer certificate"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a TLS failure is not a successful install"
assert_contains "$OUT" 'TLS/certificate problem' "the failure is classified as TLS"
assert_contains "$OUT" 'refusing to fall back to main' "no fallback is offered"
assert_not_contains "$OUT" 'FAKE-INSTALL executed' "nothing was installed"

# -----------------------------------------------------------------------------
t_begin "an interrupted download aborts and installs nothing"
reset_curl
setup_release
fail_with "$TARBALL" 18 "curl: (18) transfer closed with 1024 bytes remaining"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "an interrupted transfer is not a successful install"
assert_contains "$OUT" 'the transfer was interrupted' "the interruption is named"
assert_not_contains "$OUT" 'FAKE-INSTALL executed' "nothing was installed"

# -----------------------------------------------------------------------------
t_begin "an outer SHA256 mismatch is refused"
reset_curl
setup_release "" broken
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a tampered archive is refused"
assert_contains "$OUT" "checksum mismatch for $TARBALL" "the outer manifest failure names the file"
assert_not_contains "$OUT" 'FAKE-INSTALL executed' "nothing was installed"

# -----------------------------------------------------------------------------
t_begin "an inner SHA256 mismatch is refused"
reset_curl
setup_release corrupt
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a tampered tree is refused"
assert_contains "$OUT" 'checksum mismatch for' "the inner manifest failure names the file"
assert_not_contains "$OUT" 'FAKE-INSTALL executed' "nothing was installed"

# -----------------------------------------------------------------------------
t_begin "a failed release lookup never falls back to main"
reset_curl
setup_release
fail_with "releases/latest" 7 "curl: (7) Failed to connect to api.github.com port 443: Connection refused"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a failed lookup is not a successful install"
assert_contains "$OUT" 'could not discover the latest stable release' "the lookup failure is reported"
assert_contains "$OUT" 'refusing to fall back to main' "the refusal names the no-fallback rule"
assert_contains "$OUT" 'host or gateway unreachable (network)' "the failure is classified as network"
assert_file_not_contains "$CURL_DIR/calls.log" 'releases/download' "no download was attempted"

# -----------------------------------------------------------------------------
t_begin "a non-release redirect target is refused"
reset_curl
setup_release
set_discovery "https://github.com/xinian5216/vps-gateway-manager/commits/main"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a non-tag redirect is refused"
assert_contains "$OUT" 'latest redirect was not a tag URL' "the redirect problem is reported"
reset_curl
setup_release
set_discovery "https://github.com/xinian5216/vps-gateway-manager/releases/tag/main"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a non-release tag is refused"
assert_contains "$OUT" "refusing non-release tag 'main'" "the non-release tag is named"

# -----------------------------------------------------------------------------
t_begin "a gateway ACL refusal is named as such"
reset_curl
setup_release
fail_with "releases/download" 56 "curl: (56) CONNECT tunnel failed, response 403"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "an ACL refusal is not a successful install"
assert_contains "$OUT" 'authorize this host' "the fix is the gateway source ACL"
assert_contains "$OUT" '/32 or /128' "the exact-address requirement is named"
assert_not_contains "$OUT" 'FAKE-INSTALL executed' "nothing was installed"
# A refused CONNECT can also surface as an HTTP error (curl -f); on the
# gateway path the failure must still name the ACL fix and never blame the
# network.
fail_with "releases/download" 22 "curl: (22) The requested URL returned error: 403"
OUT="$(run_vgm --upstream "$GW" client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "an HTTP refusal through the gateway is not a successful install"
assert_contains "$OUT" 'authorize this host' "an HTTP refusal through the gateway is attributed to the ACL"
assert_contains "$OUT" '/32 or /128' "an HTTP refusal through the gateway also names the ACL fix"
assert_not_contains "$OUT" 'unreachable (network)' "an HTTP refusal is not blamed on the network"

# -----------------------------------------------------------------------------
t_begin "install arguments reach install.sh unchanged"
reset_curl
setup_release
OUT="$(run_vgm --upstream "$GW" client --upstream-family 6 --ref "$TAG" --local-port 3129 --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the passthrough install succeeds"
assert_contains "$OUT" "FAKE-INSTALL args: --upstream $GW client --upstream-family 6 --ref $TAG --local-port 3129 --yes" \
  "every argument reaches install.sh verbatim"

# -----------------------------------------------------------------------------
t_begin "an http:// upstream is refused; TLS is mandatory"
reset_curl
setup_release
OUT="$(run_vgm --upstream http://gw.test.invalid:8443 client 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a plaintext upstream is refused"
assert_contains "$OUT" 'https:// gateway URL' "the refusal names the TLS requirement"

sandbox_teardown
t_summary
