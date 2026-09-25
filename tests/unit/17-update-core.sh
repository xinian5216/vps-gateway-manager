#!/usr/bin/env bash
# =============================================================================
# unit test :: management-toolchain update engine
#
# Covers version rules, role detection, the shared updater, failure injection,
# crash recovery, the lock, dry-run, and the v0.5.1 silent-skip regression.
# No firewall, ACL or Squid behaviour is changed here.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

COMMIT_STABLE="0123456789abcdef0123456789abcdef01234567"
GP_ASSUME_YES=1
GP_DRY_RUN=0
GP_INTERACTIVE=no
export GP_ASSUME_YES GP_DRY_RUN GP_INTERACTIVE
VGM_UPDATE_HEALTH_RESULT=pass
export VGM_UPDATE_HEALTH_RESULT

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
  return 0
}

write_release_tree() {
  local dest="$1" ver="$2" channel="${3:-stable}" commit="${4:-$COMMIT_STABLE}" floor="${5:-0.5.1}"
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/lib" "$dest/templates"
  cp -a "$REPO_ROOT/lib/." "$dest/lib/"
  if [ -d "$REPO_ROOT/templates" ]; then
    cp -a "$REPO_ROOT/templates/." "$dest/templates/"
  fi
  cp -a "$REPO_ROOT/bin/ghproxyctl" "$dest/bin/ghproxyctl"
  cp -a "$REPO_ROOT/bin/vgm-bootstrap" "$dest/bin/vgm-bootstrap"
  cp -a "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$dest/"
  printf '%s\n' "$ver" >"$dest/VERSION"
  cat >"$dest/release.meta" <<EOF
version=$ver
commit=$commit
upgrade_from_min=$floor
config_migration=0
service_reload=0
channel=$channel
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
  local mode="${1:-fresh}"
  mkdir -p "$(gp_state_dir)" "$(gp_squid_conf_dir)/tls"
  printf 'server\n' >"$(gp_role_file)"
  cat >"$(gp_server_conf)" <<EOF
mode=$mode
domain=gh.example.test
tls_port=8443
loopback_port=3128
tls_cert_dir=$(gp_squid_conf_dir)/tls
EOF
  printf 'NOT-A-REAL-KEY\n' >"$(gp_squid_conf_dir)/tls/privkey.pem"
  printf 'acl-marker\n' >"$(gp_managed_clients_acl)"
  printf 'inventory-marker\n' >"$(gp_clients_db)"
}

seed_client() {
  mkdir -p "$(gp_state_dir)" "$(gp_systemd_dir)"
  rm -f "$(gp_server_conf)"
  printf 'client\n' >"$(gp_role_file)"
  cat >"$(gp_client_conf)" <<EOF
upstream=https://gh.example.test:8443
upstream_family=auto
upstream_selected_family=4
upstream_peer_address=203.0.113.10
local_port=3129
service_name=vps-gateway-manager-client.service
config_file=$(gp_p /etc/vps-gateway-manager/client-squid.conf)
EOF
  printf 'client-squid-marker\n' >"$(gp_p /etc/vps-gateway-manager/client-squid.conf)"
  printf 'unit-marker\n' >"$(gp_systemd_dir)/vps-gateway-manager-client.service"
  mkdir -p "$(gp_state_dir)/migrations"
  printf 'migration-marker\n' >"$(gp_state_dir)/migrations/komari.env"
  printf 'env-marker\n' >"$(gp_p /etc/environment)"
}

reset_host() {
  gp_mutation_lock_release || true
  GP_MUTATION_LOCK_HELD=0
  GP_DRY_RUN=0
  GP_ASSUME_YES=1
  export GP_DRY_RUN GP_ASSUME_YES
  unset VGM_UPDATE_FAIL_AT VGM_UPDATE_CRASH_AT VGM_UPDATE_POST_HEALTH_RESULT || true
  rm -rf "$(gp_libexec_dir)" "$(gp_state_dir)" "$(gp_p /var/log/vps-gateway-manager)" \
    "$(gp_p /usr/local/lib)" "$(gp_lock_file).d"
  mkdir -p "$(gp_bin_dir)" "$(gp_state_dir)"
  rm -f "$(gp_bin_dir)/ghproxyctl"
}

installed_version() {
  update_exec_installed_version 2>/dev/null || printf '%s\n' missing
}

