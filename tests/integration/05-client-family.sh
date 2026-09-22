#!/usr/bin/env bash
# =============================================================================
# integration test :: client upstream address-family reliability (P0.5)
#
# The London pilot failure this suite pins down: a dual-stack upstream hostname
# with a blackholed IPv4 path produced random HIER_NONE/000 for GitHub API/Raw
# through `cache_peer <hostname>`, while Release passed. The fix is
# deterministic family/candidate selection with a pinned, probe-verified peer.
#
# Everything runs against a REAL Squid gateway with per-scenario TLS listeners
# on loopback-only addresses (127.0.0.2/3/4/5/6, 2001:db8::1/2), and /etc/hosts
# provides the DNS answers per scenario hostname:
#
#   dual healthy    gh-dual.test     A=127.0.0.2        AAAA=2001:db8::1
#   IPv4 broken     gh-v6only.test   A=127.0.0.9 (dead) AAAA=2001:db8::1
#   IPv6 broken     gh-v4only.test   A=127.0.0.2        AAAA=2001:db8::9 (dead)
#   both broken     gh-none.test     A=127.0.0.9 (dead) AAAA=2001:db8::9 (dead)
#   candidate 1 dead gh-cand.test    A=127.0.0.8 (dead) A=127.0.0.3
#   wrong cert name gh-badname.test  A=127.0.0.4        (cert SAN=gh-other.test)
#   self-signed     gh-selfsigned.test A=127.0.0.5
#   expired         gh-expired.test  A=127.0.0.6        (CA-issued, -days 0)
#
# Scenarios (each with a fresh client install into the sandbox):
#   A  dual healthy     -> hostname mode, install PASS, parent/direct routing
#   B  IPv4 broken      -> selected family 6, pinned peer, API/Raw/Release
#                          through the parent (NO HIER_NONE/000), direct DIRECT,
#                          git smart HTTP, status names the broken layer,
#                          upstream refresh: no-op then transactional change
#   C  IPv6 broken      -> mirror of B (family 4)
#   D  both broken      -> installer fails BEFORE any change and before any
#                          migration (a fake Komari unit stays byte-identical)
#   E  candidate failover -> the dead first candidate is skipped
#   F  TLS with a literal peer: correct cert PASS, wrong hostname FAIL,
#      self-signed FAIL, expired FAIL (never -k/--insecure/DONT_VERIFY_*)
#
# Requires: Linux, root, squid-openssl, internet access to api.github.com.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

integ_require
integ_setup
trap 'p05_teardown' EXIT

integ_skip_if_offline https://api.github.com/rate_limit

TLS_PORT=18443
CERT_DIR="$INTEG_WORK/certs"
STATE_DIR="$GP_ROOT/etc/vps-gateway-manager"
CLIENT_CONF="$STATE_DIR/client.conf"
CLIENT_SQUID_CONF="$STATE_DIR/client-squid.conf"
CLIENT_UNIT="$GP_ROOT/etc/systemd/system/vps-gateway-manager-client.service"
CLIENT_ACCESS="$GP_ROOT/var/log/vps-gateway-manager/access.log"
GW_CONF="$GP_ROOT/etc/squid/gateway.conf"
GW_LOG_DIR="$GP_ROOT/var/log/squid-gateway"

V6_GOOD=2001:db8::1
V6_GOOD2=2001:db8::2
V4_GOOD=127.0.0.2
V4_GOOD2=127.0.0.3

p05_teardown() {
  local a
  for a in "$V6_GOOD" "$V6_GOOD2"; do ip addr del "$a/128" dev lo 2>/dev/null || true; done
  integ_teardown
}

# Loopback test addresses (the v6 ones are scope global, which is exactly what a
# real upstream family needs to be classified as usable).
for a in "$V6_GOOD" "$V6_GOOD2"; do
  ip addr add "$a/128" dev lo 2>/dev/null || true
done

printf 'squid: %s (%s)\n' "$SQUID_VERSION" "$SQUID_FLAVOR"
printf 'work dir: %s\n' "$INTEG_WORK"

mkdir -p "$CERT_DIR" "$STATE_DIR" "$GW_LOG_DIR" "$GP_ROOT/run" "$GP_ROOT/etc/squid" \
         "$GP_ROOT/etc/profile.d" "$GP_ROOT/etc/sudoers.d"
integ_fix_perms

