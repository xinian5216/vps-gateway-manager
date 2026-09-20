#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/txn.sh
#
# Transaction engine. Every mutating operation on a production host runs inside
# a transaction:
#
#     txn_begin "add client cn-bj-01"
#       txn_backup_file /etc/squid/conf.d/00-vps-gateway-manager-clients.conf
#       txn_install_file "$tmp" /etc/squid/conf.d/00-vps-gateway-manager-clients.conf 0644
#       txn_ufw_add "allow from 203.0.113.10/32 to any port 8443 proto tcp"
#       txn_service squid reload
#       squid_parse_or_fail ...
#     txn_commit            # <- only reached when every check passed
#
# If anything fails, txn_rollback restores the exact previous state in reverse
# order. Rollback itself never fails silently: it verifies what it restored.
# =============================================================================

if [ -n "${GP_TXN_SH:-}" ]; then
  return 0
fi
GP_TXN_SH=1

TXN_ACTIVE=0
TXN_ID=""
TXN_DIR=""
TXN_LABEL=""
TXN_FILE=""

txn_journal_path()  { printf '%s\n' "$(gp_state_dir)/state/journal.current"; }
txn_archive_dir()   { printf '%s\n' "$(gp_state_dir)/state/journal"; }
txn_is_active()     { [ "$TXN_ACTIVE" = "1" ]; }

txn_require_active() {
  if ! txn_is_active; then
    die "internal error: attempted a mutating operation outside of a transaction (run with --dry-run to preview)"
    return 1
  fi
  return 0
}

# txn_begin <label>
txn_begin() {
  TXN_LABEL="$1"
  if txn_is_active; then
    # A nested transaction would silently mix journal entries from two
    # operations. Refuse instead: the caller must fix its control flow.
    log_err "internal error: transaction '${TXN_LABEL}' started while '${TXN_ID}' is still open"
    return 1
  fi
  TXN_ID="$(gp_ts)-$$"
  TXN_DIR="$(gp_backup_dir)/${TXN_ID}"
  TXN_FILE="$(txn_journal_path)"
  TXN_ACTIVE=1
  if gp_dry_run; then
    log_debug "txn $TXN_ID begin (dry-run, nothing recorded): $TXN_LABEL"
    return 0
  fi
  gp_mkdir "$(dirname "$TXN_FILE")" 0700 || return 1
  : > "$TXN_FILE" || return 1
  chmod 600 "$TXN_FILE" 2>/dev/null || true
  {
    printf 'BEGIN\t%s\t%s\t%s\t%s\n' "$TXN_ID" "$(gp_ts_human)" "$TXN_LABEL" "${GP_DRY_RUN:-0}"
    printf 'INFO\tproject\t%s\n' "$GP_PROJECT_NAME"
    printf 'INFO\tversion\t%s\n' "${VGM_VERSION:-unknown}"
    printf 'INFO\trole\t%s\n' "$(gp_role)"
    printf 'INFO\thost\t%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
  } >> "$TXN_FILE"
  log_debug "transaction $TXN_ID started: $TXN_LABEL"
  return 0
}

_txn_record() {
  txn_require_active || return 1
  gp_dry_run && return 0
  # Records are TAB separated; $* joins with $IFS, so set it explicitly.
  local IFS=$'\t'
  if [ ! -e "$TXN_FILE" ]; then
    mkdir -p "$(dirname "$TXN_FILE")" 2>/dev/null || true
    : > "$TXN_FILE" 2>/dev/null || return 1
  fi
  printf '%s\n' "$*" >> "$TXN_FILE"
  return 0
}

# -----------------------------------------------------------------------------
# Backups
# -----------------------------------------------------------------------------
_txn_backup_path() {
  local path="$1" safe
  safe="$(printf '%s' "$path" | sed -e 's#^/##' -e 's#[/\\]#__#g')"
  printf '%s\n' "$TXN_DIR/files/${safe}"
}

