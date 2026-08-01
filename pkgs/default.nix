# Overlay that provides keystone-desktop packages.
# Receives flake inputs as arguments so that paths and flake references resolve
# correctly when a consumer flake applies the overlay.
{ hyprland }:
let
  # Paths must be captured in `let` BEFORE the overlay function, otherwise they
  # get evaluated in the wrong context when the overlay is applied by a consumer flake
  write-polkit-theme-src = ./write-polkit-theme;
  hyprpolkitagent-src = ./hyprpolkitagent;
  keystone-dpms-wake-src = ./keystone-dpms-wake.nix;
in
final: prev: {
  keystone-desktop = {
    write-polkit-theme = final.callPackage write-polkit-theme-src { };
    hyprpolkitagent = final.callPackage hyprpolkitagent-src { };
    # hyprctl comes from this flake's hyprland input so IPC always matches
    # the compositor this flake pins.
    keystone-dpms-wake = final.callPackage keystone-dpms-wake-src {
      hyprlandPkg = hyprland.packages.${final.stdenv.hostPlatform.system}.hyprland;
    };
  };
}
