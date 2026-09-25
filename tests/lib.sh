#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: tests/lib.sh
#
# Test harness. Provides:
#   * assertions with a summary and a non-zero exit code on failure
#   * a sandbox (GP_ROOT) so nothing ever touches the real system
#   * command stubs (systemctl, ufw, squid, curl, openssl, ...) so the whole
#     toolchain can be driven deterministically from a unit test
#
# Unit tests run anywhere (Linux, macOS, Git Bash). Integration tests in
# tests/integration/ use the real squid binary and are only run on Linux CI.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
export REPO_ROOT TESTS_DIR
export GP_NO_COLOR=1

T_PASSED=0
T_FAILED=0
T_SKIPPED=0
T_CURRENT=""
T_FAIL_NAMES=""

t_begin() {
  T_CURRENT="$1"
  printf '\n-- %s\n' "$T_CURRENT"
}

t_ok() {
  T_PASSED=$((T_PASSED+1))
  printf '   ok   %s\n' "${1:-}"
}

t_fail() {
  T_FAILED=$((T_FAILED+1))
  T_FAIL_NAMES="$T_FAIL_NAMES
  * ${T_CURRENT}: ${1:-assertion failed}"
  printf '   FAIL %s\n' "${1:-}" >&2
}

t_skip() {
  T_SKIPPED=$((T_SKIPPED+1))
  printf '   skip %s\n' "${1:-}"
}

assert_ok() {
  # assert_ok <description> <command...>
  local desc="$1"; shift
  if "$@"; then t_ok "$desc"; else t_fail "$desc"; fi
}

assert_eq() {
  local expected="$1" actual="$2" desc="${3:-values differ}"
  if [ "$expected" = "$actual" ]; then
    t_ok "$desc"
  else
    t_fail "$desc (expected '$expected', got '$actual')"
  fi
}

assert_ne() {
  local a="$1" b="$2" desc="${3:-values should differ}"
  if [ "$a" != "$b" ]; then t_ok "$desc"; else t_fail "$desc (both '$a')"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" desc="${3:-contains}"
  case "$haystack" in
    *"$needle"*) t_ok "$desc" ;;
    *) t_fail "$desc (missing: '$needle')" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="${3:-does not contain}"
  case "$haystack" in
    *"$needle"*) t_fail "$desc (unexpectedly found: '$needle')" ;;
    *) t_ok "$desc" ;;
  esac
}

# assert_matches_line <content> <ERE> <description>
# assert_contains() is a literal substring check; this one matches a line.
assert_matches_line() {
  local content="$1" pattern="$2" desc="${3:-matches}"
  if printf '%s\n' "$content" | grep -qE -- "$pattern"; then t_ok "$desc"; else t_fail "$desc (no line matches '$pattern')"; fi
}

assert_no_line_matches() {
  local content="$1" pattern="$2" desc="${3:-no line matches}"
  if printf '%s\n' "$content" | grep -qE -- "$pattern"; then t_fail "$desc (found a line matching '$pattern')"; else t_ok "$desc"; fi
}

assert_rc() {
  local expected="$1"; shift
  local desc="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$expected" ]; then t_ok "$desc"; else t_fail "$desc (expected rc=$expected, got rc=$rc)"; fi
}

assert_rc_fails() {
  local desc="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != "0" ]; then t_ok "$desc"; else t_fail "$desc (expected failure, got success)"; fi
}

assert_file_exists() {
  local f="$1" desc="${2:-file exists: $1}"
  if [ -e "$f" ]; then t_ok "$desc"; else t_fail "$desc (missing: $f)"; fi
}

assert_file_absent() {
  local f="$1" desc="${2:-file absent: $1}"
  if [ -e "$f" ]; then t_fail "$desc (still present: $f)"; else t_ok "$desc"; fi
}

assert_file_contains() {
  local f="$1" pattern="$2" desc="${3:-file contains '$2'}"
  if [ -r "$f" ] && grep -qE -- "$pattern" "$f"; then t_ok "$desc"; else t_fail "$desc (in $f)"; fi
}

assert_file_not_contains() {
  local f="$1" pattern="$2" desc="${3:-file does not contain '$2'}"
  if [ ! -e "$f" ]; then t_ok "$desc (file absent)"; return 0; fi
  if grep -qE -- "$pattern" "$f"; then t_fail "$desc (in $f)"; else t_ok "$desc"; fi
}

assert_file_mode() {
  local f="$1" want="$2" desc="${3:-mode $2 on $1}"
  local got
  got="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
  if [ "$got" = "$want" ]; then t_ok "$desc"; else t_fail "$desc (got '$got')"; fi
}

