#!/usr/bin/env bash
# =============================================================================
# unit test :: client install (local smart routing proxy)
#
# Verifies:
#   * the local proxy is fully independent (own config, pid, logs, unit)
#   * it listens on loopback only
#   * /etc/profile.d merges NO_PROXY instead of replacing it
#   * the sudoers drop-in is validated with visudo before installation
#   * git is configured for GitHub only (never a global http.proxy)
#   * the distribution squid unit is not used and not disturbed
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

UPSTREAM="https://gh.smartproxy.test:8443"
stub_register_unit squid 1
# The client unit exists on a real host (installed by install.sh) and is managed
# by systemd; the stub mirrors that so the systemd reload path is exercised.
stub_register_unit vps-gateway-manager-client.service 0
stub_add_port "127.0.0.1:3128"
# The local proxy port must look "in use" to the ss stub, and the curl stub
# writes Squid-like access-log lines so the routing checks have evidence.
stub_add_port "127.0.0.1:3129"
stub_set_access_log "$GP_ROOT/var/log/vps-gateway-manager/access.log"

# The install now probes the upstream per address family before touching the
# host (P0.5): the sandbox needs a dual-stack egress and DNS answers.
cat > "$STUB_STATE/ips" <<'EOF'
2: eth0    inet 212.135.36.99/24 scope global eth0
3: eth0    inet6 2a06:a005:ad:fffd::89/64 scope global eth0
EOF
stub_add_host gh.smartproxy.test 203.0.113.10 2001:db8::10

# An unrelated pre-existing squid config that must never be touched.
mkdir -p "$GP_ROOT/etc/squid"
printf '# unrelated distribution config\nhttp_port 3128\n' > "$GP_ROOT/etc/squid/squid.conf"
DISTRO_SUM="$(gp_sha256 "$GP_ROOT/etc/squid/squid.conf")"

# An existing NO_PROXY the operator already relies on.
mkdir -p "$GP_ROOT/etc/profile.d" "$GP_ROOT/etc/sudoers.d" "$GP_ROOT/etc/ssl/certs"
printf 'export NO_PROXY="agent.example.com,db.example.com"\n' > "$GP_ROOT/etc/profile.d/00-company.sh"
mkdir -p "$GP_ROOT/etc"
printf 'NO_PROXY="legacy.example.net"\n' > "$GP_ROOT/etc/environment"
# The system trust store (the real host has this; the sandbox needs one).
printf -- '-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n' > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"

# -----------------------------------------------------------------------------
t_begin "client dry-run changes nothing"
OUT="$(run_install client --upstream "$UPSTREAM" --dry-run --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "dry-run exits successfully"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/role" "no role written"
assert_file_absent "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" "no squid config written"
assert_file_absent "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" "no unit written"
assert_eq "" "$(stub_systemd_actions)" "no service action in dry-run"

# -----------------------------------------------------------------------------
t_begin "client install"
OUT="$(run_install client --upstream "$UPSTREAM" --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "install exits successfully"
assert_contains "$OUT" 'client install complete' "install reported completion"

t_begin "independent local instance"
assert_eq "client" "$(cat "$GP_ROOT/etc/vps-gateway-manager/role" | tr -d '[:space:]')" "role is client"
assert_eq "$UPSTREAM" "$(conf_get "$GP_ROOT/etc/vps-gateway-manager/client.conf" upstream)" "upstream recorded"
assert_eq "3129" "$(conf_get "$GP_ROOT/etc/vps-gateway-manager/client.conf" local_port)" "local port recorded"
assert_eq "$DISTRO_SUM" "$(gp_sha256 "$GP_ROOT/etc/squid/squid.conf")" "the distribution squid.conf was not touched"
assert_file_exists "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" "dedicated squid config created"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" 'http_port 127\.0\.0\.1:3129' "listens on loopback"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" 'cache_peer gh\.smartproxy\.test parent 8443' "parent proxy configured"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" 'tls tls-cafile=' "TLS to the parent enabled"
assert_file_not_contains "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" 'DONT_VERIFY' "no verification bypass"
assert_file_not_contains "$GP_ROOT/etc/vps-gateway-manager/client-squid.conf" 'http_port 3128' "does not reuse the distribution port"

t_begin "unit file"
assert_file_exists "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" "dedicated unit installed"
assert_file_contains "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" \
  "ExecStart=.*-f $GP_ROOT/etc/vps-gateway-manager/client-squid.conf" "unit runs our config"
