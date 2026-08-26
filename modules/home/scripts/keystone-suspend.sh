#!/usr/bin/env bash
set -euo pipefail

lid_event=false

case "${1:-}" in
  "") ;;
  --lid) lid_event=true ;;
  *)
    printf 'Usage: keystone-suspend [--lid]\n' >&2
    exit 2
    ;;
esac

hibernate_marker="${KEYSTONE_SUSPEND_THEN_HIBERNATE_MARKER:-/etc/keystone/suspend-then-hibernate}"

if [[ "$lid_event" == true ]]; then
  runtime_dir="${XDG_RUNTIME_DIR:?keystone-suspend --lid requires XDG_RUNTIME_DIR}"
  exec 9>"$runtime_dir/keystone-suspend-lid.lock"
  flock --nonblock 9 || exit 0

  login1_property() {
    local property="$1"
    local value

    value="$(busctl --value get-property \
      org.freedesktop.login1 \
      /org/freedesktop/login1 \
      org.freedesktop.login1.Manager \
      "$property" 2>/dev/null)" || return 1
    [[ "$value" == true || "$value" == false ]] || return 1
    printf '%s\n' "$value"
  }

  docked="$(login1_property Docked)" || docked=false
  lid_closed="$(login1_property LidClosed)" || exit 0

  while [[ "$docked" == true && "$lid_closed" == true ]]; do
    sleep "${KEYSTONE_LID_POLL_INTERVAL_SECONDS:-2}"
    lid_closed="$(login1_property LidClosed)" || exit 0
    [[ "$lid_closed" == true ]] || exit 0
    docked="$(login1_property Docked)" || docked=false
  done

  [[ "$lid_closed" == true ]] || exit 0

  keystone-lock 9>&-

  lid_closed="$(login1_property LidClosed)" || exit 0
  [[ "$lid_closed" == true ]] || exit 0
else
  keystone-lock
fi

if [[ -e "$hibernate_marker" ]]; then
  if [[ "$lid_event" == true ]]; then
    systemctl suspend-then-hibernate 9>&-
  else
    systemctl suspend-then-hibernate
  fi
else
  if [[ "$lid_event" == true ]]; then
    systemctl suspend 9>&-
  else
    systemctl suspend
  fi
fi
