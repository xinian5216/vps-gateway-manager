#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/firewall.sh
#
# Firewall handling. Deliberately minimal and additive:
#
#   * only UFW is managed, and only by *adding* exact /32 | /128 source rules
#     for the public proxy port;
#   * rules created by this project are tagged with a comment marker
#     ("gsp:<client>") and are the only rules this project ever deletes;
#   * pre-existing rules (even ones that look identical) are reported and left
#     untouched;
#   * `ufw reset`, `ufw --force reset`, `ufw flush` and friends are never
#     executed -- they are blocked by policy below.
# =============================================================================

if [ -n "${GP_FIREWALL_SH:-}" ]; then
  return 0
fi
GP_FIREWALL_SH=1

FW_TYPE="none"        # ufw | nftables | iptables | none
FW_ACTIVE="0"
FW_IPV6_ENABLED="0"
FW_STATUS_CACHE=""

fw_detect() {
  FW_TYPE="none"; FW_ACTIVE="0"; FW_IPV6_ENABLED="0"
  if have ufw; then
    FW_TYPE="ufw"
    if ufw status 2>/dev/null | head -n 1 | grep -qi '^Status: active'; then
      FW_ACTIVE="1"
    fi
    local default_file
    default_file="$(gp_p /etc/default/ufw)"
    if [ -r "$default_file" ] && grep -qiE '^[[:space:]]*IPV6=yes' "$default_file"; then
      FW_IPV6_ENABLED="1"
    fi
  elif have nft; then
    FW_TYPE="nftables"
  elif have iptables; then
    FW_TYPE="iptables"
  fi
  return 0
}

fw_backend_summary() {
  printf 'backend=%s active=%s ipv6=%s\n' "$FW_TYPE" "$FW_ACTIVE" "$FW_IPV6_ENABLED"
}

# Canonical rule specification, e.g.
#   allow from 203.0.113.10/32 to any port 8443 proto tcp
fw_rule_spec() {
  local cidr="$1" port="$2"
  printf 'allow from %s to any port %s proto tcp\n' "$cidr" "$port"
}

fw_rule_spec_v6() {
  local cidr="$1" port="$2"
  printf 'allow from %s to any port %s proto tcp\n' "$cidr" "$port"
}

fw_marker() { printf 'gsp:%s\n' "$1"; }

fw_status_refresh() {
  if [ "$FW_TYPE" = "ufw" ]; then
    FW_STATUS_CACHE="$(ufw status 2>/dev/null || true)"
  fi
}

# Normalise a source address for text matching ("203.0.113.10/32" -> "203.0.113.10").
fw_normalize_addr() {
  printf '%s' "$1" | sed -e 's#/32$##' -e 's#/128$##'
}

fw_spec_addr() { printf '%s' "$1" | sed -n 's/.*from \([^ ]*\) .*/\1/p'; }
fw_spec_port() { printf '%s' "$1" | sed -n 's/.*port \([0-9]*\).*/\1/p'; }

# fw_rule_exists <spec>
# Compares the normalised `ufw status` table (port column + source column), so
# it works whether the rule was created as "1.2.3.4" or "1.2.3.4/32".
fw_rule_exists() {
  local spec="$1" from port
  from="$(fw_normalize_addr "$(fw_spec_addr "$spec")")"
  port="$(fw_spec_port "$spec")"
  [ -n "$from" ] && [ -n "$port" ] || return 1
  fw_status_refresh
  printf '%s\n' "$FW_STATUS_CACHE" | awk -v p="$port" -v f="$from" '
    $1 == p"/tcp" && $2 == "ALLOW" && NF >= 3 {
      src=$3; sub(/\/32$/,"",src); sub(/\/128$/,"",src)
      if (src == f) { found=1 }
    }
    END { exit !found }
  '
}

# fw_rule_has_marker <spec> <marker>
fw_rule_has_marker() {
  local spec="$1" marker="$2" from port
  from="$(fw_normalize_addr "$(fw_spec_addr "$spec")")"
  port="$(fw_spec_port "$spec")"
  fw_status_refresh
  printf '%s\n' "$FW_STATUS_CACHE" | awk -v p="$port" -v f="$from" -v m="$marker" '
    $1 == p"/tcp" && $2 == "ALLOW" && NF >= 3 {
      src=$3; sub(/\/32$/,"",src); sub(/\/128$/,"",src)
      if (src == f && index($0, m) > 0) { found=1 }
    }
    END { exit !found }
  '
}

# fw_rule_number <spec> [marker] -> the [ n] index in `ufw status numbered`
fw_rule_number() {
  local spec="$1" marker="${2:-}" from port
  from="$(fw_normalize_addr "$(fw_spec_addr "$spec")")"
  port="$(fw_spec_port "$spec")"
  ufw status numbered 2>/dev/null | awk -v p="$port" -v f="$from" -v m="$marker" '
    {
      ob = index($0, "[")
      cb = index($0, "]")
      if (ob == 0 || cb <= ob) next
      num = substr($0, ob+1, cb-ob-1)
      gsub(/[^0-9]/, "", num)
      if (num == "") next
      if (index($0, p "/tcp") > 0 && index($0, f) > 0 && (m == "" || index($0, m) > 0)) {
        print num
        exit
      }
    }'
}

