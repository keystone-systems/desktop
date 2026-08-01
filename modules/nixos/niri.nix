# Keystone Desktop — niri environment (minimal stub).
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.keystone.desktop;
  # nixpkgs gained a programs.niri module; fall back to a bare package +
  # session command if the pinned nixpkgs does not have it.
  hasNiriModule = options.programs ? niri;
in
{
  config = lib.mkIf (cfg.enable && cfg.environment == "niri") (
    lib.mkMerge [
      {
        # Warning, not assertion — stubs must evaluate and boot.
        warnings = [
          "keystone.desktop: niri support is a minimal stub — no keystone theming, menus, or lock integration"
        ];

        # niri has no display manager of its own; greetd owns the session
        # (disjoint with gnome's gdm — every DE branch is mkIf on the enum).
        services.greetd = {
          enable = lib.mkDefault true;
          settings = {
            default_session = {
              command = lib.mkDefault "${pkgs.greetd}/bin/agreety --cmd niri-session";
              user = lib.mkDefault "greeter";
            };
            initial_session = {
              command = lib.mkDefault "niri-session";
              user = lib.mkDefault cfg.user;
            };
          };
        };
      }
      (lib.optionalAttrs hasNiriModule {
        programs.niri.enable = true;
      })
      (lib.optionalAttrs (!hasNiriModule) {
        environment.systemPackages = [ pkgs.niri ];
      })
    ]
  );
}
