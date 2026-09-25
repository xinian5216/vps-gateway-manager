#!/usr/bin/env bash
# =============================================================================
# unit test :: interactive manager. Stdin is piped; nothing here waits for a human.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

GP_INTERACTIVE=yes
GP_ASSUME_YES=0
GP_DRY_RUN=0
export GP_INTERACTIVE GP_ASSUME_YES GP_DRY_RUN

run_menu() {
  wizard_main 2>&1
}

# -----------------------------------------------------------------------------
t_begin "uninstalled menu"
rm -rf "$(gp_state_dir)" "$(gp_libexec_dir)" "$(gp_bin_dir)/ghproxyctl"
out="$(printf '0\n' | run_menu)" || true
assert_contains "$out" "Choose a role" "a clean host is asked to choose a role"
assert_contains "$out" "Gateway Server" "server is one of the choices"
assert_contains "$out" "Client" "client is one of the choices"
assert_file_absent "$(gp_role_file)" "choosing exit does not create a role"

out="$(printf '9\n' | run_menu)" || true
assert_contains "$out" "invalid selection" "an invalid number is rejected"
assert_file_absent "$(gp_role_file)" "an invalid number does not install"

out="$(printf '\n' | run_menu)" || true
assert_contains "$out" "blank selection" "a blank line is not treated as a choice"

out="$(printf 'q\n' | run_menu)" || true
assert_file_absent "$(gp_role_file)" "q exits without installing"

rc=0
printf '' | run_menu >/dev/null || rc=$?
assert_eq "0" "$rc" "EOF exits instead of waiting"

# -----------------------------------------------------------------------------
t_begin "installed server is not asked to pick a role"
mkdir -p "$(gp_libexec_dir)/lib" "$(gp_bin_dir)" "$(gp_state_dir)"
printf 'server\n' >"$(gp_role_file)"
printf 'mode=adopted\ndomain=gh.example.test\ntls_port=8443\n' >"$(gp_server_conf)"
printf '0.5.1\n' >"$(gp_libexec_dir)/VERSION"
printf 'stub\n' >"$(gp_libexec_dir)/lib/common.sh"
printf '#!/bin/sh\n' >"$(gp_bin_dir)/ghproxyctl"
chmod 0755 "$(gp_bin_dir)/ghproxyctl" || true
out="$(printf '0\n' | run_menu)" || true
assert_contains "$out" "Server" "the menu names the detected role"
assert_contains "$out" "adopted" "adopted mode is shown"
assert_not_contains "$out" "Choose a role" "an installed server is not asked to become a client"
assert_not_contains "$out" "Gateway Server" "the fresh-install role menu is not shown"
assert_eq "server" "$(gp_role)" "the menu did not rewrite the role"

out="$(printf '9\n0\n' | run_menu)" || true
assert_contains "$out" "invalid selection" "an installed menu rejects a bad number"
assert_eq "server" "$(gp_role)" "a bad number does not change the role"

# -----------------------------------------------------------------------------
t_begin "installed client is not offered a server install"
rm -f "$(gp_server_conf)"
printf 'client\n' >"$(gp_role_file)"
printf 'upstream=https://gh.example.test:8443\nlocal_port=3129\n' >"$(gp_client_conf)"
out="$(printf '0\n' | run_menu)" || true
assert_contains "$out" "Client" "the menu names the client role"
assert_not_contains "$out" "Choose a role" "an installed client is not asked to pick a role"
assert_eq "client" "$(gp_role)" "the client role is unchanged"

# -----------------------------------------------------------------------------
t_begin "broken state refuses install"
rm -f "$(gp_role_file)"
out="$(printf '1\n' | run_menu)" || true
assert_contains "$out" "BROKEN" "missing role with leftover state is broken"
assert_contains "$out" "disabled" "install is disabled for a broken host"
assert_file_absent "$(gp_role_file)" "the broken menu did not invent a role"

# -----------------------------------------------------------------------------
t_begin "existing squid config is not overwritten"
rm -rf "$(gp_state_dir)" "$(gp_libexec_dir)" "$(gp_bin_dir)/ghproxyctl"
mkdir -p "$(gp_squid_conf_dir)"
printf 'foreign-squid-conf\n' >"$(gp_squid_conf_dir)/squid.conf"
out="$(printf '1\n0\n' | run_menu)" || true
assert_contains "$out" "existing Squid" "a foreign squid.conf is reported"
assert_contains "$out" "will not overwrite" "fresh install is not the offered path"
assert_eq "foreign-squid-conf" "$(cat "$(gp_squid_conf_dir)/squid.conf")" "the foreign config is unchanged"
assert_file_absent "$(gp_role_file)" "viewing the warning does not install a role"

# -----------------------------------------------------------------------------
t_begin "confirmation defaults to no"
rc=0
printf '\n' | wizard_confirm_no "Migrate Komari?" >/dev/null || rc=$?
assert_ne "0" "$rc" "an empty answer does not migrate"
rc=0
printf 'n\n' | wizard_confirm_no "Migrate xray-manager?" >/dev/null || rc=$?
assert_ne "0" "$rc" "n does not migrate"
rc=0
printf 'y\n' | wizard_confirm_no "Configure git?" >/dev/null || rc=$?
assert_eq "0" "$rc" "only an explicit yes proceeds"

# -----------------------------------------------------------------------------
t_begin "interrupt handler does not install"
rm -rf "$(gp_state_dir)"
rc=0
(wizard_on_interrupt) || rc=$?
assert_eq "130" "$rc" "Ctrl+C exits 130"
assert_file_absent "$(gp_role_file)" "Ctrl+C does not create a role"

# -----------------------------------------------------------------------------
t_begin "non-TTY install.sh --interactive fails closed"
rc=0
out="$(GP_INTERACTIVE=no bash "$REPO_ROOT/install.sh" --interactive </dev/null 2>&1)" || rc=$?
assert_ne "0" "$rc" "non-TTY --interactive is a failure"
assert_contains "$out" "not a terminal" "the failure tells the operator to use the CLI"

sandbox_teardown
t_summary
