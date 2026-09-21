#!/usr/bin/env bash
# =============================================================================
# unit test :: real-shaped Komari client dry-run (P0.3)
#
# Host shape (modelled on the first real client dry-run):
#   Debian 12, dual stack, komari-agent.service with an Environment= drop-in
#   (proxy.conf), Endpoint/Token in the unit's ExecStart, no xray-manager, no
#   Git proxy, no /etc/environment proxy.
#
# Pins:
#   * the Komari Token never appears in the dry-run output - not truncated, not
#     partially, not once - for every supported token flag form and length
#   * the report says "detected, value hidden" instead of printing argv
#   * the dry-run claims no state it did not write
#   * the remote whitelist probe really runs (TLS verified, no -k, bounded
#     timeout) and reports 200/403/407/000 explicitly; a failed probe is not a
#     silent success
#   * the per-address-family upstream diagnostic and the one-family warning
#   * nothing on the host is modified (no state dir, no service action, the
#     operator's drop-in stays byte-identical)
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

UPSTREAM="https://gh.example.test:8443"
SYSD="$GP_ROOT/etc/systemd/system"
DROPIN_DIR="$SYSD/komari-agent.service.d"
DROPIN="$DROPIN_DIR/proxy.conf"
SECRET="SUPER_SECRET_VALUE"

stub_register_unit komari-agent 1
stub_register_unit vps-gateway-manager-client.service 0
mkdir -p "$DROPIN_DIR" "$GP_ROOT/etc/ssl/certs" "$GP_ROOT/etc/xray-manager" "$GP_ROOT/etc/profile.d" "$GP_ROOT/etc/sudoers.d"
printf -- '-----BEGIN CERTIFICATE-----\nstub\n' > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"

# Dual-stack host (the real node has one IPv4 and one IPv6 address).
cat > "$STUB_STATE/ips" <<'EOF'
2: eth0    inet 212.135.36.99/24 scope global eth0
3: eth0    inet6 2a06:a005:ad:fffd::89/64 scope global
EOF

# --- Komari as it exists today ------------------------------------------------
cat > "$SYSD/komari-agent.service" <<EOF
[Unit]
Description=Komari Agent
[Service]
ExecStart=/opt/komari/agent -e https://panel.example.com -t $SECRET --disable-web-ssh
[Install]
WantedBy=multi-user.target
EOF
cat > "$DROPIN" <<EOF
[Service]
Environment="HTTPS_PROXY=$UPSTREAM" "HTTP_PROXY=$UPSTREAM" "NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1"
Environment="http_proxy=http://legacy-user:LEGACY_PASSWORD_VALUE@old-proxy.example.test:3128"
EOF
{
  printf '# %s\n' "$SYSD/komari-agent.service"
  cat "$SYSD/komari-agent.service"
  printf '# %s\n' "$DROPIN"
  cat "$DROPIN"
} > "$STUB_STATE/systemd/komari-agent.cat"
printf 'Environment=HTTPS_PROXY=%s HTTP_PROXY=%s NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1 http_proxy=http://legacy-user:LEGACY_PASSWORD_VALUE@old-proxy.example.test:3128\nExecStart={ path=/opt/komari/agent ; argv[]=/opt/komari/agent -e https://panel.example.com -t %s --disable-web-ssh ; ignore_errors=no ; status=0/0 }\n' \
  "$UPSTREAM" "$UPSTREAM" "$SECRET" > "$STUB_STATE/systemd/komari-agent.show"

printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules"
printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules-4"
printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules-6"

DROPIN_SUM="$(gp_sha256 "$DROPIN")"
UNIT_SUM="$(gp_sha256 "$SYSD/komari-agent.service")"

run_dry() {
  OUT="$(run_install client --upstream "$UPSTREAM" --adopt-existing --dry-run --verbose --yes 2>&1)"; RC=$?
}
occurrences() { printf '%s\n' "$1" | grep -c -F -- "$2" || true; }

# -----------------------------------------------------------------------------
# 1. The real-shaped dry-run
# -----------------------------------------------------------------------------
t_begin "the Komari client dry-run produces the full read-only plan"
run_dry
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "dry-run exits successfully"
assert_contains "$OUT" 'client adoption plan (read-only)' "plan headline"
assert_contains "$OUT" 'komari-agent' "Komari unit detected"
assert_contains "$OUT" 'proxy.conf' "the operator's drop-in is reported"
assert_contains "$OUT" 'EnvironmentFile   : not used' "no EnvironmentFile"
assert_contains "$OUT" 'xray-manager' "xray-manager section present"
assert_contains "$OUT" 'not present' "xray-manager absent"
assert_contains "$OUT" '127.0.0.1:3129' "local proxy port mentioned"
assert_contains "$OUT" 'rewrite the 4 proxy variables' "the four proxy variables will be rewritten"
assert_contains "$OUT" 'what will NOT be touched' "the untouched list is printed"
assert_contains "$OUT" 'Komari Endpoint, Token and ExecStart' "the promise about Endpoint/Token/ExecStart stays"

