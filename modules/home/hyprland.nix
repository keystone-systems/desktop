{
  config,
  lib,
  pkgs,
  desktopInputs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
  hyprpaperPkg = desktopInputs.hyprpaper.packages.${pkgs.stdenv.hostPlatform.system}.hyprpaper;
  keystoneLockPkg =
    desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.keystone-lock;
in
{
  # Session wiring only. Hyprland/hypridle/hyprlock/hyprpaper/waybar settings
  # are NOT generated here — editable configuration comes from the user's
  # stowed dotfiles (seed with `nix run .#seed-dotfiles`). Nix owns the
  # binaries (OS-level) and these hand-written user units.
  config = mkIf (cfg.enable && cfg.environment == "hyprland") {
    home.packages = [ keystoneLockPkg ];

    # UWSM session target fix: greetd starts wayland-session-envelope@ but not
    # wayland-session@ which is what binds to graphical-session.target.
    # hypridle and other services depend on graphical-session.target, so we need
    # to ensure wayland-session@ is started when the envelope starts.
    # See: https://github.com/hyprwm/Hyprland/issues/9342
    systemd.user.targets."wayland-session-envelope@Hyprland" = {
      Unit = {
        Wants = [ "wayland-session@Hyprland.target" ];
      };
    };

    systemd.user.services.hypridle = {
      Unit = {
        Description = "Hyprland idle manager";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service.ExecStart = "${pkgs.hypridle}/bin/hypridle";
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.hyprpaper = {
      Unit = {
        Description = "Hyprland wallpaper daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service.ExecStart = "${hyprpaperPkg}/bin/hyprpaper";
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.waybar = {
      Unit = {
        Description = "Waybar status bar";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.waybar}/bin/waybar";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
