{ pkgs }:
pkgs.runCommand "test-desktop-health-monitor"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      jq
      gnugrep
    ];
  }
  ''
    set -euo pipefail

    scripts="${../..}/modules/home/scripts"
    test_root="$TMPDIR/health-test"
    fake_bin="$test_root/bin"
    state_dir="$test_root/state"
    notify_log="$test_root/notifications"
    mkdir -p "$fake_bin" "$state_dir"
    : > "$notify_log"

    cat > "$fake_bin/df" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf 'Use%% Avail Size\n'
    printf '%s%% %s %s\n' "$FAKE_DISK_USED" 107374182400 1073741824000
    EOF
    chmod +x "$fake_bin/df"

    cat > "$fake_bin/notify-send" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf '%s\n' "$*" >> "$NOTIFY_LOG"
    EOF
    chmod +x "$fake_bin/notify-send"

    export PATH="$fake_bin:$PATH"
    export NOTIFY_LOG="$notify_log"
    export KEYSTONE_HEALTH_STATE_DIR="$state_dir"
    export KEYSTONE_NOTIFY_SEND_BIN="$fake_bin/notify-send"
    export KEYSTONE_DF_BIN="$fake_bin/df"
    export KEYSTONE_DISK_WARNING_USED_PERCENT=80
    export KEYSTONE_DISK_CRITICAL_USED_PERCENT=90

    disk_monitor="${pkgs.bash}/bin/bash $scripts/keystone-disk-monitor.sh"

    FAKE_DISK_USED=79 $disk_monitor notify
    [[ ! -s "$notify_log" ]]

    FAKE_DISK_USED=80 $disk_monitor notify
    FAKE_DISK_USED=80 $disk_monitor notify
    [[ "$(grep -c 'Disk space running low' "$notify_log")" -eq 1 ]]

    FAKE_DISK_USED=90 $disk_monitor notify
    FAKE_DISK_USED=90 $disk_monitor notify
    [[ "$(grep -c 'Disk space critically low' "$notify_log")" -eq 1 ]]

    FAKE_DISK_USED=89 $disk_monitor notify
    FAKE_DISK_USED=90 $disk_monitor notify
    [[ "$(grep -c 'Disk space critically low' "$notify_log")" -eq 2 ]]

    healthy_json="$(FAKE_DISK_USED=79 $disk_monitor waybar)"
    warning_json="$(FAKE_DISK_USED=80 $disk_monitor waybar)"
    critical_json="$(FAKE_DISK_USED=90 $disk_monitor waybar)"
    [[ "$(jq -r '.text' <<<"$healthy_json")" == "" ]]
    [[ "$(jq -r '.class' <<<"$warning_json")" == "warning" ]]
    [[ "$(jq -r '.class' <<<"$critical_json")" == "critical" ]]
    jq -e '.tooltip | contains("100GiB free")' <<<"$warning_json" >/dev/null

    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    : > "$notify_log"
    export KEYSTONE_BATTERY_WARNING_PERCENT=20
    export KEYSTONE_BATTERY_CRITICAL_PERCENT=10
    battery_monitor="${pkgs.bash}/bin/bash $scripts/keystone-battery-monitor.sh"

    KEYSTONE_BATTERY_LEVEL=21 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    [[ ! -s "$notify_log" ]]

    KEYSTONE_BATTERY_LEVEL=20 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    KEYSTONE_BATTERY_LEVEL=20 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    [[ "$(grep -c 'Battery low' "$notify_log")" -eq 1 ]]

    KEYSTONE_BATTERY_LEVEL=10 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    KEYSTONE_BATTERY_LEVEL=10 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    [[ "$(grep -c 'Battery critically low' "$notify_log")" -eq 1 ]]

    KEYSTONE_BATTERY_LEVEL=50 KEYSTONE_BATTERY_STATE=charging $battery_monitor
    KEYSTONE_BATTERY_LEVEL=20 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    [[ "$(grep -c 'Battery low' "$notify_log")" -eq 2 ]]

    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    : > "$notify_log"
    KEYSTONE_BATTERY_LEVEL=5 KEYSTONE_BATTERY_STATE=discharging $battery_monitor
    [[ "$(grep -c 'Battery critically low' "$notify_log")" -eq 1 ]]
    ! grep -q 'Battery low' "$notify_log"

    touch "$out"
  ''
