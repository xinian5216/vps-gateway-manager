#!/usr/bin/env bash
# =============================================================================
# unit test :: migrating an existing client (Komari, xray-manager, Git, env)
#
# The migration contract:
#   * "build first, tear down later": the local proxy must be installed and
#     verified before a single component is touched
#   * only the four proxy variables and NO_PROXY change
#   * Endpoint, Token and ExecStart are never modified
#   * every change is backed up and restorable
#   * a failed verification restores the previous configuration
#   * /etc/environment needs an explicit --migrate-global-env
#   * unknown systemd units are reported, never migrated silently
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

UPSTREAM="https://gh.smartproxy.test:8443"
LOCAL="http://127.0.0.1:3129"
SYSD="$GP_ROOT/etc/systemd/system"
DROPIN_DIR="$SYSD/komari-agent.service.d"
DROPIN="$DROPIN_DIR/override.conf"
XRAYM_DIR="$GP_ROOT/etc/xray-manager"
XRAYM_FILE="$XRAYM_DIR/download_proxy"
ENVFILE="$GP_ROOT/etc/environment"
UNKNOWN="$SYSD/custom-sync.service"

stub_register_unit squid 1
stub_register_unit komari-agent 1
stub_register_unit vps-gateway-manager-client.service 0
stub_add_port "127.0.0.1:3129"
stub_set_access_log "$GP_ROOT/var/log/vps-gateway-manager/access.log"
mkdir -p "$GP_ROOT/etc/profile.d" "$GP_ROOT/etc/sudoers.d" "$GP_ROOT/etc/ssl/certs" "$XRAYM_DIR" "$DROPIN_DIR"
printf -- '-----BEGIN CERTIFICATE-----\nstub\n' > "$GP_ROOT/etc/ssl/certs/ca-certificates.crt"

# --- Komari as it exists today ------------------------------------------------
cat > "$DROPIN" <<EOF
[Service]
Environment="HTTPS_PROXY=$UPSTREAM" "HTTP_PROXY=$UPSTREAM" "NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1"
# Endpoint and token are managed by Komari itself.
Environment="KOMARI_ENDPOINT=https://panel.example.com"
Environment="KOMARI_TOKEN=super-secret-token"
ExecStart=/usr/local/bin/komari-agent -e https://panel.example.com -t super-secret-token
EOF
cat > "$SYSD/komari-agent.service" <<EOF
[Unit]
Description=Komari Agent
[Service]
Environment="HTTPS_PROXY=$UPSTREAM" "HTTP_PROXY=$UPSTREAM"
ExecStart=/usr/local/bin/komari-agent -e https://panel.example.com -t super-secret-token
EOF
{
  printf '# %s\n' "$SYSD/komari-agent.service"
  cat "$SYSD/komari-agent.service"
  printf '# %s\n' "$DROPIN"
  cat "$DROPIN"
} > "$STUB_STATE/systemd/komari-agent.cat"
printf 'Environment=HTTPS_PROXY=%s HTTP_PROXY=%s NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1\n' \
  "$UPSTREAM" "$UPSTREAM" > "$STUB_STATE/systemd/komari-agent.show"
printf '2026-09-19T00:00:00Z Github Repo 正常\n2026-09-19T00:00:01Z WebSocket connected using v2 protocol\n' \
  > "$STUB_STATE/journal/komari-agent"

# --- xray-manager, git, /etc/environment, an unknown unit ---------------------
printf '%s\n' "$UPSTREAM" > "$XRAYM_FILE"
cat > "$ENVFILE" <<EOF
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
HTTP_PROXY="$UPSTREAM"
HTTPS_PROXY="$UPSTREAM"
EOF
cat > "$UNKNOWN" <<EOF
[Service]
Environment="HTTPS_PROXY=$UPSTREAM"
ExecStart=/usr/local/bin/custom-sync --once
EOF
stub_register_unit custom-sync 1
{
  printf '# %s\n' "$UNKNOWN"
  cat "$UNKNOWN"
} > "$STUB_STATE/systemd/custom-sync.cat"
printf 'Environment=HTTPS_PROXY=%s\n' "$UPSTREAM" > "$STUB_STATE/systemd/custom-sync.show"

if have git; then
  HOME="$HOME" git config --global http.https://github.com.proxy "$UPSTREAM"
  git config --global --list >/dev/null 2>&1
fi

