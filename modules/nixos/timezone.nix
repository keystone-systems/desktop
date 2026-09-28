{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.keystone.desktop.timezone;
  overrideFile = cfg.overrideFile;
  apply = pkgs.writeShellApplication {
    name = "keystone-timezone-apply";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = builtins.readFile (
      pkgs.replaceVars ./scripts/timezone-apply.sh {
        overrideFile = lib.escapeShellArg overrideFile;
      }
    );
  };
  menu = pkgs.writeShellApplication {
    name = "keystone-timezone-menu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
      pkgs.polkit
      pkgs.libnotify
    ];
    text = builtins.readFile (
      pkgs.replaceVars ./scripts/timezone-menu.sh {
        overrideFile = lib.escapeShellArg overrideFile;
        applyCommand = lib.escapeShellArg "${apply}/bin/keystone-timezone-apply";
      }
    );
  };
in
{
  options.keystone.desktop.timezone = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.automatic-timezoned.enable;
      description = "Enable the desktop timezone selector when automatic timezone detection is available.";
    };
    overrideFile = lib.mkOption {
      type = lib.types.str;
      default = "${
        config.users.users.${config.keystone.desktop.user}.home
      }/.config/omarchy/timezone-override";
      description = "Editable file containing the primary desktop user's manual timezone; absence selects automatic detection.";
    };
  };

  config = lib.mkIf (config.keystone.desktop.enable && cfg.enable) {
    environment.systemPackages = [
      apply
      menu
    ];

    # The automatic agent must not replace a manual choice, including after reboot.
    systemd.services.automatic-timezoned.unitConfig.ConditionPathExists = "!${overrideFile}";

    systemd.services.keystone-timezone-override = {
      description = "Apply the local timezone override";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${apply}/bin/keystone-timezone-apply";
      };
    };
  };
}