# -----------------------------------------------------------------------------
t_begin "version comparison"
assert_eq "-1" "$(update_version_cmp 0.5.1 0.6.0)" "0.5.1 is older than 0.6.0"
assert_eq "0" "$(update_version_cmp 0.6.0 0.6.0)" "equal versions compare equal"
assert_eq "1" "$(update_version_cmp 0.6.0 0.5.1)" "0.6.0 is newer than 0.5.1"
assert_eq "0" "$(update_version_cmp v0.5.1 0.5.1)" "a leading v is ignored"
rc=0
update_version_cmp 0.6.0-rc1 0.6.0 >/dev/null || rc=$?
assert_eq "2" "$rc" "a prerelease is not a comparable release version"
assert_ok "0.5.1 is a release version" update_version_is_release 0.5.1
assert_rc_fails "a raw SHA is not a release version" update_version_is_release abcdef
assert_rc_fails "an empty version is not a release" update_version_is_release ""

# -----------------------------------------------------------------------------
t_begin "role detection"
reset_host
rm -rf "$(gp_state_dir)"
assert_eq "UNINSTALLED" "$(gp_detect_state)" "a clean sandbox is uninstalled"
assert_rc_fails "uninstalled does not allow mutation" gp_detect_allows_mutation UNINSTALLED

seed_server fresh
install_tree "$SANDBOX/unused" 2>/dev/null || true
OLD="$SANDBOX/rel-051"
NEW="$SANDBOX/rel-060"
write_release_tree "$OLD" 0.5.1
install_tree "$OLD"
seed_server fresh
assert_eq "SERVER_FRESH" "$(gp_detect_state)" "fresh server with a toolchain"
seed_server adopted
assert_eq "SERVER_ADOPTED" "$(gp_detect_state)" "adopted server with a toolchain"
seed_client
assert_eq "CLIENT" "$(gp_detect_state)" "client with a toolchain"

reset_host
install_tree "$OLD"
printf 'server\n' >"$(gp_role_file)"
printf 'upstream=https://gh.example.test:8443\n' >"$(gp_client_conf)"
assert_eq "CONFLICT" "$(gp_detect_state)" "role=server plus only client.conf is a conflict"
assert_rc_fails "conflict blocks mutation" gp_detect_allows_mutation CONFLICT

reset_host
install_tree "$OLD"
printf 'client\n' >"$(gp_role_file)"
printf 'mode=fresh\n' >"$(gp_server_conf)"
assert_eq "CONFLICT" "$(gp_detect_state)" "role=client plus only server.conf is a conflict"

reset_host
install_tree "$OLD"
printf 'mode=fresh\n' >"$(gp_server_conf)"
printf 'upstream=x\n' >"$(gp_client_conf)"
printf 'server\n' >"$(gp_role_file)"
assert_eq "CONFLICT" "$(gp_detect_state)" "both configs are a conflict"

reset_host
install_tree "$OLD"
assert_eq "BROKEN" "$(gp_detect_state)" "toolchain without a role is broken"
reset_host
seed_server fresh
rm -rf "$(gp_libexec_dir)" "$(gp_bin_dir)/ghproxyctl"
assert_eq "BROKEN" "$(gp_detect_state)" "state without a toolchain is broken"
reset_host
printf 'nope\n' >"$(gp_role_file)"
assert_eq "BROKEN" "$(gp_detect_state)" "a corrupt role is broken"
assert_rc_fails "broken blocks mutation" gp_detect_allows_mutation BROKEN

# -----------------------------------------------------------------------------
t_begin "release discovery"
printf 'releases/latest\thttps://github.com/xinian5216/vps-gateway-manager/releases/tag/v0.6.0\n' >"$STUB_STATE/curl/redirects"
printf 'releases/latest\t200\n' >>"$STUB_STATE/curl/rules"
assert_eq "v0.6.0" "$(update_discover_latest)" "latest redirect yields the stable tag"

printf 'releases/latest\thttps://github.com/xinian5216/vps-gateway-manager/releases/tag/v0.6.0-rc1\n' >"$STUB_STATE/curl/redirects"
rc=0
out="$(update_discover_latest 2>&1)" || rc=$?
assert_ne "0" "$rc" "a prerelease redirect is rejected"
assert_contains "$out" "not a stable release" "prerelease rejection names the reason"
assert_contains "$out" "Nothing was changed" "a rejected discovery changes nothing"

printf 'releases/latest\thttps://github.com/xinian5216/vps-gateway-manager/releases/latest\n' >"$STUB_STATE/curl/redirects"
rc=0
out="$(update_discover_latest 2>&1)" || rc=$?
assert_ne "0" "$rc" "a redirect that is not a tag URL is rejected"
assert_contains "$out" "not a tag URL" "empty/non-tag redirect is explained"