# -----------------------------------------------------------------------------
# Certificates: one trusted test CA and per-scenario gateway certificates
# -----------------------------------------------------------------------------
integ_make_ca "$CERT_DIR" || { printf 'could not create a test CA\n'; exit 1; }

# The "healthy" gateway certificate covers every scenario hostname that must
# verify, on both address families.
make_multi_cert() {
  local name="$1" san="$2"
  openssl req -newkey rsa:2048 -nodes -keyout "$CERT_DIR/$name.key" \
    -out "$CERT_DIR/$name.csr" -subj "/CN=gh-dual.test" >/dev/null 2>&1 || return 1
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san" > "$CERT_DIR/$name.ext"
  openssl x509 -req -in "$CERT_DIR/$name.csr" -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial -out "$CERT_DIR/$name.crt" -days 30 -extfile "$CERT_DIR/$name.ext" >/dev/null 2>&1 || return 1
  cat "$CERT_DIR/$name.crt" "$CERT_DIR/ca.pem" > "$CERT_DIR/$name.fullchain.pem"
  return 0
}

make_multi_cert gateway "DNS:gh-dual.test,DNS:gh-v6only.test,DNS:gh-v4only.test,DNS:gh-cand.test,IP:127.0.0.2,IP:127.0.0.3,IP:2001:db8:0:0:0:0:0:1,IP:2001:db8:0:0:0:0:0:2" \
  || { printf 'could not create the gateway certificate\n'; exit 1; }
# Wrong hostname: trusted CA, but the SAN does not cover gh-dual.test.
make_multi_cert wrongname "DNS:gh-other.test"
# Self-signed: its own issuer, matching name - must still FAIL (untrusted).
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERT_DIR/selfsign.key" \
  -out "$CERT_DIR/selfsign.crt" -days 30 -subj "/CN=gh-selfsigned.test" \
  -addext "subjectAltName=DNS:gh-selfsigned.test" >/dev/null 2>&1
cat "$CERT_DIR/selfsign.crt" > "$CERT_DIR/selfsign.fullchain.pem"
# Expired: trusted CA and correct name, but notAfter is already in the past.
openssl req -newkey rsa:2048 -nodes -keyout "$CERT_DIR/expired.key" \
  -out "$CERT_DIR/expired.csr" -subj "/CN=gh-expired.test" >/dev/null 2>&1
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:gh-expired.test\n' > "$CERT_DIR/expired.ext"
if openssl x509 -req -in "$CERT_DIR/expired.csr" -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca.key" \
     -CAcreateserial -out "$CERT_DIR/expired.crt" -days 0 -extfile "$CERT_DIR/expired.ext" >/dev/null 2>&1; then
  EXPIRED_OK=1
else
  EXPIRED_OK=0
fi
cat "$CERT_DIR/expired.crt" "$CERT_DIR/ca.pem" > "$CERT_DIR/expired.fullchain.pem" 2>/dev/null || true
sleep 1   # make sure a -days 0 certificate is really past notAfter

# -----------------------------------------------------------------------------
# The gateway: one real Squid with one TLS listener per scenario certificate
# -----------------------------------------------------------------------------
cat > "$GW_CONF" <<EOF
visible_hostname gsp-p05-gateway
pid_filename $GP_ROOT/run/gateway.pid
coredump_dir $GP_ROOT/spool
cache_effective_user $(squid_effective_user)
cache_effective_group $(squid_effective_group)
access_log $GW_LOG_DIR/access.log
cache_log $GW_LOG_DIR/cache.log
buffered_logs off
cache deny all

https_port $V4_GOOD:$TLS_PORT tls-cert=$CERT_DIR/gateway.fullchain.pem tls-key=$CERT_DIR/gateway.key
https_port $V4_GOOD2:$TLS_PORT tls-cert=$CERT_DIR/gateway.fullchain.pem tls-key=$CERT_DIR/gateway.key
https_port [$V6_GOOD]:$TLS_PORT tls-cert=$CERT_DIR/gateway.fullchain.pem tls-key=$CERT_DIR/gateway.key
https_port [$V6_GOOD2]:$TLS_PORT tls-cert=$CERT_DIR/gateway.fullchain.pem tls-key=$CERT_DIR/gateway.key
https_port 127.0.0.4:$TLS_PORT tls-cert=$CERT_DIR/wrongname.fullchain.pem tls-key=$CERT_DIR/wrongname.key
https_port 127.0.0.5:$TLS_PORT tls-cert=$CERT_DIR/selfsign.fullchain.pem tls-key=$CERT_DIR/selfsign.key
https_port 127.0.0.6:$TLS_PORT tls-cert=$CERT_DIR/expired.fullchain.pem tls-key=$CERT_DIR/expired.key

