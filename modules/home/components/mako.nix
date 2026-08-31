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
  config = mkIf (cfg.enable && cfg.environment == "hyprland") {
    # Enable mako service - config symlink is created in theming activation script
    # to ensure proper symlink ordering (theme symlinks must exist first)
    services.mako.enable = mkDefault true;
    systemd.user.services.mako = {
      Unit = {
        Description = "Mako notification daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.mako}";
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.bash
              pkgs.mako
            ]
          }:${config.home.profileDirectory}/bin"
        ];
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
