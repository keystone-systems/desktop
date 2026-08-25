# desktop-main-menu-entries — behavioral gate on the Mod+Escape main menu.
#
# This check does NOT read the module source. It evaluates the HM module across
# the (photos.enable, agents.enable, integration.ksPackage) matrix, takes the
# keystone-main-menu derivation the module actually installs, RUNS it, and
# compares the entry list it prints.
#
# It therefore fails on:
#   * keystone-main-menu not installed (or installed twice) for a cell — the
#     package-level mkIf that killed Mod+Escape entirely when ksPackage = null;
#   * the production wrapper dropping extraEnvSetup — Photos/Agents/Update go
#     missing even though the options are on;
#   * the production wrapper emitting an empty live-checkout `for` loop — the
#     command does not even parse, so main-json exits non-zero.
#
# Build: nix build .#checks.x86_64-linux.desktop-main-menu-entries
{
  pkgs,
  lib,
  self,
  home-manager,
}:
let
  themeSwitch = pkgs.writeShellScriptBin "keystone-theme-switch" ''
    case "$*" in
      "--current") printf '%s\n' tokyo-night ;;
      "--backgrounds --json") printf '%s\n' '{"theme":"tokyo-night","backgrounds":[{"path":"backgrounds/one.jpg","current":true},{"path":"backgrounds/two.jpg","current":false}]}' ;;
      *) exit 2 ;;
    esac
  '';
  mkHome =
    {
      photos,
      agents,
      ks,
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
              # pkgs.hello is a cheap stand-in for the `ks` CLI: main-json never
              # execs it, it only has to be a non-null package.
              ksPackage = if ks then pkgs.hello else null;
              agenixPackage = null;
            };
          };
        }
      ];
    };

  # The command exactly as the module installs it. Exactly-one is part of the
  # contract: zero means the entrypoint was gated away, two means a package is
  # registered both raw and wrapped (a home.packages collision at activation).
  commandOf =
    label: home: name:
    let
      matches = lib.filter (p: lib.getName p == name) home.config.home.packages;
    in
    if lib.length matches == 1 then
      "${lib.head matches}/bin/${name}"
    else
      throw "desktop-main-menu-entries(${label}): expected exactly one home.packages entry named ${name}, found ${toString (lib.length matches)}";

  # The contract, in one place. Mirrors the KEYSTONE_MENU_SHOW_* exports in
  # modules/home/scripts/default.nix, and SPEC.md "Menu System".
  #
  #   Photos  — its option AND `ks`: keystone-photos-menu stays mkIf-gated on
  #             integration.ksPackage, so the entry would open a dead submenu.
  #   Agents  — its option only: keystone-agent-menu is unconditional, its only
  #             external tool being agentctl.
  #   Install — `ks`: the keystone-install provider execs the still-gated
  #             keystone-package-menu.
  #   Update  — `ks`: the entry SPEC.md names verbatim.
  #
  # Everything else is pure walker/hyprland/systemd and must survive a
  # ksPackage = null host, which is the whole point of the Mod+Escape fix.
  entriesFor =
    {
      photos,
      agents,
      ks,
    }:
    [ "Apps" ]
    ++ lib.optional (photos && ks) "Photos"
    ++ lib.optional agents "Agents"
    ++ [
      "Learn"
      "Capture"
      "Toggle"
      "Style"
      "Setup"
    ]
    ++ lib.optional ks "Install"
    ++ [ "Remove" ]
    ++ lib.optional ks "Update"
    ++ [ "System" ];

  cells = [
    {
      photos = false;
      agents = false;
      ks = false;
    }
    # The regression cell: options on, no `ks`. The entries must still be
    # hidden, and the menu must still work.
    {
      photos = true;
      agents = true;
      ks = false;
    }
    {
      photos = false;
      agents = false;
      ks = true;
    }
    {
      photos = true;
      agents = true;
      ks = true;
    }
  ];

  mkCell =
    cell:
    let
      label = "photos=${lib.boolToString cell.photos},agents=${lib.boolToString cell.agents},ks=${lib.boolToString cell.ks}";
      command = commandOf label (mkHome cell) "keystone-main-menu";
      expected = lib.concatStringsSep "," (entriesFor cell);
    in
    ''
      echo "-- ${label} --"
      # env -i: the wrapper's own `export PATH` must supply every tool the
      # script needs. Without scrubbing, this check's own nativeBuildInputs
      # leak in and a wrapper that exports no PATH at all still passes — which
      # is precisely the defect this test exists to catch.
      if ! raw="$(env -i HOME="$HOME" PATH=/var/empty ${command} main-json)"; then
        echo "FAIL(${label}): keystone-main-menu main-json failed to run" >&2
        errors=$((errors + 1))
      elif ! actual="$(printf '%s' "$raw" | ${pkgs.jq}/bin/jq -r '[.[].Text] | join(",")')"; then
        echo "FAIL(${label}): main-json output was not valid JSON" >&2
        errors=$((errors + 1))
      elif [ "$actual" != "${expected}" ]; then
        echo "FAIL(${label}): main menu entry list mismatch" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   $actual" >&2
        errors=$((errors + 1))
      else
        echo "PASS(${label}): ${expected}"
      fi
    '';
in
pkgs.runCommand "desktop-main-menu-entries"
  {
    # jq is referenced by absolute store path inside the cells so it cannot
    # leak into the scrubbed environment under test.
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
    ];
  }
  ''
    set -uo pipefail

    # No display, no session: main-json is pure jq. HOME is set only so the
    # script's own fallbacks resolve inside the sandbox.
    export HOME="$PWD/home"
    mkdir -p "$HOME"

    errors=0

    ${lib.concatStringsSep "\n" (map mkCell cells)}

    echo "-- Style background submenu --"
    command="${
      commandOf "style" (mkHome {
        photos = false;
        agents = false;
        ks = false;
      }) "keystone-main-menu"
    }"
    style="$(env -i HOME="$HOME" PATH="${themeSwitch}/bin" "$command" style-json)"
    test "$(printf '%s' "$style" | ${pkgs.jq}/bin/jq -r '.[1].SubMenu')" = keystone-background
    test "$(printf '%s' "$style" | ${pkgs.jq}/bin/jq -r '.[1].Value')" = background
    backgrounds="$(env -i HOME="$HOME" PATH="${themeSwitch}/bin" "$command" background-json)"
    test "$(printf '%s' "$backgrounds" | ${pkgs.jq}/bin/jq -r '[.[].Text] | join(",")')" = one.jpg,two.jpg
    test "$(printf '%s' "$backgrounds" | ${pkgs.jq}/bin/jq -r '.[0].Value')" = $'background-select\tbackgrounds/one.jpg'

    if [ "$errors" -gt 0 ]; then
      echo "FAIL: $errors main-menu matrix cell(s) wrong" >&2
      exit 1
    fi

    touch "$out"
  ''
