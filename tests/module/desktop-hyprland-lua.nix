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
