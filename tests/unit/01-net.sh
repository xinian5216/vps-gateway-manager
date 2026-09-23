#!/usr/bin/env bash
# =============================================================================
# unit test :: address, domain and URL validation
#
# The security model depends on this file: an exact /32 or /128 source is the
# only thing that ever authorises a client, and shared CDN suffixes must never
# be accepted as a destination.
# =============================================================================
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
sandbox_setup
load_project_libs

# -----------------------------------------------------------------------------
t_begin "IPv4 normalisation"
assert_eq "203.0.113.10/32" "$(normalize_client_cidr '203.0.113.10')" "bare IPv4 becomes /32"
assert_eq "203.0.113.10/32" "$(normalize_client_cidr '203.0.113.10/32')" "explicit /32 is kept"
assert_eq "8.8.4.4/32" "$(normalize_client_cidr ' 8.8.4.4 ')" "whitespace tolerated"
assert_rc_fails "IPv4 with a /24 prefix is rejected" normalize_client_cidr '203.0.113.0/24'
assert_rc_fails "IPv4 with a /16 prefix is rejected" normalize_client_cidr '203.0.113.0/16'
assert_rc_fails "0.0.0.0/0 is rejected" normalize_client_cidr '0.0.0.0/0'
assert_rc_fails "0.0.0.0 is rejected" normalize_client_cidr '0.0.0.0'
assert_rc_fails "255.255.255.255 is rejected" normalize_client_cidr '255.255.255.255'
assert_rc_fails "leading zeros are rejected" normalize_client_cidr '010.0.0.1'
assert_rc_fails "out-of-range octet is rejected" normalize_client_cidr '203.0.113.256'
assert_rc_fails "garbage is rejected" normalize_client_cidr 'not-an-ip'
assert_rc_fails "empty input is rejected" normalize_client_cidr ''

# -----------------------------------------------------------------------------
t_begin "IPv6 normalisation"
assert_eq "2001:db8::10/128" "$(normalize_client_cidr '2001:db8::10')" "bare IPv6 becomes /128"
assert_eq "2001:db8::10/128" "$(normalize_client_cidr '2001:db8::10/128')" "explicit /128 is kept"
assert_eq "::ffff:1.2.3.4/128" "$(normalize_client_cidr '::ffff:1.2.3.4')" "v4-mapped IPv6 accepted"
assert_rc_fails "IPv6 /64 is rejected (no shortcut)" normalize_client_cidr '2001:db8::/64'
assert_rc_fails "IPv6 /48 is rejected" normalize_client_cidr '2001:db8::/48'
assert_rc_fails "::/0 is rejected" normalize_client_cidr '::/0'
assert_rc_fails ":: is rejected" normalize_client_cidr '::'
assert_rc_fails "IPv6 multicast is rejected" normalize_client_cidr 'ff02::1'
assert_rc_fails "malformed IPv6 never becomes an ACL entry" normalize_client_cidr '1:2:3:4:5:6:7'

