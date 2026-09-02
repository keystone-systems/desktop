# Red/green gate for GitHub issue #390 — gate Walker surfaces and repair
# setup, update, and wifi flows. Each assertion below encodes a requirement
# from engineering issue #391 (ISSUE-REQ-1..8). Ported from ks.systems/os
# during the desktop extraction: script assertions now target
# modules/home/scripts, and the bind assertions target the dotfile
# templates (the settings-generation modules they used to grep were deleted —
# templates are the live config surface now).
{ pkgs }:
pkgs.runCommand "test-desktop-walker-surfaces"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
    ];
  }
  ''
    set -euo pipefail

    repo="${../..}"
    scripts="$repo/modules/home/scripts"
    components="$repo/modules/home/components"
    hyprland_conf="$repo/templates/hyprland/.config/hypr/hyprland.lua"
    default_nix="$scripts/default.nix"
    main_menu="$scripts/keystone-main-menu.sh"
    setup_menu="$scripts/keystone-setup-menu.sh"

    fail() {
      echo "FAIL: $1" >&2
      exit 1
    }

    # The primary surface is Quattro QML. Walker remains available only for
    # the registered subordinate providers checked below.
    if ! grep -F 'bind(mod .. " + Escape", hl.dsp.exec_cmd("omarchy-menu toggle system"))' "$hyprland_conf" >/dev/null; then
      fail "template \$mod+Escape bind must toggle Quattro's System menu"
    fi
    if grep -Fq '"keystone-main"' "$components/launcher.nix" \
      || [[ -e "$components/keystone-main.lua" ]]; then
      fail "the retired Walker root provider must not remain registered or packaged"
    fi

    # Every submenu emitted by a backend, and every menus: provider launched by
    # a script, must resolve to a registered Elephant provider. This catches a
    # whole class of dead menu links instead of naming only today's providers.
    {
      grep -RhoE 'SubMenu: "keystone-[a-z-]+"' "$repo/modules/home" \
        | sed -E 's/.*"(keystone-[a-z-]+)"/\1/'
      grep -RhoE 'menus:keystone-[a-z-]+' "$repo/modules/home" \
        | sed 's/menus://'
    } | sort -u > "$TMPDIR/emitted-providers"
    sed -n '/menuNames = \[/,/  \];/p' "$components/launcher.nix" \
      | grep -oE '"keystone-[a-z-]+"' \
      | tr -d '"' \
      | sort -u > "$TMPDIR/registered-providers"
    while IFS= read -r provider; do
      grep -Fxq "$provider" "$TMPDIR/registered-providers" \
        || fail "Elephant provider $provider is emitted but not registered"
      [[ -f "$components/$provider.lua" ]] \
        || fail "registered Elephant provider $provider has no Lua source"
      grep -Fxq "Name = \"$provider\"" "$components/$provider.lua" \
        || fail "Elephant provider $provider has a mismatched Name"
    done < "$TMPDIR/emitted-providers"

    if grep -Fq 'Parent = "keystone-style"' "$components/keystone-background.lua"; then
      fail "the background provider must not retain the retired Walker Style parent"
    fi
    grep -Fq 'keystone-main-menu") .. " background-json' \
      "$components/keystone-background.lua" \
      || fail "keystone-background must read background-json"

    # ISSUE-REQ-6: Update entry must not be the blocked 'Use nix flake update' placeholder.
    if grep -F 'Use nix flake update for system updates.' "$main_menu" >/dev/null; then
      fail "ISSUE-REQ-6: Update entry must not remain a blocked 'Use nix flake update' placeholder"
    fi

    # ISSUE-REQ-7: Wifi entry must not be the blocked 'not implemented yet' placeholder.
    if grep -F 'Wifi setup is not implemented yet.' "$setup_menu" >/dev/null; then
      fail "ISSUE-REQ-7: Wifi entry must not remain a blocked 'not implemented yet' placeholder"
    fi

    # ISSUE-REQ-7: A keystone-wifi-menu script must exist.
    if [[ ! -f "$scripts/keystone-wifi-menu.sh" ]]; then
      fail "ISSUE-REQ-7: modules/home/scripts/keystone-wifi-menu.sh must exist"
    fi

    # ISSUE-REQ-3/4: Setup controllers MUST NOT source a sibling helper that is
    # not packaged. writeShellScriptBin places each script in its own $out/bin,
    # so a sibling keystone-desktop-config.sh path never resolves at runtime.
    #
    # keystone-update-menu.sh was removed in favour of `ks menu update` — the
    # Rust binary can't accidentally source a sibling path, so it's exempt from
    # this sweep.
    for s in \
      "$scripts/keystone-audio-menu.sh" \
      "$scripts/keystone-monitor-menu.sh" \
      "$scripts/keystone-printer-menu.sh" \
      "$scripts/keystone-package-menu.sh"; do
      if grep -F 'source "''${SCRIPT_DIR}/keystone-desktop-config.sh"' "$s" >/dev/null; then
        fail "ISSUE-REQ-3/4: $(basename "$s") must not source a sibling keystone-desktop-config.sh — helper must be packaged"
      fi
    done

    # ISSUE-REQ-5: Fingerprint menu runtime inputs must include fprintd.
    if ! grep -E 'pkgs\.fprintd' "$default_nix" >/dev/null; then
      fail "ISSUE-REQ-5: default.nix must include pkgs.fprintd in keystoneFingerprintMenu runtimeInputs"
    fi

    touch "$out"
  ''