is_linux() { [ "$(uname -s)" = "Linux" ]; }

# POSIX modes cannot be represented on Windows (Git Bash only emulates 644/755),
# so mode assertions are Linux-only and skipped elsewhere.
assert_file_mode_linux() {
  if ! is_linux; then t_skip "${3:-mode $2 on $1} (not Linux)"; return 0; fi
  assert_file_mode "$@"
}

assert_count_eq() {
  local expected="$1" actual="$2" desc="${3:-count}"
  assert_eq "$expected" "$actual" "$desc"
}

t_summary() {
  printf '\n=========================================\n'
  printf 'passed: %s   failed: %s   skipped: %s\n' "$T_PASSED" "$T_FAILED" "$T_SKIPPED"
  if [ "$T_FAILED" -gt 0 ]; then
    printf 'failures:%s\n' "$T_FAIL_NAMES"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Sandbox
# -----------------------------------------------------------------------------
SANDBOX=""
STUB_BIN=""

sandbox_setup() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  export GP_ROOT="$SANDBOX"
  export GP_ALLOW_UNSUPPORTED_OS=1
  export GP_NO_COLOR=1
  export GP_SKIP_NET_CHECKS=1
  export STUB_STATE="$SANDBOX/.stub"
  export STUB_HOME_DIR="$SANDBOX/home"
  export HOME="$SANDBOX/home"
  mkdir -p "$STUB_STATE/systemd" "$STUB_STATE/squid" "$STUB_STATE/ufw" \
           "$STUB_STATE/curl" "$STUB_STATE/openssl" "$STUB_STATE/journal" \
           "$STUB_HOME_DIR" "$SANDBOX/etc" "$SANDBOX/var/log" "$SANDBOX/run"
  : > "$STUB_STATE/ports"

  STUB_BIN="$SANDBOX/.bin"
  mkdir -p "$STUB_BIN"
  local n
  for n in systemctl ufw squid visudo; do
    cp "$TESTS_DIR/stubs/$n" "$STUB_BIN/$n"
    chmod +x "$STUB_BIN/$n"
  done
  for n in id getent runuser ss ip dpkg-query apt-get certbot journalctl systemd-analyze; do
    cp "$TESTS_DIR/stubs/helpers" "$STUB_BIN/$n"
    chmod +x "$STUB_BIN/$n"
  done
  cp "$TESTS_DIR/stubs/curl" "$STUB_BIN/curl" 2>/dev/null || true
  cp "$TESTS_DIR/stubs/openssl" "$STUB_BIN/openssl" 2>/dev/null || true
  chmod +x "$STUB_BIN"/* 2>/dev/null || true
  export PATH="$STUB_BIN:$PATH"

  # Default stub behaviour: proxy probes succeed, TLS verifies, no ports bound
  # beyond what a test adds explicitly.
  printf 'api.github.com\t200\n' > "$STUB_STATE/curl/rules"
  printf 'raw.githubusercontent.com\t200\n' >> "$STUB_STATE/curl/rules"
  printf 'cli/cli/releases/latest\t200\n' >> "$STUB_STATE/curl/rules"
  printf 'cloudflare.com\t200\n' >> "$STUB_STATE/curl/rules"
  printf 'github.com\t200\n' >> "$STUB_STATE/curl/rules"
  printf 'example.com\t403\n' >> "$STUB_STATE/curl/rules"
  printf 'deb.debian.org\t200\n' >> "$STUB_STATE/curl/rules"
  cat > "$STUB_STATE/curl/release.json" <<'EOF'
{"assets":[{"browser_download_url":"https://github.com/cli/cli/releases/download/v2.0.0/gh_2.0.0_linux_amd64.tar.gz"}]}
EOF
  printf 'Verify return code: 0 (ok)\nsubject=CN = test.invalid\nnotAfter=Dec 31 23:59:59 2030 GMT\n' > "$STUB_STATE/openssl/s_client.txt"
  return 0
}

sandbox_teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Project loading
# -----------------------------------------------------------------------------
load_project_libs() {
  export VGM_HOME="$REPO_ROOT"
  export VGM_LIB_DIR="$REPO_ROOT/lib"
  export VGM_TEMPLATES_DIR="$REPO_ROOT/templates"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/common.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/net.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/txn.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/squid.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/firewall.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/health.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/server.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/server-ops.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/client.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/migrate.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/detect.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/lock.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/update.sh"
  # shellcheck source=/dev/null
  . "$VGM_LIB_DIR/wizard.sh"
  VGM_VERSION="$(gp_load_version)"
  return 0
}

state_dir()    { printf '%s\n' "$GP_ROOT/etc/vps-gateway-manager"; }
state_file()   { printf '%s\n' "$(state_dir)/$1"; }
squid_conf_d() { printf '%s\n' "$GP_ROOT/etc/squid/conf.d"; }

# -----------------------------------------------------------------------------
# Sandbox state helpers
# -----------------------------------------------------------------------------
stub_register_unit() {
  # stub_register_unit <unit> [active] [cat-file]
  local unit="$1" active="${2:-1}" catfile="${3:-}"
  : > "$STUB_STATE/systemd/$unit.registered"
  : > "$STUB_STATE/systemd/${unit%.service}.registered"
  [ "$active" = "1" ] && touch "$STUB_STATE/systemd/$unit.active"
  if [ -n "$catfile" ]; then cp "$catfile" "$STUB_STATE/systemd/$unit.cat"; fi
  return 0
}

stub_unit_file() { printf '%s\n' "$STUB_STATE/systemd/$1"; }
stub_unit_active() { [ -f "$STUB_STATE/systemd/$1.active" ]; }
stub_unit_enabled() { [ -f "$STUB_STATE/systemd/$1.enabled" ]; }
stub_systemd_actions() { cat "$STUB_STATE/systemd/actions.log" 2>/dev/null || true; }
stub_ufw_rules() { cat "$STUB_STATE/ufw/rules" 2>/dev/null || true; }
stub_ufw_calls() { cat "$STUB_STATE/ufw/calls.log" 2>/dev/null || true; }
stub_ufw_destructive() { cat "$STUB_STATE/ufw/destructive.log" 2>/dev/null || true; }
stub_squid_calls() { cat "$STUB_STATE/squid/calls.log" 2>/dev/null || true; }

stub_add_port() { printf '%s\n' "$1" >> "$STUB_STATE/ports"; }
stub_add_host() {
  # stub_add_host <host> [address...]
  local host="$1"; shift
  mkdir -p "$STUB_STATE/hosts"
  printf '%s\n' "${@:-127.0.0.1}" > "$STUB_STATE/hosts/$host"
}

# Point the curl stub at a Squid-like access log so the routing checks can be
# exercised without a real proxy.
stub_set_access_log() {
  printf '%s\n' "$1" > "$STUB_STATE/curl/accesslog"
  mkdir -p "$(dirname "$1")" 2>/dev/null || true
  : >> "$1"
}

stub_curl_rule() {
  # stub_curl_rule <substring> <http-code>
  printf '%s\t%s\n' "$1" "$2" >> "$STUB_STATE/curl/rules"
}

stub_tls_result() {
  # stub_tls_result ok|bad
  if [ "$1" = "bad" ]; then
    printf 'Verify return code: 20 (unable to get local issuer certificate)\n' > "$STUB_STATE/openssl/s_client.txt"
  else
    printf 'Verify return code: 0 (ok)\nsubject=CN = test.invalid\nnotAfter=Dec 31 23:59:59 2030 GMT\n' > "$STUB_STATE/openssl/s_client.txt"
  fi
}

stub_make_cert() {
  # stub_make_cert <dir> [cn] -> creates fullchain.pem/privkey.pem
  local dir="$1" cn="${2:-gh.test.invalid}"
  mkdir -p "$dir"
  if ! command -v openssl >/dev/null 2>&1; then return 1; fi
  if [ -s "$dir/privkey.pem" ]; then return 0; fi
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/privkey.pem" \
    -out "$dir/fullchain.pem" -days 3650 -subj "/CN=$cn" >/dev/null 2>&1
  return $?
}

stub_make_komari() {
  # stub_make_komari <dropin-file> [proxy-url]
  local file="$1" proxy="${2:-https://gh.test.invalid:8443}"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<EOF
[Service]
Environment="HTTPS_PROXY=$proxy" "HTTP_PROXY=$proxy" "NO_PROXY=agent.example.com,db.example.com,localhost,127.0.0.1,::1"
# Endpoint and Token are managed by Komari - never touched by this project
Environment="KOMARI_ENDPOINT=https://panel.example.com"
Environment="KOMARI_TOKEN=secret-token-value"
ExecStart=/usr/local/bin/komari-agent -e https://panel.example.com -t secret-token-value
EOF
  return 0
}

# -----------------------------------------------------------------------------
# Running the CLI inside the sandbox
# -----------------------------------------------------------------------------
run_install() {
  # run_install <args...>
  bash "$REPO_ROOT/install.sh" "$@"
}

run_ctl() {
  # run_ctl <args...>
  bash "$REPO_ROOT/bin/ghproxyctl" "$@"
}
