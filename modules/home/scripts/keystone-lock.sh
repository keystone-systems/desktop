#!/usr/bin/env bash
# Matches the options writeShellApplication injects around this text, so the
# packaged binary and a direct `bash keystone-lock.sh` behave identically.
set -euo pipefail

fail_closed=false
startup=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --fail-closed) fail_closed=true ;;
    --startup) startup=true ;;
    -h | --help)
      printf 'Usage: keystone-lock [--startup] [--fail-closed]\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

poll_interval_seconds="${KEYSTONE_LOCK_POLL_INTERVAL_SECONDS:-0.1}"
timeout_milliseconds="${KEYSTONE_LOCK_TIMEOUT_MILLISECONDS:-3000}"
teardown_timeout_milliseconds="${KEYSTONE_LOCK_TEARDOWN_TIMEOUT_MILLISECONDS:-1000}"

log() {
  local priority="$1"
  shift
  local message="$*"

  printf 'keystone-lock: %s\n' "$message" >&2
  printf '%s\n' "$message" | systemd-cat -t keystone-lock -p "$priority" || true
}

# Resolved once: the logind session cannot change under a running lock request,
# and session_locked() is called on every poll tick.
session=""
user_name="$(id -un)"
user_id="$(id -u)"
if [[ "$startup" == true ]]; then
  lock_unit="keystone-hyprlock-startup.service"
else
  lock_unit="keystone-hyprlock.service"
fi

startup_lock_active() {
  systemctl --user is-active --quiet keystone-hyprlock-startup.service
}

lock_service_active() {
  # The startup lock is password-only because it also opens the login keyring.
  # An ordinary request must therefore accept it as the current supervised
  # client instead of starting the conflicting fingerprint-capable unit. A
  # startup request is stricter: only the startup unit satisfies that gate.
  if systemctl --user is-active --quiet "$lock_unit"; then
    return 0
  fi

  [[ "$startup" == false ]] && startup_lock_active
}

session_belongs_to_user() {
  local candidate="$1"
  local owner
  local session_type

  [[ -n "$candidate" && "$candidate" != "n/a" ]] || return 1
  owner="$(loginctl show-session "$candidate" -p User --value 2>/dev/null || true)"
  session_type="$(loginctl show-session "$candidate" -p Type --value 2>/dev/null || true)"
  [[ "$owner" == "$user_id" && "$session_type" == "wayland" ]]
}

if session_belongs_to_user "${XDG_SESSION_ID:-}"; then
  session="$XDG_SESSION_ID"
else
  display_session="$(loginctl show-user "$user_name" -p Display --value 2>/dev/null || true)"
  if session_belongs_to_user "$display_session"; then
    session="$display_session"
  fi
fi

lock_ready() {
  # Hyprland v0.56 exposes its ext-session-lock state directly, but retains
  # locked=true after a lock client disappears without a clean unlock. Require
  # both protocol state and a live, user-owned Hyprlock client. Neither signal
  # is sufficient alone: a stale process can exist before locking, while a
  # stale compositor bit otherwise suppresses recovery after a client crash.
  hyprctl -j locked 2>/dev/null | jq -e '.locked == true' >/dev/null 2>&1 \
    && lock_service_active \
    && pgrep -u "$user_id" -x hyprlock >/dev/null 2>&1
}

terminate_session() {
  log err "Terminating the desktop session because the lock did not become ready."
  # UWSM owns the compositor lifecycle. Give it a bounded opportunity to stop
  # the session before logind kills this helper and all of its children.
  uwsm stop >/dev/null 2>&1 &
  uwsm_pid=$!
  teardown_deadline_milliseconds=$(( $(date +%s%3N) + teardown_timeout_milliseconds ))

  while kill -0 "$uwsm_pid" 2>/dev/null; do
    if [[ "$(date +%s%3N)" -ge "$teardown_deadline_milliseconds" ]]; then
      break
    fi
    sleep "$poll_interval_seconds"
  done

  if ! kill -0 "$uwsm_pid" 2>/dev/null; then
    if ! wait "$uwsm_pid"; then
      log warning "UWSM did not stop the desktop session cleanly."
    fi
  else
    log warning "UWSM did not stop the desktop session before the teardown deadline."
  fi

  if ! systemctl --user start --no-block wayland-session-shutdown.target >/dev/null 2>&1; then
    log err "Could not request the UWSM session shutdown target."
  fi

  if [[ -n "$session" ]]; then
    if ! loginctl terminate-session "$session" >/dev/null 2>&1; then
      log err "Could not terminate the validated logind session ${session}."
    fi
  fi
}

if lock_ready; then
  log info "session already reports locked"
  exit 0
fi

if [[ "$startup" == false ]] && startup_lock_active; then
  # The startup client is password-only and opens the login keyring. It can be
  # active before Hyprland reports ext-session-lock readiness, so an ordinary
  # request must wait for it instead of starting the conflicting fingerprint-
  # capable unit and replacing the authentication client mid-startup.
  log info "waiting for keystone-hyprlock-startup.service"
else
  log info "starting ${lock_unit}"
  if ! systemctl --user start "$lock_unit"; then
    log err "could not start ${lock_unit}"
  fi
fi

# Real lock state stays authoritative: a concurrent launcher may win the
# ext-session-lock race and establish the lock even if our own child exits.
deadline_milliseconds=$(( $(date +%s%3N) + timeout_milliseconds ))
while [[ "$(date +%s%3N)" -lt "$deadline_milliseconds" ]]; do
  sleep "$poll_interval_seconds"

  if lock_ready; then
    log info "session lock is ready"
    exit 0
  fi
done

# Check once after the deadline. The lock can become ready between the loop's
# last condition check and the failure path.
if lock_ready; then
  log info "session lock is ready"
  exit 0
fi

log err "hyprlock did not produce an observable lock state"
notify-send -u critical "Screen lock failed" "Hyprlock did not establish a session lock." >/dev/null 2>&1 || true

if [[ "$fail_closed" == true ]]; then
  terminate_session
fi

exit 1