acl gsp_test_src src 127.0.0.1/32 127.0.0.2/32 127.0.0.3/32 ::1/128 $V6_GOOD/128 $V6_GOOD2/128
acl gsp_safe_ports port 80 443
acl gsp_ssl_ports port 443
acl gsp_connect method CONNECT
acl github_dst dstdomain .github.com .githubusercontent.com .githubassets.com ghcr.io .github.io
http_access deny !gsp_safe_ports
http_access deny gsp_connect !gsp_ssl_ports
http_access allow gsp_test_src gsp_connect gsp_ssl_ports github_dst
http_access allow gsp_test_src gsp_safe_ports github_dst
http_access deny all
EOF
mkdir -p "$GP_ROOT/spool" "$GW_LOG_DIR"
integ_fix_perms

assert_ok "the gateway configuration parses" squid_parse "$GW_CONF"
GW_PID="$(integ_start_squid "$GW_CONF" "$GP_ROOT/run/gateway.pid" "$GP_ROOT/gateway.out")"
assert_ok "gateway listener up on $V4_GOOD:$TLS_PORT" integ_wait_port "$TLS_PORT" 20

# DNS answers per scenario (order matters for gh-cand.test: dead candidate first).
integ_add_host_alias gh-dual.test "$V4_GOOD"
integ_add_host_alias gh-dual.test "$V6_GOOD"
integ_add_host_alias gh-v6only.test 127.0.0.9
integ_add_host_alias gh-v6only.test "$V6_GOOD"
integ_add_host_alias gh-v4only.test "$V4_GOOD"
integ_add_host_alias gh-v4only.test 2001:db8::9
integ_add_host_alias gh-none.test 127.0.0.9
integ_add_host_alias gh-none.test 2001:db8::9
integ_add_host_alias gh-cand.test 127.0.0.8
integ_add_host_alias gh-cand.test "$V4_GOOD2"
integ_add_host_alias gh-badname.test 127.0.0.4
integ_add_host_alias gh-selfsigned.test 127.0.0.5
integ_add_host_alias gh-expired.test 127.0.0.6

integ_trust_ca "$CERT_DIR/ca.pem" && printf 'test CA installed in the system trust store\n'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
reset_client() {
  systemctl stop vps-gateway-manager-client.service >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR" "$CLIENT_UNIT" \
         "$GP_ROOT/etc/profile.d/vps-gateway-manager.sh" \
         "$GP_ROOT/etc/sudoers.d/vps-gateway-manager" \
         "$GP_ROOT/var/log/vps-gateway-manager" \
         "$GP_ROOT/run/vps-gateway-manager" \
         "$GP_ROOT/var/spool/vps-gateway-manager" \
         "$GP_ROOT/usr/local/lib/vps-gateway-manager" \
         "$GP_ROOT/usr/local/sbin/ghproxyctl" \
         "$INTEG_WORK/service/vps-gateway-manager-client" 2>/dev/null || true
  mkdir -p "$STATE_DIR"
  return 0
}

