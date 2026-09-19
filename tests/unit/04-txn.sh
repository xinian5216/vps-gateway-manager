#!/usr/bin/env bash
# =============================================================================
# unit test :: transaction engine (backup, atomic write, rollback)
#
# The production promise is "every change is reversible". These tests are the
# evidence for that promise.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

TARGET="$GP_ROOT/etc/squid/conf.d/github-whitelist.conf"
mkdir -p "$(dirname "$TARGET")"
printf 'acl old src 198.51.100.1/32\nhttp_access allow old\n' > "$TARGET"
ORIGINAL="$(cat "$TARGET")"

# -----------------------------------------------------------------------------
t_begin "install + rollback restores the previous content exactly"
txn_begin "test-rollback"
if txn_is_active; then t_ok "transaction is active"; else t_fail "transaction should be active"; fi
txn_install_file <(printf 'replaced content\n') "$TARGET" 0644
assert_eq "replaced content" "$(cat "$TARGET")" "file replaced"
txn_rollback "test"
assert_eq "$ORIGINAL" "$(cat "$TARGET")" "original content restored"
if txn_is_active; then t_fail "transaction still open"; else t_ok "transaction closed after rollback"; fi

t_begin "rollback removes files that did not exist before"
NEW="$GP_ROOT/etc/squid/conf.d/00-vps-gateway-manager-clients.conf"
txn_begin "test-newfile"
txn_install_file <(printf 'acl gsp_c_a src 203.0.113.1/32\n') "$NEW" 0644
assert_file_exists "$NEW" "new file created"
txn_rollback "test"
assert_file_absent "$NEW" "new file removed on rollback"

t_begin "new directories are removed again"
NEWDIR="$GP_ROOT/etc/empty-created-dir"
txn_begin "test-newdir"
txn_mkdir "$NEWDIR" 0700
assert_ok "directory created" test -d "$NEWDIR"
txn_rollback "test"
assert_file_absent "$NEWDIR" "empty directory removed on rollback"

t_begin "commit keeps the change and archives the journal"
txn_begin "test-commit"
txn_backup_file "$TARGET"
txn_install_file <(printf 'kept content\n') "$TARGET" 0644
txn_commit success
assert_eq "kept content" "$(cat "$TARGET")" "change kept after commit"
assert_file_absent "$(gp_state_dir)/state/journal.current" "current journal cleared"
JOURNAL="$(find "$(gp_backup_dir)" -name 'journal.tsv' -type f 2>/dev/null | head -n1)"
assert_file_exists "$JOURNAL" "journal archived for audit"

t_begin "backups are kept, pruned by count"
txn_prune_backups 20
assert_ok "backup root still exists" test -d "$(gp_backup_dir)"

# -----------------------------------------------------------------------------
t_begin "dry-run never writes"
rm -rf "$(gp_state_dir)"
DRYS="$GP_ROOT/etc/dryrun-target.conf"
GP_DRY_RUN=1
txn_begin "dry"
txn_install_file <(printf 'should not appear\n') "$DRYS" 0644
txn_backup_file "$DRYS"
assert_file_absent "$DRYS" "dry-run install wrote nothing"
txn_rollback "dry-run"
GP_DRY_RUN=0
if txn_is_active; then t_fail "transaction still open after rollback"; else t_ok "transaction closed after a dry-run rollback"; fi

t_begin "rollback of a firewall rule and a service action"
fw_detect
FW_ACTIVE=1
FW_TYPE=ufw
txn_begin "test-fw"
spec="$(fw_rule_spec '203.0.113.55/32' 8443)"
txn_ufw_add "$spec"
txn_service squid reload
fw_add_rule "$spec" "gsp:test"
assert_contains "$(stub_ufw_rules)" '203.0.113.55/32' "firewall rule added through the stub"
txn_rollback "test"
assert_not_contains "$(stub_ufw_rules)" '203.0.113.55/32' "firewall rule removed by rollback"

sandbox_teardown
t_summary
