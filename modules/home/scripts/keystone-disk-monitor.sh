#!/usr/bin/env bash
set -euo pipefail

command="${1:-notify}"
disk_path="${KEYSTONE_DISK_PATH:-/}"
warning_percent="${KEYSTONE_DISK_WARNING_USED_PERCENT:-80}"
critical_percent="${KEYSTONE_DISK_CRITICAL_USED_PERCENT:-90}"
state_dir="${KEYSTONE_HEALTH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/keystone-health-monitor}"
notify_send="${KEYSTONE_NOTIFY_SEND_BIN:-notify-send}"
df_bin="${KEYSTONE_DF_BIN:-df}"
warning_flag="$state_dir/disk-warning"
critical_flag="$state_dir/disk-critical"

read -r percentage_used available_bytes total_bytes < <(
  "$df_bin" -B1 --output=pcent,avail,size "$disk_path" | tail -n 1
)
percentage_used="${percentage_used%%%}"

if [[ ! "$percentage_used" =~ ^[0-9]+$ ]] \
  || [[ ! "$available_bytes" =~ ^[0-9]+$ ]] \
  || [[ ! "$total_bytes" =~ ^[0-9]+$ ]]; then
  echo "keystone-disk-monitor: could not read filesystem usage for $disk_path" >&2
  exit 1
fi

available_human="$(numfmt --to=iec-i --suffix=B "$available_bytes")"
total_human="$(numfmt --to=iec-i --suffix=B "$total_bytes")"

health_class="healthy"
if (( percentage_used >= critical_percent )); then
  health_class="critical"
elif (( percentage_used >= warning_percent )); then
  health_class="warning"
fi

case "$command" in
  json)
    text=""
    if [[ "$health_class" != "healthy" ]]; then
      text="󰋊 ${percentage_used}%"
    fi

    jq -cn \
      --arg text "$text" \
      --arg class "$health_class" \
      --arg tooltip "$disk_path: ${available_human} free of ${total_human} (${percentage_used}% used)" \
      '{ text: $text, class: $class, tooltip: $tooltip }'
    ;;
  notify)
    mkdir -p "$state_dir"

    if [[ "$health_class" == "critical" ]]; then
      if [[ ! -e "$critical_flag" ]]; then
        "$notify_send" \
          -u critical \
          -i drive-harddisk \
          -t 0 \
          "Disk space critically low" \
          "$disk_path is ${percentage_used}% full with ${available_human} remaining."
        touch "$critical_flag" "$warning_flag"
      fi
    elif [[ "$health_class" == "warning" ]]; then
      rm -f "$critical_flag"
      if [[ ! -e "$warning_flag" ]]; then
        "$notify_send" \
          -u normal \
          -i drive-harddisk \
          -t 30000 \
          "Disk space running low" \
          "$disk_path is ${percentage_used}% full with ${available_human} remaining."
        touch "$warning_flag"
      fi
    else
      rm -f "$warning_flag" "$critical_flag"
    fi
    ;;
  *)
    echo "Usage: keystone-disk-monitor [notify|json]" >&2
    exit 2
    ;;
esac