# traffic_proof <label> -> asserts the GitHub/direct routing through the client
traffic_proof() {
  local label="$1" skip hier
  skip="$(integ_access_log_count "$CLIENT_ACCESS")"
  integ_wait_http_code 200 "$label: GitHub API through the local proxy" \
    --proxy "http://127.0.0.1:3129" https://api.github.com/rate_limit
  sleep 1
  hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'api.github.com' "$skip")"
  assert_contains "$hier" 'PARENT' "$label: API went through the parent ($hier)"
  assert_not_contains "$hier" 'NONE' "$label: API produced no HIER_NONE/000 ($hier)"

  skip="$(integ_access_log_count "$CLIENT_ACCESS")"
  integ_wait_http_code 206 "$label: GitHub Raw through the local proxy" \
    --proxy "http://127.0.0.1:3129" -r 0-1024 https://raw.githubusercontent.com/git/git/master/README.md
  sleep 1
  hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'raw.githubusercontent.com' "$skip")"
  assert_contains "$hier" 'PARENT' "$label: Raw went through the parent ($hier)"
  assert_not_contains "$hier" 'NONE' "$label: Raw produced no HIER_NONE/000 ($hier)"

  skip="$(integ_access_log_count "$CLIENT_ACCESS")"
  CODE="$(integ_curl_code --proxy "http://127.0.0.1:3129" -r 0-1024 -L \
    https://github.com/git/git/archive/refs/heads/master.tar.gz)"
  if [ "$CODE" = "200" ] || [ "$CODE" = "206" ]; then
    t_ok "$label: GitHub Release via the parent (HTTP $CODE)"
  else
    t_fail "$label: GitHub Release failed (HTTP $CODE)"
  fi
  sleep 1
  hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'github.com' "$skip")"
  assert_contains "$hier" 'PARENT' "$label: Release went through the parent ($hier)"

  skip="$(integ_access_log_count "$CLIENT_ACCESS")"
  integ_wait_http_code 200 "$label: non-GitHub goes DIRECT" \
    --proxy "http://127.0.0.1:3129" https://www.cloudflare.com/cdn-cgi/trace
  sleep 1
  hier="$(integ_hierarchy_of "$CLIENT_ACCESS" 'cloudflare.com' "$skip")"
  assert_contains "$hier" 'DIRECT' "$label: cloudflare went DIRECT ($hier)"

  if have git; then
    GIT_TERMINAL_PROMPT=0 timeout 25 git -c http.proxy=http://127.0.0.1:3129 \
      -c https.proxy=http://127.0.0.1:3129 \
      ls-remote --heads https://github.com/git/git.git HEAD >/dev/null 2>&1 \
      && t_ok "$label: git smart HTTP through the parent" \
      || t_fail "$label: git smart HTTP failed"
  fi
  return 0
}

# =============================================================================A. dual healthy: verified hostname mode, full routing
# =============================================================================
t_begin "A: dual-stack healthy -> hostname mode, install passes"
reset_client
OUT="$(run_install client --upstream "https://gh-dual.test:$TLS_PORT" --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "install passes when both families work"
assert_contains "$OUT" 'both families verified usable' "the hostname mode decision is reported"
assert_eq "dual" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "state: hostname (dual-stack) mode"
assert_eq "" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: no peer pinned"
assert_file_contains "$CLIENT_SQUID_CONF" "cache_peer gh-dual.test parent $TLS_PORT" "the dual-stack hostname is the peer"
traffic_proof "A"
OUT="$(run_ctl status 2>&1)" || true
assert_contains "$OUT" 'Upstream family   hostname (dual-stack, both verified)' "status shows the hostname mode"

# =============================================================================
# B. IPv4 blackholed, IPv6 healthy: pin family 6 to a probe-verified peer
# =============================================================================
t_begin "B: IPv4 blackholed -> family 6 pinned, no HIER_NONE/000"
reset_client
OUT="$(run_install client --upstream "https://gh-v6only.test:$TLS_PORT" --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the install succeeds via the healthy family"
assert_contains "$OUT" 'upstream family 6 selected' "family 6 was selected"
assert_eq "auto" "$(conf_get "$CLIENT_CONF" upstream_family)" "state: configured family"
assert_eq "6" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "state: selected family 6"
assert_eq "$V6_GOOD" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: the peer is the probe-verified v6 address"
assert_file_contains "$CLIENT_SQUID_CONF" "^cache_peer (\\[)?$V6_GOOD(\\])? parent $TLS_PORT" "cache_peer pins the peer address"
assert_file_contains "$CLIENT_SQUID_CONF" "ssldomain=gh-v6only.test" "the certificate is verified against the logical name"
assert_file_not_contains "$CLIENT_SQUID_CONF" "cache_peer gh-v6only.test" "the dual-stack hostname is not the peer"
assert_file_not_contains "$CLIENT_SQUID_CONF" 'DONT_VERIFY' "no verification bypass is rendered"
traffic_proof "B"

OUT="$(run_ctl status 2>&1)" || true
assert_contains "$OUT" 'Upstream IPv4' "the IPv4 diagnostic exists"
assert_contains "$OUT" 'TRANSPORT UNAVAILABLE' "the broken IPv4 path is named as transport, not auth"
assert_contains "$OUT" 'Upstream family   IPv6 (pinned)' "status shows the pinned family"
assert_contains "$OUT" "Upstream peer     $V6_GOOD (TLS name: gh-v6only.test)" "status shows peer and TLS name"
assert_not_contains "$OUT" 'not authorised' "000 is never described as not authorised"