touch "$STUB_STATE/curl/fail"
rc=0
out="$(update_discover_latest 2>&1)" || rc=$?
assert_ne "0" "$rc" "a network failure is not a successful discovery"
assert_contains "$out" "Refusing to fall back to main" "network failure does not fall back to main"
rm -f "$STUB_STATE/curl/fail"
printf 'releases/latest\thttps://github.com/xinian5216/vps-gateway-manager/releases/tag/v0.6.0\n' >"$STUB_STATE/curl/redirects"

# -----------------------------------------------------------------------------
t_begin "0.5.1 to 0.6.0 server update"
reset_host
write_release_tree "$OLD" 0.5.1
write_release_tree "$NEW" 0.6.0
install_tree "$OLD"
seed_server adopted
marker="$(cat "$(gp_server_conf)")"
key="$(cat "$(gp_squid_conf_dir)/tls/privkey.pem")"
acl="$(cat "$(gp_managed_clients_acl)")"
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
assert_eq "0" "$rc" "server update exits 0"
assert_contains "$out" "SUCCESS" "server update reports success"
assert_not_contains "$out" "SUCCESSFUL WITH WARNINGS" "a clean pass is not labelled warnings-only"
assert_eq "0.6.0" "$(installed_version)" "executed ghproxyctl reports 0.6.0"
assert_eq "0.6.0" "$(head -n 1 "$(gp_libexec_dir)/VERSION" | tr -d '[:space:]')" "VERSION file is 0.6.0"
assert_eq "0.6.0" "$(conf_get "$(gp_libexec_dir)/release.meta" version '')" "release.meta version is 0.6.0"
assert_file_exists "$(gp_libexec_dir)/bin/vgm-bootstrap" "vgm-bootstrap is staged with the toolchain"
assert_eq "$marker" "$(cat "$(gp_server_conf)")" "server.conf was not rewritten"
assert_eq "$key" "$(cat "$(gp_squid_conf_dir)/tls/privkey.pem")" "TLS private key was not rewritten"
assert_eq "$acl" "$(cat "$(gp_managed_clients_acl)")" "managed ACL was not rewritten"
assert_file_exists "$(update_history_file)" "update history was recorded"
assert_contains "$(cat "$(update_history_file)")" "SUCCESS" "history says SUCCESS, not a guessed filename"
assert_not_contains "$(cat "$(update_history_file)")" $'\tFAIL' "history does not invent a failure"
# The old silent-success path must not be how this succeeded.
assert_not_contains "$out" "skipping toolchain install" "success is not the v0.5.1 silent skip"

# -----------------------------------------------------------------------------
t_begin "already up to date does not overwrite"
before="$(gp_sha256 "$(gp_libexec_dir)/lib/common.sh")"
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
if [ "$rc" != "0" ]; then printf 'SAME-VERSION OUTPUT:\n%s\n' "$out" >&2; fi
assert_eq "0" "$rc" "same version exits 0"
assert_contains "$out" "Already up to date." "same version says already up to date"
assert_eq "$before" "$(gp_sha256 "$(gp_libexec_dir)/lib/common.sh")" "same version does not replace files"

# -----------------------------------------------------------------------------
t_begin "downgrade is refused without the explicit flag"
rc=0
out="$(update_run --source "$OLD" 2>&1)" || rc=$?
if ! printf '%s\n' "$out" | grep -q 'refusing to downgrade'; then printf 'DOWNGRADE OUTPUT:\n%s\n' "$out" >&2; fi
assert_ne "0" "$rc" "a downgrade is not a normal update"
assert_contains "$out" "refusing to downgrade" "downgrade refusal is explicit"
assert_eq "0.6.0" "$(installed_version)" "refused downgrade leaves 0.6.0 installed"
if [ "${VGM_TEST_STOP:-}" = "downgrade" ]; then
  sandbox_teardown
  t_summary
  exit 0
fi

# -----------------------------------------------------------------------------
t_begin "older than the upgrade floor is refused"
reset_host
write_release_tree "$SANDBOX/rel-050" 0.5.0 stable "$COMMIT_STABLE" 0.5.0
install_tree "$SANDBOX/rel-050"
seed_server fresh
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
assert_ne "0" "$rc" "0.5.0 is not a validated upgrade source"
assert_contains "$out" "Upgrade to v0.5.1 first." "the operator is told to reach 0.5.1 first"
assert_eq "0.5.0" "$(head -n 1 "$(gp_libexec_dir)/VERSION" | tr -d '[:space:]')" "refused floor check leaves the old VERSION"