assert_file_not_contains "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service" '^Conflicts=' "does not stop other services"
assert_contains "$(stub_systemd_actions)" 'started vps-gateway-manager-client.service' "our unit was started"
assert_contains "$(stub_systemd_actions)" 'enabled vps-gateway-manager-client.service' "our unit was enabled"
assert_not_contains "$(stub_systemd_actions)" 'stopped squid' "the distribution squid unit was left alone"

t_begin "shell environment merges NO_PROXY"
PROFILE="$GP_ROOT/etc/profile.d/vps-gateway-manager.sh"
assert_file_exists "$PROFILE" "profile.d file created"
assert_file_contains "$PROFILE" 'HTTP_PROXY="http://127\.0\.0\.1:3129"' "HTTP_PROXY set to the local proxy"
assert_file_contains "$PROFILE" 'HTTPS_PROXY="http://127\.0\.0\.1:3129"' "HTTPS_PROXY set to the local proxy"
assert_file_contains "$PROFILE" 'agent\.example\.com' "existing profile.d NO_PROXY preserved"
assert_file_contains "$PROFILE" 'legacy\.example\.net' "existing /etc/environment NO_PROXY preserved"
assert_file_contains "$PROFILE" '127\.0\.0\.1' "loopback is always in NO_PROXY"
assert_file_contains "$PROFILE" '169\.254\.169\.254' "metadata endpoint is always in NO_PROXY"
assert_file_contains "$PROFILE" 'db\.example\.com' "all existing entries are kept"

t_begin "sudoers drop-in is validated"
SUDOERS="$GP_ROOT/etc/sudoers.d/vps-gateway-manager"
assert_file_exists "$SUDOERS" "sudoers drop-in installed"
assert_file_contains "$SUDOERS" 'env_keep \+= "HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy"' "only proxy variables are kept"
assert_contains "$(cat "$STUB_STATE/visudo/calls.log" 2>/dev/null)" '-cf' "visudo -cf was called before installing"

t_begin "git configured for GitHub only"
if have git; then
  GITCFG="$HOME/.gitconfig"
  assert_file_exists "$GITCFG" "gitconfig created for the maintenance user"
  assert_file_contains "$GITCFG" '^\[http "https://github\.com"\]' "GitHub-only section written"
  assert_file_contains "$GITCFG" '^	proxy = http://127\.0\.0\.1:3129$' "proxy points at the local smart proxy"
  assert_eq "1" "$(grep -c 'proxy = ' "$GITCFG")" "exactly one proxy entry"
  assert_file_not_contains "$GITCFG" '^\[http\]$' "no site-wide http section"
  assert_file_not_contains "$GITCFG" '^\[https\]$' "no site-wide https section"
else
  t_skip "git is not installed in this environment"
fi

t_begin "upstream validation"
OUT="$(run_install client --upstream "http://gh.smartproxy.test:8443" --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "a plaintext upstream is refused by default"
assert_contains "$OUT" 'without TLS' "the refusal explains why"
OUT="$(run_install client --upstream "https://user:pass@gh.smartproxy.test:8443" --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "credentials in the upstream URL are refused"

t_begin "idempotent re-install"
PROFILE_SUM="$(gp_sha256 "$PROFILE")"
OUT="$(run_install client --upstream "$UPSTREAM" --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "second install exits successfully"
assert_eq "$PROFILE_SUM" "$(gp_sha256 "$PROFILE")" "profile.d unchanged"
assert_eq "1" "$(grep -c '^ExecStart=' "$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service")" "unit not duplicated"
assert_eq "1" "$(grep -c '^HTTP_PROXY=' "$PROFILE")" "single proxy assignment"
NO_PROXY_LINE="$(grep '^NO_PROXY=' "$PROFILE")"
assert_eq "1" "$(printf '%s' "$NO_PROXY_LINE" | grep -o 'agent\.example\.com' | wc -l | tr -d ' ')" "NO_PROXY entry not duplicated"
assert_eq "1" "$(printf '%s' "$NO_PROXY_LINE" | grep -o 'legacy\.example\.net' | wc -l | tr -d ' ')" "second NO_PROXY entry not duplicated"

t_begin "status output"
OUT="$(run_ctl status 2>&1)"; RC=$?
assert_eq "0" "$RC" "status exits successfully"
assert_contains "$OUT" 'Role              client' "status shows the role"
assert_contains "$OUT" 'Local proxy       127.0.0.1:3129' "status shows the local proxy"
assert_contains "$OUT" "$UPSTREAM" "status shows the upstream"

sandbox_teardown
t_summary
