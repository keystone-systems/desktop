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
    query_count_file="$test_root/query-count"
    mkdir -p "$fake_bin"
    : > "$stale_pid_file"
    : > "$launch_log"
    : > "$notify_log"
    : > "$terminate_log"
    printf '0\n' > "$query_count_file"

    cat > "$fake_bin/loginctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "$1" == "show-user" ]]; then
      printf '%s\n' "''${FAKE_DISPLAY_SESSION:-7}"
    elif [[ "$1" == "show-session" ]]; then
      property="$4"
      if [[ "$property" == "User" ]]; then
        printf '%s\n' "$FAKE_USER_ID"
      elif [[ "$2" == "''${FAKE_DISPLAY_SESSION:-7}" ]]; then
        printf 'wayland\n'
      else
        printf 'tty\n'
      fi
    elif [[ "$1" == "terminate-session" ]]; then
      printf 'loginctl %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
      if [[ "''${FAKE_LOGINCTL_KILL_CALLER:-false}" == "true" ]]; then
        kill -TERM "$PPID"
      fi
    fi
    EOF

    cat > "$fake_bin/hyprctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "''${1:-}" == "-j" && "''${2:-}" == "locked" ]]; then
      query_count=$(( $(cat "$FAKE_QUERY_COUNT_FILE") + 1 ))
      printf '%s\n' "$query_count" > "$FAKE_QUERY_COUNT_FILE"
      if [[ -n "''${FAKE_LOCK_ON_QUERY:-}" && "$query_count" -eq "$FAKE_LOCK_ON_QUERY" ]]; then
        printf 'locked\n' > "$FAKE_LOCK_STATE"
      fi
      [[ "$(cat "$FAKE_LOCK_STATE")" == "locked" ]] \
        && printf '{"locked":true}\n' \
        || printf '{"locked":false}\n'
    elif [[ "''${1:-}" == "dispatch" && "''${2:-}" == "exit" ]]; then
      printf 'hyprctl %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
    fi
    EOF

    cat > "$fake_bin/hyprlock" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf 'launch' >> "$FAKE_LAUNCH_LOG"
    printf ' %s' "$@" >> "$FAKE_LAUNCH_LOG"
    printf '\n' >> "$FAKE_LAUNCH_LOG"
    if [[ "''${FAKE_LOCK_ON_LAUNCH:-false}" == "true" ]]; then
      printf 'locked\n' > "$FAKE_LOCK_STATE"
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
    export FAKE_QUERY_COUNT_FILE="$query_count_file"
    export FAKE_USER_ID="$(id -u)"
    export KEYSTONE_LOCK_POLL_INTERVAL_SECONDS=0.05
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=1000
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
      printf '0\n' > "$query_count_file"
      ${pkgs.bash}/bin/bash "$script" "$@"
    }

    launch_count() {
      grep -c '^launch --immediate-render$' "$launch_log" || true
    }

    menu_arm() {
      grep -A4 "$1)" "$main_menu"
    }

    # 1. Hyprland's session-lock state is authoritative.
    check "Hyprland locked state must return success" run_lock locked
    check "Hyprland locked state must not launch hyprlock" test ! -s "$launch_log"

    # 2. A stale logind LockedHint is not compositor lock truth.
    export FAKE_LOCK_ON_LAUNCH=true
    check "stale LockedHint must not suppress the launch" run_lock hint
    unset FAKE_LOCK_ON_LAUNCH
    [[ "$(launch_count)" -eq 1 ]] || fail "expected one launch after stale LockedHint"

    # A lock established at the deadline boundary must succeed. The first
    # query is the pre-launch check. The second query is the final check after
    # a zero-length deadline.
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=0
    export FAKE_LOCK_ON_QUERY=2
    check "a lock established at the deadline boundary must succeed" run_lock none
    unset FAKE_LOCK_ON_QUERY
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=1000
    [[ "$(launch_count)" -eq 1 ]] || fail "deadline-boundary recovery must launch once"

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

    export XDG_SESSION_ID=stale
    export FAKE_LOGINCTL_KILL_CALLER=true
    if run_lock none --fail-closed; then
      fail "fail-closed lock failure returned success"
    fi
    unset FAKE_LOGINCTL_KILL_CALLER
    unset XDG_SESSION_ID
    # The graceful requests run asynchronously and can finish after logind
    # kills the helper. Wait briefly for both stubs to record their start.
    for _ in {1..20}; do
      grep -q '^uwsm stop$' "$terminate_log" \
        && grep -q '^hyprctl dispatch exit$' "$terminate_log" \
        && break
      sleep 0.01
    done
    check "--fail-closed must exit hyprland" grep -q '^hyprctl dispatch exit$' "$terminate_log"
    check "--fail-closed must stop uwsm" grep -q '^uwsm stop$' "$terminate_log"
    check "--fail-closed must terminate the logind session" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"
    check "a stale XDG session ID must fall back to the user's display session" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"
    check "--fail-closed must request UWSM teardown" grep -q '^uwsm stop$' "$terminate_log"
    check "--fail-closed must request compositor teardown" \
      grep -q '^hyprctl dispatch exit$' "$terminate_log"

    # Static guards: keystone-lock owns lock truth and session termination.
    if grep -Eq '\b(pidof|pgrep|pkill|flock)\b' "$script"; then
      fail "keystone-lock must not use PID or mutex state as lock truth"
    fi
    if grep -Eq 'loginctl .*LockedHint|hyprctl -j layers' "$script"; then
      fail "keystone-lock must use Hyprland's direct session-lock state"
    fi
    check "keystone-lock must query Hyprland's direct session-lock state" \
      grep -q 'hyprctl -j locked' "$script"
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
    check "a failed lid lock must block suspend" \
      grep -q 'failed lock requests session termination and deliberately blocks suspend' "$hyprland_conf"
    menu_arm system-lock | grep -q 'keystone_cmd keystone-lock' \
      || fail "the System menu lock entry must run keystone-lock"
    menu_arm system-suspend | grep -q -- '--fail-closed && systemctl suspend' \
      || fail "the System menu suspend entry must lock, fail closed, before suspending"

    touch "$out"
  ''
