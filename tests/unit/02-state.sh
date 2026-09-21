#!/usr/bin/env bash
# =============================================================================
# unit test :: state files, client database, destination list, managed files
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

# -----------------------------------------------------------------------------
t_begin "key=value state files"
CONF="$(state_file server.conf)"
conf_set "$CONF" mode fresh 0600
conf_set "$CONF" domain gh.test.invalid
conf_set "$CONF" tls_port 8443
assert_eq "fresh" "$(conf_get "$CONF" mode)" "read back a value"
assert_eq "8443" "$(conf_get "$CONF" tls_port)" "second value stored"
assert_eq "fallback" "$(conf_get "$CONF" missing fallback)" "default returned when absent"
conf_set "$CONF" mode adopted
assert_eq "adopted" "$(conf_get "$CONF" mode)" "value is updated, not duplicated"
assert_eq "1" "$(grep -c '^mode=' "$CONF")" "no duplicate keys after update"
conf_del "$CONF" domain
assert_eq "" "$(conf_get "$CONF" domain '')" "key deleted"
assert_file_mode_linux "$CONF" 600 "state file is root-only"

# -----------------------------------------------------------------------------
t_begin "client database"
clients_db_add cn-bj-01 203.0.113.10/32 ghproxyctl /etc/squid/conf.d/x.conf "note one"
clients_db_add jp-v6-01 2001:db8::10/128 ghproxyctl /etc/squid/conf.d/x.conf ""
assert_eq "2" "$(clients_db_count)" "two clients recorded"
assert_eq "203.0.113.10/32" "$(clients_db_field cn-bj-01 cidr)" "field lookup"
assert_eq "jp-v6-01" "$(clients_db_find_by_cidr '2001:db8::10/128')" "lookup by address"
# A name (or acl_id) belongs to exactly one address: reusing it for a different
# address is refused instead of silently replacing a client.
OUT="$(clients_db_add cn-bj-01 203.0.113.11/32 ghproxyctl /etc/squid/conf.d/x.conf "" 2>&1)"; RC=$?
assert_ne "0" "$RC" "a name reused for another address is refused"
assert_contains "$OUT" 'already belongs to' "the refusal explains why"
assert_eq "2" "$(clients_db_count)" "no duplicate row was created"
assert_eq "203.0.113.10/32" "$(clients_db_field cn-bj-01 cidr)" "the original row is unchanged"
# The same address is the same client: metadata is refreshed in place.
clients_db_add cn-bj-01 203.0.113.10/32 ghproxyctl /etc/squid/conf.d/x.conf "note two"
assert_eq "2" "$(clients_db_count)" "re-adding the same address does not duplicate it"
assert_eq "note two" "$(clients_db_field cn-bj-01 note)" "metadata was refreshed in place"
clients_db_remove cn-bj-01
assert_eq "1" "$(clients_db_count)" "client removed"
assert_eq "" "$(clients_db_get cn-bj-01)" "removed client is gone"

# -----------------------------------------------------------------------------
t_begin "managed file registry"
record_managed_file "$(state_file github-domains.txt)" created
record_managed_file "$(gp_squid_conf_d)/00-vps-gateway-manager-clients.conf" modified
record_managed_file "$(state_file github-domains.txt)" modified
assert_eq "modified" "$(managed_file_state "$(state_file github-domains.txt)")" "state updated, not duplicated"
assert_eq "2" "$(wc -l < "$(gp_managed_files)" | tr -d ' ')" "two managed files recorded"
assert_ok "is_managed_file finds a recorded path" is_managed_file "$(state_file github-domains.txt)"
assert_rc_fails "unknown paths are not managed" is_managed_file /etc/passwd

# -----------------------------------------------------------------------------
t_begin "destination list"
domains_seed_from_template
assert_file_exists "$(gp_domains_file)" "runtime destination list created"
assert_file_contains "$(gp_domains_file)" '^\.github\.com$' "github.com subdomains present"
assert_file_contains "$(gp_domains_file)" '^\.githubusercontent\.com$' "githubusercontent present"
assert_file_contains "$(gp_domains_file)" '^\.githubassets\.com$' "githubassets present"
assert_file_not_contains "$(gp_domains_file)" 'amazonaws' "no shared CDN entries by default"
assert_file_exists "$(gp_domains_doc)" "annotated copy written for humans"
BEFORE="$(cat "$(gp_domains_file)")"
domains_seed_from_template
assert_eq "$BEFORE" "$(cat "$(gp_domains_file)")" "seeding is idempotent"

domains_add_entry '.githubusercontent.com'
assert_eq "3" "$?" "adding an existing entry is a no-op"
domains_add_entry 'release-assets.githubusercontent.com'
assert_file_contains "$(gp_domains_file)" '^release-assets\.githubusercontent\.com$' "new destination appended"
domains_remove_entry 'release-assets.githubusercontent.com'
assert_file_not_contains "$(gp_domains_file)" 'release-assets' "destination removed"
domains_remove_entry 'release-assets.githubusercontent.com'
assert_eq "3" "$?" "removing a missing entry is a no-op"

# -----------------------------------------------------------------------------
t_begin "toolchain installation (sandbox)"
gp_install_toolchain
assert_file_exists "$(gp_p /usr/local/lib/vps-gateway-manager/lib/common.sh)" "libraries installed"
assert_file_exists "$(gp_p /usr/local/sbin/ghproxyctl)" "ghproxyctl installed"

sandbox_teardown
t_summary
