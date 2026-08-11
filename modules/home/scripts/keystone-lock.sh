#!/usr/bin/env bash
set -u -o pipefail

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
timeout_steps="${KEYSTONE_LOCK_TIMEOUT_STEPS:-30}"

log() {
  local priority="$1"
  shift
  local message="$*"

  printf 'keystone-lock: %s\n' "$message" >&2
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$message" | systemd-cat -t keystone-lock -p "$priority"
  fi
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

session_locked() {
  local current_session

  current_session="$(session_id)" || return 1
  [[ "$(loginctl show-session "$current_session" -p LockedHint --value 2>/dev/null)" == "yes" ]]
}

lock_surface_present() {
  local layers

  layers="$(hyprctl -j layers 2>/dev/null)" || return 1
  printf '%s\n' "$layers" | jq -e '
    .. | objects | select(
      (.namespace? // "") == "hyprlock"
      or (.class? // "") == "hyprlock"
      or (.name? // "") == "hyprlock"
    )
  ' >/dev/null
}

lock_ready() {
  session_locked || lock_surface_present
}

terminate_session() {
  local current_session

  log err "Terminating the desktop session because the lock did not become ready."
  hyprctl dispatch exit >/dev/null 2>&1 || true
  uwsm stop >/dev/null 2>&1 || true

  current_session="$(session_id)" || return 0
  loginctl terminate-session "$current_session" >/dev/null 2>&1 || true
}

if lock_ready; then
  log info "session already reports locked"
  exit 0
fi

log info "launching hyprlock"
hyprlock >/dev/null 2>&1 &
lock_pid=$!

for _ in $(seq 1 "$timeout_steps"); do
  if lock_ready; then
    log info "session lock is ready"
    exit 0
  fi

  # A concurrent launcher may win the ext-session-lock race. The real lock
  # state remains authoritative even when this process exits first.
  if ! kill -0 "$lock_pid" >/dev/null 2>&1; then
    wait "$lock_pid" >/dev/null 2>&1 || true
  fi

  sleep "$poll_interval_seconds"
done

if lock_ready; then
  log info "session lock became ready at the deadline"
  exit 0
fi

log err "hyprlock did not produce an observable lock state"
notify-send -u critical "Screen lock failed" "Hyprlock did not establish a session lock." >/dev/null 2>&1 || true

if [[ "$fail_closed" == true ]]; then
  terminate_session
fi

exit 1
