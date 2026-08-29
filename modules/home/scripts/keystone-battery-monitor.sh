#!/usr/bin/env bash
set -euo pipefail

warning_percent="${KEYSTONE_BATTERY_WARNING_PERCENT:-20}"
critical_percent="${KEYSTONE_BATTERY_CRITICAL_PERCENT:-10}"
state_dir="${KEYSTONE_HEALTH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/keystone-health-monitor}"
notify_send="${KEYSTONE_NOTIFY_SEND_BIN:-notify-send}"
power_supply_root="${KEYSTONE_POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
warning_flag="$state_dir/battery-warning"
critical_flag="$state_dir/battery-critical"

battery_device=""
battery_level=""
battery_state=""
for candidate in "$power_supply_root"/BAT*; do
  if [[ -r "$candidate/capacity" && -r "$candidate/status" ]] \
    && IFS= read -r battery_level < "$candidate/capacity" \
    && IFS= read -r battery_state < "$candidate/status"; then
    battery_device="$candidate"
    break
  fi
done

# A host with no readable battery is not an error; nothing to report on.
[[ -n "$battery_device" ]] || exit 0

battery_state="${battery_state,,}"

if [[ ! "$battery_level" =~ ^[0-9]+$ ]] || (( battery_level > 100 )); then
  exit 0
fi

[[ -d "$state_dir" ]] || mkdir -p "$state_dir"

clear_flags() {
  rm -f "$warning_flag" "$critical_flag"
}

if [[ "$battery_state" != "discharging" ]]; then
  clear_flags
  exit 0
fi

if (( battery_level <= critical_percent )); then
  if [[ ! -e "$critical_flag" ]]; then
    "$notify_send" \
      -u critical \
      -i battery-caution \
      -t 0 \
      "Battery critically low" \
      "Battery is at ${battery_level}%. Connect power now."
    touch "$critical_flag" "$warning_flag"
  fi
elif (( battery_level <= warning_percent )); then
  rm -f "$critical_flag"
  if [[ ! -e "$warning_flag" ]]; then
    "$notify_send" \
      -u normal \
      -i battery-caution \
      -t 30000 \
      "Battery low" \
      "Battery is at ${battery_level}%."
    touch "$warning_flag"
  fi
else
  clear_flags
fi