# fw_add_rule <spec> [marker]
# Adds an exact rule. Idempotent: an identical pre-existing rule is left alone.
# Prints nothing on success. Returns:
#   0 = rule added by us (rollback removes it)
#   3 = identical rule already present (not ours; nothing to undo)
fw_add_rule() {
  local spec="$1" marker="${2:-}" out rc=0
  if [ "$FW_TYPE" != "ufw" ]; then
    log_warn "firewall backend is '$FW_TYPE'; no rule added for: $spec"
    return 0
  fi
  if [ "$FW_ACTIVE" != "1" ]; then
    log_warn "ufw is inactive; skipping rule (Squid ACLs still apply): $spec"
    return 0
  fi
  if fw_rule_exists "$spec"; then
    log_info "firewall rule already present, leaving it untouched: $spec"
    return 3
  fi
  if gp_dry_run; then
    log_dry "ufw ${spec}${marker:+ comment '$marker'}"
    return 0
  fi
  # shellcheck disable=SC2086
  if [ -n "$marker" ]; then
    out="$(ufw allow $spec comment "$marker" 2>&1)" || rc=$?
  else
    out="$(ufw allow $spec 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log_err "ufw failed to add rule: $spec"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  fw_status_refresh
  if ! fw_rule_exists "$spec"; then
    log_err "ufw reported success but the rule is not visible: $spec"
    return 1
  fi
  log_info "added firewall rule: $spec"
  return 0
}

# fw_delete_rule <spec>
# Deletes a rule *by spec*. Only used for rules this project added, and only
# after fw_rule_has_marker confirmed our marker (when the backend supports it).
fw_delete_rule() {
  local spec="$1" out rc=0
  if [ "$FW_TYPE" != "ufw" ]; then
    log_warn "firewall backend is '$FW_TYPE'; nothing deleted for: $spec"
    return 0
  fi
  if ! fw_rule_exists "$spec"; then
    log_debug "firewall rule already absent: $spec"
    return 0
  fi
  if gp_dry_run; then
    log_dry "ufw delete $spec"
    return 0
  fi
  out="$(ufw --force delete $spec 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_err "ufw failed to delete rule: $spec"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  fw_status_refresh
  log_info "deleted firewall rule: $spec"
  return 0
}

# fw_delete_owned_rule <spec> <marker>
# Refuses to delete anything that does not carry our marker.
fw_delete_owned_rule() {
  local spec="$1" marker="$2" num
  if [ "$FW_TYPE" != "ufw" ] || [ "$FW_ACTIVE" != "1" ]; then
    log_debug "no managed firewall rule to delete ($FW_TYPE active=$FW_ACTIVE)"
    return 0
  fi
  if ! fw_rule_exists "$spec"; then
    log_debug "firewall rule already absent: $spec"
    return 0
  fi
  if ! fw_rule_has_marker "$spec" "$marker"; then
    log_warn "refusing to delete a firewall rule that this project did not create: $spec"
    return 4
  fi
  num="$(fw_rule_number "$spec" "$marker")"
  if [ -z "$num" ]; then
    log_warn "could not resolve the rule number for '$spec'; using spec-based delete"
    fw_delete_rule "$spec"
    return $?
  fi
  if gp_dry_run; then
    log_dry "ufw --force delete $num   # $spec ($marker)"
    return 0
  fi
  local out rc=0
  out="$(ufw --force delete "$num" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_err "ufw failed to delete rule #$num ($spec)"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  fw_status_refresh
  log_info "deleted firewall rule: $spec ($marker)"
  return 0
}

# fw_capture_state <file> — text snapshot used for backups/audit.
fw_capture_state() {
  local file="$1"
  {
    printf '# firewall state captured %s\n' "$(gp_ts_human)"
    printf '# backend: %s\n' "$(fw_backend_summary)"
    if [ "$FW_TYPE" = "ufw" ]; then
      ufw status verbose 2>&1 || true
      printf '\n# --- ufw status numbered ---\n'
      ufw status numbered 2>&1 || true
    elif have nft; then
      nft list ruleset 2>&1 || true
    elif have iptables; then
      iptables-save 2>&1 || true
    fi
  } > "$file" 2>/dev/null || true
  return 0
}

# Safety policy: hard-block destructive firewall commands anywhere in this code
# base. Any script that tries them fails loudly at review time.
fw_policy_guard() {
  local haystack="$1"
  local pattern
  for pattern in 'ufw reset' 'ufw --force reset' 'ufw flush' 'iptables -F' 'iptables -X' 'nft flush ruleset'; do
    case "$haystack" in
      *"$pattern"*)
        log_err "policy violation: refusing destructive firewall command '$pattern'"
        return 1
        ;;
    esac
  done
  return 0
}