t_begin "the Komari Token never appears in the output"
assert_eq "0" "$(occurrences "$OUT" "$SECRET")" "the real token value appears zero times"
assert_not_contains "$OUT" 'cut -c'
assert_contains "$OUT" 'ExecStart         : detected (redacted' "ExecStart is reported as redacted"
assert_contains "$OUT" 'Endpoint          : detected, value hidden' "Endpoint presence only"
assert_contains "$OUT" 'Token             : detected, value hidden' "Token presence only"
assert_not_contains "$OUT" 'argv[]' "no raw argv is printed"
assert_contains "$OUT" "$UPSTREAM" "the upstream itself is still shown"

t_begin "URL credentials in shown values are redacted"
assert_eq "0" "$(occurrences "$OUT" 'LEGACY_PASSWORD_VALUE')" "a password in a proxy URL never appears"
assert_contains "$OUT" 'http://***@old-proxy.example.test:3128' "the userinfo is masked"
assert_eq "http://***@proxy.example.test:3128" \
  "$(gp_redact_url_credentials 'http://alice:hunter2@proxy.example.test:3128')" "helper masks userinfo"
assert_eq "https://gh.example.test:8443" \
  "$(gp_redact_url_credentials 'https://gh.example.test:8443')" "URLs without credentials are unchanged"
assert_eq "<unset>" "$(gp_redact_url_credentials '<unset>')" "non-URL values pass through"

t_begin "the dry-run does not claim state it did not write"
assert_not_contains "$OUT" 'recorded in' "no 'recorded in' wording in a dry-run"
assert_contains "$OUT" 'inspected (read-only; nothing persisted)' "the wording is explicitly read-only"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager" "no state directory was created"

t_begin "nothing on the host was modified"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "the operator's drop-in is byte-identical"
assert_eq "$UNIT_SUM" "$(gp_sha256 "$SYSD/komari-agent.service")" "the unit is byte-identical"
assert_eq "" "$(stub_systemd_actions)" "no service action (Komari was not started/stopped/restarted)"
assert_file_absent "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" "no local proxy unit was installed"

# -----------------------------------------------------------------------------
# 2. The remote whitelist probe really runs and is TLS-verified
# -----------------------------------------------------------------------------
t_begin "the remote whitelist check runs in dry-run mode"
assert_contains "$OUT" 'remote whitelist check' "the check is part of the report"
assert_not_contains "$OUT" 'skipped (dry-run)' "the check is not skipped"
assert_contains "$OUT" 'PASS: a GitHub request through the upstream succeeded' "HTTP 200 is reported as PASS"
PROBE_CALLS="$(grep 'api.github.com' "$STUB_STATE/curl/calls.log" 2>/dev/null || true)"
assert_contains "$PROBE_CALLS" "--proxy $UPSTREAM" "the probe went through the upstream"
assert_contains "$PROBE_CALLS" '--proxy-cacert' "the proxy certificate is verified"
assert_not_contains "$PROBE_CALLS" '--insecure' "no --insecure"
assert_not_contains "$PROBE_CALLS" ' -k ' "no -k"
assert_matches_line "$PROBE_CALLS" '--max-time [0-9]+' "the timeout is bounded"

# -----------------------------------------------------------------------------
# 3. Dual stack: both families PASS means no warning
# -----------------------------------------------------------------------------
t_begin "dual stack: both families pass"
assert_contains "$OUT" 'upstream path' "the per-family diagnostic is printed"
assert_contains "$OUT" 'IPv4: PASS (HTTP 200)' "IPv4 passes"
assert_contains "$OUT" 'IPv6: PASS (HTTP 200)' "IPv6 passes"
assert_not_contains "$OUT" 'only one address family' "no warning when both families work"

t_begin "dual stack: IPv4 refused, IPv6 allowed -> explicit warning"
printf 'api.github.com\t403\n' > "$STUB_STATE/curl/rules-4"
printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules-6"
run_dry
assert_eq "0" "$RC" "the default path still passes (IPv6)"
assert_contains "$OUT" 'IPv4: FAIL (HTTP 403)' "IPv4 is reported as FAIL"
assert_contains "$OUT" 'IPv6: PASS (HTTP 200)' "IPv6 is reported as PASS"
assert_contains "$OUT" 'only one address family can reach the upstream' "the operator is warned"
assert_contains "$OUT" 'Authorise both exact host addresses before migration' "the fix is explained"
assert_not_contains "$OUT" '0.0.0.0/0' "no blanket authorisation is suggested"
assert_not_contains "$OUT" '::/0' "no blanket authorisation is suggested (v6)"

