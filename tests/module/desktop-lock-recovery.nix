{ pkgs }:
pkgs.runCommand "test-desktop-lock-recovery"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      jq
      util-linux
    ];
  }
  ''
    set -euo pipefail

    script="${../..}/modules/home/scripts/keystone-lock.sh"
    suspend_script="${../..}/modules/home/scripts/keystone-suspend.sh"
    startup_script="${../..}/modules/home/scripts/keystone-startup-lock.sh"
    startup_config="${../..}/pkgs/keystone-hyprlock-startup.conf"
    hypridle_conf="${../..}/templates/hyprland/.config/hypr/hypridle.conf"
    hyprland_conf="${../..}/templates/hyprland/.config/hypr/hyprland.lua"
    menu_router="${../..}/modules/home/scripts/keystone-menu.sh"
    test_root="$TMPDIR/lock-test"
    fake_bin="$test_root/bin"
    state_file="$test_root/state"
    service_state_file="$test_root/service-state"
    stale_pid_file="$test_root/stale.pid"
    launch_log="$test_root/launch.log"
    notify_log="$test_root/notify.log"
    terminate_log="$test_root/terminate.log"
    query_count_file="$test_root/query-count"
    suspend_log="$test_root/suspend.log"
    docked_state="$test_root/docked"
    lid_state="$test_root/lid-closed"
    lid_query_count="$test_root/lid-query-count"
    lock_child_pid_file="$test_root/lock-child.pid"
    hibernate_marker="$test_root/suspend-then-hibernate"
    mkdir -p "$fake_bin"
    : > "$stale_pid_file"
    : > "$service_state_file"
    : > "$launch_log"
    : > "$notify_log"
    : > "$terminate_log"
    printf '0\n' > "$query_count_file"
    : > "$suspend_log"
    printf 'false\n' > "$docked_state"
    printf 'true\n' > "$lid_state"
    printf '0\n' > "$lid_query_count"
    : > "$lock_child_pid_file"

    cat > "$fake_bin/loginctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "$1" == "show-user" ]]; then
      printf '%s\n' "''${FAKE_DISPLAY_SESSION:-7}"
    elif [[ "$1" == "show-session" ]]; then
      property="$4"
      if [[ "$property" == "User" ]]; then
        printf '%s\n' "''${FAKE_SESSION_OWNER:-$FAKE_USER_ID}"
      elif [[ "$2" == "''${FAKE_DISPLAY_SESSION:-7}" ]]; then
        printf 'wayland\n'
      else
        printf 'tty\n'
      fi
    elif [[ "$1" == "terminate-session" ]]; then
      printf 'loginctl %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
      if [[ "''${FAKE_LOGINCTL_FAIL:-false}" == "true" ]]; then
        exit 1
      fi
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

    # Model both a live lock client and the deliberately stale process in case
    # 3. The protocol bit and process liveness must corroborate each other.
    cat > "$fake_bin/pgrep" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "''${FAKE_HYPRLOCK_RUNNING:-false}" == "true" ]]; then
      printf '1234\n'
    elif [[ -s "$FAKE_STALE_PID" ]]; then
      cat "$FAKE_STALE_PID"
    elif [[ "$(cat "$FAKE_LOCK_STATE")" == "locked" && -s "$FAKE_SERVICE_STATE" ]]; then
      printf '5678\n'
    else
      exit 1
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

    cat > "$fake_bin/systemctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [[ "''${1:-}" == "--user" && "''${2:-}" == "is-active" ]]; then
      requested="''${4:-}"
      [[ "''${FAKE_ACTIVE_LOCK_UNIT:-}" == "$requested" || "$(cat "$FAKE_SERVICE_STATE")" == "$requested" ]]
      exit
    fi
    if [[ "''${1:-}" == "--user" && "''${2:-}" == "start" ]]; then
      case "''${3:-}" in
        keystone-hyprlock.service | keystone-hyprlock-startup.service)
          printf 'start %s\n' "$3" >> "$FAKE_LAUNCH_LOG"
          printf '%s\n' "$3" > "$FAKE_SERVICE_STATE"
          if [[ "''${FAKE_LOCK_ON_LAUNCH:-false}" == "true" ]]; then
            printf 'locked\n' > "$FAKE_LOCK_STATE"
          fi
          [[ "''${FAKE_LOCK_SERVICE_START_FAIL:-false}" != "true" ]]
          exit
          ;;
      esac
    fi
    printf 'systemctl %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
    [[ "''${FAKE_SYSTEMCTL_FAIL:-false}" != "true" ]]
    EOF

    cat > "$fake_bin/uwsm" <<'EOF'
    #!${pkgs.bash}/bin/bash
    sleep "''${FAKE_UWSM_DELAY_SECONDS:-0}"
    printf 'uwsm %s\n' "$*" >> "$FAKE_TERMINATE_LOG"
    [[ "''${FAKE_UWSM_FAIL:-false}" != "true" ]]
    EOF

    chmod +x "$fake_bin"/*
    export PATH="$fake_bin:$PATH"
    export FAKE_LOCK_STATE="$state_file"
    export FAKE_SERVICE_STATE="$service_state_file"
    export FAKE_STALE_PID="$stale_pid_file"
    export FAKE_LAUNCH_LOG="$launch_log"
    export FAKE_NOTIFY_LOG="$notify_log"
    export FAKE_TERMINATE_LOG="$terminate_log"
    export FAKE_QUERY_COUNT_FILE="$query_count_file"
    export FAKE_USER_ID="$(id -u)"
    export KEYSTONE_LOCK_POLL_INTERVAL_SECONDS=0.05
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=1000
    export KEYSTONE_LOCK_TEARDOWN_TIMEOUT_MILLISECONDS=250
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
      : > "$service_state_file"
      : > "$launch_log"
      printf '0\n' > "$query_count_file"
      ${pkgs.bash}/bin/bash "$script" "$@"
    }

    launch_count() {
      grep -c '^start keystone-hyprlock.service$' "$launch_log" || true
    }

    startup_launch_count() {
      grep -c '^start keystone-hyprlock-startup.service$' "$launch_log" || true
    }

    menu_arm() {
      grep -A3 "  $1 |" "$menu_router"
    }

    # 1. Protocol state corroborated by a live Hyprlock client is authoritative.
    export FAKE_HYPRLOCK_RUNNING=true
    export FAKE_ACTIVE_LOCK_UNIT=keystone-hyprlock.service
    check "a live locked session must return success" run_lock locked
    check "a live locked session must not launch hyprlock" test ! -s "$launch_log"
    unset FAKE_HYPRLOCK_RUNNING FAKE_ACTIVE_LOCK_UNIT

    # An ordinary request during startup must preserve the password-only
    # client that opens the login keyring. Conversely, startup mode must not
    # accept an already-running ordinary fingerprint-capable client.
    export FAKE_HYPRLOCK_RUNNING=true
    export FAKE_ACTIVE_LOCK_UNIT=keystone-hyprlock-startup.service
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=0
    if run_lock none; then
      fail "an ordinary request accepted a startup lock before it was ready"
    fi
    check "an ordinary request must not replace a not-yet-ready startup lock" \
      test ! -s "$launch_log"
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=1000
    check "an ordinary request must accept the supervised startup lock" run_lock locked
    check "an ordinary request must not replace the startup lock" test ! -s "$launch_log"
    export FAKE_ACTIVE_LOCK_UNIT=keystone-hyprlock.service
    export FAKE_LOCK_ON_LAUNCH=true
    check "startup mode must replace an ordinary lock" run_lock locked --startup
    [[ "$(startup_launch_count)" -eq 1 ]] || fail "startup mode accepted the ordinary lock unit"
    unset FAKE_HYPRLOCK_RUNNING FAKE_ACTIVE_LOCK_UNIT FAKE_LOCK_ON_LAUNCH

    # Hyprland deliberately retains locked=true if its lock client disappears.
    # That stale bit must not suppress a replacement Hyprlock launch.
    export FAKE_LOCK_ON_LAUNCH=true
    check "a stale compositor lock bit must relaunch hyprlock" run_lock locked
    unset FAKE_LOCK_ON_LAUNCH
    [[ "$(launch_count)" -eq 1 ]] || fail "stale compositor lock recovery must launch once"

    # A crashed supervised client leaves a stale compositor lock bit and an
    # inactive unit. The replacement service must reclaim the session lock.
    export FAKE_LOCK_ON_LAUNCH=true
    check "a crashed lock client must be recovered" run_lock locked
    unset FAKE_LOCK_ON_LAUNCH
    [[ "$(launch_count)" -eq 1 ]] || fail "crash recovery must launch the supervised lock once"

    # Startup mode is an order-independent addition to the same verified lock
    # path. It changes only the selected Hyprlock config.
    export FAKE_LOCK_ON_LAUNCH=true
    check "startup mode must establish a lock" run_lock none --startup
    [[ "$(startup_launch_count)" -eq 1 ]] || fail "startup mode did not select its Nix-owned config"
    check "combined startup/fail-closed flags must work in either order" \
      run_lock none --fail-closed --startup
    [[ "$(startup_launch_count)" -eq 1 ]] || fail "reordered startup flags changed the launch"
    unset FAKE_LOCK_ON_LAUNCH

    set +e
    run_lock none --unknown >/dev/null 2>&1
    unknown_status=$?
    set -e
    [[ "$unknown_status" -eq 2 ]] || fail "unknown flags must return status 2"

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
    check "--fail-closed must stop uwsm" grep -q '^uwsm stop$' "$terminate_log"
    check "--fail-closed must request the UWSM shutdown target" \
      grep -q '^systemctl --user start --no-block wayland-session-shutdown.target$' "$terminate_log"
    check "--fail-closed must terminate the logind session" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"
    check "a stale XDG session ID must fall back to the user's display session" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"
    uwsm_line="$(grep -n '^uwsm stop$' "$terminate_log" | cut -d: -f1)"
    shutdown_line="$(grep -n '^systemctl --user start --no-block wayland-session-shutdown.target$' "$terminate_log" | cut -d: -f1)"
    loginctl_line="$(grep -n '^loginctl terminate-session 7$' "$terminate_log" | cut -d: -f1)"
    [[ "$uwsm_line" -lt "$shutdown_line" && "$shutdown_line" -lt "$loginctl_line" ]] \
      || fail "fail-closed teardown did not use UWSM, its shutdown target, then logind"

    # UWSM may hang. The helper must still reach the logind fallback after its
    # bounded grace period.
    : > "$terminate_log"
    export FAKE_UWSM_DELAY_SECONDS=0.2
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=0
    export KEYSTONE_LOCK_TEARDOWN_TIMEOUT_MILLISECONDS=25
    started_milliseconds="$(date +%s%3N)"
    if run_lock none --fail-closed; then
      fail "bounded fail-closed lock failure returned success"
    fi
    elapsed_milliseconds=$(( $(date +%s%3N) - started_milliseconds ))
    [[ "$elapsed_milliseconds" -lt 500 ]] \
      || fail "UWSM teardown exceeded its bounded grace period"
    check "bounded teardown must reach logind" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"
    check "bounded teardown must request the UWSM shutdown target" \
      grep -q '^systemctl --user start --no-block wayland-session-shutdown.target$' "$terminate_log"
    for _ in {1..30}; do
      grep -q '^uwsm stop$' "$terminate_log" && break
      sleep 0.01
    done
    check "the timed-out UWSM request must still have started" grep -q '^uwsm stop$' "$terminate_log"
    loginctl_line="$(grep -n '^loginctl terminate-session 7$' "$terminate_log" | cut -d: -f1)"
    shutdown_line="$(grep -n '^systemctl --user start --no-block wayland-session-shutdown.target$' "$terminate_log" | cut -d: -f1)"
    uwsm_line="$(grep -n '^uwsm stop$' "$terminate_log" | cut -d: -f1)"
    [[ "$shutdown_line" -lt "$loginctl_line" && "$loginctl_line" -lt "$uwsm_line" ]] \
      || fail "the UWSM timeout did not precede native and logind fallbacks"
    unset FAKE_UWSM_DELAY_SECONDS
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=1000
    export KEYSTONE_LOCK_TEARDOWN_TIMEOUT_MILLISECONDS=250

    # A session that belongs to another user must never be terminated.
    : > "$terminate_log"
    export FAKE_SESSION_OWNER=$(( FAKE_USER_ID + 1 ))
    export XDG_SESSION_ID=foreign
    if run_lock none --fail-closed; then
      fail "foreign-owner lock failure returned success"
    fi
    unset XDG_SESSION_ID FAKE_SESSION_OWNER
    check "foreign-owner recovery must still ask UWSM to stop" grep -q '^uwsm stop$' "$terminate_log"
    if grep -q '^loginctl terminate-session' "$terminate_log"; then
      fail "foreign-owner recovery must not terminate a logind session"
    fi

    # Failed graceful and logind requests must retain the supported UWSM
    # shutdown-target fallback and preserve the fail-closed ordering.
    : > "$terminate_log"
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=0
    export FAKE_UWSM_FAIL=true
    export FAKE_LOGINCTL_FAIL=true
    if run_lock none --fail-closed; then
      fail "failed teardown requests returned success"
    fi
    unset FAKE_UWSM_FAIL FAKE_LOGINCTL_FAIL
    export KEYSTONE_LOCK_TIMEOUT_MILLISECONDS=1000
    check "failed UWSM teardown must request uwsm stop" grep -q '^uwsm stop$' "$terminate_log"
    check "failed UWSM teardown must request its shutdown target" \
      grep -q '^systemctl --user start --no-block wayland-session-shutdown.target$' "$terminate_log"
    check "failed UWSM teardown must reach logind" \
      grep -q '^loginctl terminate-session 7$' "$terminate_log"
    uwsm_line="$(grep -n '^uwsm stop$' "$terminate_log" | cut -d: -f1)"
    shutdown_line="$(grep -n '^systemctl --user start --no-block wayland-session-shutdown.target$' "$terminate_log" | cut -d: -f1)"
    loginctl_line="$(grep -n '^loginctl terminate-session 7$' "$terminate_log" | cut -d: -f1)"
    [[ "$uwsm_line" -lt "$shutdown_line" && "$shutdown_line" -lt "$loginctl_line" ]] \
      || fail "failed teardown requests ran out of order"

    # Static guards: keystone-lock owns lock truth and session termination.
    if grep -Eq '\b(pidof|pkill|flock)\b' "$script"; then
      fail "keystone-lock must not use legacy PID or mutex state as lock truth"
    fi
    if grep -Eq 'loginctl .*LockedHint|hyprctl -j layers' "$script"; then
      fail "keystone-lock must use Hyprland's direct session-lock state"
    fi
    check "keystone-lock must query Hyprland's direct session-lock state" \
      grep -q 'hyprctl -j locked' "$script"
    check "keystone-lock must corroborate protocol state with a user-owned Hyprlock client" \
      grep -q 'pgrep -u "\$user_id" -x hyprlock' "$script"
    check "keystone-lock must require its supervised service to be active" \
      grep -q 'lock_service_active' "$script"
    check "ordinary locking must preserve an active startup lock" \
      grep -q 'startup_lock_active' "$script"
    check "keystone-lock must launch through the supervised user service" \
      grep -q 'systemctl --user start "\$lock_unit"' "$script"
    if grep -Eq '^[[:space:]]*hyprlock([[:space:]]|$).*&|hyprlock_args|KEYSTONE_LOCK_STARTUP_CONFIG' "$script"; then
      fail "keystone-lock must not launch Hyprlock directly or accept an ambient startup config"
    fi
    if grep -q 'hyprctl dispatch exit' "$script"; then
      fail "UWSM sessions must not use compositor-native exit"
    fi
    if grep -Eq '\b(pidof|pgrep|pkill)\b' "$startup_script"; then
      fail "startup lock must not accept PID existence or stability"
    fi
    check "startup lock must delegate its fail-closed path to keystone-lock" \
      grep -q 'keystone-lock --startup --fail-closed' "$startup_script"
    check "every ordinary startup attempt must select the startup config" \
      grep -q 'keystone-lock --startup' "$startup_script"
    if grep -q 'terminate-session' "$startup_script"; then
      fail "session termination must live only in keystone-lock --fail-closed"
    fi

    if grep -R 'pidof hyprlock' "${../..}/templates"; then
      fail "desktop templates must not use a Hyprlock PID as lock truth"
    fi
    check "hypridle must lock through keystone-lock" \
      grep -q '^  lock_cmd=keystone-lock$' "$hypridle_conf"
    check "hypridle must use an ordinary lock before sleep" \
      grep -q '^  before_sleep_cmd=keystone-lock$' "$hypridle_conf"
    if grep -q -- '--fail-closed' "$hypridle_conf"; then
      fail "runtime hypridle hooks must never terminate the visible session"
    fi
    check "the idle listener must lock through keystone-lock" \
      grep -q '^  on-timeout=keystone-lock$' "$hypridle_conf"
    check "hypridle after-sleep must use the typed DPMS dispatcher" \
      grep -Fqx "  after_sleep_cmd=keystone-dpms-wake || (hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })' && brightnessctl -r)" "$hypridle_conf"
    check "hypridle resume must use the typed DPMS dispatcher" \
      grep -Fqx "  on-resume=keystone-dpms-wake || (hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })' && brightnessctl -r)" "$hypridle_conf"
    check "hypridle timeout must use the typed DPMS dispatcher" \
      grep -Fqx "  on-timeout=hyprctl dispatch 'hl.dsp.dpms({ action = \"off\" })'" "$hypridle_conf"
    if grep -Eq '^[^#]*hyprctl dispatch[[:space:]]+dpms([[:space:]]|$)' "$hypridle_conf"; then
      fail "hypridle must not use the legacy bare DPMS dispatcher form"
    fi
    check "the lid must use the suspend policy helper" \
      grep -q 'keystone-suspend --lid' "$hyprland_conf"
    check "Hyprland must accept a supervised replacement lock client" \
      grep -q 'allow_session_lock_restore = true' "$hyprland_conf"
    menu_arm lock | grep -q 'keystone_cmd keystone-lock' \
      || fail "the System menu lock entry must run keystone-lock"
    menu_arm suspend | grep -q 'keystone_cmd keystone-suspend' \
      || fail "the System menu suspend entry must use keystone-suspend"

    cat > "$fake_bin/keystone-lock" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf 'lock %s\n' "$*" >> "$FAKE_SUSPEND_LOG"
    if [[ "''${FAKE_LOCK_BACKGROUND_CHILD:-false}" == "true" ]]; then
      sleep 30 &
      printf '%s\n' "$!" > "$FAKE_LOCK_CHILD_PID_FILE"
    fi
    [[ "''${FAKE_LOCK_FAIL:-false}" != "true" ]]
    EOF
    cat > "$fake_bin/systemctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    printf 'systemctl %s\n' "$*" >> "$FAKE_SUSPEND_LOG"
    EOF
    cat > "$fake_bin/busctl" <<'EOF'
    #!${pkgs.bash}/bin/bash
    property="$5"
    if [[ "$property" == "Docked" ]]; then
      [[ "''${FAKE_DOCK_LOOKUP_FAIL:-false}" != "true" ]] || exit 1
      printf 'b %s\n' "$(cat "$FAKE_DOCKED_STATE")"
    elif [[ "$property" == "LidClosed" ]]; then
      count=$(( $(cat "$FAKE_LID_QUERY_COUNT") + 1 ))
      printf '%s\n' "$count" > "$FAKE_LID_QUERY_COUNT"
      [[ "''${FAKE_LID_FAIL_ON_QUERY:-0}" -ne "$count" ]] || exit 1
      printf 'b %s\n' "$(cat "$FAKE_LID_STATE")"
    else
      exit 1
    fi
    EOF
    chmod +x "$fake_bin/keystone-lock" "$fake_bin/systemctl" "$fake_bin/busctl"
    export FAKE_SUSPEND_LOG="$suspend_log"
    export FAKE_DOCKED_STATE="$docked_state"
    export FAKE_LID_STATE="$lid_state"
    export FAKE_LID_QUERY_COUNT="$lid_query_count"
    export FAKE_LOCK_CHILD_PID_FILE="$lock_child_pid_file"
    export KEYSTONE_SUSPEND_THEN_HIBERNATE_MARKER="$hibernate_marker"
    export KEYSTONE_LID_POLL_INTERVAL_SECONDS=0.05
    export XDG_RUNTIME_DIR="$test_root/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"

    run_suspend() {
      : > "$suspend_log"
      printf '0\n' > "$lid_query_count"
      ${pkgs.bash}/bin/bash "$suspend_script" "$@"
    }

    wait_for_lid_lock() {
      local lock_file="$XDG_RUNTIME_DIR/keystone-suspend-lid.lock"
      local attempt

      for attempt in {1..100}; do
        if [[ -e "$lock_file" ]] && ! flock --nonblock "$lock_file" true; then
          return 0
        fi
        sleep 0.01
      done
      fail "timed out waiting for lid waiter to hold the singleton lock"
    }

    touch "$hibernate_marker"
    # Battery and AC use the same session-owned undocked policy.
    check "battery/AC undocked lid close must succeed" run_suspend --lid
    grep -qx 'lock ' "$suspend_log" || fail "lid close did not use an ordinary lock"
    grep -qx 'systemctl suspend-then-hibernate' "$suspend_log" \
      || fail "undocked lid close did not sleep using the marker"

    # A closed, docked lid waits; undocking while still closed then locks and sleeps.
    : > "$suspend_log"
    printf 'true\n' > "$docked_state"
    printf 'true\n' > "$lid_state"
    ${pkgs.bash}/bin/bash "$suspend_script" --lid &
    waiter_pid=$!
    wait_for_lid_lock
    check "docked lid close must wait awake" test ! -s "$suspend_log"
    printf 'false\n' > "$docked_state"
    wait "$waiter_pid" || fail "undock-while-closed waiter failed"
    grep -qx 'lock ' "$suspend_log" || fail "undocking while closed did not lock"
    grep -qx 'systemctl suspend-then-hibernate' "$suspend_log" \
      || fail "undocking while closed did not sleep"

    # Opening the lid while docked cancels the pending sleep.
    : > "$suspend_log"
    printf 'true\n' > "$docked_state"
    printf 'true\n' > "$lid_state"
    ${pkgs.bash}/bin/bash "$suspend_script" --lid &
    waiter_pid=$!
    wait_for_lid_lock
    printf 'false\n' > "$lid_state"
    wait "$waiter_pid" || fail "opening lid while waiting failed"
    check "opening lid while waiting must stay awake" test ! -s "$suspend_log"

    printf 'true\n' > "$lid_state"
    printf 'false\n' > "$docked_state"
    export FAKE_DOCK_LOOKUP_FAIL=true
    check "failed dock lookup must succeed after locking" run_suspend --lid
    grep -qx 'lock ' "$suspend_log" \
      || fail "failed dock lookup did not lock defensively"
    grep -qx 'systemctl suspend-then-hibernate' "$suspend_log" \
      || fail "failed dock lookup did not follow the undocked policy"
    unset FAKE_DOCK_LOOKUP_FAIL

    # If the final lid verification is unreadable, remain awake after locking.
    export FAKE_LID_FAIL_ON_QUERY=2
    check "unreadable final lid state must exit awake" run_suspend --lid
    grep -qx 'lock ' "$suspend_log" || fail "final-lid case did not lock first"
    if grep -q '^systemctl ' "$suspend_log"; then
      fail "unreadable final lid state invoked systemctl"
    fi
    unset FAKE_LID_FAIL_ON_QUERY

    # Duplicate switch events share one nonblocking waiter and one sleep.
    : > "$suspend_log"
    printf '0\n' > "$lid_query_count"
    printf 'true\n' > "$docked_state"
    ${pkgs.bash}/bin/bash "$suspend_script" --lid &
    waiter_pid=$!
    wait_for_lid_lock
    ${pkgs.bash}/bin/bash "$suspend_script" --lid \
      || fail "duplicate lid event did not exit successfully"
    printf 'false\n' > "$docked_state"
    wait "$waiter_pid" || fail "singleton lid waiter failed"
    [[ "$(grep -c '^lock ' "$suspend_log")" -eq 1 ]] \
      || fail "duplicate lid events produced more than one lock"
    [[ "$(grep -c '^systemctl ' "$suspend_log")" -eq 1 ]] \
      || fail "duplicate lid events produced more than one sleep"

    # A lock implementation may leave a long-lived child behind. The child
    # must not inherit the lid singleton after keystone-suspend exits.
    : > "$suspend_log"
    printf 'false\n' > "$docked_state"
    export FAKE_LOCK_BACKGROUND_CHILD=true
    ${pkgs.bash}/bin/bash "$suspend_script" --lid \
      || fail "lid suspend with a background lock child failed"
    unset FAKE_LOCK_BACKGROUND_CHILD
    lock_child_pid="$(cat "$lock_child_pid_file")"
    check "fake lock child must remain alive" kill -0 "$lock_child_pid"
    ${pkgs.bash}/bin/bash "$suspend_script" --lid \
      || fail "later lid invocation failed"
    [[ "$(grep -c '^systemctl ' "$suspend_log")" -eq 2 ]] \
      || fail "long-lived lock child retained the lid singleton"
    kill "$lock_child_pid" 2>/dev/null || true

    check "Walker suspend must succeed" run_suspend
    grep -qx 'lock ' "$suspend_log" || fail "manual suspend did not use an ordinary lock"
    grep -qx 'systemctl suspend-then-hibernate' "$suspend_log" \
      || fail "manual suspend did not select suspend-then-hibernate"

    export FAKE_LOCK_FAIL=true
    : > "$terminate_log"
    if run_suspend --lid; then
      fail "a failed lock must fail the suspend request"
    fi
    if grep -q '^systemctl ' "$suspend_log"; then
      fail "a failed lock must block sleep"
    fi
    check "runtime lock failure must not terminate the session" test ! -s "$terminate_log"
    unset FAKE_LOCK_FAIL

    rm "$hibernate_marker"
    check "unsupported-host suspend must succeed" run_suspend
    grep -qx 'systemctl suspend' "$suspend_log" \
      || fail "an unsupported host must use plain suspend"
    if grep -q 'suspend-then-hibernate' "$suspend_log"; then
      fail "an unsupported host must not request hibernation"
    fi

    touch "$out"
  ''
