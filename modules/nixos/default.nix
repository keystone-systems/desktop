# Keystone Desktop — NixOS-level option surface and environment dispatch.
# Implements REQ-002 (Keystone Desktop)
# See conventions/process.enable-by-default.md (ks.systems/os)
{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
in
{
  # nix-flatpak is imported via flake.nix nixosModules.default (hoisted to
  # avoid _module.args infinite recursion when desktopInputs is used in
  # imports). Each per-DE module below self-gates on cfg.environment.
  imports = [
    ./common.nix
    ./hyprland.nix
    ./gnome.nix
    ./niri.nix
  ];

  options.keystone.desktop = {
    enable = mkEnableOption "Keystone Desktop - Core desktop packages and utilities";

    user = mkOption {
      type = types.str;
      description = "Primary desktop user for the graphical session";
    };

    environment = mkOption {
      type = types.enum [
        "hyprland"
        "gnome"
        "niri"
      ];
      default = "hyprland";
      description = ''
        Desktop environment to configure. "hyprland" is the full keystone
        experience; "gnome" and "niri" are minimal stubs.
      '';
    };

    camera.libcamera.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable WirePlumber discovery of cameras through libcamera. Set this to
        false only on hardware where libcamera prevents WirePlumber from
        stopping cleanly; V4L2 camera discovery remains enabled.
      '';
    };

    obs = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable OBS Studio for screen recording and streaming";
      };
      # TODO: Teach hosts to declare their GPU type and derive this default
      # automatically so desktop systems do not need to set OBS GPU support
      # manually.
      gpuType = mkOption {
        type = types.nullOr (
          types.enum [
            "amd"
            "intel"
            "nvidia"
          ]
        );
        default = null;
        description = ''
          GPU type for hardware-accelerated encoding in OBS.
          - amd: enables VA-API and Vulkan capture plugins
          - intel: enables VA-API plugin
          - nvidia: enables Vulkan capture plugin (NVENC is built into OBS core)
          When null, only PipeWire audio capture is included (no GPU-specific plugins).
          Future desktop hosts SHOULD declare their GPU type so Keystone can
          select this automatically.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # Pass the DE selection down to Home Manager. The homeModules.default
    # import itself stays hoisted in the flake wrapper — only the option
    # value is threaded here.
    home-manager.sharedModules = [
      { keystone.desktop.environment = lib.mkDefault cfg.environment; }
    ];
  };
}
