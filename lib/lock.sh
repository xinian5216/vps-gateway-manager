#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# vps-gateway-manager :: lib/lock.sh
#
# One mutation lock for update, install, uninstall and the other write commands.
# Read-only commands (status, test, doctor, update check/history) do not take it.
#
# A directory lock, not an inherited flock fd. Squid and other children must
# not keep the mutation lock after the shell that started them has exited.
# gp_abort_guard removes the lock on normal exit. A killed holder is reclaimed
# when /proc no longer has its BASHPID. Nested acquire in the same process is
# a no-op so the CLI and the update engine can both call this safely.
# =============================================================================

if [ -n "${GP_LOCK_SH:-}" ]; then
  return 0
fi
GP_LOCK_SH=1

GP_MUTATION_LOCK_HELD="${GP_MUTATION_LOCK_HELD:-0}"
GP_LOCK_FD="${GP_LOCK_FD:-}"

gp_lock_file() { printf '%s\n' "$(gp_p "/run/lock/vps-gateway-manager.lock")"; }

gp_lock_backend() {
  # Always the directory lock. A flock file descriptor would be inherited by
  # Squid (and any other child), and the mutation lock would stay held until
  # that daemon exited. The directory lock is not inherited. Normal exit
  # removes it via gp_abort_guard; a killed holder is reclaimed when /proc
  # shows the recorded BASHPID is gone.
  case "${GP_LOCK_BACKEND:-mkdir}" in
    mkdir|flock) printf '%s\n' mkdir ;;
    *) printf '%s\n' mkdir ;;
  esac
}

_gp_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  # $$ is the parent shell even inside a subshell. Holders record BASHPID.
  # /proc is authoritative where it exists (including Git Bash); kill -0 is not.
  if [ -d /proc ]; then
    [ -d "/proc/$pid" ]
    return $?
  fi
  kill -0 "$pid" 2>/dev/null
}

# The PID of this process, not the parent of a command substitution.
gp_lock_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

_gp_lock_busy() {
  die "Another vps-gateway-manager mutation is running."
  return 1
}

# Test-only. After a stale PID has been read, wait so a test can install a
# new lock before this process is allowed to reclaim. Production leaves the
# variable unset. A missed wake-up fails closed instead of deleting whatever
# directory is now at the lock path.
_gp_lock_pause_after_stale_read() {
  local i=0
  [ -n "${VGM_LOCK_PAUSE_FILE:-}" ] || return 0
  [ "${GP_LOCK_PAUSED:-0}" = "1" ] && return 0
  GP_LOCK_PAUSED=1
  printf 'paused\n' >"${VGM_LOCK_PAUSE_FILE}.ready" || return 1
  while [ ! -f "${VGM_LOCK_PAUSE_FILE}.go" ]; do
    sleep 0.05
    i=$((i + 1))
    if [ "$i" -gt 400 ]; then
      return 1
    fi
  done
  return 0
}

# Delete lockdir only if it is still the stale generation we observed.
# mkdir of lockdir/reclaim is the exclusive right to delete. If the path has
# been replaced by a new holder, the PID will not match and we remove only
# the reclaim marker we just created.
_gp_lock_reclaim_stale() {
  local lockdir="$1" observed="$2" now=""
  if ! mkdir "$lockdir/reclaim" 2>/dev/null; then
    return 1
  fi
  now="$(head -n 1 "$lockdir/pid" 2>/dev/null || true)"
  if [ "$now" != "$observed" ] || { [ -n "$now" ] && _gp_pid_alive "$now"; }; then
    rmdir "$lockdir/reclaim" 2>/dev/null || rm -rf "$lockdir/reclaim"
    return 1
  fi
  rm -rf "$lockdir"
  return 0
}

# gp_mutation_lock_acquire -> 0 when this process holds the lock.
# Dry-run does not create a lock file: a preview must not mutate the sandbox.
gp_mutation_lock_acquire() {
  local lock dir backend lockdir pid me tries now mtime
  if [ "$GP_MUTATION_LOCK_HELD" = "1" ]; then
    return 0
  fi
  if gp_dry_run; then
    return 0
  fi
  lock="$(gp_lock_file)"
  dir="$(dirname "$lock")"
  mkdir -p "$dir" || return 1
  backend="$(gp_lock_backend)"
  case "$backend" in
    flock)
      # shellcheck disable=SC3023
      exec {GP_LOCK_FD}>"$lock" || return 1
      if ! flock -n "$GP_LOCK_FD"; then
        _gp_lock_busy
        return 1
      fi
      gp_lock_pid >"$lock"
      ;;
    mkdir)
      # mkdir is the atomic claim. The PID is written immediately after.
      # A directory with no PID is not stale while it is younger than 2s, so a
      # second process cannot steal a claim that has not finished writing.
      # Reclaim of a dead holder is an atomic mv; only one process wins it.
      lockdir="${lock}.d"
      me="${BASHPID:-$$}"
      tries=0
      while [ "$tries" -lt 40 ]; do
        if mkdir "$lockdir" 2>/dev/null; then
          printf '%s\n' "$me" >"$lockdir/pid" || true
          if [ "$(head -n 1 "$lockdir/pid" 2>/dev/null || true)" = "$me" ]; then
            GP_MUTATION_LOCK_HELD=1
            return 0
          fi
          tries=$((tries + 1))
          continue
        fi
        pid="$(head -n 1 "$lockdir/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && _gp_pid_alive "$pid"; then
          _gp_lock_busy
          return 1
        fi
        if [ -z "$pid" ]; then
          now="$(date +%s)"
          mtime="$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null || printf 0)"
          if [ $((now - mtime)) -lt 2 ]; then
            sleep 0.05
            tries=$((tries + 1))
            continue
          fi
        fi
        # Do not mv the lock directory here. That rename is atomic, but it
        # would move whatever is at this path now, including a lock created
        # after we read the dead PID.
        _gp_lock_pause_after_stale_read || { _gp_lock_busy; return 1; }
        _gp_lock_reclaim_stale "$lockdir" "$pid" || true
        tries=$((tries + 1))
      done
      _gp_lock_busy
      return 1
      ;;
    *)
      die "unknown lock backend: $backend"
      return 1
      ;;
  esac
  GP_MUTATION_LOCK_HELD=1
  return 0
}

gp_mutation_lock_release() {
  local lock backend lockdir
  [ "$GP_MUTATION_LOCK_HELD" = "1" ] || return 0
  if gp_dry_run; then
    GP_MUTATION_LOCK_HELD=0
    return 0
  fi
  lock="$(gp_lock_file)"
  backend="$(gp_lock_backend)"
  case "$backend" in
    flock)
      if [ -n "$GP_LOCK_FD" ]; then
        flock -u "$GP_LOCK_FD" 2>/dev/null || true
        eval "exec ${GP_LOCK_FD}>&-" 2>/dev/null || true
      fi
      ;;
    mkdir)
      lockdir="${lock}.d"
      if [ "$(head -n 1 "$lockdir/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ]; then
        rm -rf "$lockdir"
      fi
      ;;
  esac
  GP_LOCK_FD=""
  GP_MUTATION_LOCK_HELD=0
  return 0
}