# -----------------------------------------------------------------------------
t_begin "client update leaves runtime files alone"
reset_host
install_tree "$OLD"
seed_client
conf="$(cat "$(gp_client_conf)")"
squidc="$(cat "$(gp_p /etc/vps-gateway-manager/client-squid.conf)")"
unit="$(cat "$(gp_systemd_dir)/vps-gateway-manager-client.service")"
mig="$(cat "$(gp_state_dir)/migrations/komari.env")"
envf="$(cat "$(gp_p /etc/environment)")"
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
assert_eq "0" "$rc" "client update exits 0"
assert_eq "0.6.0" "$(installed_version)" "client toolchain reports 0.6.0"
assert_eq "$conf" "$(cat "$(gp_client_conf)")" "client.conf unchanged"
assert_eq "$squidc" "$(cat "$(gp_p /etc/vps-gateway-manager/client-squid.conf)")" "client squid config unchanged"
assert_eq "$unit" "$(cat "$(gp_systemd_dir)/vps-gateway-manager-client.service")" "client unit unchanged"
assert_eq "$mig" "$(cat "$(gp_state_dir)/migrations/komari.env")" "migrations unchanged"
assert_eq "$envf" "$(cat "$(gp_p /etc/environment)")" "environment file unchanged"
assert_contains "$out" "Will NOT modify:" "the plan names protected client files"

# -----------------------------------------------------------------------------
t_begin "verification failures change nothing"
reset_host
install_tree "$OLD"
seed_server fresh
bad="$SANDBOX/rel-bad"
write_release_tree "$bad" 0.6.0
printf 'version=0.6.1\n' >>"$bad/release.meta"
# checksums no longer match, and versions disagree
rc=0
out="$(update_run --source "$bad" 2>&1)" || rc=$?
assert_ne "0" "$rc" "a mismatched manifest is rejected"
assert_eq "0.5.1" "$(installed_version)" "rejected manifest leaves 0.5.1"
assert_contains "$out" "Nothing was changed" "the failure says nothing was changed"

# -----------------------------------------------------------------------------
t_begin "injected failures restore or refuse"
fail_at() {
  local point="$1" expect_ver="$2"
  reset_host
  install_tree "$OLD"
  seed_server fresh
  VGM_UPDATE_FAIL_AT="$point"
  export VGM_UPDATE_FAIL_AT
  rc=0
  out="$(update_run --source "$NEW" 2>&1)" || rc=$?
  unset VGM_UPDATE_FAIL_AT
  assert_ne "0" "$rc" "injected $point fails"
  assert_eq "$expect_ver" "$(installed_version)" "injected $point leaves version $expect_ver"
  assert_not_contains "$out" $'\nSUCCESS\n' "injected $point does not report SUCCESS"
}

fail_at checksum 0.5.1
fail_at unpack 0.5.1
fail_at missing-lib 0.5.1
fail_at missing-cli 0.5.1
fail_at staging 0.5.1
fail_at backup 0.5.1
fail_at disk-full 0.5.1
fail_at switch-lib 0.5.1
fail_at switch-cli 0.5.1
fail_at version-check 0.5.1
fail_at post-health 0.5.1

# download failure is the network path, not --source. Prove the phase text.
reset_host
install_tree "$OLD"
seed_server fresh
VGM_UPDATE_FAIL_AT=download
export VGM_UPDATE_FAIL_AT
touch "$STUB_STATE/curl/fail"
rc=0
out="$(update_run --version v0.6.0 2>&1)" || rc=$?
unset VGM_UPDATE_FAIL_AT
rm -f "$STUB_STATE/curl/fail"
assert_ne "0" "$rc" "download failure is not success"
assert_eq "0.5.1" "$(installed_version)" "download failure leaves 0.5.1"
assert_contains "$out" "FAIL [FETCH]" "download failure names the phase"

