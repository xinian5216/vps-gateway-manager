#!/usr/bin/env bash
# =============================================================================
# TEMPORARY EXPERIMENT (P0.5 evidence only) - delete before merge.
#
# Question: can a curl-native HTTPS-proxy probe replace the raw
# `openssl s_client` CONNECT probe for upstream candidate selection?
#
# Prove, inside the same real-gateway shape as 05-client-family.sh:
#   1. the proxy connection is PINNED to the --resolve address (both
#      directions: pin-to-live works, pin-to-dead fails although DNS is live),
#   2. TLS verification is against the LOGICAL name, not the IP (the gateway
#      certificate carries DNS SANs and NO IP SANs; an IP-as-proxy-host probe
#      must fail name verification),
#   3. the success shape is: rc=0 connect=200 final=200,
#   4. the negatives separate cleanly by rc + stderr + http_connect:
#      wrong hostname / self-signed / expired / dead candidate / CONNECT 403.
#
# Nothing is implemented here: no classification code, no product changes.
# Every case records: curl exit code, stderr, http_connect, http_code.
# =============================================================================
set -u

echo "== distro: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") =="
echo "== curl:   $(curl --version | head -n1) =="
echo "== openssl:$(openssl version) =="

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq squid-openssl curl ca-certificates iproute2 openssl >/dev/null 2>&1

# Scope-global v6 test addresses (CAP_NET_ADMIN), like 05.
ip addr add 2001:db8::1/128 dev lo 2>&1 | sed 's/^/  ip: /' || true
ip addr add 2001:db8::2/128 dev lo 2>&1 | sed 's/^/  ip: /' || true
echo "--- ip -6 addr show dev lo ---"
ip -6 -o addr show dev lo

W=/tmp/exp
C="$W/certs"
rm -rf "$W"
mkdir -p "$C" "$W/log" "$W/spool"
cd "$C" || exit 1

# --- certificates ------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 \
  -subj "/CN=exp CA" -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

# name <SANs> [days]
make_cert() {
  local name="$1" san="$2" days="${3:-30}" rc=0
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" \
    -subj "/CN=exp" >/dev/null 2>&1 || return 1
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out "$name.crt" -days "$days" -extfile "$name.ext" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != "0" ]; then
    echo "  cert generation FAILED for $name (days=$days) rc=$rc"
    return 1
  fi
  cat "$name.crt" ca.pem > "$name.fullchain.pem"
  echo "  cert ok: $name SANs=$san days=$days"
  return 0
}

# The healthy gateway certificate carries DNS SANs ONLY - no IP SAN. If the
# probe verified the connect IP instead of the URL name, this could never pass.
make_cert gw "DNS:gh-v6only.test,DNS:gh-v4only.test,DNS:gh-dual.test"
make_cert wrong "DNS:gh-other.test"
# Self-signed with the CORRECT name: failure then means trust, not naming.
openssl req -x509 -newkey rsa:2048 -nodes -keyout ss.key -out ss.crt -days 30 \
  -subj "/CN=gh-v6only.test" -addext "subjectAltName=DNS:gh-v6only.test" >/dev/null 2>&1
echo "  cert ok: ss (self-signed, name matches)"
# Expired with the CORRECT name: failure then means expiry.
EXPIRED_OK=0
make_cert expired "DNS:gh-expired.test" 0 && EXPIRED_OK=1

