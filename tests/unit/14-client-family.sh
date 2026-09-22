#!/usr/bin/env bash
# =============================================================================
# unit test :: client upstream address-family reliability (P0.5)
#
# Production background (the London pilot): the node has a blackholed IPv4 path
# and a healthy IPv6 path. `cache_peer <dual-stack-hostname>` then produced
# random HIER_NONE/000 for GitHub API/Raw while Release passed, and the install
# rolled back. This suite pins the replacement behaviour:
#
#   * deterministic family selection (auto/4/6) with probe-verified candidates
#   * per-family classification: 200 usable, 403/407 reached-but-refused,
#     000 transport (never "not authorised")
#   * a pinned peer is rendered into cache_peer while ssldomain= keeps the
#     certificate verified against the LOGICAL hostname
#   * state schema (family / selected family / peer) survives a round trip
#   * `ghproxyctl client upstream refresh`: no-op when unchanged, transactional
#     update when the DNS answer changed
#   * rollback restores the PRE-INSTALL system-squid unit state (enabled/
#     disabled/active/absent) instead of unconditionally enabling it
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

UPSTREAM="https://gh.family.test:8443"
CLIENT_CONF="$GP_ROOT/etc/vps-gateway-manager/client.conf"
SQUID_CLIENT_CONF="$GP_ROOT/etc/vps-gateway-manager/client-squid.conf"

stub_register_unit squid 1
stub_register_unit vps-gateway-manager-client.service 0
stub_add_port "127.0.0.1:3128"
stub_add_port "127.0.0.1:3129"
stub_set_access_log "$GP_ROOT/var/log/vps-gateway-manager/access.log"
mkdir -p "$GP_ROOT/etc/squid" "$GP_ROOT/etc/ssl/certs" "$GP_ROOT/etc/profile.d" "$GP_ROOT/etc/sudoers.d"
printf -- '-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n' > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"

# Dual-stack host, DNS answers for the upstream, healthy probes by default.
cat > "$STUB_STATE/ips" <<'EOF'
2: eth0    inet 212.135.36.99/24 scope global eth0
3: eth0    inet6 2a06:a005:ad:fffd::89/64 scope global eth0
EOF
stub_add_host gh.family.test 203.0.113.10 2001:db8::10

fam_rules() {
  # fam_rules <v4-code> <v6-code>
  printf 'api.github.com\t%s\n' "$1" > "$STUB_STATE/curl/rules-4"
  printf 'api.github.com\t%s\n' "$2" > "$STUB_STATE/curl/rules-6"
}

reset_selection() {
  # Fill every default first (the render/state helpers assume they exist), then
  # reset the selection state - including the CONFIGURED family: the explicit
  # family tests below set it and it must not leak into later scenarios.
  client_set_defaults
  CLIENT_UPSTREAM_FAMILY="auto"
  CLIENT_UPSTREAM_SELECTION_DONE=0
  CLIENT_SELECTED_FAMILY=""
  CLIENT_UPSTREAM_PEER_ADDRESS=""
  CLIENT_PEER_V6_FORM=""
  CLIENT_UPSTREAM="https://gh.family.test:8443"
  CLIENT_UPSTREAM_HOST="gh.family.test"
  CLIENT_UPSTREAM_PORT="8443"
  CLIENT_UPSTREAM_SCHEME="https"
}

# Select in the CURRENT shell (the globals must stick) with stderr captured.
select_capture() {
  SEL_LOG="$(mktemp)"
  { client_select_upstream; } 2>"$SEL_LOG"
  SEL_RC=$?
  return 0
}

# -----------------------------------------------------------------------------
t_begin "probe classification"
assert_eq 'PASS (HTTP 200)' "$(client_classify_code 200)" "200 is a pass"
assert_eq 'REACHED BUT REFUSED (HTTP 403)' "$(client_classify_code 403)" "403 is reached-but-refused"
assert_eq 'REACHED BUT REFUSED (HTTP 407)' "$(client_classify_code 407)" "407 is reached-but-refused"
assert_eq 'TRANSPORT UNAVAILABLE (HTTP 000)' "$(client_classify_code 000)" "000 is transport, never 'not authorised'"
assert_eq 'REACHED, UNEXPECTED RESPONSE (HTTP 502)' "$(client_classify_code 502)" "other codes are unexpected responses"

