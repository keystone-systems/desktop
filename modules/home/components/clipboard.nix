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
    # Clipboard manager packages (clipse configuration is in hyprland/autostart.nix and layout.nix)
    home.packages = with pkgs; [
      clipse
      wl-clipboard
      wl-clip-persist
    ];

    systemd.user.services.wl-clip-persist = {
      Unit = {
        Description = "Wayland clipboard persistence";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.wl-clip-persist}/bin/wl-clip-persist --clipboard regular";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.clipse-listen = {
      Unit = {
        Description = "Clipse clipboard history listener";
        PartOf = [ "graphical-session.target" ];
        After = [
          "graphical-session.target"
          "wl-clip-persist.service"
        ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.clipse}/bin/clipse -listen";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

  };
}
