{
  config,
  lib,
  pkgs,
  desktopInputs,
  ...
}:
let
  cfg = config.keystone.desktop;
  quattro = import ../../lib/quattro-runtime.nix { inherit pkgs desktopInputs; };
  runtime = quattro.runtimeTree;
in
{
  config = lib.mkIf (cfg.enable && cfg.environment == "hyprland") {
    # The runtime's public commands belong in the interactive profile. Its
    # large tool closure belongs only to the service PATH below.
    home.packages = [ runtime ];
    home.sessionVariables.OMARCHY_PATH = runtime;
    systemd.user.services.omarchy-shell = {
      Unit = {
        Description = "Omarchy Quattro desktop shell";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = [ "${runtime}/bin/omarchy-launch-shell" ];
        Environment = [
          "OMARCHY_PATH=${runtime}"
          "PATH=${
            lib.concatStringsSep ":" [
              "${runtime}/bin"
              "${config.home.profileDirectory}/bin"
              "/run/current-system/sw/bin"
              (lib.makeBinPath quattro.runtimePackages)
            ]
          }"
        ]
        ++ lib.optional (
          cfg.integration.configCheckout != null
        ) "KEYSTONE_CONFIG_CHECKOUT=${cfg.integration.configCheckout}";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