t_begin "candidate resolution and rendering helpers"
assert_eq "203.0.113.10" "$(client_resolve_candidates gh.family.test 4)" "the IPv4 candidate is resolved"
assert_eq "2001:db8::10" "$(client_resolve_candidates gh.family.test 6)" "the IPv6 candidate is resolved"
assert_eq "203.0.113.10" "$(client_resolve_candidates 203.0.113.10 4)" "an IPv4 literal is its own candidate"
assert_eq "2001:db8::10" "$(client_resolve_candidates 2001:db8::10 6)" "an IPv6 literal is its own candidate"
assert_not_contains "$(client_resolve_candidates gh.family.test 6)" "203.0.113.10" "no IPv4 leaks into the v6 candidate list"
assert_eq "[2001:db8::10]" "$(client_connect_host 2001:db8::10)" "connect targets are bracketed for IPv6"
assert_eq "203.0.113.10" "$(client_connect_host 203.0.113.10)" "IPv4 connect targets are plain"
# The cache_peer spelling is decided by `squid -k parse`, never guessed: with
# the test stub accepting everything the numeric (unbracketed) form is chosen.
CLIENT_PEER_V6_FORM=""
assert_eq "2001:db8::10" "$(client_peer_token 2001:db8::10)" "the squid-validated bare form is used"
CLIENT_PEER_V6_FORM="brackets"
assert_eq "[2001:db8::10]" "$(client_peer_token 2001:db8::10)" "a squid that only parses brackets gets brackets"
CLIENT_PEER_V6_FORM=""

# -----------------------------------------------------------------------------
t_begin "auto selection: both families healthy -> verified hostname mode"
reset_selection
fam_rules 200 200
select_capture
assert_eq "0" "$SEL_RC" "selection succeeds"
assert_eq "dual" "$CLIENT_SELECTED_FAMILY" "hostname mode is kept"
assert_eq "" "$CLIENT_UPSTREAM_PEER_ADDRESS" "no peer is pinned"

t_begin "auto selection: IPv4 blackholed, IPv6 healthy -> IPv6 pinned"
reset_selection
fam_rules 000 200
select_capture
assert_eq "0" "$SEL_RC" "selection succeeds"
assert_eq "6" "$CLIENT_SELECTED_FAMILY" "family 6 is selected"
assert_eq "2001:db8::10" "$CLIENT_UPSTREAM_PEER_ADDRESS" "the probe-verified v6 candidate is pinned"
assert_contains "$(cat "$SEL_LOG")" 'upstream family 6 selected' "the decision is logged"
assert_not_contains "$(cat "$SEL_LOG")" 'Authorise both exact host addresses' "no authorisation advice for a 000"

t_begin "auto selection: IPv6 blackholed, IPv4 healthy -> IPv4 pinned"
reset_selection
fam_rules 200 000
select_capture
assert_eq "0" "$SEL_RC" "selection succeeds"
assert_eq "4" "$CLIENT_SELECTED_FAMILY" "family 4 is selected"
assert_eq "203.0.113.10" "$CLIENT_UPSTREAM_PEER_ADDRESS" "the probe-verified v4 candidate is pinned"

t_begin "auto selection: both families broken -> abort before any change"
reset_selection
fam_rules 000 000
select_capture
assert_ne "0" "$SEL_RC" "selection fails"
assert_eq "" "$CLIENT_SELECTED_FAMILY" "nothing is selected"
assert_contains "$(cat "$SEL_LOG")" 'IPv4: TRANSPORT UNAVAILABLE (HTTP 000)' "IPv4 is reported as transport"
assert_contains "$(cat "$SEL_LOG")" 'IPv6: TRANSPORT UNAVAILABLE (HTTP 000)' "IPv6 is reported as transport"
assert_contains "$(cat "$SEL_LOG")" 'NOT an authorisation failure' "the guidance distinguishes transport from authorisation"

