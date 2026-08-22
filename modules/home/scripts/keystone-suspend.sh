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

power_supply_root="${KEYSTONE_POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
hibernate_marker="${KEYSTONE_SUSPEND_THEN_HIBERNATE_MARKER:-/etc/keystone/suspend-then-hibernate}"

on_ac_power() {
  local supply type

  [[ -d "$power_supply_root" ]] || return 1
  for supply in "$power_supply_root"/*; do
    [[ -r "$supply/type" && -r "$supply/online" ]] || continue
    type=$(<"$supply/type")
    case "$type" in
      Mains|USB|USB_C|USB_PD)
        [[ "$(<"$supply/online")" == "1" ]] && return 0
        ;;
    esac
  done
  return 1
}

# An AC lid close must not change the lock state or the sleep state.
if [[ "$lid_event" == true ]] && on_ac_power; then
  exit 0
fi

# keystone-lock returns success only after it observes the session lock.
keystone-lock --fail-closed

if [[ -e "$hibernate_marker" ]]; then
  systemctl suspend-then-hibernate
else
  systemctl suspend
fi