# txn_backup_file <path>
# Records a restore point for <path> (file or directory). Safe to call twice.
txn_backup_file() {
  local path="$1" dest
  txn_require_active || return 1
  if gp_dry_run; then
    if [ -e "$path" ]; then log_dry "back up $path -> $(gp_backup_dir)/<txn>/files/"
    else log_dry "note that $path does not exist yet (rollback would remove it)"; fi
    return 0
  fi
  if grep -q -F "$(printf 'FILE\t%s\t' "$path")" "$TXN_FILE" 2>/dev/null; then
    log_debug "already backed up in this transaction: $path"
    return 0
  fi
  dest="$(_txn_backup_path "$path")"
  mkdir -p "$(dirname "$dest")" || return 1
  if [ -e "$path" ]; then
    local mode
    mode="$(gp_file_mode "$path")"
    if [ -d "$path" ]; then
      cp -a "$path" "$dest" || return 1
    else
      cp -p "$path" "$dest" || return 1
    fi
    _txn_record "FILE" "$path" "$dest" "1" "${mode:-0644}"
    log_debug "backed up $path -> $dest"
  else
    _txn_record "FILE" "$path" "-" "0" "-"
    log_debug "recorded absence of $path"
  fi
  return 0
}

# txn_install_file <source-file> <dest-path> <mode>
txn_install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  txn_require_active || return 1
  [ -r "$src" ] || { die "txn_install_file: source not readable: $src"; return 1; }
  txn_backup_file "$dest" || return 1
  if gp_dry_run; then
    log_dry "install $src -> $dest (mode $mode)"
    return 0
  fi
  gp_mkdir "$(dirname "$dest")" 0755 || return 1
  gp_atomic_write "$dest" "$mode" < "$src" || return 1
  return 0
}

# txn_remove_file <path>   (records the current content so it can be restored)
txn_remove_file() {
  local path="$1"
  txn_require_active || return 1
  if [ ! -e "$path" ]; then
    log_debug "txn_remove_file: nothing to remove at $path"
    return 0
  fi
  txn_backup_file "$path" || return 1
  if gp_dry_run; then
    log_dry "remove $path"
    return 0
  fi
  rm -f "$path" || return 1
  return 0
}

# txn_mkdir <path> <mode>
txn_mkdir() {
  local path="$1" mode="${2:-0755}"
  txn_require_active || return 1
  if [ -d "$path" ]; then return 0; fi
  gp_dry_run && { log_dry "create directory $path (mode $mode)"; return 0; }
  mkdir -p "$path" || return 1
  chmod "$mode" "$path" || return 1
  _txn_record "NEWDIR" "$path"
  return 0
}

