{ pkgs }:
pkgs.runCommand "test-desktop-lock-recovery"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      jq
    ];
  }
  ''
    set -euo pipefail

    script="${../..}/modules/home/scripts/keystone-lock.sh"
    startup_script="${../..}/modules/home/scripts/keystone-startup-lock.sh"
    hypridle_conf="${../..}/templates/hyprland/.config/hypr/hypridle.conf"
    hyprland_conf="${../..}/templates/hyprland/.config/hypr/hyprland.conf"
    main_menu="${../..}/modules/home/scripts/keystone-main-menu.sh"
    test_root="$TMPDIR/lock-test"
    fake_bin="$test_root/bin"
    state_file="$test_root/state"
    launch_log="$test_root/launch.log"
    notify_log="$test_root/notify.log"
    terminate_log="$test_root/terminate.log"
    mkdir -p "$fake_bin"
    : > "$launch_log"
    : > "$notify_log"
    : > "$terminate_log"

    cat > "$fake_bin/loginctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "$1" == "show-user" ]]; then
      printf '7\n'
    elif [[ "$1" == "show-session" ]]; then
      [[ "$(cat "$FAKE_LOCK_STATE")" == "hint" ]] && printf 'yes\n' || printf 'no\n'
    elif [[ "$1" == "terminate-session" ]]; then
      printf 'loginctl %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
    fi
    EOF

    cat > "$fake_bin/hyprctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "''${1:-}" == "-j" && "''${2:-}" == "layers" ]]; then
      if [[ "$(cat "$FAKE_LOCK_STATE")" == "layer" ]]; then
        printf '{"layers":{"DP-1":{"levels":{"0":[{"namespace":"hyprlock"}]}}}}\n'
      else
        printf '{"layers":{}}\n'
      fi
    elif [[ "''${1:-}" == "dispatch" && "''${2:-}" == "exit" ]]; then
      printf 'hyprctl %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
    fi
    EOF

    cat > "$fake_bin/hyprlock" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf 'launch\n' >> "$FAKE_LAUNCH_LOG"
    if [[ "''${FAKE_LOCK_ON_LAUNCH:-false}" == "true" ]]; then
      printf 'hint\n' > "$FAKE_LOCK_STATE"
    fi
    EOF

    cat > "$fake_bin/notify-send" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf '%s\n' "$*" >> "$FAKE_NOTIFY_LOG"
    EOF

    cat > "$fake_bin/systemd-cat" <<'EOF'
    #!${pkgs.bash}/bin/bash
    cat >/dev/null
    EOF

    cat > "$fake_bin/uwsm" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf 'uwsm %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
    EOF

    chmod +x "$fake_bin"/*
    export PATH="$fake_bin:$PATH"
    export FAKE_LOCK_STATE="$state_file"
    export FAKE_LAUNCH_LOG="$launch_log"
    export FAKE_NOTIFY_LOG="$notify_log"
    export FAKE_TERMINATE_LOG="$terminate_log"
    export KEYSTONE_LOCK_POLL_INTERVAL_SECONDS=0
    export KEYSTONE_LOCK_TIMEOUT_STEPS=2
    unset XDG_SESSION_ID

    printf 'hint\n' > "$state_file"
    ${pkgs.bash}/bin/bash "$script"
    [[ ! -s "$launch_log" ]]

    printf 'layer\n' > "$state_file"
    ${pkgs.bash}/bin/bash "$script"
    [[ ! -s "$launch_log" ]]

    printf 'none\n' > "$state_file"
    FAKE_LOCK_ON_LAUNCH=true ${pkgs.bash}/bin/bash "$script"
    [[ "$(grep -c '^launch$' "$launch_log")" -eq 1 ]]

    : > "$launch_log"
    printf 'none\n' > "$state_file"
    if ${pkgs.bash}/bin/bash "$script"; then
      echo "FAIL: ordinary lock failure returned success" >&2
      exit 1
    fi
    grep -q 'Screen lock failed' "$notify_log"
    [[ ! -s "$terminate_log" ]]

    if ${pkgs.bash}/bin/bash "$script" --fail-closed; then
      echo "FAIL: fail-closed lock failure returned success" >&2
      exit 1
    fi
    grep -q '^hyprctl dispatch exit$' "$terminate_log"
    grep -q '^uwsm stop$' "$terminate_log"
    grep -q '^loginctl terminate-session 7$' "$terminate_log"

    if grep -Eq '\b(pidof|pgrep|pkill|flock)\b' "$script"; then
      echo "FAIL: keystone-lock must not use PID or mutex state as lock truth" >&2
      exit 1
    fi

    grep -q 'keystone-lock' "$startup_script"
    if grep -Eq 'pgrep|stable_lock|remained alive' "$startup_script"; then
      echo "FAIL: startup lock must not accept PID existence or stability" >&2
      exit 1
    fi

    if grep -R 'pidof hyprlock' "${../..}/templates"; then
      echo "FAIL: desktop templates must not use a Hyprlock PID as lock truth" >&2
      exit 1
    fi
    grep -q '^  lock_cmd=keystone-lock$' "$hypridle_conf"
    grep -q '^  before_sleep_cmd=keystone-lock --fail-closed$' "$hypridle_conf"
    grep -q '^  on-timeout=keystone-lock$' "$hypridle_conf"
    grep -q 'switch:on:Lid Switch, exec, keystone-lock --fail-closed && systemctl suspend' "$hyprland_conf"
    grep -A2 'system-lock)' "$main_menu" | grep -q 'keystone-lock'
    grep -A2 'system-suspend)' "$main_menu" | grep -q 'keystone-lock.*--fail-closed.*systemctl suspend'

    touch "$out"
  ''