# -----------------------------------------------------------------------------
t_begin "IPv6 structural validation (RFC 4291 grammar)"
assert_ok "a compressed address is valid"          is_ipv6 '2001:db8::10'
assert_ok "a fully written address is valid"       is_ipv6 '2001:db8:0:1:2:3:4:5'
assert_ok "::1 is valid"                           is_ipv6 '::1'
assert_ok ":: is valid (unspecified)"              is_ipv6 '::'
assert_ok "the v4-mapped form is valid"            is_ipv6 '::ffff:1.2.3.4'
assert_ok "the v4-compatible form is valid"        is_ipv6 '::1.2.3.4'
assert_ok "an embedded tail after groups is valid" is_ipv6 '2001:db8::1.2.3.4'
assert_rc_fails "three colons are rejected"        is_ipv6 ':::'
assert_rc_fails "two :: runs are rejected"         is_ipv6 '1::2::3'
assert_rc_fails "a group longer than 4 hex digits is rejected" is_ipv6 '12345::1'
assert_rc_fails "7 groups without :: are rejected" is_ipv6 '1:2:3:4:5:6:7'
assert_rc_fails "9 groups are rejected"            is_ipv6 '1:2:3:4:5:6:7:8:9'
assert_rc_fails ":: compressing no group is rejected" is_ipv6 '1:2:3:4:5:6:7:8::'
assert_rc_fails "a leading single colon is rejected" is_ipv6 ':1:2:3:4:5:6:7'
assert_rc_fails "a trailing single colon is rejected" is_ipv6 '1:2:3:4:5:6:7:8:'
assert_rc_fails "a lone colon is rejected"         is_ipv6 ':'
assert_rc_fails "an inner ::: run is rejected"     is_ipv6 '2001::db8:::1'
assert_rc_fails "a short v4 tail is rejected"      is_ipv6 '::ffff:1.2.3'
assert_rc_fails "an out-of-range v4 tail is rejected" is_ipv6 '::ffff:256.1.1.1'
assert_rc_fails "a leading-zero v4 tail is rejected" is_ipv6 '::ffff:01.2.3.4'
assert_rc_fails "a v4 tail that is not last is rejected" is_ipv6 '1.2.3.4::'
assert_rc_fails "a zone id is rejected"            is_ipv6 'fe80::1%eth0'
assert_rc_fails "hex-colon garbage is rejected"    is_ipv6 'not:an:address'
assert_rc_fails "pure IPv4 is not IPv6"            is_ipv6 '1.2.3.4'

t_begin "IPv6 expansion handles the embedded IPv4 tail"
assert_eq "00000000000000000000ffff01020304" "$(_ipv6_expand '::ffff:1.2.3.4')" \
  "the v4-mapped form expands into two 16-bit groups"
assert_eq "00000000000000000000000001020304" "$(_ipv6_expand '::1.2.3.4')" \
  "the v4-compatible form expands correctly"
assert_eq "00000000000000000000000000000001" "$(_ipv6_expand '::1')" "::1 expands to 32 nibbles"
assert_eq "00000000000000000000000000000000" "$(_ipv6_expand '::')" ":: expands to the all-zero form"

# -----------------------------------------------------------------------------
t_begin "regression: a bash error can never hide behind a passing assertion"
# The old validator evaluated $((16#1.2.3.4)) on the dotted tail, bash printed
# "value too great for base" on stderr, and the assertion still passed. Every
# call below must be silent: rejection belongs to the validator, never to a
# bash arithmetic error.
ERRF="$SANDBOX/addr.err"
OUT="$(normalize_client_cidr '::ffff:1.2.3.4' 2>"$ERRF")"
assert_eq "::ffff:1.2.3.4/128" "$OUT" "the v4-mapped client still normalises"
assert_eq "" "$(cat "$ERRF")" "normalising a v4-mapped address emits no bash error"
rc=0
normalize_client_cidr '::ffff:256.1.1.1' > "$SANDBOX/addr.out" 2>"$ERRF" || rc=$?
assert_ne "0" "$rc" "a malformed v4 tail is rejected"
assert_no_line_matches "$(cat "$ERRF")" 'value too great for base|arithmetic|invalid number|syntax error' \
  "the malformed tail is rejected by the validator, not by bash arithmetic"
assert_contains "$(cat "$SANDBOX/addr.out" "$ERRF")" "not a valid IPv4/IPv6 address" \
  "the validator explains the rejection"
for bad in ':::' '1::2::3' '12345::1' '1:2:3:4:5:6:7' '1:2:3:4:5:6:7:8::' '1:2:3:4:5:6:7:8:' \
           ':' '2001::db8:::1' '::ffff:1.2.3' '::ffff:01.2.3.4' 'fe80::1%eth0' 'not:an:address'; do
  rc=0
  _ipv6_expand "$bad" >/dev/null 2>"$ERRF" || rc=$?
  assert_ne "0" "$rc" "_ipv6_expand rejects '$bad'"
  assert_eq "" "$(cat "$ERRF")" "_ipv6_expand rejects '$bad' silently"
done