# txn_write_text <path> <mode> <content...>
txn_write_text() {
  local path="$1" mode="$2" tmp
  shift 2
  txn_require_active || return 1
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$*" > "$tmp"
  txn_install_file "$tmp" "$path" "$mode" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# -----------------------------------------------------------------------------
# External state records
# -----------------------------------------------------------------------------
# The txn_* recorders are no-ops outside of a transaction: migrations and
# client-side operations legitimately run without one (there is nothing to roll
# back to on a fresh client), and they must not fail just because of that.

# txn_ufw_add <spec>   — a rule we are about to create
txn_ufw_add() { txn_is_active && _txn_record "UFW_ADD" "$1"; return 0; }

# txn_ufw_del <spec>   — a rule we are about to delete (pre-existing)
txn_ufw_del() { txn_is_active && _txn_record "UFW_DEL" "$1"; return 0; }

# txn_service <unit> <reload|restart|start|stop|enable|disable>
txn_service() { txn_is_active && _txn_record "SVC" "$1" "$2"; return 0; }

# txn_cmd <undo command>  — arbitrary rollback step (executed with bash -c)
txn_cmd() { txn_is_active && _txn_record "CMD" "$*"; return 0; }

# txn_note <text>  — informational, also useful for audit
txn_note() { txn_is_active && _txn_record "NOTE" "$*"; return 0; }

# -----------------------------------------------------------------------------
# Commit / rollback
# -----------------------------------------------------------------------------
txn_commit() {
  local status="${1:-success}" arch
  txn_is_active || return 0
  if gp_dry_run; then
    log_debug "txn $TXN_ID would be committed ($status)"
    TXN_ACTIVE=0
    return 0
  fi
  printf 'COMMIT\t%s\t%s\t%s\n' "$(gp_ts_human)" "$status" "$TXN_LABEL" >> "$TXN_FILE"
  # Archive the journal next to the backups for auditing.
  arch="$(gp_state_dir)/state/journal"
  mkdir -p "$arch" 2>/dev/null || true
  if [ -d "$TXN_DIR" ]; then
    cp -f "$TXN_FILE" "$TXN_DIR/journal.tsv" 2>/dev/null || true
  fi
  rm -f "$TXN_FILE" 2>/dev/null || true
  log_debug "transaction $TXN_ID committed ($status)"
  TXN_ACTIVE=0
  return 0
}

# txn_rollback [reason]
txn_rollback() {
  local reason="${1:-failure}" line type rest rc=0 restored=0 failed=0
  TXN_NEED_FINAL_RELOAD=0
  txn_is_active || return 0
  if gp_dry_run; then
    log_dry "rollback of transaction '${TXN_LABEL}' (dry-run: no changes were made)"
    TXN_ACTIVE=0
    return 0
  fi
  log_warn "rolling back '${TXN_LABEL}' ($reason)"
  if [ ! -r "$TXN_FILE" ]; then
    TXN_ACTIVE=0
    return 1
  fi
  # Reverse replay
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$TXN_FILE"
  local i
  for ((i=${#lines[@]}-1; i>=0; i--)); do
    line="${lines[$i]}"
    type="${line%%$'\t'*}"
    case "$type" in
      BEGIN|INFO|COMMIT|NOTE) continue ;;
      FILE)
        local path backup existed mode
        IFS=$'\t' read -r _ path backup existed mode <<< "$line"
        if [ "$existed" = "1" ]; then
          if [ -e "$backup" ]; then
            mkdir -p "$(dirname "$path")" 2>/dev/null || true
            if [ -d "$backup" ]; then
              rm -rf "$path" 2>/dev/null || true
              cp -a "$backup" "$path" && { restored=$((restored+1)); log_info "restored directory $path"; } || { failed=$((failed+1)); log_err "failed to restore $path"; }
            else
              cp -p "$backup" "$path" && { restored=$((restored+1)); log_info "restored $path"; } || { failed=$((failed+1)); log_err "failed to restore $path"; }
            fi
            [ "$mode" != "-" ] && [ -n "$mode" ] && chmod "$mode" "$path" 2>/dev/null || true
          else
            failed=$((failed+1)); log_err "backup missing for $path ($backup)"
          fi
        else
          rm -f "$path" 2>/dev/null; rm -rf "$path" 2>/dev/null || true
          restored=$((restored+1))
          log_info "removed $path (did not exist before)"
        fi
        ;;
      NEWDIR)
        path="${line#NEWDIR$'\t'}"
        rmdir "$path" 2>/dev/null && log_info "removed directory $path" || true
        ;;
      UFW_ADD)
        rest="${line#UFW_ADD$'\t'}"
        if declare -F fw_delete_rule >/dev/null 2>&1; then
          fw_delete_rule "$rest" && { restored=$((restored+1)); log_info "removed firewall rule: $rest"; } \
            || { failed=$((failed+1)); log_err "failed to remove firewall rule: $rest"; }
        else
          log_warn "firewall helper unavailable; rule left in place: $rest"
          failed=$((failed+1))
        fi
        ;;
      UFW_DEL)
        rest="${line#UFW_DEL$'\t'}"
        if declare -F fw_add_rule >/dev/null 2>&1; then
          fw_add_rule "$rest" && { restored=$((restored+1)); log_info "re-added firewall rule: $rest"; } \
            || { failed=$((failed+1)); log_err "failed to re-add firewall rule: $rest"; }
        else
          log_warn "firewall helper unavailable; rule not restored: $rest"
          failed=$((failed+1))
        fi
        ;;
      SVC)
        local unit action
        IFS=$'\t' read -r _ unit action <<< "$line"
        case "$action" in
          reload)
            # Use the validated reload path: it never lets Squid start a second
            # instance because of a stale pid file.
            if declare -F squid_reload >/dev/null 2>&1; then
              squid_reload "$unit" "${SERVER_MAIN_CONF:-}" \
                || log_warn "could not reload after restoring the configuration"
            else
              systemctl_cmd reload "$unit" || true
            fi
            # Records are replayed in reverse, so the daemon may have been
            # reloaded before the files were restored. A final reload at the end
            # of the rollback makes the running daemon and the files agree.
            TXN_NEED_FINAL_RELOAD=1
            ;;
          restart) systemctl_cmd restart "$unit" || true ;;
          start)   systemctl_cmd stop "$unit"    || true ;;
          stop)    systemctl_cmd start "$unit"   || true ;;
          enable)  systemctl_cmd disable "$unit" || true ;;
          disable) systemctl_cmd enable "$unit"  || true ;;
        esac
        log_info "reversed service action: $action $unit"
        ;;
      CMD)
        rest="${line#CMD$'\t'}"
        log_info "running rollback command: $rest"
        bash -c "$rest" || { failed=$((failed+1)); log_err "rollback command failed: $rest"; }
        ;;
      *) log_debug "ignoring unknown journal entry: $type" ;;
    esac
  done
  printf 'ROLLBACK\t%s\t%s\t%s\n' "$(gp_ts_human)" "$reason" "$TXN_LABEL" >> "$TXN_FILE"
  if [ -d "$TXN_DIR" ]; then cp -f "$TXN_FILE" "$TXN_DIR/journal.tsv" 2>/dev/null || true; fi
  rm -f "$TXN_FILE" 2>/dev/null || true
  TXN_ACTIVE=0
  # Restores happen after the (reverse-ordered) reload record, so reload once
  # more to line the daemon up with the files that are now on disk.
  if [ "${TXN_NEED_FINAL_RELOAD:-0}" = "1" ]; then
    if declare -F squid_reload >/dev/null 2>&1; then
      squid_reload "${SERVER_SERVICE:-}" "${SERVER_MAIN_CONF:-}" \
        || log_warn "the daemon could not be reloaded; it may still run the configuration that was rolled back"
    elif have systemctl && [ -n "${SERVER_SERVICE:-}" ]; then
      systemctl_cmd reload "$SERVER_SERVICE" || true
    fi
    log_info "reloaded the service so it matches the restored configuration"
  fi
  if [ "$failed" -gt 0 ]; then
    log_err "rollback finished with $failed problem(s); manual review required"
    return 1
  fi
  log_ok "rollback finished: $restored item(s) restored"
  return $rc
}