t_begin "auto selection: 403 is authorisation, not transport"
reset_selection
fam_rules 403 000
select_capture
assert_ne "0" "$SEL_RC" "selection fails (nothing usable)"
assert_contains "$(cat "$SEL_LOG")" 'IPv4: REACHED BUT REFUSED (HTTP 403)' "IPv4 is reached-but-refused"
assert_contains "$(cat "$SEL_LOG")" 'ghproxyctl client add' "the server-side fix is explained"
assert_not_contains "$(cat "$SEL_LOG")" 'NOT an authorisation failure' "403 IS an authorisation issue"

t_begin "explicit family is honoured, healthy or not"
reset_selection
fam_rules 200 200
CLIENT_UPSTREAM_FAMILY=6
select_capture
assert_eq "0" "$SEL_RC" "family 6 is selected although 4 also works"
assert_eq "6" "$CLIENT_SELECTED_FAMILY" "explicit family wins"
assert_eq "2001:db8::10" "$CLIENT_UPSTREAM_PEER_ADDRESS" "the peer is pinned"
reset_selection
fam_rules 200 000
CLIENT_UPSTREAM_FAMILY=6
select_capture
assert_ne "0" "$SEL_RC" "an explicit but broken family aborts"
assert_contains "$(cat "$SEL_LOG")" 'requested explicitly' "the abort names the explicit request"
reset_selection
fam_rules 200 200
CLIENT_UPSTREAM_FAMILY=nonsense
select_capture
assert_ne "0" "$SEL_RC" "an invalid family value is rejected"

t_begin "family flags for the whitelist probe"
reset_selection
CLIENT_SELECTED_FAMILY=6
assert_eq "-6" "$(client_upstream_probe_family_flag)" "family 6 forces -6"
CLIENT_SELECTED_FAMILY=4
assert_eq "-4" "$(client_upstream_probe_family_flag)" "family 4 forces -4"
CLIENT_SELECTED_FAMILY=dual
assert_eq "" "$(client_upstream_probe_family_flag)" "hostname mode forces nothing"

# -----------------------------------------------------------------------------
t_begin "candidate failover inside one family"
stub_add_host gh.cand.test 2001:db8::1 2001:db8::2
reset_selection
CLIENT_UPSTREAM_HOST="gh.cand.test"
CLIENT_UPSTREAM="https://gh.cand.test:8443"
fam_rules 000 200
# The first DNS candidate is dead, the second one answers: the second must win.
printf '[2001:db8::1]:8443\tdown\n' > "$STUB_STATE/openssl/probe-rules"
select_capture
assert_eq "0" "$SEL_RC" "selection succeeds"
assert_eq "2001:db8::2" "$CLIENT_UPSTREAM_PEER_ADDRESS" "the broken candidate is skipped, not the DNS order"
assert_contains "$(cat "$SEL_LOG")" 'TRANSPORT UNAVAILABLE' "the failed candidate is reported"

t_begin "a candidate with a wrong certificate is refused, not skipped silently"
reset_selection
CLIENT_UPSTREAM_HOST="gh.cand.test"
CLIENT_UPSTREAM="https://gh.cand.test:8443"
fam_rules 000 200
printf '[2001:db8::1]:8443\ttls\n' > "$STUB_STATE/openssl/probe-rules"
select_capture
assert_eq "0" "$SEL_RC" "selection succeeds via the second candidate"
assert_contains "$(cat "$SEL_LOG")" 'CERTIFICATE VERIFICATION FAILED' "the TLS failure is classified precisely"
rm -f "$STUB_STATE/openssl/probe-rules"

# -----------------------------------------------------------------------------
t_begin "the rendered configuration separates peer and TLS name"
reset_selection
CLIENT_UPSTREAM_PEER_ADDRESS="2001:db8::10"
CLIENT_PEER_V6_FORM=""
CCONF="$(client_render_squid_conf)"
assert_contains "$CCONF" 'cache_peer 2001:db8::10 parent 8443' "the peer address is the cache_peer host"
assert_contains "$CCONF" 'ssldomain=gh.family.test' "the certificate is verified against the logical hostname"
assert_not_contains "$CCONF" 'cache_peer gh.family.test' "the hostname is not used as the peer"
assert_contains "$CCONF" 'tls tls-cafile=' "TLS to the upstream stays on"
reset_selection
CCONF="$(client_render_squid_conf)"
assert_contains "$CCONF" 'cache_peer gh.family.test parent 8443' "hostname mode renders the hostname"
assert_no_line_matches "$CCONF" '^cache_peer.*ssldomain=' "no ssldomain is invented in hostname mode"