# -----------------------------------------------------------------------------
t_begin "address scope classification"
assert_eq "public"   "$(ip_scope '203.0.113.10')" "documentation IPv4 treated as public"
assert_eq "private"  "$(ip_scope '10.0.0.5')"     "RFC1918 detected"
assert_eq "loopback" "$(ip_scope '127.0.0.1')"    "IPv4 loopback detected"
assert_eq "public"   "$(ip_scope '2001:db8::1')"  "global IPv6 classified as public"
assert_eq "private"  "$(ip_scope 'fd00::1')"      "ULA detected"
assert_eq "reserved" "$(ip_scope '::ffff:1.2.3.4')" "v4-mapped addresses are reserved space"

t_begin "client validation policy"
assert_eq "203.0.113.10/32" "$(validate_client_ip '203.0.113.10' test 0)" "public IPv4 accepted"
assert_rc_fails "private IPv4 refused without --allow-private" validate_client_ip '10.1.2.3' test 0
assert_eq "10.1.2.3/32" "$(validate_client_ip '10.1.2.3' test 1)" "private IPv4 accepted with the flag"
assert_rc_fails "loopback refused by default" validate_client_ip '127.0.0.1' test 0
assert_eq "127.0.0.1/32" "$(validate_client_ip '127.0.0.1' test 1)" "loopback accepted for tests only with the flag"

# -----------------------------------------------------------------------------
t_begin "domain validation"
assert_eq ".github.com" "$(validate_domain_entry '.github.com')" "leading dot accepted"
assert_eq "github.com"  "$(validate_domain_entry 'github.com')"  "bare host accepted"
assert_eq ".github.io"  "$(validate_domain_entry '.GitHub.IO')"  "case is normalised (lowercased)"
assert_eq ".github.io"  "$(validate_domain_entry '.github.io')"  "normalisation is applied"
assert_rc_fails "wildcards are rejected" validate_domain_entry '*.github.com'
assert_rc_fails "URLs are rejected" validate_domain_entry 'https://github.com'
assert_rc_fails "paths are rejected" validate_domain_entry 'github.com/foo'
assert_rc_fails "empty entries are rejected" validate_domain_entry ''
assert_rc_fails "a single label is rejected" validate_domain_entry 'localhost'
assert_rc_fails ".amazonaws.com is refused" validate_domain_entry '.amazonaws.com'
assert_rc_fails ".cloudfront.net is refused" validate_domain_entry '.cloudfront.net'
assert_rc_fails ".azureedge.net is refused" validate_domain_entry '.azureedge.net'
assert_rc_fails "s3.amazonaws.com is refused" validate_domain_entry 's3.amazonaws.com'
assert_eq "github-cloud.s3.amazonaws.com" "$(validate_domain_entry 'github-cloud.s3.amazonaws.com' 1)" \
  "an exact S3 bucket is allowed only with the explicit override"
assert_rc_fails "an S3 bucket is refused without the override" validate_domain_entry 'github-cloud.s3.amazonaws.com'

t_begin "GitHub release-asset hosts are unaffected by the CDN policy"
# The CDN tiers must never misfire on the hosts a normal GitHub Release
# download goes through.
assert_eq "objects.githubusercontent.com" "$(validate_domain_entry 'objects.githubusercontent.com')" \
  "a release-asset host is accepted without any override"
assert_eq "release-assets.githubusercontent.com" "$(validate_domain_entry 'release-assets.githubusercontent.com')" \
  "the newer release-asset host is accepted without any override"
assert_ok "objects.githubusercontent.com is a GitHub host"      host_is_github 'objects.githubusercontent.com'
assert_ok "release-assets.githubusercontent.com is"             host_is_github 'release-assets.githubusercontent.com'
assert_ok "codeload.github.com is a GitHub host"                host_is_github 'codeload.github.com'
assert_ok "user.github.io (Pages) is a GitHub host"             host_is_github 'user.github.io'
assert_ok "the seeded list covers the release-asset hosts" \
  domain_matches_list 'objects.githubusercontent.com' "$(gp_default_github_domains)"
assert_ok "the seeded list covers release-assets too" \
  domain_matches_list 'release-assets.githubusercontent.com' "$(gp_default_github_domains)"