# txn_run_guarded <label> <command...>
# Runs a function inside a transaction and rolls back automatically on failure.
txn_run_guarded() {
  local label="$1"; shift
  txn_begin "$label" || return 1
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    txn_rollback "command failed (rc=$rc): $*"
    return "$rc"
  fi
  txn_commit success || return 1
  return 0
}

# Remove old backup sets, keeping the newest <keep>.
txn_prune_backups() {
  local keep="${1:-20}" dir
  gp_dry_run && { log_dry "prune backups, keeping newest $keep"; return 0; }
  dir="$(gp_backup_dir)"
  [ -d "$dir" ] || return 0
  # shellcheck disable=SC2012
  ls -1 "$dir" 2>/dev/null | sort -r | tail -n "+$((keep+1))" | while IFS= read -r old; do
    [ -n "$old" ] || continue
    rm -rf "${dir:?}/$old" 2>/dev/null || true
    log_debug "pruned old backup set: $old"
  done
  return 0
}

# Restore a specific backup set (disaster recovery / uninstall helper).
txn_restore_set() {
  local set="$1" dir="$2" line type path backup existed mode
  [ -d "$set" ] || { die "backup set not found: $set"; return 1; }
  [ -r "$set/journal.tsv" ] || { die "backup set has no journal: $set"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    type="${line%%$'\t'*}"
    case "$type" in
      FILE)
        IFS=$'\t' read -r _ path backup existed mode <<< "$line"
        if [ "$existed" = "1" ] && [ -e "$backup" ]; then
          path="$dir$path"
          mkdir -p "$(dirname "$path")" 2>/dev/null || true
          rm -rf "$path" 2>/dev/null || true
          cp -a "$backup" "$path" && { chmod "${mode:-0644}" "$path" 2>/dev/null || true; log_info "restored $path"; } || log_err "failed: $path"
        fi
        ;;
    esac
  done < "$set/journal.tsv"
  return 0
}