t_begin "the state schema separates configured and selected family"
reset_selection
fam_rules 000 200
select_capture
CLIENT_UPSTREAM_FAMILY="auto"
CLIENT_SELECTED_FAMILY="6"
CLIENT_UPSTREAM_PEER_ADDRESS="2001:db8::10"
client_state_write
CLIENT_UPSTREAM_FAMILY=""; CLIENT_SELECTED_FAMILY=""; CLIENT_UPSTREAM_PEER_ADDRESS=""
CLIENT_UPSTREAM=""; CLIENT_UPSTREAM_HOST=""; CLIENT_UPSTREAM_PORT=""
client_state_load
assert_eq "auto" "$CLIENT_UPSTREAM_FAMILY" "the configured family survives"
assert_eq "6" "$CLIENT_SELECTED_FAMILY" "the selected family survives"
assert_eq "2001:db8::10" "$CLIENT_UPSTREAM_PEER_ADDRESS" "the peer survives"
assert_eq "gh.family.test" "$CLIENT_UPSTREAM_HOST" "the logical hostname survives"
assert_eq "8443" "$CLIENT_UPSTREAM_PORT" "the port survives"

# -----------------------------------------------------------------------------
# Full install with a blackholed IPv4 (the London shape)
# -----------------------------------------------------------------------------
t_begin "install on a one-family host: IPv4 blackholed, IPv6 healthy"
fam_rules 000 200
rm -f "$GP_ROOT/etc/vps-gateway-manager/role" 2>/dev/null || true
OUT="$(run_install client --upstream "$UPSTREAM" --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the install succeeds via the healthy family"
assert_contains "$OUT" 'upstream family 6 selected' "the family choice is reported"
assert_eq "auto" "$(conf_get "$CLIENT_CONF" upstream_family)" "state: configured family"
assert_eq "6" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "state: selected family 6"
assert_eq "2001:db8::10" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: pinned peer"
assert_file_contains "$SQUID_CLIENT_CONF" 'cache_peer 2001:db8::10 parent 8443' "the generated config pins the peer"
assert_file_contains "$SQUID_CLIENT_CONF" 'ssldomain=gh.family.test' "TLS verification keeps the logical name"
assert_file_not_contains "$SQUID_CLIENT_CONF" 'cache_peer gh.family.test' "the dual-stack hostname is not used"

t_begin "status names the broken layer and the selection"
OUT="$(run_ctl status 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "status is healthy on the one-family host"
assert_contains "$OUT" 'Upstream IPv4' "the IPv4 record exists"
assert_contains "$OUT" 'TRANSPORT UNAVAILABLE (HTTP 000)' "IPv4 is reported as transport unavailable"
assert_matches_line "$OUT" 'Upstream IPv6[[:space:]]+PASS.*\(HTTP 200\)' "IPv6 passes"
assert_contains "$OUT" 'Upstream family   IPv6 (pinned)' "the selected family is shown"
assert_contains "$OUT" 'Upstream peer     2001:db8::10 (TLS name: gh.family.test)' "the peer and its TLS name are shown"
assert_contains "$OUT" 'Selected family' "the health table names the selection"
assert_not_contains "$OUT" 'not authorised' "000 is never described as not authorised"

# -----------------------------------------------------------------------------
t_begin "refresh: unchanged path is a no-op"
CONF_SUM="$(gp_sha256 "$SQUID_CLIENT_CONF")"
CALLS_BEFORE="$(stub_systemd_actions)"
OUT="$(run_ctl client upstream refresh --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the refresh succeeds"
assert_contains "$OUT" 'upstream path unchanged' "the no-op is stated"
assert_eq "$CONF_SUM" "$(gp_sha256 "$SQUID_CLIENT_CONF")" "the configuration was not rewritten"
assert_eq "$CALLS_BEFORE" "$(stub_systemd_actions)" "no service action for a no-op"

