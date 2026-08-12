#!/usr/bin/env bash
set -u -o pipefail

# SECURITY: This script is the fail-closed gate for the desktop session.
# Only an observable session lock can complete startup. A running Hyprlock
# process is never proof that the desktop is protected.
poll_interval_seconds="${KEYSTONE_STARTUP_LOCK_POLL_INTERVAL_SECONDS:-0.1}"
readiness_timeout_steps="${KEYSTONE_STARTUP_LOCK_READINESS_TIMEOUT_STEPS:-100}"
max_lock_attempts="${KEYSTONE_STARTUP_LOCK_MAX_ATTEMPTS:-3}"
attempt_timeout_steps="${KEYSTONE_STARTUP_LOCK_ATTEMPT_TIMEOUT_STEPS:-30}"
retry_delay_seconds="${KEYSTONE_STARTUP_LOCK_RETRY_DELAY:-0.5}"

log() {
  local priority="$1"
  shift
  local message="$*"

  printf 'keystone-startup-lock: %s\n' "$message" >&2
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$message" | systemd-cat -t keystone-startup-lock -p "$priority"
  fi
}

session_lock_ready() {
  local monitors

  monitors="$(hyprctl -j monitors 2>/dev/null)" || return 1
  printf '%s\n' "$monitors" | jq -e 'type == "array" and length > 0' >/dev/null
}

session_id() {
  local display_session

  if [[ -n "${XDG_SESSION_ID:-}" ]]; then
    printf '%s\n' "$XDG_SESSION_ID"
    return 0
  fi

  display_session="$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null)" || return 1
  [[ -n "$display_session" && "$display_session" != "n/a" ]] || return 1
  printf '%s\n' "$display_session"
}

fail_closed() {
  local reason="$1"
  local current_session

  log err "$reason"
  log err "Terminating the desktop session instead of exposing an unlocked desktop."

  hyprctl dispatch exit >/dev/null 2>&1 || true
  uwsm stop >/dev/null 2>&1 || true

  current_session="$(session_id)" || exit 1
  loginctl terminate-session "$current_session" >/dev/null 2>&1 || true
  exit 1
}

for _ in $(seq 1 "$readiness_timeout_steps"); do
  if session_lock_ready; then
    log info "session lock prerequisites are ready"
    break
  fi
  sleep "$poll_interval_seconds"
done

if ! session_lock_ready; then
  fail_closed "Hyprland did not become ready for session locking before the startup deadline."
fi

for attempt in $(seq 1 "$max_lock_attempts"); do
  log info "requesting startup lock attempt ${attempt}/${max_lock_attempts}"
  if KEYSTONE_LOCK_TIMEOUT_STEPS="$attempt_timeout_steps" keystone-lock; then
    log info "startup lock is ready"
    exit 0
  fi

  if [[ "$attempt" -lt "$max_lock_attempts" ]]; then
    sleep "$retry_delay_seconds"
  fi
done

fail_closed "hyprlock failed to produce an observable lock state after ${max_lock_attempts} attempts."