DROPIN_SUM="$(gp_sha256 "$DROPIN")"
XRAYM_SUM="$(gp_sha256 "$XRAYM_FILE")"
ENV_SUM="$(gp_sha256 "$ENVFILE")"
GIT_SUM="$(gp_sha256 "$HOME/.gitconfig" 2>/dev/null || printf 'none')"

# -----------------------------------------------------------------------------
t_begin "migration scan (read-only)"
run_install client --upstream "$UPSTREAM" --yes >/dev/null 2>&1   # install first
# The install itself already points git at the local proxy; put the old value
# back so the scan has something to detect (this mirrors a real host that is
# still using the remote proxy).
if have git; then
  as_user root env HOME="$HOME" git config --global http.https://github.com.proxy "$UPSTREAM"
fi
OUT="$(run_ctl migrate scan 2>&1)"; RC=$?
assert_eq "0" "$RC" "scan exits successfully"
assert_contains "$OUT" 'komari-agent' "Komari detected"
assert_contains "$OUT" 'auto-supported' "Komari is auto-supported"
assert_contains "$OUT" 'xray-manager' "xray-manager detected"
assert_contains "$OUT" 'Git config' "git configuration detected"
assert_contains "$OUT" 'custom-sync' "unknown unit detected"
assert_contains "$OUT" 'manual-review' "unknown units are marked for manual review"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "scan changed nothing"

# -----------------------------------------------------------------------------
t_begin "adopt-existing dry-run changes nothing"
OUT="$(run_install client --upstream "$UPSTREAM" --adopt-existing --dry-run --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "dry-run exits successfully"
assert_contains "$OUT" 'Komari' "dry-run reports Komari"
assert_contains "$OUT" 'Token' "dry-run mentions the token handling"
assert_not_contains "$OUT" 'super-secret-token' "the token is never printed"
assert_contains "$OUT" 'will NOT be touched' "dry-run lists what stays untouched"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "Komari drop-in untouched by dry-run"
assert_eq "$XRAYM_SUM" "$(gp_sha256 "$XRAYM_FILE")" "xray-manager untouched by dry-run"
assert_eq "$ENV_SUM" "$(gp_sha256 "$ENVFILE")" "/etc/environment untouched by dry-run"

# -----------------------------------------------------------------------------
t_begin "real migration"
OUT="$(run_install client --upstream "$UPSTREAM" --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "adoption exits successfully"

t_begin "Komari: only the proxy variables changed"
assert_file_contains "$DROPIN" 'Environment="HTTPS_PROXY=http://127\.0\.0\.1:3129' "HTTPS_PROXY points at the local proxy"
assert_file_contains "$DROPIN" 'HTTP_PROXY=http://127\.0\.0\.1:3129' "HTTP_PROXY points at the local proxy"
assert_file_contains "$DROPIN" 'NO_PROXY=.*agent\.example\.com' "NO_PROXY keeps the agent endpoint"
assert_file_contains "$DROPIN" 'NO_PROXY=.*db\.example\.com' "NO_PROXY keeps the database endpoint"
assert_file_contains "$DROPIN" 'NO_PROXY=.*localhost' "NO_PROXY keeps localhost"
assert_file_contains "$DROPIN" '169\.254\.169\.254' "NO_PROXY merged with the mandatory entries"
assert_file_contains "$DROPIN" 'KOMARI_ENDPOINT=https://panel\.example\.com' "Endpoint untouched"
assert_file_contains "$DROPIN" 'KOMARI_TOKEN=super-secret-token' "Token untouched"
assert_file_contains "$DROPIN" 'ExecStart=/usr/local/bin/komari-agent -e https://panel\.example\.com -t super-secret-token' "ExecStart untouched"
assert_file_not_contains "$DROPIN" "$UPSTREAM" "no reference to the old upstream remains"
assert_contains "$(stub_systemd_actions)" 'restarted komari-agent' "Komari was restarted"
assert_contains "$(stub_systemd_actions)" 'daemon-reload' "systemd was reloaded"

t_begin "Komari: backup + migration record"
BACKUP="$(find "$GP_ROOT/etc/vps-gateway-manager/migrations/backups" -name 'komari-*.bak' 2>/dev/null | head -n1)"
assert_file_exists "$BACKUP" "the previous drop-in was backed up"
assert_file_contains "$BACKUP" "$UPSTREAM" "the backup holds the original upstream"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/migrations/komari-komari-agent.env" 'kind=systemd-dropin' \
  "a restore record was written"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/migrations/komari-komari-agent.env" \
  'before_upstream=https://gh\.smartproxy\.test:8443' "the record keeps the previous value"