# -----------------------------------------------------------------------------
t_begin "post-health FAIL rolls the toolchain back"
reset_host
install_tree "$OLD"
seed_server fresh
VGM_UPDATE_POST_HEALTH_RESULT=fail
export VGM_UPDATE_POST_HEALTH_RESULT
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
unset VGM_UPDATE_POST_HEALTH_RESULT
assert_ne "0" "$rc" "a new health FAIL fails the update"
assert_contains "$out" "Previous management toolchain restored successfully." "health FAIL restores the previous toolchain"
assert_eq "0.5.1" "$(installed_version)" "health FAIL leaves the executed version at 0.5.1"
assert_contains "$(cat "$(update_history_file)" 2>/dev/null || true)" "ROLLED_BACK" "history records the rollback"

# -----------------------------------------------------------------------------
t_begin "WARN does not roll back"
reset_host
install_tree "$OLD"
seed_server fresh
VGM_UPDATE_POST_HEALTH_RESULT=warn
export VGM_UPDATE_POST_HEALTH_RESULT
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
unset VGM_UPDATE_POST_HEALTH_RESULT
assert_eq "0" "$rc" "warnings do not fail the update"
assert_contains "$out" "UPDATE SUCCESSFUL WITH WARNINGS" "warnings are visible in the result"
assert_not_contains "$out" "All good" "warnings are not hidden behind an all-clear"
assert_eq "0.6.0" "$(installed_version)" "warnings leave the new version in place"

# -----------------------------------------------------------------------------
t_begin "pre-existing health FAIL blocks unless explicitly allowed"
reset_host
install_tree "$OLD"
seed_server fresh
VGM_UPDATE_HEALTH_RESULT=fail
export VGM_UPDATE_HEALTH_RESULT
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
assert_ne "0" "$rc" "an already-unhealthy host is not updated by --yes alone"
assert_contains "$out" "already has health failures" "the existing failure is named"
assert_eq "0.5.1" "$(installed_version)" "blocked unhealthy update leaves 0.5.1"
# The pre-update injection must not also be treated as a new post-update FAIL.
VGM_UPDATE_POST_HEALTH_RESULT=pass
export VGM_UPDATE_POST_HEALTH_RESULT
rc=0
out="$(update_run --source "$NEW" --allow-unhealthy 2>&1)" || rc=$?
unset VGM_UPDATE_POST_HEALTH_RESULT
assert_eq "0" "$rc" "--allow-unhealthy is the explicit bypass"
assert_eq "0.6.0" "$(installed_version)" "explicit bypass does update"
VGM_UPDATE_HEALTH_RESULT=pass
export VGM_UPDATE_HEALTH_RESULT

# -----------------------------------------------------------------------------
t_begin "crash recovery restores the known-good toolchain"
crash_at() {
  local point="$1"
  reset_host
  install_tree "$OLD"
  seed_server adopted
  VGM_UPDATE_CRASH_AT="$point"
  export VGM_UPDATE_CRASH_AT
  rc=0
  (update_run --source "$NEW" >/dev/null 2>&1) || rc=$?
  unset VGM_UPDATE_CRASH_AT
  assert_eq "99" "$rc" "crash at $point exits 99"
  assert_ok "crash at $point leaves an interrupted marker" update_interrupted
  rc=0
  out="$(update_recover 2>&1)" || rc=$?
  assert_eq "0" "$rc" "recover after $point succeeds"
  assert_eq "0.5.1" "$(installed_version)" "recover after $point returns 0.5.1"
  assert_rc_fails "recover after $point clears the interrupted marker" update_interrupted
}
crash_at after-backup
crash_at after-staging
crash_at after-old-tree-moved
crash_at after-new-tree-switched
crash_at before-cli-switch
crash_at after-cli-switch
crash_at before-commit

# -----------------------------------------------------------------------------
t_begin "dry-run does not mutate persistent state"
reset_host
install_tree "$OLD"
seed_server fresh
snap="$(mktemp)"
# Persistent project trees only. Stub logs under .stub are not product state.
(cd "$SANDBOX" && find etc usr var -type f 2>/dev/null | sort | while IFS= read -r f; do
  printf '%s %s\n' "$(gp_sha256 "$SANDBOX/$f" 2>/dev/null || printf missing)" "$f"
done) >"$snap"
GP_DRY_RUN=1
export GP_DRY_RUN
rc=0
out="$(update_run --source "$NEW" 2>&1)" || rc=$?
GP_DRY_RUN=0
export GP_DRY_RUN
assert_eq "0" "$rc" "dry-run exits 0"
assert_contains "$out" "dry-run: no files were changed" "dry-run says it changed nothing"
after="$(mktemp)"
(cd "$SANDBOX" && find etc usr var -type f 2>/dev/null | sort | while IFS= read -r f; do
  printf '%s %s\n' "$(gp_sha256 "$SANDBOX/$f" 2>/dev/null || printf missing)" "$f"
done) >"$after"
assert_eq "$(cat "$snap")" "$(cat "$after")" "dry-run leaves etc/usr/var byte-identical"
assert_file_absent "$(update_history_file)" "dry-run writes no update history"
rm -f "$snap" "$after"

