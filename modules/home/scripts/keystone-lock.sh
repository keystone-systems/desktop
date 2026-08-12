#!/usr/bin/env bash
# Matches the options writeShellApplication injects around this text, so the
# packaged binary and a direct `bash keystone-lock.sh` behave identically.
set -euo pipefail

fail_closed=false
case "${1:-}" in
  "") ;;
  --fail-closed) fail_closed=true ;;
  -h | --help)
    printf 'Usage: keystone-lock [--fail-closed]\n'
    exit 0
    ;;
  *)
    printf 'Unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

poll_interval_seconds="${KEYSTONE_LOCK_POLL_INTERVAL_SECONDS:-0.1}"
timeout_milliseconds="${KEYSTONE_LOCK_TIMEOUT_MILLISECONDS:-3000}"

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
if [[ -n "${XDG_SESSION_ID:-}" ]]; then
  session="$XDG_SESSION_ID"
else
  session="$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null || true)"
  [[ "$session" != "n/a" ]] || session=""
fi

lock_ready() {
  # Hyprland v0.56 exposes its ext-session-lock state directly. Do not use
  # logind's LockedHint or layer-shell surfaces as substitutes: LockedHint can
  # be stale, and ext-session-lock surfaces are not layer-shell surfaces.
  hyprctl -j locked 2>/dev/null | jq -e '.locked == true' >/dev/null 2>&1
}

terminate_session() {
  log err "Terminating the desktop session because the lock did not become ready."
  if [[ -n "$session" ]]; then
    loginctl terminate-session "$session" >/dev/null 2>&1 || true
  fi
  uwsm stop >/dev/null 2>&1 || true
  hyprctl dispatch exit >/dev/null 2>&1 || true
}

if lock_ready; then
  log info "session already reports locked"
  exit 0
fi

log info "launching hyprlock"
hyprlock >/dev/null 2>&1 &

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

log err "hyprlock did not produce an observable lock state"
notify-send -u critical "Screen lock failed" "Hyprlock did not establish a session lock." >/dev/null 2>&1 || true

if [[ "$fail_closed" == true ]]; then
  terminate_session
fi

exit 1
