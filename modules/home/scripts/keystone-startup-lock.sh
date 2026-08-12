#!/usr/bin/env bash
set -u -o pipefail

# SECURITY: This script is the fail-closed gate for the desktop session.
# Only an observable session lock can complete startup. A running Hyprlock
# process is never proof that the desktop is protected.
poll_interval_seconds="${KEYSTONE_STARTUP_LOCK_POLL_INTERVAL_SECONDS:-0.1}"
readiness_timeout_steps="${KEYSTONE_STARTUP_LOCK_READINESS_TIMEOUT_STEPS:-100}"
max_lock_attempts="${KEYSTONE_STARTUP_LOCK_MAX_ATTEMPTS:-3}"
retry_delay_seconds="${KEYSTONE_STARTUP_LOCK_RETRY_DELAY:-0.5}"

log() {
  local priority="$1"
  shift
  local message="$*"

  printf 'keystone-startup-lock: %s\n' "$message" >&2
  printf '%s\n' "$message" | systemd-cat -t keystone-startup-lock -p "$priority" || true
}

session_lock_ready() {
  hyprctl -j monitors 2>/dev/null | jq -e 'type == "array" and length > 0' >/dev/null 2>&1
}

# The final lock request runs --fail-closed so keystone-lock owns the single
# session teardown sequence (UWSM stop, then a validated logind session kill).
# A second copy here is how the two paths drift apart.
final_attempt() {
  log info "requesting the final startup lock (fail closed)"

  if keystone-lock --fail-closed; then
    log info "startup lock is ready"
    exit 0
  fi

  log err "hyprlock produced no observable lock state; desktop session termination was requested"
  exit 1
}

ready=false
step=0
while [[ "$step" -lt "$readiness_timeout_steps" ]]; do
  step=$((step + 1))
  if session_lock_ready; then
    ready=true
    log info "session lock prerequisites are ready"
    break
  fi
  sleep "$poll_interval_seconds"
done

if [[ "$ready" != true ]]; then
  log err "Hyprland did not become ready for session locking before the startup deadline"
  final_attempt
fi

attempt=1
while [[ "$attempt" -lt "$max_lock_attempts" ]]; do
  log info "requesting startup lock attempt ${attempt}/${max_lock_attempts}"
  if keystone-lock; then
    log info "startup lock is ready"
    exit 0
  fi

  attempt=$((attempt + 1))
  sleep "$retry_delay_seconds"
done

final_attempt