# -----------------------------------------------------------------------------
t_begin "development channel is not treated as stable"
reset_host
install_tree "$OLD"
seed_server fresh
dev="$SANDBOX/rel-dev"
write_release_tree "$dev" 0.6.0 development unreleased
rc=0
out="$(update_run --source "$dev" 2>&1)" || rc=$?
assert_ne "0" "$rc" "a development tree is refused by default"
assert_contains "$out" "development / non-release build" "the refusal names the channel"
assert_eq "0.5.1" "$(installed_version)" "refused development tree leaves 0.5.1"
rc=0
out="$(update_run --source "$dev" --allow-development 2>&1)" || rc=$?
assert_eq "0" "$rc" "--allow-development permits the explicit local tree"
assert_contains "$out" "development / non-release build" "an allowed development build is still labelled"
assert_eq "0.6.0" "$(installed_version)" "explicit development install reports 0.6.0"

# -----------------------------------------------------------------------------
t_begin "mutation lock"
reset_host
install_tree "$OLD"
seed_server fresh
GP_LOCK_BACKEND="mkdir"
export GP_LOCK_BACKEND
(
  gp_mutation_lock_acquire || exit 2
  sleep 30
) &
holder=$!
sleep 0.4
rc=0
gp_mutation_lock_acquire 2>"$SANDBOX/lock.err" || rc=$?
assert_ne "0" "$rc" "a second mutation is refused while the lock is held"
assert_contains "$(cat "$SANDBOX/lock.err")" "Another vps-gateway-manager mutation is running." "the lock error is explicit"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
GP_MUTATION_LOCK_HELD=0
rc=0
gp_mutation_lock_acquire || rc=$?
assert_eq "0" "$rc" "a dead holder is reclaimed"
gp_mutation_lock_release || true
unset GP_LOCK_BACKEND

# -----------------------------------------------------------------------------
t_begin "local archive source"
reset_host
install_tree "$OLD"
seed_server fresh
# A hand-packed fixture tarball keeps its checksum under test control.
mkdir -p "$SANDBOX/dist"
tar -czf "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" -C "$SANDBOX" "$(basename "$NEW")"
if have sha256sum; then
  hash="$(sha256sum "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" | awk '{print $1}')"
else
  hash="$(shasum -a 256 "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" | awk '{print $1}')"
fi
printf '%s  %s\n' "$hash" "vps-gateway-manager-v0.6.0.tar.gz" >"$SANDBOX/dist/SHA256SUMS"
rc=0
out="$(update_run --source "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" 2>&1)" || rc=$?
assert_eq "0" "$rc" "a checksummed local archive updates"
assert_eq "0.6.0" "$(installed_version)" "archive update reports 0.6.0"
# Wrong checksum must not succeed.
printf '0000000000000000000000000000000000000000000000000000000000000000  vps-gateway-manager-v0.6.0.tar.gz\n' >"$SANDBOX/dist/SHA256SUMS"
reset_host
install_tree "$OLD"
seed_server fresh
rc=0
out="$(update_run --source "$SANDBOX/dist/vps-gateway-manager-v0.6.0.tar.gz" 2>&1)" || rc=$?
assert_ne "0" "$rc" "a bad archive checksum is rejected"
assert_eq "0.5.1" "$(installed_version)" "bad checksum leaves 0.5.1"
assert_contains "$out" "checksum mismatch" "bad checksum names the failure"

# -----------------------------------------------------------------------------
t_begin "manual rollback"
reset_host
install_tree "$OLD"
seed_server fresh
update_run --source "$NEW" >/dev/null 2>&1 || true
assert_eq "0.6.0" "$(installed_version)" "rollback setup reached 0.6.0"
rc=0
out="$(update_rollback --to 0.5.1 2>&1)" || rc=$?
assert_eq "0" "$rc" "rollback to the known-good backup succeeds"
assert_eq "0.5.1" "$(installed_version)" "rollback executes the previous version"
marker="$(cat "$(gp_server_conf)")"
assert_contains "$marker" "mode=fresh" "rollback does not rewrite server.conf"

sandbox_teardown
t_summary
