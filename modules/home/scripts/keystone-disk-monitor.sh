#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

command="${1:-notify}"
disk_path="${KEYSTONE_DISK_PATH:-/}"
all_local="${KEYSTONE_DISK_ALL_LOCAL_FILESYSTEMS:-1}"
warning_percent="${KEYSTONE_DISK_WARNING_USED_PERCENT:-80}"
critical_percent="${KEYSTONE_DISK_CRITICAL_USED_PERCENT:-90}"
state_dir="${KEYSTONE_HEALTH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/keystone-health-monitor}"
notify_send="${KEYSTONE_NOTIFY_SEND_BIN:-notify-send}"
df_bin="${KEYSTONE_DF_BIN:-df}"

case "$command" in notify|json) ;; *) echo 'Usage: keystone-disk-monitor [notify|json]' >&2; exit 2 ;; esac

# df reports each mounted ZFS dataset's effective capacity, including quotas
# and ancestor limits. A healthy root filesystem says nothing about its children.
rows="$("$df_bin" -B1 --output=pcent,avail,size,target "$disk_path")"
if [[ "$all_local" == 1 ]]; then
  rows+=$'\n'"$("$df_bin" -l -x tmpfs -x devtmpfs -B1 --output=pcent,avail,size,target)"
fi

# df cannot see unmounted datasets or quota-bearing parents of VM zvols.
# Include their explicit quota/refquota limits when ZFS is installed.
zfs_bin="${KEYSTONE_ZFS_BIN:-zfs}"
if [[ "$all_local" == 1 ]] && command -v "$zfs_bin" >/dev/null 2>&1; then
  zfs_rows="$("$zfs_bin" list -Hp -t filesystem,volume -o name,used,referenced,quota,refquota,mounted 2>/dev/null)" || zfs_rows=""
  while read -r dataset used referenced quota refquota mounted; do
    [[ "$mounted" == yes ]] && continue
    for limit_kind in quota refquota; do
      limit="$quota"
      consumed="$used"
      if [[ "$limit_kind" == refquota ]]; then
        limit="$refquota"
        consumed="$referenced"
      fi
      # Volumes have no refquota, represented by a dash.
      [[ "$limit" =~ ^[0-9]+$ && "$consumed" =~ ^[0-9]+$ ]] || continue
      (( limit > 0 )) || continue
      remaining=$((limit > consumed ? limit - consumed : 0))
      percent=$(((consumed * 100 + limit - 1) / limit))
      rows+=$'\n'"$percent% $remaining $limit $dataset ($limit_kind)"
    done
  done <<< "$zfs_rows"
fi

declare -A seen=()
worst_percent=-1
health_class=healthy
tooltip=""
while read -r percentage_used available_bytes total_bytes mount_path; do
  percentage_used="${percentage_used%%%}"
  # Skip df's headers; reject invalid measurements rather than treating them
  # as healthy. read's last field preserves spaces in mountpoint names.
  [[ "$percentage_used" == 'Use%' || "$percentage_used" == Use ]] && continue
  if [[ ! "$percentage_used" =~ ^[0-9]+$ || ! "$available_bytes" =~ ^[0-9]+$ || ! "$total_bytes" =~ ^[0-9]+$ || -z "$mount_path" ]]; then
    echo "keystone-disk-monitor: invalid filesystem usage: $percentage_used $mount_path" >&2
    exit 1
  fi
  [[ -n "${seen[$mount_path]:-}" ]] && continue
  seen[$mount_path]=1
  available_human="$(numfmt --to=iec-i --suffix=B "$available_bytes")"
  total_human="$(numfmt --to=iec-i --suffix=B "$total_bytes")"
  level=healthy
  if (( percentage_used >= critical_percent )); then
    level=critical
  elif (( percentage_used >= warning_percent )); then
    level=warning
  fi
  if (( percentage_used > worst_percent )); then
    worst_percent="$percentage_used"
    health_class="$level"
  fi
  tooltip+="${mount_path}: ${available_human} free of ${total_human} (${percentage_used}% used)"$'\n'

  if [[ "$command" == notify ]]; then
    # Each filesystem has independent suppression and recovery, so one full
    # dataset cannot mask another or silence its escalation to critical.
    key="$(printf '%s' "$mount_path" | sha256sum)"
    key="${key%% *}"
    warning_flag="$state_dir/disk-$key-warning"
    critical_flag="$state_dir/disk-$key-critical"
    mkdir -p "$state_dir"
    if [[ "$level" == critical ]]; then
      if [[ ! -e "$critical_flag" ]]; then
        "$notify_send" -u critical -i drive-harddisk -t 0 \
          'Disk space critically low' \
          "$mount_path is ${percentage_used}% full with ${available_human} remaining."
        touch "$critical_flag" "$warning_flag"
      fi
    elif [[ "$level" == warning ]]; then
      rm -f "$critical_flag"
      if [[ ! -e "$warning_flag" ]]; then
        "$notify_send" -u normal -i drive-harddisk -t 30000 \
          'Disk space running low' \
          "$mount_path is ${percentage_used}% full with ${available_human} remaining."
        touch "$warning_flag"
      fi
    else
      rm -f "$warning_flag" "$critical_flag"
    fi
  fi
done <<< "$rows"

(( worst_percent >= 0 )) || { echo 'keystone-disk-monitor: no filesystem measurements' >&2; exit 1; }
if [[ "$command" == json ]]; then
  text=""
  [[ "$health_class" == healthy ]] || text="󰋊 ${worst_percent}%"
  jq -cn --arg text "$text" --arg class "$health_class" \
    --arg tooltip "${tooltip%$'\n'}" '{text: $text, class: $class, tooltip: $tooltip}'
fi