t_begin "single-stack host: the missing family is unavailable, not a failure"
printf '3: eth0    inet6 2a06:a005:ad:fffd::89/64 scope global\n' > "$STUB_STATE/ips"
run_dry
assert_contains "$OUT" 'IPv4: unavailable' "IPv4 is unavailable"
assert_contains "$OUT" 'IPv6: PASS (HTTP 200)' "IPv6 passes"
assert_not_contains "$OUT" 'only one address family' "no warning on a single-stack host"
cat > "$STUB_STATE/ips" <<'EOF'
2: eth0    inet 212.135.36.99/24 scope global eth0
3: eth0    inet6 2a06:a005:ad:fffd::89/64 scope global
EOF

# -----------------------------------------------------------------------------
# 4. Token flag forms and lengths never leak
# -----------------------------------------------------------------------------
t_begin "every token flag form and length stays hidden"
check_token_form() {
  local spec="$1"; shift
  printf 'ExecStart={ path=/opt/komari/agent ; argv[]=/opt/komari/agent -e https://panel.example.com %s --disable-web-ssh ; ignore_errors=no }\n' \
    "$spec" > "$STUB_STATE/systemd/komari-agent.show"
  run_dry
  assert_eq "0" "$RC" "dry-run succeeds for: $spec"
  local tok
  for tok in "$@"; do
    if [ "$(occurrences "$OUT" "$tok")" != "0" ]; then
      t_fail "leaked '$tok' for spec: $spec"
    fi
  done
  t_ok "no token value leaked for: $spec"
}
check_token_form "-t SHORTTOK" SHORTTOK
check_token_form "--token A_MUCH_LONGER_TOKEN_VALUE_0123456789" A_MUCH_LONGER_TOKEN_VALUE_0123456789
check_token_form "-t=EQFORMTOKEN" EQFORMTOKEN
check_token_form "--token=EQFORMTOKEN2" EQFORMTOKEN2
check_token_form "--token FIRSTTAIL --token SECONDFLAG" FIRSTTAIL SECONDFLAG
check_token_form "-e https://panel.example.com --custom-flag custom-value"
# restore the baseline show file
printf 'Environment=HTTPS_PROXY=%s HTTP_PROXY=%s NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1\nExecStart={ path=/opt/komari/agent ; argv[]=/opt/komari/agent -e https://panel.example.com -t %s --disable-web-ssh ; ignore_errors=no ; status=0/0 }\n' \
  "$UPSTREAM" "$UPSTREAM" "$SECRET" > "$STUB_STATE/systemd/komari-agent.show"

t_begin "a unit without a token flag reports 'not found', not a value"
printf 'Environment=HTTPS_PROXY=%s HTTP_PROXY=%s\nExecStart={ path=/opt/komari/agent ; argv[]=/opt/komari/agent -e https://panel.example.com ; ignore_errors=no }\n' \
  "$UPSTREAM" "$UPSTREAM" > "$STUB_STATE/systemd/komari-agent.show"
run_dry
assert_contains "$OUT" 'Token             : not found' "absence is reported honestly"
assert_contains "$OUT" 'Endpoint          : detected, value hidden' "the endpoint is still detected"
printf 'Environment=HTTPS_PROXY=%s HTTP_PROXY=%s NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1\nExecStart={ path=/opt/komari/agent ; argv[]=/opt/komari/agent -e https://panel.example.com -t %s --disable-web-ssh ; ignore_errors=no ; status=0/0 }\n' \
  "$UPSTREAM" "$UPSTREAM" "$SECRET" > "$STUB_STATE/systemd/komari-agent.show"

# -----------------------------------------------------------------------------
# 5. A failed probe is never a silent success
# -----------------------------------------------------------------------------
t_begin "the upstream refusing this host fails the dry-run explicitly"
printf 'api.github.com\t403\n' > "$STUB_STATE/curl/rules"
run_dry
assert_ne "0" "$RC" "the dry-run reports failure"
assert_contains "$OUT" 'FAIL: the upstream refused this host (HTTP 403)' "HTTP 403 is shown"
assert_contains "$OUT" 'ghproxyctl client add <this-host-egress-ip> <name>' "the server-side fix is explained"
assert_contains "$OUT" 'nothing was changed' "the read-only guarantee is restated"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager" "still no state written"

t_begin "no response at all is reported as HTTP 000"
printf 'example.invalid\t200\n' > "$STUB_STATE/curl/rules"
run_dry
assert_ne "0" "$RC" "the dry-run reports failure"
assert_contains "$OUT" 'FAIL: no response through the upstream (HTTP 000)' "HTTP 000 is shown"
printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules"

t_begin "a passing probe is HTTP 200 and leaves no trace"
printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules"
run_dry
assert_eq "0" "$RC" "the dry-run passes"
assert_contains "$OUT" 'PASS: a GitHub request through the upstream succeeded' "HTTP 200 is reported"
assert_not_contains "$OUT" "$SECRET" "still no token in the final run"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager" "no state directory at the end"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "drop-in untouched at the end"
assert_eq "" "$(stub_systemd_actions)" "no service action at the end"

sandbox_teardown 2>/dev/null || true
t_summary
