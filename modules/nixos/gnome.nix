# Keystone Desktop — GNOME environment (minimal stub).
{
  config,
  lib,
  ...
}:
let
  cfg = config.keystone.desktop;
in
{
  config = lib.mkIf (cfg.enable && cfg.environment == "gnome") {
    services.displayManager.gdm.enable = true;
    services.desktopManager.gnome.enable = true;
    # Warning, not assertion — stubs must evaluate and boot.
    warnings = [
      "keystone.desktop: gnome support is a minimal stub — no keystone theming, menus, or lock integration"
    ];
    # No keystone HM desktop config is applied (the HM tree gates on hyprland).
  };
}