t_begin "B2: upstream refresh is a no-op while DNS is unchanged"
OUT="$(run_ctl client upstream refresh --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the refresh succeeds"
assert_contains "$OUT" 'upstream path unchanged' "the no-op is stated"
assert_eq "$V6_GOOD" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state unchanged"

t_begin "B3: upstream refresh follows a changed DNS answer, transactionally"
sed -i "s/^$V6_GOOD gh-v6only.test/$V6_GOOD2 gh-v6only.test/" /etc/hosts
OUT="$(run_ctl client upstream refresh --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the refresh succeeds"
assert_contains "$OUT" 'upstream path refreshed' "the change is applied"
assert_eq "$V6_GOOD2" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: the new peer is recorded"
assert_file_contains "$CLIENT_SQUID_CONF" "^cache_peer (\\[)?$V6_GOOD2(\\])? parent $TLS_PORT" "the config was rewritten"
assert_file_contains "$CLIENT_SQUID_CONF" 'ssldomain=gh-v6only.test' "the TLS name is preserved across a refresh"
if grep -q "systemctl reload vps-gateway-manager-client" "$INTEG_WORK/service/calls.log" 2>/dev/null; then
  t_ok "the local squid was reloaded, not restarted"
else
  t_fail "the local squid was reloaded, not restarted (calls.log: $(tail -n 3 "$INTEG_WORK/service/calls.log" 2>/dev/null | tr '\n' ' '))"
fi
traffic_proof "B3"
# restore the DNS answer for later runs
sed -i "s/^$V6_GOOD2 gh-v6only.test/$V6_GOOD gh-v6only.test/" /etc/hosts

# =============================================================================
# C. IPv6 blackholed, IPv4 healthy: pin family 4 (mirror of B)
# =============================================================================
t_begin "C: IPv6 blackholed -> family 4 pinned"
reset_client
OUT="$(run_install client --upstream "https://gh-v4only.test:$TLS_PORT" --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the install succeeds via the healthy family"
assert_contains "$OUT" 'upstream family 4 selected' "family 4 was selected"
assert_eq "4" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "state: selected family 4"
assert_eq "$V4_GOOD" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: the peer is the probe-verified v4 address"
assert_file_contains "$CLIENT_SQUID_CONF" "^cache_peer $V4_GOOD parent $TLS_PORT" "cache_peer pins the v4 peer"
assert_file_contains "$CLIENT_SQUID_CONF" 'ssldomain=gh-v4only.test' "the certificate is verified against the logical name"
traffic_proof "C"
OUT="$(run_ctl status 2>&1)" || true
assert_contains "$OUT" 'TRANSPORT UNAVAILABLE' "the broken IPv6 path is named as transport"
assert_contains "$OUT" 'Upstream family   IPv4 (pinned)' "status shows the pinned family"

# =============================================================================
# D. Both families broken: fail before any change and before any migration
# =============================================================================
t_begin "D: both families broken -> abort before install AND before migration"
reset_client
SYSD="$GP_ROOT/etc/systemd/system"
mkdir -p "$SYSD/komari-agent.service.d"
DROPIN="$SYSD/komari-agent.service.d/override.conf"
cat > "$SYSD/komari-agent.service" <<EOF
[Unit]
Description=Komari Agent
[Service]
ExecStart=/opt/komari/agent -e https://panel.example.com -t fake-token
[Install]
WantedBy=multi-user.target
EOF
cat > "$DROPIN" <<EOF
[Service]
Environment="HTTPS_PROXY=https://gh-none.test:$TLS_PORT" "HTTP_PROXY=https://gh-none.test:$TLS_PORT" "NO_PROXY=localhost,127.0.0.1,::1"
EOF
DROPIN_SUM="$(gp_sha256 "$DROPIN")"
UNIT_SUM="$(gp_sha256 "$SYSD/komari-agent.service")"

