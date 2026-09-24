#!/usr/bin/env bash
# =============================================================================
# unit test :: health-check honesty (v0.5.1)
#
# The production gateway reported "Unknown source refused FAIL 000000" and
# `ghproxyctl status` then died with "aborted unexpectedly" before printing
# the table. curl -w already prints 000 on a failed connect; appending another
# 000 hid the transport failure, and set -e aborted before hc_print.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

cls() { hc_classify_unknown_source "$@" | cut -f1; }
det() { hc_classify_unknown_source "$@" | cut -f2-; }

# -----------------------------------------------------------------------------
t_begin "unknown-source classification"
assert_eq "WARN" "$(cls 28 000 0)" "curl 28 + 000 is not a Squid refusal"
assert_contains "$(det 28 000 0)" "not independently verified" "a timeout says the ACL was not verified"
assert_contains "$(det 28 000 0)" "firewall drop" "a firewall drop is named as the lookalike"
assert_eq "WARN" "$(cls 7 000 0)" "curl 7 + 000 is a transport failure"
assert_eq "WARN" "$(cls 28 '' 0)" "a timeout with no status is not a pass"
assert_contains "$(det 28 '' 0)" "not independently verified" "empty write-out is explained"
assert_eq "PASS" "$(cls 0 403 0)" "HTTP 403 is a real refusal"
assert_eq "PASS" "$(cls 0 407 0)" "HTTP 407 is a real refusal"
assert_eq "PASS" "$(cls 22 403 0)" "a refusal stays a pass when curl itself exits non-zero"
assert_eq "FAIL" "$(cls 0 200 0)" "HTTP 200 from an unknown source is a fail"
assert_contains "$(det 0 200 0)" "was served" "a served request is described as served"
assert_eq "FAIL" "$(cls 22 200 0)" "HTTP 200 is a fail even when curl exits non-zero"
assert_eq "FAIL" "$(cls 0 206 0)" "any 2xx is a served request"
assert_eq "WARN" "$(cls 0 500 0)" "an unexpected status is not a pass"
assert_eq "WARN" "$(cls 0 000000 0)" "the concatenated 000000 is not a pass and not a 000"
assert_contains "$(det 0 000000 0)" "status 000000" "the malformed token is shown, not rewritten"
assert_eq "WARN" "$(cls 0 200ok 0)" "a malformed write-out is not a pass"
assert_eq "WARN" "$(cls 0 200 1)" "an authorised probe source is not evidence of a refusal"
assert_eq "WARN" "$(cls 0 403 1)" "403 from an authorised source is not an unknown-source pass"
assert_not_contains "$(cls 28 000 0)" "PASS" "transport failure is never classified PASS"

# -----------------------------------------------------------------------------
t_begin "curl capture does not invent a second 000"
printf '28\t000\n' > "$STUB_STATE/curl/interface-result"
CAP="$(hc_capture_http_status -sS -o /dev/null -w '%{http_code}' --interface 203.0.113.50 \
  --proxy https://gw.example:8443 --max-time 12 https://api.github.com/rate_limit)"
assert_eq "$(printf '28\t000')" "$CAP" "curl 28 printing 000 is captured as exactly 000"
assert_not_contains "$CAP" "000000" "nothing appends a second 000"

printf '7\t000\n' > "$STUB_STATE/curl/interface-result"
CAP="$(hc_capture_http_status -sS -o /dev/null -w '%{http_code}' --interface 203.0.113.50 \
  --max-time 12 https://api.github.com/rate_limit)"
assert_eq "$(printf '7\t000')" "$CAP" "curl 7 printing 000 is captured as exactly 000"

printf '28\t\n' > "$STUB_STATE/curl/interface-result"
CAP="$(hc_capture_http_status -sS -o /dev/null -w '%{http_code}' --interface 203.0.113.50 \
  --max-time 12 https://api.github.com/rate_limit)"
