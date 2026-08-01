#!/usr/bin/env bash
set -euo pipefail

warning_percent="${KEYSTONE_BATTERY_WARNING_PERCENT:-20}"
critical_percent="${KEYSTONE_BATTERY_CRITICAL_PERCENT:-10}"
state_dir="${KEYSTONE_HEALTH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/keystone-health-monitor}"
notify_send="${KEYSTONE_NOTIFY_SEND_BIN:-notify-send}"
warning_flag="$state_dir/battery-warning"
critical_flag="$state_dir/battery-critical"

mkdir -p "$state_dir"

if [[ -n "${KEYSTONE_BATTERY_LEVEL:-}" || -n "${KEYSTONE_BATTERY_STATE:-}" ]]; then
  battery_level="${KEYSTONE_BATTERY_LEVEL:-}"
  battery_state="${KEYSTONE_BATTERY_STATE:-}"
else
  battery_device="$(upower -e | grep 'BAT' | head -n 1 || true)"
  if [[ -z "$battery_device" ]]; then
    exit 0
  fi

  battery_info="$(upower -i "$battery_device")"
  battery_level="$(
    awk '/percentage:/ { gsub("%", "", $2); print $2; exit }' <<<"$battery_info"
  )"
  battery_state="$(
    awk '/state:/ { print $2; exit }' <<<"$battery_info"
  )"
fi

if [[ ! "$battery_level" =~ ^[0-9]+$ ]]; then
  exit 0
fi

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