t_begin "shared CDN platforms: --force can never open the platform"
assert_rc_fails ".amazonaws.com is refused even with --force" validate_domain_entry '.amazonaws.com' 1
assert_rc_fails ".cloudfront.net is refused even with --force" validate_domain_entry '.cloudfront.net' 1
assert_rc_fails "a platform root is refused even with --force" validate_domain_entry 'amazonaws.com' 1
assert_rc_fails "the shared s3 endpoint is refused even with --force" validate_domain_entry 's3.amazonaws.com' 1
assert_rc_fails "a regional s3 endpoint is refused even with --force" validate_domain_entry 's3.us-east-1.amazonaws.com' 1
assert_rc_fails "a .s3.amazonaws.com suffix is refused even with --force" validate_domain_entry '.s3.amazonaws.com' 1
assert_eq "d111111abcdef8.cloudfront.net" "$(validate_domain_entry 'd111111abcdef8.cloudfront.net' 1)" \
  "an exact CloudFront distribution is allowed with the explicit override"
assert_rc_fails "an exact distribution is refused without the override" validate_domain_entry 'd111111abcdef8.cloudfront.net'
assert_eq ".amazonaws.com" "$(validate_domain_entry '.amazonaws.com' 2)" \
  "normalisation-only mode can express a legacy entry so it can be removed"

t_begin "domain matching (Squid dstdomain semantics)"
GITHUB_LIST=".github.com
.githubusercontent.com
.githubassets.com"
assert_ok "github.com matches .github.com"  domain_matches_list 'github.com' "$GITHUB_LIST"
assert_ok "api.github.com matches"          domain_matches_list 'api.github.com' "$GITHUB_LIST"
assert_ok "codeload.github.com matches"     domain_matches_list 'codeload.github.com' "$GITHUB_LIST"
assert_ok "raw.githubusercontent.com matches" domain_matches_list 'raw.githubusercontent.com' "$GITHUB_LIST"
assert_rc_fails "example.com does not match" domain_matches_list 'example.com' "$GITHUB_LIST"
assert_rc_fails "notgithub.com does not match" domain_matches_list 'notgithub.com' "$GITHUB_LIST"
assert_rc_fails "github.com.evil.net does not match" domain_matches_list 'github.com.evil.net' "$GITHUB_LIST"

# -----------------------------------------------------------------------------
t_begin "upstream URL parsing"
assert_eq "$(printf 'gh.test.invalid\t8443\thttps\t/')" "$(parse_upstream_url 'https://gh.test.invalid:8443')" "https with port"
assert_eq "$(printf 'gh.test.invalid\t443\thttps\t/')"  "$(parse_upstream_url 'https://gh.test.invalid')" "https default port"
assert_eq "$(printf 'proxy.example.com\t3128\thttp\t/')" "$(parse_upstream_url 'http://proxy.example.com:3128/')" "http with trailing slash"
assert_eq "$(printf '2001:db8::1\t8443\thttps\t/')" "$(parse_upstream_url 'https://[2001:db8::1]:8443')" "IPv6 literal"
assert_rc_fails "missing scheme is rejected"     parse_upstream_url 'gh.test.invalid:8443'
assert_rc_fails "userinfo is rejected"           parse_upstream_url 'https://user:pass@gh.test.invalid:8443'
assert_rc_fails "a path is rejected"             parse_upstream_url 'https://gh.test.invalid:8443/proxy'
assert_rc_fails "ftp scheme is rejected"         parse_upstream_url 'ftp://gh.test.invalid:8443'
assert_rc_fails "port out of range is rejected"  parse_upstream_url 'https://gh.test.invalid:99999'

# -----------------------------------------------------------------------------
t_begin "GitHub destination policy helpers"
assert_ok "api.github.com is a GitHub host"   host_is_github 'api.github.com'
assert_ok "objects.githubusercontent.com is"  host_is_github 'objects.githubusercontent.com'
assert_rc_fails "example.com is not"          host_is_github 'example.com'
assert_ok "https://api.github.com URL"        is_github_url 'https://api.github.com/repos/x/y'
assert_rc_fails "https://example.com URL"     is_github_url 'https://example.com/x'

sandbox_teardown
t_summary