assert_eq "$(printf '28\t')" "$CAP" "a timeout with an empty write-out stays empty"
rm -f "$STUB_STATE/curl/interface-result"

# -----------------------------------------------------------------------------
t_begin "an authorised address is recognised exactly"
printf 'node-a\t203.0.113.60/32\t2026\tghproxyctl\t-\t-\tnode_a\n' > "$SANDBOX/clients.db"
# clients_db_list reads gp_clients_db(); point the sandbox state at this file.
# These addresses are not the probe source used below, and the files are
# removed before install so they cannot mark that source as authorised.
mkdir -p "$GP_ROOT/etc/vps-gateway-manager"
cp "$SANDBOX/clients.db" "$GP_ROOT/etc/vps-gateway-manager/clients.db"
assert_ok "the exact /32 is authorised" hc_source_is_authorised 203.0.113.60
assert_rc_fails "a prefix of that address is not a match" hc_source_is_authorised 203.0.113.6
assert_rc_fails "a neighbour is not a match" hc_source_is_authorised 203.0.113.61
printf '203.0.113.77/32\n' > "$GP_ROOT/etc/vps-gateway-manager/managed-clients.acl"
assert_ok "an exact ACL-file host is authorised" hc_source_is_authorised 203.0.113.77
assert_rc_fails "203.0.113.7 is not 203.0.113.77" hc_source_is_authorised 203.0.113.7
rm -f "$GP_ROOT/etc/vps-gateway-manager/clients.db" \
  "$GP_ROOT/etc/vps-gateway-manager/managed-clients.acl"

# -----------------------------------------------------------------------------
t_begin "unexpected exit still trips the abort guard"
OUT="$(bash -c "
  set -euo pipefail
  . '$REPO_ROOT/lib/common.sh'
  gp_install_abort_guard
  false
" 2>&1)" || RC=$?
assert_ne "0" "${RC:-0}" "an unexpected failure still exits non-zero"
assert_contains "$OUT" "aborted unexpectedly" "an unexpected failure is still reported"
RC=0
OUT="$(bash -c "
  set -euo pipefail
  . '$REPO_ROOT/lib/common.sh'
  gp_install_abort_guard
  log_err 'health checks: 1 failed'
  exit 1
" 2>&1)" || RC=$?
assert_ne "0" "$RC" "a reported health failure still exits non-zero"
assert_not_contains "$OUT" "aborted unexpectedly" "a reported failure is not rephrased as an unexpected abort"

# -----------------------------------------------------------------------------
t_begin "server status and test print every result"
DOMAIN="ghproxy.smartproxy.test"
PORT=8443
CERTDIR="$SANDBOX/certs"
stub_make_cert "$CERTDIR" "$DOMAIN" || { printf 'openssl unavailable\n'; exit 1; }
stub_register_unit squid 0
mkdir -p "$GP_ROOT/etc/letsencrypt/renewal-hooks/deploy" \
  "$GP_ROOT/etc/squid/conf.d" "$GP_ROOT/var/log/squid" \
  "$GP_ROOT/etc/ssl/certs"
printf -- '-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n' \
  > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"
OUT="$(run_install server --domain "$DOMAIN" --port "$PORT" --cert-source "$CERTDIR" \
  --no-obtain-cert --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "sandbox server install succeeds"

set_pub() {
  printf '2: eth0    inet %s/24 scope global eth0\n' "$1" > "$STUB_STATE/ips"
}
set_probe() { printf '%s\t%s\n' "$1" "$2" > "$STUB_STATE/curl/interface-result"; }

set_pub 203.0.113.50
set_probe 0 403
OUT="$(run_ctl status 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "status exits 0 when every check passed"
assert_contains "$OUT" "Unknown source refused PASS" "a real 403 is a pass"
assert_contains "$OUT" "health checks: all recorded checks passed" "the summary says every recorded check passed"
assert_not_contains "$OUT" "aborted unexpectedly" "a passing status is not an abort"
OUT="$(run_ctl test 2>&1)"; RC=$?
assert_eq "0" "$RC" "test exits 0 on the same all-pass result"
assert_contains "$OUT" "health checks: all recorded checks passed" "test prints the same summary"

