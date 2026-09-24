#!/usr/bin/env bash
# =============================================================================
# unit test :: pre-release hardening of the updater
# temp-dir cleanup, lock reclaim, backup checksums, pre-existing health FAILs,
# and the stable-artifact guard. No Squid / firewall behaviour.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

export GP_ASSUME_YES=1 GP_DRY_RUN=0 GP_INTERACTIVE=no
export VGM_UPDATE_HEALTH_RESULT=pass
COMMIT_STABLE="0123456789abcdef0123456789abcdef01234567"

vgm_update_count() {
  find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -type d -name 'vgm-update.*' 2>/dev/null | sort -u | wc -l | tr -d ' '
}

write_sums() {
  local dest="$1" list f hash
  list="$(mktemp)"
  (cd "$dest" && find . -type f ! -name SHA256SUMS -print | sed 's#^\./##' | sort) >"$list"
  : >"$dest/SHA256SUMS"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hash="$(gp_sha256 "$dest/$f")" || { rm -f "$list"; return 1; }
    printf '%s  %s\n' "$hash" "$f" >>"$dest/SHA256SUMS"
  done <"$list"
  rm -f "$list"
}

write_release_tree() {
  local dest="$1" ver="$2"
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/lib" "$dest/templates"
  cp -a "$REPO_ROOT/lib/." "$dest/lib/"
  cp -a "$REPO_ROOT/templates/." "$dest/templates/" 2>/dev/null || true
  cp -a "$REPO_ROOT/bin/ghproxyctl" "$dest/bin/ghproxyctl"
  cp -a "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$dest/"
  printf '%s\n' "$ver" >"$dest/VERSION"
  cat >"$dest/release.meta" <<EOF
version=$ver
commit=$COMMIT_STABLE
upgrade_from_min=0.5.1
config_migration=0
service_reload=0
channel=stable
EOF
  write_sums "$dest"
}

install_tree() {
  local src="$1" dest
  dest="$(gp_libexec_dir)"
  rm -rf "$dest"
  mkdir -p "$dest" "$(gp_bin_dir)"
  cp -a "$src/." "$dest/"
  cp -a "$src/bin/ghproxyctl" "$(gp_bin_dir)/ghproxyctl"
  chmod 0755 "$(gp_bin_dir)/ghproxyctl" || true
}

seed_server() {
  mkdir -p "$(gp_state_dir)"
  printf 'server\n' >"$(gp_role_file)"
  printf 'mode=fresh\ndomain=gh.example.test\ntls_port=8443\nloopback_port=3128\n' >"$(gp_server_conf)"
}

# -----------------------------------------------------------------------------
t_begin "temp work dir is not leaked"
if grep -n '$(update_acquire_source' "$REPO_ROOT/lib/update.sh" >/dev/null 2>&1; then
  t_fail "update_acquire_source is still wrapped in a command substitution"
else
  t_ok "update_acquire_source is not wrapped in a command substitution"
fi
OLD="$SANDBOX/rel-051"
NEW="$SANDBOX/rel-060"
write_release_tree "$OLD" 0.5.1
write_release_tree "$NEW" 0.6.0
install_tree "$OLD"
seed_server
mkdir -p "$SANDBOX/dist"
tar -czf "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" -C "$SANDBOX" "$(basename "$NEW")"
hash="$(sha256sum "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "vps-gateway-manager-v0.6.0.tar.gz" >"$SANDBOX/dist/SHA256SUMS"
before="$(vgm_update_count)"
update_acquire_source "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" "" || t_fail "archive acquire failed"
work="${UPDATE_WORK:-}"
if [ -n "$work" ] && [ -d "$work" ]; then
  t_ok "archive acquire records the temp dir in this shell"
else
  t_fail "archive acquire did not record UPDATE_WORK"
fi
update_cleanup_work
if [ -n "$work" ] && [ -d "$work" ]; then
  t_fail "cleanup left $work"
else
  t_ok "cleanup removes the recorded temp dir"
fi
after="$(vgm_update_count)"
assert_eq "$before" "$after" "cleanup does not leave a new vgm-update directory"

# A path that is not our temp prefix must survive, even if a txn names it.
keep="$SANDBOX/not-a-temp"
mkdir -p "$keep"
printf 'keep\n' >"$keep/marker"
update_txn_set work "$keep"
update_cleanup_work
assert_eq "keep" "$(cat "$keep/marker")" "cleanup does not delete a non-temp path named by the txn"

# Interrupt before switch removes the temp dir and does not touch a backup.
work="$(mktemp -d "${TMPDIR:-/tmp}/vgm-update.XXXXXX")"
UPDATE_WORK="$work"
export UPDATE_WORK
update_txn_set phase PRECHECK
update_txn_set backup "$keep"
rc=0
(update_on_interrupt) || rc=$?
assert_eq "130" "$rc" "interrupt exits 130"
assert_file_absent "$work" "interrupt removes the temp work dir"
assert_eq "keep" "$(cat "$keep/marker")" "interrupt does not delete recovery material outside the temp prefix"

