# Behavioral gate for the primary Quattro QML menu and its capability flags.
{
  pkgs,
  lib,
  self,
  home-manager,
}:
let
  mkHome =
    {
      photos,
      agents,
      ks,
      agenix,
    }:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.default
        {
          home.username = "testuser";
          home.homeDirectory = "/home/testuser";
          home.stateVersion = "25.05";
          keystone.desktop = {
            enable = true;
            environment = "hyprland";
            photos.enable = photos;
            agents.enable = agents;
            integration = {
              ksPackage = if ks then pkgs.hello else null;
              agenixPackage = if agenix then pkgs.hello else null;
            };
          };
        }
      ];
    };

  cells = [
    {
      photos = false;
      agents = false;
      ks = false;
      agenix = false;
    }
    {
      photos = true;
      agents = true;
      ks = false;
      agenix = false;
    }
    {
      photos = true;
      agents = true;
      ks = true;
      agenix = true;
    }
  ];

  mkCell =
    cell:
    let
      home = mkHome cell;
      environment = lib.concatStringsSep "\n" home.config.systemd.user.services.omarchy-shell.Service.Environment;
      expected = {
        photos = cell.photos && cell.ks;
        agents = cell.agents;
        install = cell.ks;
        update = cell.ks;
        hardware = cell.ks;
        secrets = cell.agenix;
      };
      assertion = name: value: ''
        grep -Fqx 'KEYSTONE_MENU_SHOW_${lib.toUpper name}=${lib.boolToString value}' \
          ${pkgs.writeText "quattro-menu-${name}-environment" environment}
      '';
    in
    lib.concatStringsSep "\n" (lib.mapAttrsToList assertion expected);
in
pkgs.runCommand "desktop-main-menu-entries"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      gnugrep
      jq
    ];
  }
  ''
    set -euo pipefail

    menu=${../../modules/home/quattro-menu.jsonc}

    test "$(jq -r '
      to_entries
      | map(select(.key | contains(".") | not))
      | map(.key)
      | join(",")
    ' "$menu")" = "apps,learn,trigger,style,setup,install,remove,update,about,system"

    jq -e '
      .apps.provider == "apps"
      and .apps.aliases == ["app", "applications"]
      and .setup.aliases == ["settings"]
      and .system.aliases == ["power-menu"]
      and (.["trigger.capture"].aliases | contains(["capture", "screenshot", "screenrecord"]))
    ' "$menu" >/dev/null

    jq -e '
      .["trigger.photos"].when != null
      and .["trigger.agents"].when != null
      and .["trigger.capture.screenrecord"].checked != null
      and .["trigger.toggle.idle-lock"].checked != null
      and .["trigger.toggle.top-bar"].checked != null
      and .["setup.default.agent"].label == "Agent"
      and .["setup.default"].aliases == ["default", "defaults"]
      and .["setup.default.agent"].title == "Default Agent"
      and .["setup.default.agent.codex"].action == "keystone-menu default-agent codex"
      and .["setup.default.agent.hermes"].when == "command -v hermes >/dev/null 2>&1"
      and ([to_entries[] | select(.key | startswith("setup.default.agent.")) | .key | ltrimstr("setup.default.agent.")] == ["agy", "claude", "codex", "copilot", "crush", "grok", "hermes", "omp", "opencode", "ori", "pi"])
      and ([to_entries[] | select(.key | startswith("setup.default.agent.")) | .value.checked] | all(. != null))
      and ([to_entries[] | select(.key | startswith("setup.default.agent.")) | .value.when] | all(. != null))
      and .["remove.managed"].disabled == "true"
    ' "$menu" >/dev/null

    test "$(jq '[to_entries[] | select(.value.action != null and ((.value.icon // "") == ""))] | length' "$menu")" = 0

    jq -r '[to_entries[].value.action? | select(. != null) | split(" ")[0]] | unique[]' "$menu" \
      > "$TMPDIR/action-commands"
    printf '%s\n' keystone-menu > "$TMPDIR/expected-action-commands"
    diff -u "$TMPDIR/expected-action-commands" "$TMPDIR/action-commands"

    if grep -Ein '(^|[^[:alnum:]_])(pacman|yay|sudo)([^[:alnum:]_]|$)|Arch Linux|/(usr|etc)/' "$menu"; then
      echo "FAIL: Quattro menu exposes an Arch or privileged operation" >&2
      exit 1
    fi

    main_menu=${../../modules/home/scripts/keystone-main-menu.sh}
    mkdir -p "$TMPDIR/fake-bin"
    cat > "$TMPDIR/fake-bin/keystone-theme-switch" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$1" in
      --list) printf '%s\n' '{"themes":[]}' ;;
      --backgrounds) printf '%s\n' '{"backgrounds":[]}' ;;
      *) exit 2 ;;
    esac
    EOF
    cat > "$TMPDIR/fake-bin/notify-send" <<'EOF'
    #!${pkgs.runtimeShell}
    test "$#" -eq 2
    printf '%s\t%s\n' "$1" "$2" >> "$NOTIFY_LOG"
    EOF
    chmod +x "$TMPDIR/fake-bin/keystone-theme-switch" "$TMPDIR/fake-bin/notify-send"

    theme_payload="$(PATH="$TMPDIR/fake-bin:$PATH" ${pkgs.bash}/bin/bash "$main_menu" theme-json | jq -r '.[0].Value')"
    background_payload="$(PATH="$TMPDIR/fake-bin:$PATH" ${pkgs.bash}/bin/bash "$main_menu" background-json | jq -r '.[0].Value')"
    NOTIFY_LOG="$TMPDIR/notify.log" PATH="$TMPDIR/fake-bin:$PATH" \
      ${pkgs.bash}/bin/bash "$main_menu" dispatch "$theme_payload"
    NOTIFY_LOG="$TMPDIR/notify.log" PATH="$TMPDIR/fake-bin:$PATH" \
      ${pkgs.bash}/bin/bash "$main_menu" dispatch "$background_payload"
    printf '%s\n' \
      $'Theme\tNo themes were found.' \
      $'Background\tNo wallpapers were found for the current theme.' \
      > "$TMPDIR/expected-notify.log"
    diff -u "$TMPDIR/expected-notify.log" "$TMPDIR/notify.log"

    ${lib.concatStringsSep "\n" (map mkCell cells)}

    touch "$out"
  ''
