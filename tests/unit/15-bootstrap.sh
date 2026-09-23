#!/usr/bin/env bash
# =============================================================================
# unit test :: install.sh self-bootstrap with pinned refs
#
# The documented one-liner downloads only install.sh; the bootstrap then fetches
# the toolkit archive. A pinned ref must install EXACTLY what was asked for:
#   * a branch        -> archive/refs/heads/<ref>.tar.gz
#   * a tag (v0.5.0)  -> archive/refs/tags/<ref>.tar.gz (tried after heads)
#   * a full SHA      -> archive/<sha>.tar.gz
# and when the ref cannot be fetched the bootstrap must FAIL loudly instead of
# silently falling back to main. Archive layout is discovered, never guessed
# (GitHub strips the leading "v" from tag names and uses the SHA for commits).
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup

CURL_DIR="$STUB_STATE/curl"
FULL_SHA="32b9f6633e6b8eaeaa481fefbe6bc5c9f038815d"

# make_fake_toolkit <tarball> <topdir-name>
make_fake_toolkit() {
  local out="$1" top="$2" stage
  stage="$SANDBOX/stage-$RANDOM$RANDOM"
  mkdir -p "$stage/$top/lib" "$stage/$top/templates"
  cat > "$stage/$top/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'FAKE-TOOLKIT install.sh executed\n'
printf 'FAKE-TOOLKIT VGM_HOME=%s\n' "${VGM_HOME:-unset}"
printf 'FAKE-TOOLKIT VGM_LIB_DIR=%s\n' "${VGM_LIB_DIR:-unset}"
printf 'FAKE-TOOLKIT args: %s\n' "$*"
EOF
  : > "$stage/$top/lib/common.sh"
  : > "$stage/$top/templates/github-domains.txt"
  tar -czf "$out" -C "$stage" "$top"
  rm -rf "$stage"
}

# run_bootstrap <args...>: run install.sh with NO libraries visible, so the
# self-bootstrap path really executes (instead of returning immediately).
run_bootstrap() {
  VGM_LIB_DIR="$SANDBOX/no-libs" bash "$REPO_ROOT/install.sh" "$@"
}

serve() { printf '%s\t%s\n' "$1" "$2" > "$CURL_DIR/files"; }
reset_calls() { : > "$CURL_DIR/calls.log"; }
first_line_of() { grep -n -- "$1" "$CURL_DIR/calls.log" 2>/dev/null | head -n1 | cut -d: -f1; }

# -----------------------------------------------------------------------------
t_begin "a branch ref installs from refs/heads"
make_fake_toolkit "$CURL_DIR/toolkit-main.tgz" "vps-gateway-manager-main"
serve "archive/refs/heads/main" "$CURL_DIR/toolkit-main.tgz"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref main 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the branch archive installs"
assert_contains "$OUT" 'FAKE-TOOLKIT install.sh executed' "the downloaded toolkit is executed"
assert_matches_line "$OUT" 'FAKE-TOOLKIT VGM_HOME=.*vps-gateway-manager-main' \
  "VGM_HOME points into the extracted branch tree"
assert_contains "$OUT" 'args: client --upstream https://gh.test.invalid:8443 --ref main' \
  "the original arguments are passed through"
assert_file_contains "$CURL_DIR/calls.log" 'archive/refs/heads/main\.tar\.gz' "the branch archive URL is used"
assert_file_not_contains "$CURL_DIR/calls.log" 'refs/tags' "the tag path is not probed for a branch"

# -----------------------------------------------------------------------------
t_begin "a tag ref falls back to refs/tags and the extracted dir is discovered"
# GitHub names the extracted directory repo-0.5.0 for the tag v0.5.0: the old
# code guessed repo-$ref and failed on every tag.
make_fake_toolkit "$CURL_DIR/toolkit-tag.tgz" "vps-gateway-manager-0.5.0"
serve "archive/refs/tags/v0.5.0" "$CURL_DIR/toolkit-tag.tgz"
# the branch path does not exist for this ref (a real 404 fails the -f download)
printf 'archive/refs/heads\t000\n' > "$CURL_DIR/rules"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref v0.5.0 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the tag archive installs"
assert_contains "$OUT" 'FAKE-TOOLKIT install.sh executed' "the tag toolkit is executed"
assert_matches_line "$OUT" 'FAKE-TOOLKIT VGM_HOME=.*vps-gateway-manager-0\.5\.0' \
  "the v-stripped tag directory is discovered, not guessed"
