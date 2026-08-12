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
    stale_pid_file="$test_root/stale.pid"
    launch_log="$test_root/launch.log"
    notify_log="$test_root/notify.log"
    terminate_log="$test_root/terminate.log"
    mkdir -p "$fake_bin"
    : > "$stale_pid_file"
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

    # Reports the deliberately stale hyprlock process of case 3. keystone-lock
    # MUST never consult these, so a PID heuristic shows up as a missing launch.
    cat > "$fake_bin/pidof" <<'EOF'
    #!${pkgs.bash}/bin/bash
    [[ -s "$FAKE_STALE_PID" ]] && cat "$FAKE_STALE_PID"
    EOF
    cp "$fake_bin/pidof" "$fake_bin/pgrep"

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
    export FAKE_STALE_PID="$stale_pid_file"
    export FAKE_LAUNCH_LOG="$launch_log"
    export FAKE_NOTIFY_LOG="$notify_log"
    export FAKE_TERMINATE_LOG="$terminate_log"
    export KEYSTONE_LOCK_POLL_INTERVAL_SECONDS=0.05
    export KEYSTONE_LOCK_TIMEOUT_STEPS=4
    unset XDG_SESSION_ID

    fail() {
      echo "FAIL: $*" >&2
      exit 1
    }

    check() {
      local message="$1"
      shift
      "$@" || fail "$message"
    }

    run_lock() {
      local state="$1"
      shift
      printf '%s\n' "$state" > "$state_file"
      : > "$launch_log"
      ${pkgs.bash}/bin/bash "$script" "$@"
    }

    launch_count() {
      grep -c '^launch$' "$launch_log" || true
    }

    menu_arm() {
      grep -A2 "$1)" "$main_menu"
    }

    # 1. LockedHint=yes is lock truth on its own.
    check "LockedHint=yes must return success" run_lock hint
    check "LockedHint=yes must not launch hyprlock" test ! -s "$launch_log"

    # 2. A hyprlock layer is lock truth even while LockedHint=no.
    check "a hyprlock layer must return success" run_lock layer
    check "a hyprlock layer must not launch hyprlock" test ! -s "$launch_log"

    # 3. A stale, inert hyprlock process is NOT lock truth: launch anyway,
    #    observe the real lock, and leave the stale process running.
    ${pkgs.bash}/bin/bash -c 'while :; do sleep 60; done' &
    stale_pid=$!
    printf '%s\n' "$stale_pid" > "$stale_pid_file"

    export FAKE_LOCK_ON_LAUNCH=true
    check "a stale hyprlock must not suppress the launch" run_lock none
    unset FAKE_LOCK_ON_LAUNCH
    [[ "$(launch_count)" -eq 1 ]] || fail "expected one hyprlock launch, got $(launch_count)"
    check "the stale hyprlock process must survive" kill -0 "$stale_pid"
    kill "$stale_pid" 2>/dev/null || true
    : > "$stale_pid_file"

    # 4. No lock appears: ordinary mode reports, --fail-closed tears down.
    if run_lock none; then
      fail "ordinary lock failure returned success"
    fi
    check "an ordinary failure must notify the user" grep -q 'Screen lock failed' "$notify_log"
    check "an ordinary failure must keep the session" test ! -s "$terminate_log"

    if run_lock none --fail-closed; then
      fail "fail-closed lock failure returned success"
    fi
    check "--fail-closed must exit hyprland" grep -q '^hyprctl dispatch exit$' "$terminate_log"
    check "--fail-closed must stop uwsm" grep -q '^uwsm stop$' "$terminate_log"
    check "--fail-closed must terminate the logind session" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"

    # Static guards: keystone-lock owns lock truth and session termination.
    if grep -Eq '\b(pidof|pgrep|pkill|flock)\b' "$script"; then
      fail "keystone-lock must not use PID or mutex state as lock truth"
    fi
    if grep -Eq '\b(pidof|pgrep|pkill)\b' "$startup_script"; then
      fail "startup lock must not accept PID existence or stability"
    fi
    check "startup lock must delegate its fail-closed path to keystone-lock" \
      grep -q 'keystone-lock --fail-closed' "$startup_script"
    if grep -q 'terminate-session' "$startup_script"; then
      fail "session termination must live only in keystone-lock --fail-closed"
    fi

    if grep -R 'pidof hyprlock' "${../..}/templates"; then
      fail "desktop templates must not use a Hyprlock PID as lock truth"
    fi
    check "hypridle must lock through keystone-lock" \
      grep -q '^  lock_cmd=keystone-lock$' "$hypridle_conf"
    check "hypridle must fail closed before sleep" \
      grep -q '^  before_sleep_cmd=keystone-lock --fail-closed$' "$hypridle_conf"
    check "the idle listener must lock through keystone-lock" \
      grep -q '^  on-timeout=keystone-lock$' "$hypridle_conf"
    check "the lid must lock before it suspends" \
      grep -q 'switch:on:Lid Switch, exec, keystone-lock --fail-closed && systemctl suspend' "$hyprland_conf"
    menu_arm system-lock | grep -q 'keystone_cmd keystone-lock' \
      || fail "the System menu lock entry must run keystone-lock"
    menu_arm system-suspend | grep -q -- '--fail-closed && systemctl suspend' \
      || fail "the System menu suspend entry must lock, fail closed, before suspending"

    touch "$out"
  ''