# no public address: the check runs and says it could not probe
rm -f "$STUB_STATE/ips" "$STUB_STATE/curl/interface-result"
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "a skip does not fail status"
assert_contains "$OUT" "Unknown source refused SKIP" "no public IP is a skip, not a pass"
assert_contains "$OUT" "a warning or a skip is not a pass" "a skip is not presented as a full pass"

# adopted loopback policy is a warning, and it names the loopback probe
conf_set "$GP_ROOT/etc/vps-gateway-manager/server.conf" mode adopted
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "a warning alone does not fail status"
assert_contains "$OUT" "Non-GitHub destination WARN" "adopted non-GitHub is a warning"
assert_contains "$OUT" "loopback" "the warning says it probed loopback"
assert_contains "$OUT" "not a test of the public TLS listener" "the warning does not claim the public listener was tested"
assert_contains "$OUT" "a warning or a skip is not a pass" "warnings are not dressed up as passes"
conf_set "$GP_ROOT/etc/vps-gateway-manager/server.conf" mode fresh

# firewall-drop signature: curl 28 printing 000 must not become FAIL 000000
set_pub 198.51.100.8
set_probe 28 000
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "a transport failure is not a health-check failure"
assert_contains "$OUT" "Unknown source refused WARN" "a dropped probe is a warning"
assert_contains "$OUT" "not independently verified" "the warning says the ACL was not verified"
assert_not_contains "$OUT" "000000" "the 000000 concatenation does not reappear"
assert_not_contains "$OUT" "aborted unexpectedly" "a warning does not abort status"
OUT="$(run_ctl test 2>&1)"; RC=$?
assert_eq "0" "$RC" "test agrees: a dropped probe is not a failure"
assert_contains "$OUT" "not independently verified" "test prints the same warning"

# the probe source is already a client: 200 must not fail, 403 must not pass
run_ctl client add 203.0.113.50 already-client --yes >/dev/null 2>&1
set_pub 203.0.113.50
set_probe 0 200
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "an authorised probe source does not fail the suite"
assert_contains "$OUT" "already authorised" "the result says the source was already authorised"
assert_not_contains "$OUT" "Unknown source refused PASS" "an authorised source is not a refusal pass"
assert_not_contains "$OUT" "Unknown source refused FAIL" "an authorised source being served is not an open-proxy fail"

# unknown source actually served: FAIL, and the rest of the table is still printed
set_pub 198.51.100.9
set_probe 0 200
OUT="$(run_ctl status 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "a served unknown source fails status"
assert_contains "$OUT" "Unknown source refused FAIL" "the served request is a fail"
assert_contains "$OUT" "was served" "the fail says the proxy served the request"
assert_contains "$OUT" "Configured listeners" "checks after the failure are still printed"
assert_contains "$OUT" "health checks: 1 failed" "the failure count is printed"
assert_contains "$OUT" "health checks: 1 failed" "log_err repeats the count"
assert_not_contains "$OUT" "aborted unexpectedly" "an expected failure is not an unexpected abort"
OUT="$(run_ctl test 2>&1)"; RC=$?
assert_ne "0" "$RC" "test exits non-zero on the same fail"
assert_contains "$OUT" "Unknown source refused FAIL" "test prints the fail"
assert_contains "$OUT" "Configured listeners" "test also prints the later checks"
assert_not_contains "$OUT" "aborted unexpectedly" "test does not hide the table"

# a failure in the middle does not stop the rest of the suite
printf 'api.github.com\t500\nraw.githubusercontent.com\t200\ncli/cli/releases/latest\t200\ncloudflare.com\t200\ngithub.com\t200\nexample.com\t403\ndeb.debian.org\t200\n' \
  > "$STUB_STATE/curl/rules"