OUT="$(run_install client --upstream "https://gh-none.test:$TLS_PORT" --adopt-existing --no-git-config --yes 2>&1)"; RC=$?
assert_ne "0" "$RC" "the installer fails"
assert_contains "$OUT" 'no usable path' "the failure is named as a transport problem"
assert_contains "$OUT" 'TRANSPORT UNAVAILABLE' "000 is classified as transport"
assert_not_contains "$OUT" 'not authorised' "000 is never described as not authorised"
assert_contains "$OUT" 'Komari agent        : komari-agent' "Komari was detected (and would have been migrated on success)"
assert_file_absent "$STATE_DIR/role" "no client state was written"
assert_file_absent "$CLIENT_UNIT" "no unit was installed"
assert_file_absent "$STATE_DIR/migrations" "no migration ran"
assert_eq "$DROPIN_SUM" "$(gp_sha256 "$DROPIN")" "the Komari drop-in is byte-identical"
assert_eq "$UNIT_SUM" "$(gp_sha256 "$SYSD/komari-agent.service")" "the Komari unit is byte-identical"
if grep -qE "systemctl (start|stop|reload|restart|enable|disable) vps-gateway-manager-client" "$INTEG_WORK/service/calls.log" 2>/dev/null; then
  t_fail "the local proxy must not be touched when no family works"
else
  t_ok "no service action on the client unit"
fi
rm -rf "$SYSD/komari-agent.service" "$SYSD/komari-agent.service.d"

# =============================================================================
# E. Candidate failover inside one family
# =============================================================================
t_begin "E: the first DNS candidate is dead -> the working one is selected"
reset_client
OUT="$(run_install client --upstream "https://gh-cand.test:$TLS_PORT" --no-git-config --yes 2>&1)"; RC=$?
if [ "$RC" != "0" ]; then printf '%s\n' "$OUT" >&2; fi
assert_eq "0" "$RC" "the install succeeds via the second candidate"
assert_contains "$OUT" 'candidate 127.0.0.8' "the dead candidate was probed and reported"
assert_eq "4" "$(conf_get "$CLIENT_CONF" upstream_selected_family)" "state: family 4"
assert_eq "$V4_GOOD2" "$(conf_get "$CLIENT_CONF" upstream_peer_address)" "state: the WORKING candidate is pinned, not the DNS order"
assert_file_contains "$CLIENT_SQUID_CONF" "^cache_peer $V4_GOOD2 parent $TLS_PORT" "cache_peer uses the working candidate"
traffic_proof "E"

# =============================================================================
# F. TLS with a literal peer address stays strict
# =============================================================================
t_begin "F: TLS verification with a literal peer is strict"
CLIENT_UPSTREAM_SCHEME="https"
CLIENT_UPSTREAM_PORT="$TLS_PORT"
CLIENT_UPSTREAM_HOST="gh-dual.test"
RES="$(client_candidate_probe "$V4_GOOD")"
assert_contains "$RES" 'PASS (HTTP 200)' "a correct certificate passes ($RES)"

RC=0
RES="$(client_candidate_probe 127.0.0.4)" || RC=$?
assert_contains "$RES" 'CERTIFICATE VERIFICATION FAILED' "a wrong certificate name fails ($RES)"
assert_ne "0" "$RC" "the wrong-name probe exits non-zero"

CLIENT_UPSTREAM_HOST="gh-selfsigned.test"
RES="$(client_candidate_probe 127.0.0.5)"
assert_contains "$RES" 'CERTIFICATE VERIFICATION FAILED' "a self-signed certificate fails ($RES)"

if [ "$EXPIRED_OK" = "1" ]; then
  CLIENT_UPSTREAM_HOST="gh-expired.test"
  RES="$(client_candidate_probe 127.0.0.6)"
  assert_contains "$RES" 'CERTIFICATE VERIFICATION FAILED' "an expired certificate fails ($RES)"
else
  t_skip "expired certificate could not be generated with this openssl"
fi

assert_file_not_contains "$CLIENT_SQUID_CONF" 'DONT_VERIFY_PEER' "no DONT_VERIFY_PEER anywhere"
assert_file_not_contains "$CLIENT_SQUID_CONF" 'DONT_VERIFY_DOMAIN' "no DONT_VERIFY_DOMAIN anywhere"

# -----------------------------------------------------------------------------
integ_dump_logs "gateway access.log" "$GW_LOG_DIR/access.log" 10
integ_dump_logs "client access.log" "$CLIENT_ACCESS" 10
integ_dump_logs "client cache.log" "$GP_ROOT/var/log/vps-gateway-manager/cache.log" 15
p05_teardown
trap - EXIT
t_summary
