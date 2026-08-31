{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
  devScripts = import ../../../lib/dev-script-link.nix { inherit lib; };
  inherit (devScripts) mkHomeRepoFiles;

  # One name per Elephant menu provider. Every path is a mechanical function of
  # the name, so this list is the only place a menu is registered.
  menuNames = [
    "keystone-main"
    "keystone-learn"
    "keystone-capture"
    "keystone-screenshot"
    "keystone-toggle"
    "keystone-style"
    "keystone-theme"
    "keystone-background"
    "keystone-system"
    "keystone-install"
    "keystone-update"
    "keystone-photos"
    "keystone-agents"
    "keystone-agent-actions"
    "keystone-setup"
    "keystone-hardware"
    "keystone-fingerprint"
    "keystone-monitors"
    "keystone-monitor-actions"
    "keystone-monitor-values"
    "keystone-printer"
    "keystone-wifi"
    "keystone-audio"
    "keystone-audio-devices"
    "keystone-accounts"
    "keystone-secrets"
    "keystone-secret-list"
    "keystone-secret-actions"
    "keystone-account-sections"
    "keystone-account-mailbox"
    "keystone-account-calendar"
    "keystone-account-events"
  ];

  mkMenuFile = name: {
    targetPath = ".config/elephant/menus/${name}.lua";
    relativePath = "modules/home/components/${name}.lua";
    sourcePath = ./. + "/${name}.lua";
  };
in
{
  # walker is imported via flake.nix homeModules.default (hoisted to avoid
  # _module.args infinite recursion when desktopInputs is used in imports)

  config = mkIf (cfg.enable && cfg.environment == "hyprland") (mkMerge [
    (mkHomeRepoFiles {
      inherit config;
      repoFlakeInput = "desktop";
      files = [
        {
          targetPath = ".local/share/applications/keystone-notes.desktop";
          relativePath = "modules/home/components/keystone-notes.desktop";
          sourcePath = ./keystone-notes.desktop;
        }
      ]
      ++ map mkMenuFile menuNames;
    })
    {
      home.packages = [
        pkgs.wofi
        config.programs.walker.package
      ];

      # Runtime integration only: Walker's editable configuration is supplied
      # by the selected Stow package, while Keystone keeps the launcher backend
      # and long-running application service available.
      programs.elephant.enable = true;
      systemd.user.services.walker = {
        Unit = {
          Description = "Walker - Application Runner";
          ConditionEnvironment = "WAYLAND_DISPLAY";
          After = [
            "graphical-session.target"
            "elephant.service"
          ];
          Requires = [ "elephant.service" ];
          Requisite = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${lib.getExe config.programs.walker.package} --gapplication-service";
          Restart = "on-failure";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      systemd.user.services.elephant = {
        Unit = {
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
          Requisite = [ "graphical-session.target" ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      # Wofi as the application launcher
      programs.wofi = {
        enable = false;
        settings = {
          show = "drun";
          width = 600;
          height = 400;
          term = "ghostty";
          prompt = "Search...";
          allow_images = true;
          image_size = 24;
          insensitive = true;
        };
      };

      # Walker launcher using the official home-manager module
      # Walker's editable configuration is owned by the Stow template at
      # templates/walker/.config/walker/config.toml, so the upstream Walker
      # home-manager module stays disabled. Its whole `config` section sits
      # under `mkIf cfg.enable`, which means every option set here rendered
      # nothing: ~200 lines of placeholders and keybinds that never reached
      # disk. Enabling it would also emit xdg.configFile."walker/config.toml"
      # and collide with the Stow package (see the home-stow-collision check).
      #
      # `config.programs.walker.package`, used above for home.packages and the
      # walker.service ExecStart, is an option default and resolves regardless
      # of `enable`.
      programs.walker.enable = false;
    }
  ]);
}