# --- the real gateway (same shape as 05-client-family.sh) --------------------
cat > "$W/squid.conf" <<EOF
visible_hostname exp-gateway
pid_filename $W/squid.pid
coredump_dir $W/spool
cache_effective_user proxy
cache_effective_group proxy
access_log $W/log/access.log
cache_log $W/log/cache.log
buffered_logs off
cache deny all
https_port 127.0.0.2:18443 tls-cert=$C/gw.fullchain.pem tls-key=$C/gw.key
https_port [2001:db8::1]:18443 tls-cert=$C/gw.fullchain.pem tls-key=$C/gw.key
https_port 127.0.0.4:18443 tls-cert=$C/wrong.fullchain.pem tls-key=$C/wrong.key
https_port 127.0.0.5:18443 tls-cert=$C/ss.crt tls-key=$C/ss.key
https_port 127.0.0.6:18443 tls-cert=$C/expired.fullchain.pem tls-key=$C/expired.key
acl gsp_test_src src 127.0.0.1/32 127.0.0.2/32 2001:db8::1/128 2001:db8::2/128 ::1/128
acl gsp_safe_ports port 80 443
acl gsp_ssl_ports port 443
acl gsp_connect method CONNECT
acl github_dst dstdomain .github.com .githubusercontent.com .githubassets.com ghcr.io .github.io
http_access deny !gsp_safe_ports
http_access deny gsp_connect !gsp_ssl_ports
http_access allow gsp_test_src gsp_connect gsp_ssl_ports github_dst
http_access deny all
EOF
chown -R proxy:proxy "$W" 2>/dev/null || true
chmod 0640 "$C"/*.key 2>/dev/null || true

squid -k parse -f "$W/squid.conf" >/dev/null 2>&1 && echo "gateway config parses" || echo "GATEWAY CONFIG FAILED TO PARSE"
squid -f "$W/squid.conf" -N -d1 >"$W/log/stdout.log" 2>&1 &
SQ=$!
i=0
while [ "$i" -lt 20 ]; do
  ss -H -ltn | grep -q ':18443' && break
  sleep 1; i=$((i+1))
done
echo "--- listeners on 18443 ---"
ss -H -ltn | grep 18443 | sed 's/^/  /'

# DNS answers (bind mounts: append only, never sed -i).
cat >> /etc/hosts <<'EOF'
2001:db8::1 gh-v6only.test
127.0.0.2 gh-v4only.test
2001:db8::1 gh-dual.test
127.0.0.6 gh-expired.test
EOF

SBUNDLE="$W/ca-and-system.pem"
{ cat /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; cat "$C/ca.pem"; } > "$SBUNDLE"

# --- probe harness -----------------------------------------------------------
probe() {
  # probe <label> <target-url> <curl args...>
  local label="$1" target="$2"; shift 2
  local out rc=0
  echo
  echo "=============================================================="
  echo "CASE: $label"
  echo "ARGS: $*"
  echo "TARG: $target"
  out="$(curl -sS -v -o /dev/null "$@" --connect-timeout 5 --max-time 15 \
        -w 'RESULT connect=%{http_connect} final=%{http_code}' \
        "$target" 2>&1)" || rc=$?
  echo "rc=$rc"
  echo "--- evidence (connect / TLS / error lines) ---"
  printf '%s\n' "$out" | grep -E '^\* *(Trying|Connected to|CONNECT |HTTP/|SSL connection|TLSv|subject:|start date:|expire date:|issuer:|SSL certificate|error|curl:)|^RESULT' | sed 's/^/  /' || true
  echo "--- tail ---"
  printf '%s\n' "$out" | tail -n 6 | sed 's/^/  /'
}

API="https://api.github.com/rate_limit"

echo
echo "################ POSITIVE / PINNING ################"
probe "P1 v6 pin, bracketed form (expect connect=200 final=200)" "$API" \
  --proxy https://gh-v6only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v6only.test:18443:[2001:db8::1]'
probe "P2 v6 pin, unbracketed form (form support check)" "$API" \
  --proxy https://gh-v6only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v6only.test:18443:2001:db8::1'
probe "P3 v4 pin mirror (expect connect=200 final=200)" "$API" \
  --proxy https://gh-v4only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v4only.test:18443:127.0.0.2'
probe "P4 pin-to-DEAD although DNS is live -> pin governs (expect transport fail)" "$API" \
  --proxy https://gh-v6only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v6only.test:18443:[2001:db8::9]'
probe "P5 IP as proxy host must FAIL name verification (gw cert has no IP SAN)" "$API" \
  --proxy 'https://[2001:db8::1]:18443' --proxy-cacert "$SBUNDLE"

echo
echo "################ TLS NEGATIVES ################"
probe "N1 wrong hostname cert (SAN=gh-other.test)" "$API" \
  --proxy https://gh-v6only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v6only.test:18443:127.0.0.4'
probe "N2 self-signed, name matches -> trust failure" "$API" \
  --proxy https://gh-v6only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v6only.test:18443:127.0.0.5'
if [ "$EXPIRED_OK" = "1" ]; then
  probe "N3 expired cert, name matches -> expiry failure" "$API" \
    --proxy https://gh-expired.test:18443 --proxy-cacert "$SBUNDLE" \
    --resolve 'gh-expired.test:18443:127.0.0.6'
else
  echo
  echo "CASE: N3 expired cert - SKIPPED (cert generation failed on this openssl)"
fi

echo
echo "################ TRANSPORT / AUTHORISATION ################"
probe "T1 dead candidate (nothing on 127.0.0.8:18443) -> transport" "$API" \
  --proxy https://gh-v4only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v4only.test:18443:127.0.0.8'
probe "A1 proxy CONNECT denied (example.com not in github_dst) -> http_connect=403" "https://example.com/" \
  --proxy https://gh-v6only.test:18443 --proxy-cacert "$SBUNDLE" \
  --resolve 'gh-v6only.test:18443:[2001:db8::1]'

echo
echo "################ gateway access.log (squid side) ################"
tail -n 12 "$W/log/access.log" 2>/dev/null | sed 's/^/  /'

echo
echo "################ classification mapping (observation only) ################"
cat <<'EOF'
  rc=0  + http_connect=200 + final=200        => PASS
  http_connect=403/407                       => REACHED BUT REFUSED
  curl TLS verify error (rc 51/60/77, stderr
    "SSL: no alternative certificate subject
     name" / "self-signed" / "certificate has
     expired" / "unable to get local issuer") => CERTIFICATE VERIFICATION FAILED
  rc=7/28 (refused/timeout/unreachable)      => TRANSPORT UNAVAILABLE
  anything else                              => REACHED / UNEXPECTED
EOF

kill "$SQ" 2>/dev/null || true
echo "== experiment finished =="