t_begin "refresh: a changed DNS answer updates the peer transactionally"
stub_add_host gh.family.test 2001:db8::99
CONF_SUM="$(gp_sha256 "$SQUID_CLIENT_CONF")"
OUT="$(run_ctl client upstream refresh --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the refresh succeeds"
assert_contains "$OUT" 'upstream path refreshed' "the update is reported"
assert_eq "2001:db8::99" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: the new peer is recorded"
assert_file_contains "$SQUID_CLIENT_CONF" 'cache_peer 2001:db8::99 parent 8443' "the config uses the new peer"
assert_file_contains "$SQUID_CLIENT_CONF" 'ssldomain=gh.family.test' "the TLS name is preserved"
assert_ne "$CONF_SUM" "$(gp_sha256 "$SQUID_CLIENT_CONF")" "the configuration really changed"
assert_contains "$(stub_systemd_actions)" 'reloaded vps-gateway-manager-client' "the local squid was reloaded"

t_begin "refresh --dry-run plans without touching anything"
stub_add_host gh.family.test 2001:db8::10
CONF_SUM="$(gp_sha256 "$SQUID_CLIENT_CONF")"
OUT="$(run_ctl client upstream refresh --dry-run --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "the dry-run succeeds"
assert_contains "$OUT" 'read-only refresh plan' "the dry-run is explicit"
assert_contains "$OUT" '2001:db8::10' "the new peer appears in the plan"
assert_eq "$CONF_SUM" "$(gp_sha256 "$SQUID_CLIENT_CONF")" "nothing was written"
assert_eq "2001:db8::99" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "the state is unchanged"

# -----------------------------------------------------------------------------
t_begin "install aborts before any change when no family works"
rm -rf "$GP_ROOT/etc/vps-gateway-manager" "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service"
: > "$STUB_STATE/systemd/actions.log"
fam_rules 000 000
OUT="$(run_install client --upstream "$UPSTREAM" --no-git-config --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "the install fails"
assert_contains "$OUT" 'no usable path' "the failure is named"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/role" "no state was written"
assert_file_absent "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" "no unit was installed"
assert_eq "" "$(stub_systemd_actions)" "no service action at all"

