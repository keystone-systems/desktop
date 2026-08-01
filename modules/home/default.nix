{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
in
{
  imports = [
    ./components
    ./hyprland.nix
    ./scripts
    ./theming
    # Terminal is provided by ks.systems/os (keystone.terminal) via
    # home-manager.sharedModules since 2a9c266. Do not re-import here
    # to avoid duplicate option declarations when both OS and desktop
    # modules are active.
  ];

  options.keystone.desktop = {
    enable = mkEnableOption "Keystone Desktop - Core desktop packages and utilities for Home Manager";

    environment = mkOption {
      type = types.enum [
        "hyprland"
        "gnome"
        "niri"
      ];
      default = "hyprland";
      description = ''
        Desktop environment this Home Manager configuration targets. All
        Hyprland session wiring (user units, menus, scripts, theming) is
        applied only when this is "hyprland".
      '';
    };

    browser = mkOption {
      type = types.str;
      default = "chromium";
      description = "Default browser binary name. Used by the $mod+B keybinding.";
    };

    uhk = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Install the Ultimate Hacking Keyboard agent";
      };
    };

    audio = {
      defaults = {
        sink = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Default output device name to apply at desktop session start.";
        };

        source = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Default input device name to apply at desktop session start.";
        };
      };
    };

    printer = {
      default = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default CUPS printer name to apply at desktop session start.";
      };
    };

    # Top-level Walker main-menu surfaces. Each gates one hard-coded entry in
    # keystone-main-menu's main_json via KEYSTONE_MENU_SHOW_* env vars. Default
    # off; ks.systems/os glue may raise them to keystone.experimental.
    photos.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Show the Photos entry in the Mod+Escape Walker main menu.";
    };

    agents.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Show the Agents entry in the Mod+Escape Walker main menu.";
    };

    # NOTE: no startupLockCommand option. The template hyprland.conf's
    # exec-once calls keystone-startup-lock directly; autostart generation is
    # gone, so an option here would be a silently-ignored knob on a
    # security-critical (fail-closed lock) behavior. Users who want a
    # different lock command edit their seeded hyprland.conf.

    integration = {
      ksPackage = mkOption {
        type = types.nullOr types.package;
        default = pkgs.keystone.ks or null;
        defaultText = literalExpression "pkgs.keystone.ks or null";
        description = ''
          The keystone `ks` CLI package. Menus and scripts that shell out to
          `ks` are omitted when this is null (standalone use without the
          keystone overlay).
        '';
      };

      agenixPackage = mkOption {
        type = types.nullOr types.package;
        default = pkgs.keystone.agenix or null;
        defaultText = literalExpression "pkgs.keystone.agenix or null";
        description = ''
          The agenix CLI package used by the secrets menu. The menu is omitted
          when this is null.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # UHK Agent copies firmware docs from the Nix store into ~/.config/uhk-agent.
    # Those source files are read-only, and the app preserves that mode, which
    # breaks later updates when it tries to refresh docs for the current firmware.
    home.activation.keystoneUhkAgentCacheFix = mkIf cfg.uhk.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        uhk_cache_dir="$HOME/.config/uhk-agent/smart-macro-docs"
        if [ -d "$uhk_cache_dir" ]; then
          ${pkgs.findutils}/bin/find "$uhk_cache_dir" -type d -exec ${pkgs.coreutils}/bin/chmod u+rwx {} +
          ${pkgs.findutils}/bin/find "$uhk_cache_dir" -type f -exec ${pkgs.coreutils}/bin/chmod u+rw {} +
        fi
      ''
    );

    home.packages = optionals cfg.uhk.enable [
      pkgs.uhk-agent
    ];
  };
}
