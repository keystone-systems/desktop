{
  pkgs,
  hyprland,
  system,
}:
let
  hyprlandPkg = hyprland.packages.${system}.hyprland;
in
pkgs.runCommand "test-desktop-hyprland-lua"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnugrep
      jq
    ];
  }
  ''
        set -euo pipefail

        templates=${../..}/templates
        main="$templates/hyprland/.config/hypr/hyprland.lua"
        config_home="$TMPDIR/home/.config"
        runtime_dir="$TMPDIR/runtime"
        mkdir -p "$config_home/hypr" "$config_home/themes/current" "$runtime_dir"
        cp "$templates/hyprland/.config/hypr/"*.lua "$config_home/hypr/"
        chmod u+w "$config_home/hypr/"*.lua

        fail() {
          echo "FAIL: $*" >&2
          exit 1
        }

        start_callbacks_are_safe() {
          local file
          for file in "$@"; do
            awk '
              # Contract: hyprland.start callbacks may only perform compositor-local
              # typed dispatch and configuration work. They must not launch a shell,
              # process, GUI, or long-lived service, directly or through a local
              # alias of a Hyprland command dispatcher.
              function unsafe(callback, normalized, remaining, captures, alias, pattern) {
                normalized = callback
                gsub(/[[:space:]]+/, " ", normalized)
                if (normalized ~ /hl[.]exec_(cmd|raw)[[:space:]]*\(/ \
                  || normalized ~ /hl[.]dsp[.]exec_(cmd|raw)[[:space:]]*\(/ \
                  || normalized ~ /os[.]execute[[:space:]]*\(/ \
                  || normalized ~ /io[.]popen[[:space:]]*\(/ \
                  || normalized ~ /uwsm[[:space:]]+app/) {
                  return 1
                }

                remaining = normalized
                pattern = "(^|[^[:alnum:]_])((local[[:space:]]+)?([[:alpha:]_][[:alnum:]_]*))[[:space:]]*=[[:space:]]*hl[.](dsp[.])?exec_(cmd|raw)([^[:alnum:]_]|$)"
                while (match(remaining, pattern, captures)) {
                  alias = captures[4]
                  if (normalized ~ ("(^|[^[:alnum:]_])" alias "[[:space:]]*[(]")) {
                    return 1
                  }
                  remaining = substr(remaining, RSTART + RLENGTH)
                }
                return 0
              }

              BEGIN {
                active = 0
                depth = 0
              }

              {
                code = $0
                trimmed = code
                sub(/^[[:space:]]+/, "", trimmed)
                if (!active && trimmed ~ /^--/) {
                  next
                }

                if (!active) {
                  if (!match(code, /hl[.]on[[:space:]]*\([[:space:]]*["\047]hyprland[.]start["\047]/)) {
                    next
                  }
                  active = 1
                  depth = 0
                  callback = ""
                  code = substr(code, RSTART)
                }

                quote = ""
                escaped = 0
                for (i = 1; i <= length(code); i++) {
                  character = substr(code, i, 1)
                  following = substr(code, i + 1, 1)

                  if (quote == "" && character == "-" && following == "-") {
                    break
                  }

                  callback = callback character
                  if (quote != "") {
                    if (escaped) {
                      escaped = 0
                    } else if (character == "\\") {
                      escaped = 1
                    } else if (character == quote) {
                      quote = ""
                    }
                    continue
                  }

                  if (character == "\"" || character == "\047") {
                    quote = character
                  } else if (character == "(") {
                    depth++
                  } else if (character == ")") {
                    depth--
                    if (depth == 0) {
                      if (unsafe(callback)) {
                        exit 1
                      }
                      active = 0
                      callback = ""
                      break
                    }
                  }
                }
                callback = callback "\n"
              }

              END {
                if (active) {
                  exit 2
                }
              }
            ' "$file" || return 1
          done
        }

        verify() {
          local label="$1"
          local expected_diagnostic="''${2:-}"
          local output
          if ! output="$({
            unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY
            HOME="$TMPDIR/home" \
              XDG_CONFIG_HOME="$config_home" \
              XDG_RUNTIME_DIR="$runtime_dir" \
              ${hyprlandPkg}/bin/Hyprland --verify-config --i-am-really-stupid \
              -c "$config_home/hypr/hyprland.lua"
          } 2>&1)"; then
            echo "$output" >&2
            fail "$label did not parse"
          fi
          grep -q 'config ok' <<<"$output" || {
            echo "$output" >&2
            fail "$label did not report config ok"
          }
          if [[ -n "$expected_diagnostic" ]]; then
            grep -Fq "$expected_diagnostic" <<<"$output" || {
              echo "$output" >&2
              fail "$label did not report its protected module error"
            }
          fi
        }

        verify_rejected_overlay() {
          local label="$1"
          local expected_diagnostic="$2"
          local output
          if output="$({
            unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY
            HOME="$TMPDIR/home" \
              XDG_CONFIG_HOME="$config_home" \
              XDG_RUNTIME_DIR="$runtime_dir" \
              ${hyprlandPkg}/bin/Hyprland --verify-config --i-am-really-stupid \
              -c "$config_home/hypr/hyprland.lua"
          } 2>&1)"; then
            echo "$output" >&2
            fail "$label must fail closed"
          fi
          grep -Fq "$expected_diagnostic" <<<"$output" || {
            echo "$output" >&2
            fail "$label did not report the rejected overlay"
          }
        }

        : > "$config_home/themes/current/hyprland.lua"
        verify base

        cat > "$config_home/hypr/host.lua" <<'LUA'
    hl.monitor({ output = "eDP-1", disabled = true })
    hl.monitor({
      output = "DP-1",
      disabled = false,
      mode = "preferred",
      position = "auto-right",
      scale = 1,
      transform = 0,
      mirror = "",
    })
    LUA
        verify "generated monitor rule fields"
        cp "$templates/hyprland/.config/hypr/host.lua" "$config_home/hypr/host.lua"

        for theme_dir in "$templates/themes/.config/themes/"*; do
          theme="$(basename "$theme_dir")"
          if [[ -f "$theme_dir/hyprland.lua" ]]; then
            cp "$theme_dir/hyprland.lua" "$config_home/themes/current/hyprland.lua"
          else
            : > "$config_home/themes/current/hyprland.lua"
          fi
          # Each theme composition includes the seeded user.lua and host.lua
          # modules copied above.
          verify "theme $theme with optional overlays"
        done

        printf 'this is not valid Lua\n' > "$config_home/themes/current/hyprland.lua"
        verify "invalid optional theme" "Keystone theme load failed:"
        : > "$config_home/themes/current/hyprland.lua"

        printf 'error("invalid optional user")\n' > "$config_home/hypr/user.lua"
        verify_rejected_overlay "invalid optional user overlay" 'require("user"):'
        cp "$templates/hyprland/.config/hypr/user.lua" "$config_home/hypr/user.lua"

        printf 'error("invalid optional host")\n' > "$config_home/hypr/host.lua"
        verify_rejected_overlay "invalid optional host overlay" 'require("host"):'
        cp "$templates/hyprland/.config/hypr/host.lua" "$config_home/hypr/host.lua"

        find "$templates" -name 'hyprland.conf' -print -quit | grep -q . \
          && fail "legacy Hyprlang compositor entry point remains"
        grep -q 'loadfile(home .. "/.config/themes/current/hyprland.lua")' "$main" \
          || fail "active theme must load through absolute loadfile"
        grep -q 'pcall(chunk)' "$main" || fail "active theme execution must be protected"
        grep -q 'pcall(require, module)' "$main" || fail "optional overlays must use protected require"
        grep -q 'cursor = { no_hardware_cursors = 1 }' "$main" \
          || fail "no_hardware_cursors must use the v0.56 integer contract"
        grep -Fq 'bind("SHIFT + F11", hl.dsp.window.fullscreen({ mode = "fullscreen" }))' "$main" \
          || fail "Shift+F11 must preserve layout-aware fullscreen"
        grep -Fq 'bind("ALT + F11", hl.dsp.window.fullscreen({ mode = "maximized" }))' "$main" \
          || fail "Alt+F11 must preserve layout-aware maximization"
        if grep -E 'F11.*layout_aware = false' "$main"; then
          fail "F11 binds must retain Hyprland 0.56 layout-aware defaults"
        fi
        grep -q 'hl.timer(function()' "$main" || fail "DPMS wake must use a timer callback"
        grep -q 'hl.dispatch(hl.dsp.dpms' "$main" || fail "DPMS wake must dispatch inside the callback"
        grep -q 'timeout = 500, type = "oneshot"' "$main" || fail "DPMS wake timer contract changed"

        for command in ghostty chromium nautilus wofi walker keystone-menu \
          keystone-menu-keybindings keystone-screenshot hyprpicker; do
          grep -E "app \\.\\. .*''${command}" "$main" >/dev/null \
            || fail "graphical launcher $command must run through uwsm app --"
        done

        if grep -RE 'exec-once|import-environment|dbus-update-activation-environment|hyprctl dispatch exit' \
          "$templates/hyprland/.config/hypr"; then
          fail "legacy startup or compositor-native exit remains"
        fi

        # The monitor menu and DPMS hooks must use the Lua IPC surface. Keep
        # this guard scoped to the migrated paths. keystone-context.sh remains
        # outside this migration because its legacy dispatcher set includes
        # movetoworkspacesilent, which has no direct Lua `silent` equivalent.
        monitor_menu=${../..}/modules/home/scripts/keystone-monitor-menu.sh
        legacy_ipc="$(grep -RnE 'hyprctl[[:space:]]+(keyword|dispatch)' \
          "$monitor_menu" ${../..}/pkgs "$templates" \
          | grep -vE ':[0-9]+:[[:space:]]*#' \
          | grep -oE 'hyprctl[[:space:]]+(keyword|dispatch)[^|;&]*' \
          | grep -vE "^hyprctl[[:space:]]+dispatch[[:space:]]+['\"]?hl\\.dsp\\." || true)"
        if [ -n "$legacy_ipc" ]; then
          echo "$legacy_ipc" >&2
          fail "hyprctl takes Lua — use hl.dsp.* dispatchers and hl.* config tables"
        fi
        grep -Fq "hl.monitor({" "$monitor_menu" \
          || fail "monitor menu must build hl.monitor Lua tables"
        hyprctl_help="$(${hyprlandPkg}/bin/hyprctl --help 2>&1 || true)"
        grep -Fq 'eval <code>' <<<"$hyprctl_help" \
          || fail "pinned hyprctl must expose the Lua eval command"

        # Exercise the live-session path against a fake hyprctl. This must not
        # connect to the compositor running the build host's desktop session.
        fake_bin="$TMPDIR/fake-bin"
        hyprctl_record="$TMPDIR/hyprctl-record"
        hyprctl_applied="$TMPDIR/hyprctl-applied"
        notify_record="$TMPDIR/notify-record"
        monitors_fixture="$TMPDIR/monitors.json"
        mkdir -p "$fake_bin"
        cat > "$monitors_fixture" <<'JSON'
    [
      {
        "name": "eDP-1",
        "description": "BOE Internal Panel",
        "width": 1920,
        "height": 1080,
        "refreshRate": 60,
        "scale": 1,
        "transform": 0,
        "x": 0,
        "y": 0,
        "mirrorOf": "none",
        "disabled": false,
        "availableModes": ["1920x1080@60.00Hz"]
      },
      {
        "name": "DP-1",
        "description": "LG External Display",
        "width": 2560,
        "height": 1440,
        "refreshRate": 60,
        "scale": 1,
        "transform": 0,
        "x": 300,
        "y": 200,
        "mirrorOf": "none",
        "disabled": false,
        "availableModes": ["2560x1440@60.00Hz"]
      }
    ]
    JSON
        cat > "$fake_bin/hyprctl" <<'SH'
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    if [[ "$1" == "-j" && "$2" == "monitors" && "$3" == "all" ]]; then
      if [[ -e "$HYPRCTL_APPLIED" && -n "''${HYPRCTL_AFTER_FIXTURE:-}" ]]; then
        cat "$HYPRCTL_AFTER_FIXTURE"
      elif [[ "''${MONITOR_DISABLED:-0}" == "1" ]]; then
        jq 'map(if .name == "eDP-1" then .disabled = true | .width = 0 | .height = 0 | .availableModes = [] else . end)' "$MONITORS_FIXTURE"
      elif [[ "''${MONITOR_MIRRORED:-0}" == "1" ]]; then
        jq 'map(if .name == "DP-1" then .mirrorOf = "eDP-1" else . end)' "$MONITORS_FIXTURE"
      else
        cat "$MONITORS_FIXTURE"
      fi
      exit 0
    fi
    if [[ "$1" == "eval" ]]; then
      printf '%s\n' "$2" > "$HYPRCTL_RECORD"
      touch "$HYPRCTL_APPLIED"
      if [[ "''${HYPRCTL_FAIL:-0}" == "1" ]]; then
        printf 'error: rejected monitor rule\n'
        exit 7
      fi
      printf 'ok\n'
      exit 0
    fi
    printf 'unexpected hyprctl invocation: %s\n' "$*" >&2
    exit 64
    SH
        cat > "$fake_bin/notify-send" <<'SH'
    #!${pkgs.bash}/bin/bash
    printf '%s\n' "$*" >> "$NOTIFY_RECORD"
    SH
        chmod +x "$fake_bin/hyprctl" "$fake_bin/notify-send"

        run_monitor_action() {
          env \
            PATH="$fake_bin:$PATH" \
            MONITORS_FIXTURE="''${HYPRCTL_BEFORE_FIXTURE:-$monitors_fixture}" \
            HYPRCTL_RECORD="$hyprctl_record" \
            HYPRCTL_APPLIED="$hyprctl_applied" \
            NOTIFY_RECORD="$notify_record" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            bash "$monitor_menu" dispatch "$1"
        }

        : > "$notify_record"
        run_monitor_action $'apply-scale\teDP-1\t2'
        grep -Fxq 'hl.monitor({ output = "eDP-1", disabled = false, mode = "1920x1080@60.00", position = "0x0", scale = 2, transform = 0, mirror = "" })' "$hyprctl_record" \
          || fail "scale action did not eval the expected hl.monitor table"
        grep -Fq 'Monitor updated eDP-1 scale set to 2x' "$notify_record" \
          || fail "successful scale action did not notify"

        right_fixture="$TMPDIR/monitors-right.json"
        odd_height_right_fixture="$TMPDIR/monitors-odd-height-right.json"
        below_fixture="$TMPDIR/monitors-below.json"
        mirror_fixture="$TMPDIR/monitors-mirror.json"
        jq 'map(if .name == "DP-1" then .x = 1920 | .y = -180 else . end)' \
          "$monitors_fixture" > "$right_fixture"
        jq 'map(if .name == "eDP-1" then .height = 1081 elif .name == "DP-1" then .x = 1920 | .y = -179 else . end)' \
          "$monitors_fixture" > "$odd_height_right_fixture"
        jq 'map(if .name == "eDP-1" then .x = 620 | .y = 1640 else . end)' \
          "$monitors_fixture" > "$below_fixture"
        jq 'map(if .name == "DP-1" then .mirrorOf = "eDP-1" else . end)' \
          "$monitors_fixture" > "$mirror_fixture"

        : > "$notify_record"
        rm -f "$hyprctl_applied"
        HYPRCTL_AFTER_FIXTURE="$right_fixture" run_monitor_action $'apply-layout\tDP-1\tright-of\teDP-1'
        sed -n '1p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "eDP-1", disabled = false, mode = "1920x1080@60.00", position = "0x0", scale = 1, transform = 0, mirror = "" })' \
          || fail "relative layout action did not declare the target anchor first"
        sed -n '2p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@60.00", position = "1920x-180", scale = 1, transform = 0, mirror = "" })' \
          || fail "relative layout action did not declare the dependent monitor second"

        rm -f "$hyprctl_applied"
        : > "$notify_record"
        HYPRCTL_BEFORE_FIXTURE="$odd_height_right_fixture" \
          HYPRCTL_AFTER_FIXTURE="$odd_height_right_fixture" \
          run_monitor_action $'apply-layout\tDP-1\tright-of\teDP-1'
        sed -n '2p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@60.00", position = "1920x-179", scale = 1, transform = 0, mirror = "" })' \
          || fail "odd-dimension layout did not use the nearest integer-centered position"
        grep -Fq 'Monitor updated DP-1 placed right-of eDP-1' "$notify_record" \
          || fail "nearest integer-centered layout with odd logical dimensions was rejected"

        rm -f "$hyprctl_applied"
        HYPRCTL_AFTER_FIXTURE="$below_fixture" run_monitor_action $'apply-layout\teDP-1\tbelow\tDP-1'
        sed -n '1p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@60.00", position = "300x200", scale = 1, transform = 0, mirror = "" })' \
          || fail "relative layout action did not preserve the target monitor offset"
        sed -n '2p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "eDP-1", disabled = false, mode = "1920x1080@60.00", position = "620x1640", scale = 1, transform = 0, mirror = "" })' \
          || fail "relative layout action ignored the target monitor offset"

        rm -f "$hyprctl_applied"
        HYPRCTL_AFTER_FIXTURE="$mirror_fixture" run_monitor_action $'apply-layout\tDP-1\tmirror\teDP-1'
        sed -n '2p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@60.00", position = "auto", scale = 1, transform = 0, mirror = "eDP-1" })' \
          || fail "mirror action did not set the mirror target"

        rm -f "$hyprctl_applied"
        MONITOR_MIRRORED=1 HYPRCTL_AFTER_FIXTURE="$right_fixture" run_monitor_action $'apply-layout\tDP-1\tright-of\teDP-1'
        sed -n '2p' "$hyprctl_record" \
          | grep -Fxq 'hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@60.00", position = "1920x-180", scale = 1, transform = 0, mirror = "" })' \
          || fail "relative layout action did not clear the mirror target"

        rm -f "$hyprctl_applied"
        : > "$notify_record"
        if HYPRCTL_AFTER_FIXTURE="$monitors_fixture" run_monitor_action $'apply-layout\tDP-1\tright-of\teDP-1'; then
          fail "corner-touching layout reported success"
        fi
        grep -Fq 'Monitor layout failed' "$notify_record" \
          || fail "invalid post-apply geometry did not notify failure"

        run_monitor_action $'disable\teDP-1'
        grep -Fxq 'hl.monitor({ output = "eDP-1", disabled = true })' "$hyprctl_record" \
          || fail "disable action did not eval the disabled monitor table"
        MONITOR_DISABLED=1 run_monitor_action $'enable\teDP-1'
        grep -Fxq 'hl.monitor({ output = "eDP-1", disabled = false, mode = "preferred", position = "auto", scale = 1, transform = 0, mirror = "" })' "$hyprctl_record" \
          || fail "enable action did not explicitly clear the disabled state"

        printf 'not-called\n' > "$hyprctl_record"
        if run_monitor_action $'apply-orientation\teDP-1\t0 }) error("injected") --'; then
          fail "invalid monitor transform was accepted"
        fi
        grep -Fxq 'not-called' "$hyprctl_record" \
          || fail "invalid monitor transform reached hyprctl eval"

        : > "$notify_record"
        if HYPRCTL_FAIL=1 run_monitor_action $'apply-scale\teDP-1\t2'; then
          fail "rejected monitor rule reported success"
        fi
        grep -Fq 'Monitor change failed error: rejected monitor rule' "$notify_record" \
          || fail "rejected monitor rule did not notify failure"
        if grep -Fq 'Monitor updated' "$notify_record"; then
          fail "rejected monitor rule emitted a success notification"
        fi

        saved_monitors="$TMPDIR/saved-monitors.lua"
        monitors_link="$TMPDIR/monitors.lua"
        : > "$saved_monitors"
        ln -s "$saved_monitors" "$monitors_link"
        : > "$notify_record"
        KEYSTONE_HYPRLAND_MONITORS_FILE="$monitors_link" run_monitor_action $'save-layout\teDP-1'
        [[ -L "$monitors_link" ]] \
          || fail "saving a Stow-owned monitor file replaced its symlink"
        grep -Fq 'output = "desc:BOE Internal Panel"' "$saved_monitors" \
          || fail "saved layout did not use the internal panel description"
        grep -Fq 'output = "desc:LG External Display"' "$saved_monitors" \
          || fail "saved layout did not use the external display description"
        [[ "$(grep -n 'output = ' "$saved_monitors" | sed -n '1p')" == *'desc:BOE Internal Panel'* ]] \
          || fail "saved layout did not declare the internal anchor first"
        if grep -Fq 'keystone.desktop.monitors' "$saved_monitors"; then
          fail "saved layout still emits the retired Nix monitor option"
        fi
        grep -Fq "Saved monitor defaults Updated $monitors_link" "$notify_record" \
          || fail "saved layout did not report the Stow-owned destination"

        # Input must be able to rescue a blanked panel. With these off, the
        # only routes back from DPMS off are hypridle's on-resume hook and the
        # lid-open bind — so one broken hook strands the display dark.
        grep -Fq "key_press_enables_dpms = true" "$main" \
          || fail "key presses must wake the display from DPMS off"
        grep -Fq "mouse_move_enables_dpms = true" "$main" \
          || fail "mouse movement must wake the display from DPMS off"

        if ! start_callbacks_are_safe \
          "$templates/hyprland/.config/hypr/hyprland.lua" \
          "$templates/hyprland/.config/hypr/user.lua" \
          "$templates/hyprland/.config/hypr/host.lua"; then
          fail "hyprland.start must not launch applications before the lock gate"
        fi

        unsafe_fixture="$TMPDIR/unsafe-start-callback.lua"
        for unsafe_dispatcher in hl.exec_cmd hl.dsp.exec_cmd hl.exec_raw hl.dsp.exec_raw; do
          cat > "$unsafe_fixture" <<LUA
    hl.on("hyprland.start", function()
      local launch = $unsafe_dispatcher
      launch(
        "unsafe-example"
      )
    end)
    LUA
          if start_callbacks_are_safe "$unsafe_fixture"; then
            fail "hyprland.start guard accepted aliased dispatcher: $unsafe_dispatcher"
          fi
        done
        for unsafe_call in \
          'hl.exec_raw("unsafe-example")' \
          'hl.dsp.exec_raw("unsafe-example")' \
          'os.execute("unsafe-example")' \
          'io.popen("unsafe-example")'; do
          printf 'hl.on("hyprland.start", function()\n  %s\nend)\n' "$unsafe_call" \
            > "$unsafe_fixture"
          if start_callbacks_are_safe "$unsafe_fixture"; then
            fail "hyprland.start guard accepted unsafe callback: $unsafe_call"
          fi
        done

        safe_fixture="$TMPDIR/safe-start-callback.lua"
        cat > "$safe_fixture" <<'LUA'
    hl.on("hyprland.start", function()
      hl.dispatch(hl.dsp.focus({ workspace = 2 }))
    end)
    LUA
        start_callbacks_are_safe "$safe_fixture" \
          || fail "hyprland.start guard rejected compositor-local typed dispatch"
        if grep -R 'WLR_RENDERER_ALLOW_SOFTWARE\|GTK_THEME' "$templates/hyprland/.config/uwsm"; then
          fail "obsolete or runtime-theme-conflicting environment remains"
        fi
        if grep -q '^export HYPR' "$templates/hyprland/.config/uwsm/env"; then
          fail "HYPR variables belong in env-hyprland"
        fi
        grep -q '^export HYPRCURSOR_' "$templates/hyprland/.config/uwsm/env-hyprland" \
          || fail "env-hyprland has no Hyprland-specific variables"
        grep -Fq 'export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-' "$templates/hyprland/.config/uwsm/env" \
          || fail "XDG_DATA_DIRS must have a nonempty default"

        touch "$out"
  ''
