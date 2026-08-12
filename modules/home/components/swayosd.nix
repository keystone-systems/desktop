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
    # SwayOSD for volume/brightness on-screen display
    services.swayosd = {
      enable = mkDefault true;
      topMargin = 0.95; # Near bottom of screen
    };
    systemd.user.services.swayosd = {
      Unit = {
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
    # swayosd package is installed OS-level by ks.systems/desktop's hyprland
    # NixOS module.
  };
}