t_begin "xray-manager migrated"
assert_eq "$LOCAL" "$(cat "$XRAYM_FILE" | tr -d '[:space:]')" "download_proxy points at the local proxy"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/migrations/xray-manager-download-proxy.env" 'kind=file' \
  "xray-manager migration recorded"

t_begin "git migrated to a GitHub-only proxy"
if have git; then
  assert_file_contains "$HOME/.gitconfig" '^\[http "https://github\.com"\]' "GitHub-only section present"
  assert_file_contains "$HOME/.gitconfig" "proxy = $LOCAL" "git points at the local proxy"
  assert_file_not_contains "$HOME/.gitconfig" "$UPSTREAM" "no reference to the old upstream remains"
  assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/migrations/git-root.env" 'kind=git' "git migration recorded"
else
  t_skip "git is not installed"
fi

t_begin "/etc/environment is NOT changed without the explicit flag"
assert_eq "$ENV_SUM" "$(gp_sha256 "$ENVFILE")" "/etc/environment untouched"
assert_contains "$OUT" 'migrate-global-env' "the operator is told which flag is required"

t_begin "unknown services are never migrated automatically"
assert_file_contains "$UNKNOWN" "$UPSTREAM" "unknown unit still points at the old proxy"
assert_not_contains "$(stub_systemd_actions)" 'restarted custom-sync' "unknown unit was not restarted"
assert_contains "$OUT" 'custom-sync' "unknown unit is reported"

# -----------------------------------------------------------------------------
t_begin "explicit migration of an unknown service"
OUT="$(run_ctl migrate service custom-sync --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "explicit migration succeeds"
assert_file_contains "$UNKNOWN" 'HTTPS_PROXY=http://127\.0\.0\.1:3129' "unknown unit migrated on request"
assert_file_contains "$UNKNOWN" 'ExecStart=/usr/local/bin/custom-sync --once' "ExecStart untouched"
assert_contains "$(stub_systemd_actions)" 'restarted custom-sync' "unknown unit restarted"
run_ctl migrate restore --yes >/dev/null 2>&1

# -----------------------------------------------------------------------------
t_begin "explicit global environment migration"
OUT="$(run_install client --upstream "$UPSTREAM" --adopt-existing --migrate-global-env --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_file_contains "$ENVFILE" "HTTP_PROXY=\"$LOCAL\"" "/etc/environment migrated when asked"
assert_file_contains "$ENVFILE" '^PATH=' "unrelated lines preserved"
assert_file_contains "$GP_ROOT/etc/vps-gateway-manager/migrations/environment.env" 'kind=file' "environment migration recorded"

# -----------------------------------------------------------------------------
t_begin "restore puts everything back"
OUT="$(run_ctl migrate restore --yes 2>&1)"; RC=$?
assert_eq "0" "$RC" "restore exits successfully"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "Komari drop-in restored byte for byte"
assert_eq "$XRAYM_SUM" "$(gp_sha256 "$XRAYM_FILE")" "xray-manager restored"
assert_eq "$ENV_SUM" "$(gp_sha256 "$ENVFILE")" "/etc/environment restored"
if have git; then
  assert_eq "$GIT_SUM" "$(gp_sha256 "$HOME/.gitconfig")" "git configuration restored"
fi
assert_eq "" "$(migrate_record_list)" "no migration records left"
assert_contains "$(stub_systemd_actions)" 'restarted komari-agent' "Komari was restarted during restore"

# -----------------------------------------------------------------------------
t_begin "a failing Komari verification rolls back automatically"
# The journal now shows a proxy/TLS error: verification must fail and restore.
printf '2026-09-19T00:00:00Z Github Repo error: x509: certificate signed by unknown authority\n' \
  > "$STUB_STATE/journal/komari-agent"
OUT="$(run_install client --upstream "$UPSTREAM" --adopt-existing --yes 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_ne "0" "$RC" "adoption reports the failure"
assert_contains "$OUT" 'restoring the previous configuration' "the rollback is announced"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "Komari drop-in restored after the failure"
assert_file_not_contains "$DROPIN" "$LOCAL" "no half-migrated state remains"

sandbox_teardown
t_summary