set_probe 0 403
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_ne "0" "$RC" "a mid-suite fail exits non-zero"
assert_contains "$OUT" "GitHub API" "the failing check is printed"
assert_contains "$OUT" "GitHub Raw" "the next check is still printed"
assert_contains "$OUT" "Policy audit" "a check after the failure is still printed"
assert_contains "$OUT" "Configured listeners" "the last check is still printed"
assert_contains "$OUT" "health checks:" "the summary is printed"
assert_not_contains "$OUT" "aborted unexpectedly" "a mid-suite fail does not abort before the table"

# curl 7, the other production-shaped transport failure
set_probe 7 000
printf 'api.github.com\t200\nraw.githubusercontent.com\t200\ncli/cli/releases/latest\t200\ncloudflare.com\t200\ngithub.com\t200\nexample.com\t403\ndeb.debian.org\t200\n' \
  > "$STUB_STATE/curl/rules"
OUT="$(run_ctl test 2>&1)"; RC=$?
assert_eq "0" "$RC" "curl 7 does not fail the suite"
assert_contains "$OUT" "Unknown source refused WARN" "curl 7 is a warning"
assert_not_contains "$OUT" "000000" "curl 7 does not produce 000000"

# -----------------------------------------------------------------------------
t_begin "client status uses the same result printer"
sandbox_teardown
sandbox_setup
load_project_libs
UPSTREAM="https://gh.smartproxy.test:8443"
stub_register_unit squid 1
stub_register_unit vps-gateway-manager-client.service 0
stub_add_port "127.0.0.1:3128"
stub_add_port "127.0.0.1:3129"
stub_set_access_log "$GP_ROOT/var/log/vps-gateway-manager/access.log"
cat > "$STUB_STATE/ips" <<'EOF'
2: eth0    inet 212.135.36.99/24 scope global eth0
3: eth0    inet6 2a06:a005:ad:fffd::89/64 scope global eth0
EOF
stub_add_host gh.smartproxy.test 203.0.113.10 2001:db8::10
mkdir -p "$GP_ROOT/etc/squid" "$GP_ROOT/etc/profile.d" "$GP_ROOT/etc/sudoers.d" "$GP_ROOT/etc/ssl/certs"
printf '# unrelated\nhttp_port 3128\n' > "$GP_ROOT/etc/squid/squid.conf"
printf -- '-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n' \
  > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"
OUT="$(run_install client --upstream "$UPSTREAM" --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "sandbox client install succeeds"
OUT="$(run_ctl status 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "client status exits 0 when nothing failed"
assert_contains "$OUT" "Role              client" "client status names the role"
assert_contains "$OUT" "health checks:" "client status prints the summary"
assert_contains "$OUT" "Git smart HTTP" "a skipped check is still printed"
assert_contains "$OUT" "a warning or a skip is not a pass" "the sandbox skip is not presented as a full pass"
assert_not_contains "$OUT" "aborted unexpectedly" "a passing client status is not an abort"
printf 'api.github.com\t000\nraw.githubusercontent.com\t200\ncli/cli/releases/latest\t200\ncloudflare.com\t200\ngithub.com\t200\nexample.com\t200\ndeb.debian.org\t200\n' \
  > "$STUB_STATE/curl/rules"
OUT="$(run_ctl test 2>&1)"; RC=$?
assert_ne "0" "$RC" "client test exits non-zero when a route check fails"
assert_contains "$OUT" "GitHub API" "the failing client check is printed"
assert_contains "$OUT" "Direct Internet" "a later client check is still printed"
assert_contains "$OUT" "health checks:" "client test prints the failure count"
assert_not_contains "$OUT" "aborted unexpectedly" "a client health failure is not an unexpected abort"

sandbox_teardown
t_summary