# -----------------------------------------------------------------------------
# Rollback must restore the PRE-INSTALL system-squid state
# -----------------------------------------------------------------------------
rollback_case() {
  # rollback_case <name> <pre-state: enabled-inactive|disabled-inactive|active|absent>
  local name="$1" pre="$2"
  t_begin "rollback restores: $name"
  # Start from a clean client-free sandbox view (a fresh host: nothing of ours
  # exists yet - leftovers from earlier sections would legitimately count as
  # pre-install state and be restored on rollback).
  rm -rf "$GP_ROOT/etc/vps-gateway-manager" "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service"
  rm -rf "${GP_ROOT:?}/usr/sbin/squid" "${GP_ROOT:?}/usr/local"
  rm -rf "$GP_ROOT/etc/profile.d/vps-gateway-manager.sh" \
         "$GP_ROOT/etc/sudoers.d/vps-gateway-manager" \
         "$GP_ROOT/var/spool/vps-gateway-manager" \
         "$GP_ROOT/run/vps-gateway-manager" \
         "$GP_ROOT/var/log/vps-gateway-manager"
  rm -f "$STUB_STATE/systemd/squid.active" "$STUB_STATE/systemd/squid.enabled" \
        "$STUB_STATE/systemd/squid.registered" \
        "$STUB_STATE/systemd/vps-gateway-manager-client.active" \
        "$STUB_STATE/systemd/vps-gateway-manager-client.enabled"
  case "$pre" in
    enabled-inactive)  touch "$STUB_STATE/systemd/squid.enabled" ;;
    disabled-inactive) : ;;
    active)            stub_register_unit squid 1 ;;
    absent)            : ;;
  esac
  : > "$STUB_STATE/systemd/actions.log"
  # Make the health check fail AFTER the squid package was (stub-)installed,
  # so the transaction and its rollback are exercised for real.
  fam_rules 200 200
  printf 'api.github.com\t000\n' > "$STUB_STATE/curl/rules"
  # The package must look NOT installed (otherwise the install path short-circuits),
  # and the squid binary must not be on PATH or in the sandbox yet.
  mkdir -p "$STUB_STATE/dpkg-missing"
  touch "$STUB_STATE/dpkg-missing/squid-openssl" "$STUB_STATE/dpkg-missing/squid"
  mv "$STUB_BIN/squid" "$STUB_STATE/squid.hidden"
  OUT="$(run_install client --upstream "$UPSTREAM" --no-git-config --yes 2>&1)"; RC=$?
  mv "$STUB_STATE/squid.hidden" "$STUB_BIN/squid"
  assert_ne "0" "$RC" "the install fails its health check"
  printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules"

  # The rollback journal must never enable the distribution unit.
  local journal_hits=0 j
  for j in "$GP_ROOT"/etc/vps-gateway-manager/state/journal/*/journal.tsv; do
    [ -r "$j" ] || continue
    grep -q 'systemctl enable squid' "$j" && journal_hits=$((journal_hits+1))
  done
  assert_eq "0" "$journal_hits" "no rollback command enables the system squid"

  # §10 checklist: every artefact of the failed install must be gone/restored.
  assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/role" "client state removed (role)"
  assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/client.conf" "client state removed (client.conf)"
  assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/version" "client state removed (version)"
  assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/github-domains.txt" "destination list removed"
  assert_file_absent "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" "client unit removed"
  assert_file_absent "$GP_ROOT/etc/profile.d/vps-gateway-manager.sh" "profile.d entry removed"
  assert_file_absent "$GP_ROOT/etc/sudoers.d/vps-gateway-manager" "sudoers entry removed"
  assert_file_absent "$GP_ROOT/var/spool/vps-gateway-manager" "spool directory removed"
  assert_file_absent "$GP_ROOT/var/log/vps-gateway-manager" "log directory removed"
  assert_file_absent "$GP_ROOT/run/vps-gateway-manager" "runtime directory removed"
  # The local proxy's SERVICE state must also be restored (not just the files):
  # a fresh install must leave neither a running nor an enabled unit behind.
  if stub_unit_active vps-gateway-manager-client; then
    t_fail "the local proxy must not be running after rollback ($pre)"
  else
    t_ok "the local proxy is not running after rollback ($pre)"
  fi
  if stub_unit_enabled vps-gateway-manager-client; then
    t_fail "the client unit must not be enabled after rollback ($pre)"
  else
    t_ok "the client unit is not enabled after rollback ($pre)"
  fi

  case "$pre" in
    enabled-inactive)
      assert_contains "$(stub_systemd_actions)" 'stopped squid' "the package-started unit was stopped"
      if stub_unit_enabled squid; then t_ok "the unit is still enabled"; else t_fail "the unit must stay enabled"; fi
      if stub_unit_active squid; then t_fail "the unit must be inactive again"; else t_ok "the unit is inactive again"; fi
      ;;
    disabled-inactive|absent)
      assert_contains "$(stub_systemd_actions)" 'stopped squid' "the package-started unit was stopped"
      assert_contains "$(stub_systemd_actions)" 'disabled squid' "the freshly installed unit was disabled"
      if stub_unit_enabled squid; then t_fail "the unit must not be enabled after rollback ($pre)"; else t_ok "the unit is not enabled after rollback ($pre)"; fi
      if stub_unit_active squid; then t_fail "the unit must not be active after rollback ($pre)"; else t_ok "the unit is not active after rollback ($pre)"; fi
      ;;
    active)
      if printf '%s\n' "$(stub_systemd_actions)" | grep -q 'stopped squid'; then
        t_fail "an already-active system squid must not be stopped"
      else
        t_ok "an already-active system squid was not stopped"
      fi
      if stub_unit_active squid; then t_ok "the unit is still active"; else t_fail "the unit must stay active"; fi
      ;;
  esac
  # Cleanup for the next case.
  rm -rf "$GP_ROOT/usr/sbin/squid"
}

rollback_case enabled-inactive enabled-inactive
rollback_case disabled-inactive disabled-inactive
rollback_case active active
rollback_case absent absent

sandbox_teardown 2>/dev/null || true
t_summary