# -----------------------------------------------------------------------------
t_begin "stale lock reclaim is single-winner"
lock="$(gp_lock_file).d"
mkdir -p "$(dirname "$lock")"
rm -rf "$lock" "$lock".stale.*
mkdir "$lock"
printf '%s\n' 2147483646 >"$lock/pid"
: >"$SANDBOX/holders"
i=0
while [ "$i" -lt 8 ]; do
  (
    if gp_mutation_lock_acquire 2>/dev/null; then
      echo "$$" >>"$SANDBOX/holders"
      sleep 1
      gp_mutation_lock_release
    fi
  ) &
  i=$((i + 1))
done
sleep 0.4
held="$(wc -l <"$SANDBOX/holders" | tr -d ' ')"
assert_eq "1" "$held" "eight concurrent reclaimers produce one holder"
wait || true
GP_MUTATION_LOCK_HELD=0
rm -rf "$lock"

t_begin "SIGKILL holder is reclaimed"
(
  gp_mutation_lock_acquire || exit 2
  sleep 30
) &
holder=$!
sleep 0.3
kill -9 "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
i=0
while [ -d "/proc/$holder" ] && [ "$i" -lt 20 ]; do
  sleep 0.1
  i=$((i + 1))
done
GP_MUTATION_LOCK_HELD=0
rc=0
gp_mutation_lock_acquire || rc=$?
assert_eq "0" "$rc" "a SIGKILL'd holder does not block the next acquire"
gp_mutation_lock_release || true

# -----------------------------------------------------------------------------
t_begin "backup checksums reject a damaged library"
install_tree "$OLD"
seed_server
UPDATE_ID="bk-$$"
dest="$(update_backup_create "$UPDATE_ID")"
assert_ok "a fresh backup passes its integrity check" update_backup_ok "$dest"
printf 'corrupted\n' >>"$dest/tree/lib/common.sh"
if update_backup_ok "$dest"; then
  t_fail "a corrupted lib/common.sh still passed"
else
  t_ok "a corrupted lib/common.sh fails the backup check"
fi
out="$(update_list_backups 2>&1)"
assert_not_contains "$out" "known-good" "a corrupted backup is not listed as known-good"
rm -f "$dest/tree/lib/common.sh"
if update_backup_ok "$dest"; then
  t_fail "a missing library file still passed"
else
  t_ok "a missing library file fails the backup check"
fi

# -----------------------------------------------------------------------------
t_begin "same pre-existing FAIL is not a new-version failure"
install_tree "$OLD"
seed_server
export VGM_UPDATE_HEALTH_RESULT=fail
export VGM_UPDATE_HEALTH_FAILS="Unknown source refused"
export VGM_UPDATE_POST_HEALTH_RESULT=fail
export VGM_UPDATE_POST_HEALTH_FAILS="Unknown source refused"
rc=0
out="$(update_run --source "$NEW" --allow-unhealthy 2>&1)" || rc=$?
assert_eq "0" "$rc" "an unchanged FAIL set does not roll the update back"
assert_contains "$out" "PRE-EXISTING FAILURES" "the result names the failures as pre-existing"
assert_not_contains "$out" "new health failure" "the same FAIL is not described as new"
assert_eq "0.6.0" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "the new toolchain stays in place"

t_begin "a new FAIL name still rolls back"
install_tree "$OLD"
seed_server
export VGM_UPDATE_POST_HEALTH_FAILS=$'Unknown source refused\nGitHub API'
rc=0
out="$(update_run --source "$NEW" --allow-unhealthy 2>&1)" || rc=$?
assert_ne "0" "$rc" "a new FAIL name fails the update"
assert_contains "$out" "new health failure" "the new check is named"
assert_contains "$out" "GitHub API" "the new check name is in the report"
assert_eq "0.5.1" "$(env -u VGM_HOME -u VGM_LIB_DIR -u VGM_TEMPLATES_DIR GP_ROOT="$GP_ROOT" GP_NO_COLOR=1 bash "$(gp_bin_dir)/ghproxyctl" version | awk '{print $2}')" \
  "rollback returns the executed version to 0.5.1"
unset VGM_UPDATE_HEALTH_FAILS VGM_UPDATE_POST_HEALTH_FAILS VGM_UPDATE_POST_HEALTH_RESULT
export VGM_UPDATE_HEALTH_RESULT=pass

# -----------------------------------------------------------------------------
t_begin "stable packaging refuses a development tree"
rc=0
out="$(bash "$REPO_ROOT/packaging/build-release.sh" "$SANDBOX/dist-stable" 2>&1)" || rc=$?
assert_ne "0" "$rc" "the development tree cannot build a stable artifact"
assert_contains "$out" "refusing to build a stable artifact" "the refusal names the guard"
assert_file_absent "$SANDBOX/dist-stable/vps-gateway-manager-v0.6.0.tar.gz" "no stable tarball was written"
rc=0
out="$(bash "$REPO_ROOT/packaging/build-release.sh" --development "$SANDBOX/dist-dev" 2>&1)" || rc=$?
assert_eq "0" "$rc" "--development can still pack the working tree"
assert_contains "$out" "-dev.tar.gz" "the development artifact is not the stable filename"
assert_file_absent "$SANDBOX/dist-dev/vps-gateway-manager-v0.6.0.tar.gz" "development mode does not write the stable name"

sandbox_teardown
t_summary
