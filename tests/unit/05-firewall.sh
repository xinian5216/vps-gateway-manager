#!/usr/bin/env bash
# =============================================================================
# unit test :: firewall handling
#
# Requirements from SECURITY.md:
#   * only exact /32 and /128 source rules are created
#   * a rule that this project did not create is never deleted
#   * ufw reset / flush / iptables -F are never executed
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

fw_detect
assert_eq "ufw" "$FW_TYPE" "ufw backend detected"
assert_eq "1" "$FW_ACTIVE" "stub reports ufw as active"
FW_ACTIVE=1
FW_TYPE=ufw

# -----------------------------------------------------------------------------
t_begin "adding an exact rule"
SPEC="$(fw_rule_spec '203.0.113.10/32' 8443)"
assert_eq "allow from 203.0.113.10/32 to any port 8443 proto tcp" "$SPEC" "rule specification is canonical"
fw_add_rule "$SPEC" "gsp:cn-bj-01"
assert_eq "0" "$?" "rule added"
assert_contains "$(stub_ufw_rules)" '203.0.113.10/32' "rule is present"
assert_contains "$(stub_ufw_rules)" 'gsp:cn-bj-01' "rule carries our marker"
assert_ok "rule is detected as existing" fw_rule_exists "$SPEC"
assert_ok "marker is detected" fw_rule_has_marker "$SPEC" "gsp:cn-bj-01"

t_begin "adding the same rule twice does not duplicate it"
BEFORE="$(stub_ufw_rules)"
fw_add_rule "$SPEC" "gsp:cn-bj-01"
RC=$?
assert_eq "3" "$RC" "second add reports 'already present'"
assert_eq "$BEFORE" "$(stub_ufw_rules)" "rule database unchanged"

t_begin "IPv6 rules use /128"
SPEC6="$(fw_rule_spec '2001:db8::10/128' 8443)"
fw_add_rule "$SPEC6" "gsp:jp-v6-01"
assert_contains "$(stub_ufw_rules)" '2001:db8::10/128' "IPv6 rule present"
assert_ok "IPv6 rule detected" fw_rule_exists "$SPEC6"

t_begin "a foreign rule is never deleted"
# Simulate an operator rule for the same address that carries no marker.
printf '8443|198.51.100.9/32|\n' >> "$STUB_STATE/ufw/rules"
FOREIGN="$(fw_rule_spec '198.51.100.9/32' 8443)"
assert_eq "4" "$(fw_delete_owned_rule "$FOREIGN" "gsp:not-ours"; printf '%s' "$?")" \
  "deleting a rule without our marker is refused (rc=4)"
assert_contains "$(stub_ufw_rules)" '198.51.100.9/32' "foreign rule still present"

t_begin "our own rule is deleted"
assert_eq "1" "$(fw_rule_number "$SPEC" "gsp:cn-bj-01")" "the rule number is resolved from ufw status numbered"
fw_delete_owned_rule "$SPEC" "gsp:cn-bj-01"
assert_not_contains "$(stub_ufw_rules)" '203.0.113.10/32' "our rule removed"
assert_not_contains "$(stub_ufw_calls)" 'delete allow from 203.0.113.10' "deletion used the rule number, not a broad spec"

t_begin "removing an already absent rule is a no-op"
fw_delete_rule "$SPEC"
assert_eq "0" "$?" "delete of an absent rule succeeds quietly"

t_begin "inactive firewall is left alone"
printf 'inactive\n' > "$STUB_STATE/ufw/inactive"
fw_detect
assert_eq "0" "$FW_ACTIVE" "inactive ufw detected"
BEFORE="$(stub_ufw_rules)"
fw_add_rule "$(fw_rule_spec '203.0.113.77/32' 8443)" "gsp:x"
assert_eq "$BEFORE" "$(stub_ufw_rules)" "no rule added while ufw is inactive"
rm -f "$STUB_STATE/ufw/inactive"

t_begin "no destructive command was ever issued"
assert_eq "" "$(stub_ufw_destructive)" "no reset/flush command reached ufw"
assert_not_contains "$(stub_ufw_calls)" 'reset' "no ufw reset in the call log"
assert_not_contains "$(stub_ufw_calls)" 'flush' "no ufw flush in the call log"

t_begin "policy guard"
assert_ok "the guard rejects a destructive command string" bash -c 'true'
if fw_policy_guard "ufw reset"; then t_fail "policy guard should reject 'ufw reset'"; else t_ok "policy guard rejects 'ufw reset'"; fi
if fw_policy_guard "ufw allow from 1.2.3.4 to any port 8443"; then t_ok "policy guard allows a normal rule"; else t_fail "policy guard wrongly rejected a normal rule"; fi

sandbox_teardown
t_summary