assert_file_contains "$CURL_DIR/calls.log" 'archive/refs/heads/v0\.5\.0\.tar\.gz' "the branch path is tried first"
assert_file_contains "$CURL_DIR/calls.log" 'archive/refs/tags/v0\.5\.0\.tar\.gz' "the tag path is tried next"
if [ -n "$(first_line_of 'refs/heads/v0\.5\.0')" ] && [ -n "$(first_line_of 'refs/tags/v0\.5\.0')" ]; then
  assert_ok "the branch path is tried before the tag path" \
    [ "$(first_line_of 'refs/heads/v0\.5\.0')" -lt "$(first_line_of 'refs/tags/v0\.5\.0')" ]
else
  t_fail "the branch path is tried before the tag path (missing calls)"
fi
assert_file_not_contains "$CURL_DIR/calls.log" 'refs/heads/main' "no silent fallback to main"

# -----------------------------------------------------------------------------
t_begin "a full commit SHA installs from archive/<sha>.tar.gz"
make_fake_toolkit "$CURL_DIR/toolkit-sha.tgz" "vps-gateway-manager-$FULL_SHA"
serve "archive/$FULL_SHA" "$CURL_DIR/toolkit-sha.tgz"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref "$FULL_SHA" 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the commit archive installs"
assert_matches_line "$OUT" "FAKE-TOOLKIT VGM_HOME=.*vps-gateway-manager-$FULL_SHA" \
  "the commit tree is discovered"
assert_file_contains "$CURL_DIR/calls.log" "archive/$FULL_SHA\.tar\.gz" "the commit archive URL is used"
assert_file_not_contains "$CURL_DIR/calls.log" 'refs/heads' "a full SHA never probes the branch path"
assert_file_not_contains "$CURL_DIR/calls.log" 'refs/tags' "a full SHA never probes the tag path"

# -----------------------------------------------------------------------------
t_begin "the --ref=<ref> form pins the same way"
make_fake_toolkit "$CURL_DIR/toolkit-tag2.tgz" "vps-gateway-manager-0.5.0"
serve "archive/refs/tags/v0.5.0" "$CURL_DIR/toolkit-tag2.tgz"
printf 'archive/refs/heads\t000\n' > "$CURL_DIR/rules"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref=v0.5.0 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "--ref=<ref> installs the tag"
assert_file_contains "$CURL_DIR/calls.log" 'archive/refs/tags/v0\.5\.0\.tar\.gz' "the tag archive URL is used"

# -----------------------------------------------------------------------------
t_begin "an unfetchable ref fails loudly and never falls back to main"
: > "$CURL_DIR/files"
touch "$CURL_DIR/fail"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref v9.9.9 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "the bootstrap fails when the ref cannot be fetched"
assert_contains "$OUT" 'could not download' "the failure is reported"
assert_contains "$OUT" 'tried:' "the attempted URLs are shown"
assert_file_contains "$CURL_DIR/calls.log" 'refs/heads/v9\.9\.9' "the branch path was tried"
assert_file_contains "$CURL_DIR/calls.log" 'refs/tags/v9\.9\.9' "the tag path was tried"
assert_file_not_contains "$CURL_DIR/calls.log" 'refs/heads/main' "no silent fallback to main"
rm -f "$CURL_DIR/fail"

# -----------------------------------------------------------------------------
t_begin "an archive without install.sh at the top level is rejected"
BAD="$SANDBOX/stage-bad-$RANDOM"
mkdir -p "$BAD/wrong-layout/lib"
: > "$BAD/wrong-layout/lib/common.sh"
tar -czf "$CURL_DIR/wrong.tgz" -C "$BAD" wrong-layout
rm -rf "$BAD"
serve "archive/refs/heads/broken-layout" "$CURL_DIR/wrong.tgz"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref broken-layout 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a layout without install.sh is rejected"
assert_contains "$OUT" 'unexpected archive layout' "the layout problem is reported"

# -----------------------------------------------------------------------------
t_begin "a corrupt archive is rejected"
printf 'this is not a tarball\n' > "$CURL_DIR/broken.tgz"
serve "archive/refs/heads/corrupt" "$CURL_DIR/broken.tgz"
reset_calls
OUT="$(run_bootstrap client --upstream https://gh.test.invalid:8443 --ref corrupt 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a corrupt archive is rejected"
assert_contains "$OUT" 'could not unpack' "the unpack failure is reported"

sandbox_teardown
t_summary
